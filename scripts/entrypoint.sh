#!/bin/sh
# shellcheck disable=SC2016,SC2153 # PHP code in single quotes; variables set by compose
# Entrypoint of the Sylius containers (php, worker, cron, setup): builds the
# connection strings from the stack's variables (URL-encoding passwords), then
# runs the command through the PHP image's entrypoint.
set -eu

urlencode() { php -r 'echo rawurlencode($argv[1]);' "$1"; }

DATABASE_URL="mysql://$(urlencode "${DB_USER}"):$(urlencode "${DB_PASSWORD}")@${DB_HOST}:${DB_PORT}/${DB_NAME}?serverVersion=${DB_SERVER_VERSION}&charset=utf8mb4"
export DATABASE_URL

# SMTP_SECURE: ssl = SMTPS (smtps://), tls or empty = STARTTLS when offered
# (smtp://), none = never TLS. No SMTP_HOST: mails are discarded.
if [ -n "${SMTP_HOST:-}" ]; then
    scheme=smtp query=""
    case "$(echo "${SMTP_SECURE:-}" | tr '[:upper:]' '[:lower:]')" in
        ssl) scheme=smtps ;;
        none) query="?auto_tls=false" ;;
    esac
    auth=""
    if [ -n "${SMTP_USER:-}" ]; then
        auth="$(urlencode "${SMTP_USER}"):$(urlencode "${SMTP_PASSWORD:-}")@"
    fi
    MAILER_DSN="${scheme}://${auth}${SMTP_HOST}:${SMTP_PORT}${query}"
else
    MAILER_DSN="null://null"
fi
export MAILER_DSN

exec docker-php-entrypoint "$@"
