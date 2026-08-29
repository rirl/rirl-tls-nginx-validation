FROM nginx:1.28-alpine

RUN apk add --no-cache bash openssl coreutils python3

COPY scripts/cert-status.bash /usr/local/bin/cert-status
COPY scripts/container-entrypoint.bash /usr/local/bin/container-entrypoint

RUN chmod 0755 /usr/local/bin/cert-status /usr/local/bin/container-entrypoint

ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
