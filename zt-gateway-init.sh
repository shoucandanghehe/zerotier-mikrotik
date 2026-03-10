#!/bin/sh

set -eu

FORWARD_CHAIN="ZT-GATEWAY-FORWARD"
POSTROUTING_CHAIN="ZT-GATEWAY-POSTROUTING"

log() {
  printf '%s\n' "=> gateway: $*" >&2
}

warn() {
  printf '%s\n' "==> gateway: $*" >&2
}

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      return 0
      ;;
  esac
  return 1
}

fail() {
  warn "$*"
  if is_true "${ZT_GATEWAY_FAIL_HARD:-1}"; then
    warn "stopping container because gateway initialization failed"
    kill -TERM 1 2>/dev/null || true
  fi
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

iface_exists() {
  ip link show dev "$1" >/dev/null 2>&1
}

match_iface_pattern() {
  iface=$1
  pattern=$2

  case "$pattern" in
    *+)
      prefix=${pattern%+}
      case "$iface" in
        "$prefix"*)
          return 0
          ;;
      esac
      ;;
  esac

  case "$iface" in
    $pattern)
      return 0
      ;;
  esac

  return 1
}

get_wait_timeout() {
  timeout=${ZT_GATEWAY_WAIT_TIMEOUT:-60}
  case "$timeout" in
    ''|*[!0-9]*)
      fail "ZT_GATEWAY_WAIT_TIMEOUT must be an integer number of seconds"
      ;;
  esac
  printf '%s\n' "$timeout"
}

wait_for_iface() {
  kind=$1
  timeout=$2
  elapsed=0

  while :; do
    iface=''

    if [ "$kind" = "wan" ]; then
      iface=$(resolve_wan_iface_once)
    else
      iface=$(resolve_lan_iface_once)
    fi

    if [ -n "$iface" ]; then
      printf '%s\n' "$iface"
      return 0
    fi

    if [ "$timeout" -ne 0 ] && [ "$elapsed" -ge "$timeout" ]; then
      return 1
    fi

    if [ "$kind" = "wan" ]; then
      log "waiting for ZeroTier interface"
    else
      log "waiting for RouterOS-side interface"
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done
}

resolve_wan_iface_once() {
  if [ -n "${ZT_WAN_IF:-}" ]; then
    if iface_exists "${ZT_WAN_IF}"; then
      printf '%s\n' "${ZT_WAN_IF}"
    fi
    return 0
  fi

  pattern=${ZT_WAN_IF_PATTERN:-zt*}
  first=''
  count=0

  for iface in $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1); do
    [ "$iface" = "lo" ] && continue

    if match_iface_pattern "$iface" "$pattern"; then
      count=$((count + 1))
      if [ -z "$first" ]; then
        first=$iface
      fi
    fi
  done

  if [ "$count" -gt 1 ]; then
    warn "multiple ZeroTier interfaces match pattern ${pattern}; using ${first}"
  fi

  if [ -n "$first" ]; then
    printf '%s\n' "$first"
  fi
}

resolve_lan_iface_once() {
  if [ -n "${ZT_LAN_IF:-}" ]; then
    if iface_exists "${ZT_LAN_IF}"; then
      printf '%s\n' "${ZT_LAN_IF}"
    fi
    return 0
  fi

  default_iface=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')
  if [ -n "$default_iface" ] && [ "$default_iface" != "${ZT_WAN_IF_RESOLVED}" ] && [ "$default_iface" != "lo" ]; then
    printf '%s\n' "$default_iface"
    return 0
  fi

  pattern=${ZT_WAN_IF_PATTERN:-zt*}
  for iface in $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1); do
    [ "$iface" = "lo" ] && continue
    [ "$iface" = "${ZT_WAN_IF_RESOLVED}" ] && continue
    if match_iface_pattern "$iface" "$pattern"; then
      continue
    fi
    printf '%s\n' "$iface"
    return 0
  done
}

