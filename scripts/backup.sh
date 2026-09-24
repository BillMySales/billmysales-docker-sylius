#!/bin/bash
# Backups of the Sylius database, uploads (media) and keys (JWT, payment
# encryption: without them, stored payment credentials can't be decrypted).
#
#   backup.sh            # loop: back up now, then every BACKUP_INTERVAL_HOURS
#   backup.sh now        # one backup
#   backup.sh list       # list backups
#   backup.sh restore <timestamp>   # restore database, media and keys
#   backup.sh health     # healthcheck: last backup is recent enough
#
# Files: /backups/<timestamp>-db.sql.gz and /backups/<timestamp>-files.tar.gz
# (media/ and keys/), deleted after BACKUP_KEEP_DAYS days.
set -euo pipefail
# Backups contain password hashes, keys and customer data: owner-only files.
umask 077

BACKUP_DIR=/backups
DATA_DIR=/data

# Credentials in a temp file, not on the command line.
DB_CNF="$(mktemp)"
trap 'rm -f "${DB_CNF}"' EXIT
cat > "${DB_CNF}" <<CNF
[client]
host=${DB_HOST}
user=${DB_USER}
password=${DB_PASSWORD}
CNF

backup() {
    local ts tmp
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    echo "==> Backup ${ts}"
    tmp="${BACKUP_DIR}/.${ts}"
    mariadb-dump --defaults-extra-file="${DB_CNF}" --single-transaction --quick \
        --routines --triggers --events "${DB_NAME}" | gzip > "${tmp}-db.sql.gz"
    tar -C "${DATA_DIR}" -czf "${tmp}-files.tar.gz" media keys
    mv "${tmp}-db.sql.gz" "${BACKUP_DIR}/${ts}-db.sql.gz"
    mv "${tmp}-files.tar.gz" "${BACKUP_DIR}/${ts}-files.tar.gz"
    find "${BACKUP_DIR}" -maxdepth 1 -name '*-db.sql.gz' -mtime +"${BACKUP_KEEP_DAYS}" -delete
    find "${BACKUP_DIR}" -maxdepth 1 -name '*-files.tar.gz' -mtime +"${BACKUP_KEEP_DAYS}" -delete
    ls -lh "${BACKUP_DIR}/${ts}"-*
}

restore() {
    local ts="${1:?Usage: backup.sh restore <timestamp> (see: backup.sh list)}"
    local db="${BACKUP_DIR}/${ts}-db.sql.gz" files="${BACKUP_DIR}/${ts}-files.tar.gz"
    [ -f "${db}" ] && [ -f "${files}" ] || { echo "Backup ${ts} not found" >&2; exit 1; }
    echo "==> Restoring database from ${db}"
    # Drop the tables first: nothing created after the backup remains.
    mariadb --defaults-extra-file="${DB_CNF}" --batch --skip-column-names -e \
        "SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = '${DB_NAME}'" |
        { echo 'SET FOREIGN_KEY_CHECKS = 0;'; cat; } | mariadb --defaults-extra-file="${DB_CNF}" "${DB_NAME}"
    gunzip -c "${db}" | mariadb --defaults-extra-file="${DB_CNF}" "${DB_NAME}"
    echo "==> Restoring media and keys from ${files}"
    find "${DATA_DIR}/media" "${DATA_DIR}/keys" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    tar -C "${DATA_DIR}" -xzpf "${files}"
    echo "==> Restored ${ts}"
}

case "${1:-loop}" in
    now) backup ;;
    list) find "${BACKUP_DIR}" -maxdepth 1 -name '*-db.sql.gz' -printf '%f\n' | sed 's/-db\.sql\.gz$//' | sort ;;
    restore) restore "${2:-}" ;;
    health)
        [ -n "$(find "${BACKUP_DIR}" -maxdepth 1 -name '*-db.sql.gz' \
            -mmin -$(( BACKUP_INTERVAL_HOURS * 60 + 60 )) 2>/dev/null)" ]
        ;;
    loop)
        while :; do
            backup || echo "Backup failed" >&2
            sleep $(( BACKUP_INTERVAL_HOURS * 3600 ))
        done
        ;;
    *) echo "Unknown command: $1" >&2; exit 2 ;;
esac
