ARG ZT_UPSTREAM=zerotier/zerotier:latest
FROM ${ZT_UPSTREAM}

ENTRYPOINT ["/bin/sh", "-c", "\
    mkdir -p /dev/net; \
    if [ -e /dev/net/tun ]; then chmod 766 /dev/net/tun; fi; \
    exec /entrypoint.sh \"$@\" \
    ", "--"]