ip_to_int() {
  addr=$1
  old_ifs=$IFS
  IFS=.
  set -- $addr
  IFS=$old_ifs

  [ "$#" -eq 4 ] || return 1

  for octet in "$@"; do
    case "$octet" in
      ''|*[!0-9]*)
        return 1
        ;;
    esac
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done

  printf '%s\n' "$((($1 << 24) + ($2 << 16) + ($3 << 8) + $4))"
}

int_to_ip() {
  value=$1
  printf '%s.%s.%s.%s\n' \
    "$(((value >> 24) & 255))" \
    "$(((value >> 16) & 255))" \
    "$(((value >> 8) & 255))" \
    "$((value & 255))"
}

normalize_cidr() {
  cidr=$1
  ip=${cidr%/*}
  prefix=${cidr#*/}

  [ "$ip" != "$cidr" ] || fail "invalid CIDR: ${cidr}"

  case "$prefix" in
    ''|*[!0-9]*)
      fail "invalid CIDR prefix: ${cidr}"
      ;;
  esac

  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || fail "invalid CIDR prefix: ${cidr}"

  ip_value=$(ip_to_int "$ip") || fail "invalid IPv4 address: ${cidr}"

  if [ "$prefix" -eq 0 ]; then
    mask=0
  else
    mask=$(((0xffffffff << (32 - prefix)) & 0xffffffff))
  fi

  network=$((ip_value & mask))
  printf '%s/%s\n' "$(int_to_ip "$network")" "$prefix"
}

append_unique_word() {
  list=$1
  word=$2

  case " $list " in
    *" $word "*)
      printf '%s\n' "$list"
      ;;
    *)
      if [ -n "$list" ]; then
        printf '%s %s\n' "$list" "$word"
      else
        printf '%s\n' "$word"
      fi
      ;;
  esac
}

normalize_cidr_list() {
  input=$1
  output=''

  for raw in $(printf '%s' "$input" | tr ',' ' '); do
    [ -n "$raw" ] || continue
    normalized=$(normalize_cidr "$raw")
    output=$(append_unique_word "$output" "$normalized")
  done

  printf '%s\n' "$output"
}

detect_connected_subnets() {
  iface=$1
  output=''

  for cidr in $(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}'); do
    normalized=$(normalize_cidr "$cidr")
    output=$(append_unique_word "$output" "$normalized")
  done

  printf '%s\n' "$output"
}

exclude_cidr_list() {
  list=$1
  excluded=$2
  output=''

  for cidr in $list; do
    case " $excluded " in
      *" $cidr "*)
        log "skipping NAT for excluded subnet ${cidr}"
        ;;
      *)
        output=$(append_unique_word "$output" "$cidr")
        ;;
    esac
  done

  printf '%s\n' "$output"
}

ipt() {
  iptables -w 5 "$@"
}

ensure_chain() {
  table=$1
  chain=$2
  parent=$3

  if ! ipt -t "$table" -nL "$chain" >/dev/null 2>&1; then
    ipt -t "$table" -N "$chain" || fail "failed to create ${table} chain ${chain}"
    log "created ${table} chain ${chain}"
  fi

  if ! ipt -t "$table" -C "$parent" -j "$chain" >/dev/null 2>&1; then
    ipt -t "$table" -I "$parent" 1 -j "$chain" || fail "failed to attach ${chain} to ${table}/${parent}"
    log "attached ${chain} to ${table}/${parent}"
  fi

  ipt -t "$table" -F "$chain" || fail "failed to flush ${table} chain ${chain}"
}

enable_ip_forward() {
  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf '0')" != "1" ]; then
    printf '1' > /proc/sys/net/ipv4/ip_forward || fail "failed to enable net.ipv4.ip_forward"
  fi
  log "IPv4 forwarding enabled"
}

require_cmd ip
require_cmd iptables
require_cmd awk

wait_timeout=$(get_wait_timeout)

