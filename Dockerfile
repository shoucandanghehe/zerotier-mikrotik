ARG ZT_UPSTREAM=zerotier/zerotier:latest
FROM ${ZT_UPSTREAM}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends iptables; \
    rm -rf /var/lib/apt/lists/*; \
    mv /entrypoint.sh /usr/local/bin/zt-upstream-entrypoint.sh; \
    ln -s /usr/local/bin/zt-upstream-entrypoint.sh /entrypoint.sh

COPY zt-entrypoint.sh /usr/local/bin/zt-entrypoint.sh
COPY zt-gateway-init.sh /usr/local/bin/zt-gateway-init.sh

RUN chmod +x /usr/local/bin/zt-entrypoint.sh /usr/local/bin/zt-gateway-init.sh

ENTRYPOINT ["/usr/local/bin/zt-entrypoint.sh"]
