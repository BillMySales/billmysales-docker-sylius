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

# Symfony only answers to the host of SYLIUS_URL, SYLIUS_EXTRA_HOSTS (comma
# separated) and loopback names (Caddy's healthcheck): Sylius builds links
# from the request's Host, and a password reset requested with a forged Host
# mailed a valid reset link to that host.
SYMFONY_TRUSTED_HOSTS="$(php -r '
    $hosts = array_filter(array_map("trim", explode(",", (string) getenv("SYLIUS_EXTRA_HOSTS"))));
    $hosts[] = (string) parse_url((string) getenv("SYLIUS_URL"), PHP_URL_HOST);
    array_push($hosts, "localhost", "127.0.0.1");
    echo implode(",", array_map(fn ($h) => "^" . preg_quote($h) . "\$", array_unique(array_filter($hosts))));')"
export SYMFONY_TRUSTED_HOSTS

exec docker-php-entrypoint "$@"