ZT_WAN_IF_RESOLVED=$(wait_for_iface wan "$wait_timeout") || fail "could not determine ZeroTier interface"
ZT_LAN_IF_RESOLVED=$(wait_for_iface lan "$wait_timeout") || fail "could not determine RouterOS-side interface"

if [ "$ZT_WAN_IF_RESOLVED" = "$ZT_LAN_IF_RESOLVED" ]; then
  fail "RouterOS-side interface and ZeroTier interface resolved to the same device: ${ZT_WAN_IF_RESOLVED}"
fi

wan_addr=$(ip -o -4 addr show dev "$ZT_WAN_IF_RESOLVED" scope global 2>/dev/null | awk 'NR==1 {print $4}')

log "selected ZeroTier interface: ${ZT_WAN_IF_RESOLVED}${wan_addr:+ (${wan_addr})}"
log "selected RouterOS-side interface: ${ZT_LAN_IF_RESOLVED}"

enable_ip_forward

ensure_chain filter "$FORWARD_CHAIN" FORWARD

ipt -t filter -A "$FORWARD_CHAIN" -i "$ZT_LAN_IF_RESOLVED" -o "$ZT_WAN_IF_RESOLVED" -j ACCEPT \
  || fail "failed to allow ${ZT_LAN_IF_RESOLVED} -> ${ZT_WAN_IF_RESOLVED} forwarding"
log "allowed forwarding from ${ZT_LAN_IF_RESOLVED} to ${ZT_WAN_IF_RESOLVED}"

if is_true "${ZT_ALLOW_ZT_TO_LAN:-1}"; then
  ipt -t filter -A "$FORWARD_CHAIN" -i "$ZT_WAN_IF_RESOLVED" -o "$ZT_LAN_IF_RESOLVED" -j ACCEPT \
    || fail "failed to allow ${ZT_WAN_IF_RESOLVED} -> ${ZT_LAN_IF_RESOLVED} forwarding"
  log "allowed forwarding from ${ZT_WAN_IF_RESOLVED} to ${ZT_LAN_IF_RESOLVED}"
else
  ipt -t filter -A "$FORWARD_CHAIN" -i "$ZT_WAN_IF_RESOLVED" -o "$ZT_LAN_IF_RESOLVED" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
    || fail "failed to allow return traffic from ${ZT_WAN_IF_RESOLVED} to ${ZT_LAN_IF_RESOLVED}"
  log "allowed RELATED,ESTABLISHED traffic from ${ZT_WAN_IF_RESOLVED} to ${ZT_LAN_IF_RESOLVED}"
fi

ensure_chain nat "$POSTROUTING_CHAIN" POSTROUTING

if is_true "${ZT_ENABLE_MASQUERADE:-1}"; then
  raw_subnets=${ZT_MASQ_SOURCE_SUBNETS:-auto}
  if [ "$raw_subnets" = "auto" ] || [ -z "$raw_subnets" ]; then
    nat_subnets=$(detect_connected_subnets "$ZT_LAN_IF_RESOLVED")
    log "auto-detected NAT source subnets: ${nat_subnets:-none}"
  else
    nat_subnets=$(normalize_cidr_list "$raw_subnets")
  fi

  excluded_subnets=$(normalize_cidr_list "${ZT_NO_MASQ_SOURCE_SUBNETS:-}")
  nat_subnets=$(exclude_cidr_list "$nat_subnets" "$excluded_subnets")

  if [ -n "$nat_subnets" ]; then
    for subnet in $nat_subnets; do
      ipt -t nat -A "$POSTROUTING_CHAIN" -s "$subnet" -o "$ZT_WAN_IF_RESOLVED" -j MASQUERADE \
        || fail "failed to add MASQUERADE rule for ${subnet}"
      log "enabled MASQUERADE for ${subnet} via ${ZT_WAN_IF_RESOLVED}"
    done
  else
    log "MASQUERADE enabled but no source subnets were selected"
  fi
else
  log "MASQUERADE disabled"
fi

log "gateway initialization complete"
