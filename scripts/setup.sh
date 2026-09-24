#!/bin/sh
# shellcheck disable=SC2016 # PHP code in single quotes
# Installs or upgrades Sylius on every `docker compose up`; safe to repeat.
# Runs as root (volumes' owners), Sylius commands as www-data:
# - Keys in the `keys` volume, generated once: JWT keypair (API) and the
#   payment encryption key. Back them up (see backup.sh).
# - Empty database: `sylius:install:database` (schema, no sample data);
#   otherwise the pending Doctrine migrations (a new SYLIUS_VERSION).
# - app:stack-setup (image/overlay/src/Command): admin user and store
#   settings (see there).
# - public/ (assets of the image) copied to Caddy's `public` volume when the
#   image's build id changes.
set -eu
cd /app

console() { su-exec www-data php bin/console --no-interaction "$@"; }

for _ in $(seq 60); do
    php -r 'try { new PDO("mysql:host=" . getenv("DB_HOST") . ";port=" . getenv("DB_PORT"), getenv("DB_USER"), getenv("DB_PASSWORD")); } catch (Exception $e) { exit(1); }' && break
    sleep 2
done

echo "==> Keys"
mkdir -p "$(dirname "${JWT_SECRET_KEY}")" "$(dirname "${SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH}")"
chown -R www-data:www-data "${KEYS_DIR}"
chmod 700 "${KEYS_DIR}"
console lexik:jwt:generate-keypair --skip-if-exists
if [ ! -s "${SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH}" ]; then
    console sylius:payment:generate-key
fi

# Separate assignment: with `set -e`, a failing check aborts setup here.
installed="$(php -r '
    $pdo = new PDO("mysql:host=" . getenv("DB_HOST") . ";port=" . getenv("DB_PORT") . ";dbname=" . getenv("DB_NAME"), getenv("DB_USER"), getenv("DB_PASSWORD"));
    echo $pdo->query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = \"sylius_channel\"")->fetchColumn();')"
if [ "${installed}" = 0 ]; then
    echo "==> Installing the database (Sylius ${SYLIUS_VERSION})"
    console sylius:install:database
else
    echo "==> Migrations"
    console doctrine:migrations:migrate --allow-no-migration
fi

echo "==> Admin user and store settings"
console app:stack-setup

# Uploads written by PHP (www-data), read by Caddy.
chown -R www-data:www-data public/media

# Caddy mounts the uploads volume at /srv/public/media, inside the (read-only)
# public volume: the mount point must exist there.
mkdir -p /srv/public/media

build="$(cat public/.build)"
if [ "$(cat /srv/public/.build 2>/dev/null || true)" != "${build}" ]; then
    echo "==> Public files for Caddy (${build})"
    find /srv/public -mindepth 1 -maxdepth 1 ! -name media -exec rm -rf {} +
    tar -C public --exclude=./media --exclude=./.build -cf - . | tar -C /srv/public -xf -
    # Build id last: an interrupted copy is repeated.
    cp public/.build /srv/public/.build
fi

echo "==> Done: Sylius ${SYLIUS_VERSION}"
echo "    Shop:  ${SYLIUS_URL}"
echo "    Admin: ${SYLIUS_URL}/admin (${SYLIUS_ADMIN_EMAIL})"
