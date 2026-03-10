#!/bin/sh

set -eu

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      return 0
      ;;
  esac
  return 1
}

log() {
  printf '%s\n' "=> gateway: $*"
}

mkdir -p /dev/net
if [ -e /dev/net/tun ]; then
  chmod 766 /dev/net/tun
fi

if is_true "${ZT_GATEWAY_MODE:-0}"; then
  log "gateway mode enabled"
  /usr/local/bin/zt-gateway-init.sh &
else
  log "gateway mode disabled"
fi

exec /usr/local/bin/zt-upstream-entrypoint.sh "$@"
