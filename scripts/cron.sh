#!/bin/sh
# Sylius' periodic commands, every CRON_INTERVAL seconds: cancel unpaid orders
# and remove expired carts (their periods are Sylius settings). Writes a
# heartbeat file for the healthcheck.
set -eu
cd /app
while :; do
    su-exec www-data php bin/console --no-interaction sylius:cancel-unpaid-orders || echo "cancel-unpaid-orders failed" >&2
    su-exec www-data php bin/console --no-interaction sylius:remove-expired-carts || echo "remove-expired-carts failed" >&2
    touch /tmp/cron-heartbeat
    sleep "${CRON_INTERVAL}"
done
