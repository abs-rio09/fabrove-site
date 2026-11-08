#!/usr/bin/env bash
# =============================================================================
# FabRove restore script
#
# Restores the local site (compose project "clothing-shop") from one backup
# set made by backup.sh.
#
# Usage:
#   scripts/restore.sh 20261108-201500          # timestamp of the backup set
#   scripts/restore.sh                          # lists available backups
#
# What it does (only after you type "yes"):
#   1. Verifies both backup files (gzip -t / tar -tzf)
#   2. Stops the wordpress container (db keeps running)
#   3. Re-creates the WordPress database and imports the dump
#   4. Empties clothing-shop_wp_data and extracts the files archive into it
#   5. Starts wordpress again
#
# WARNING: this OVERWRITES the current database and WordPress files.
# Only clothing-shop_* volumes are touched; fabrove_* volumes never are.
# Passwords come from .env and are passed via environment variables only.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_PROJECT="clothing-shop"
WP_VOLUME="clothing-shop_wp_data"
BACKUP_DIR="$HOME/Fabrove/backups"
ALPINE_IMAGE="alpine:3.20"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

env_value() {
  local key="$1" line
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 || true)"
  [[ -n "$line" ]] || die "$key not found in $ENV_FILE"
  line="${line#*=}"
  line="${line%$'\r'}"
  if [[ "$line" =~ ^\"(.*)\"$ || "$line" =~ ^\'(.*)\'$ ]]; then
    line="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$line"
}

compose() { docker compose -p "$COMPOSE_PROJECT" -f "$PROJECT_DIR/docker-compose.yml" "$@"; }

# ---- Pick the backup set ----------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 YYYYMMDD-HHMMSS"
  echo "Available backup sets in $BACKUP_DIR:"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'db-*.sql.gz' -printf '%f\n' 2>/dev/null \
    | sed -E 's/^db-(.*)\.sql\.gz$/  \1/' | sort -r
  exit 1
fi

TS="$1"
[[ "$TS" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "timestamp must look like 20261108-201500"
DB_FILE="$BACKUP_DIR/db-$TS.sql.gz"
FILES_FILE="$BACKUP_DIR/files-$TS.tar.gz"
[[ -s "$DB_FILE" ]]    || die "missing or empty: $DB_FILE"
[[ -s "$FILES_FILE" ]] || die "missing or empty: $FILES_FILE"
[[ -f "$ENV_FILE" ]]   || die ".env not found at $ENV_FILE"

# ---- Verify before touching anything ----------------------------------------
log "Verifying backup set $TS ..."
gzip -t "$DB_FILE"              || die "database dump is corrupt"
TAR_LIST="$(tar -tzf "$FILES_FILE")" || die "files archive is corrupt"
printf '%s\n' "$TAR_LIST" | grep -x 'html/wp-config.php' >/dev/null \
  || die "files archive does not look like a WordPress backup"
unset TAR_LIST

DB_CONTAINER="$(docker ps -q \
  --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter "label=com.docker.compose.service=db")"
[[ -n "$DB_CONTAINER" ]] || die "db container of project '$COMPOSE_PROJECT' is not running"

# ---- Confirmation -----------------------------------------------------------
cat <<EOF

  This will OVERWRITE the current FabRove site with backup $TS:
    database : $DB_FILE
    files    : $FILES_FILE -> volume $WP_VOLUME

  Current data will be lost unless you made a fresh backup first
  (run scripts/backup.sh).

EOF
read -r -p 'Type "yes" to continue: ' answer
[[ "$answer" == "yes" ]] || { echo "Aborted. Nothing was changed."; exit 1; }

DB_NAME="$(env_value DB_NAME)"
DB_USER="$(env_value DB_USER)"
MYSQL_PWD="$(env_value DB_ROOT_PASSWORD)"
export MYSQL_PWD
# DB name/user go into SQL below; reject anything unusual.
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected characters in DB_NAME"
[[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected characters in DB_USER"

# Make sure wordpress comes back even if something below fails.
trap 'log "Starting wordpress again ..."; compose start wordpress >/dev/null || true' EXIT

# ---- 1. Stop wordpress ------------------------------------------------------
log "Stopping wordpress ..."
compose stop wordpress

# ---- 2. Database ------------------------------------------------------------
log "Re-creating database '$DB_NAME' and importing dump ..."
docker exec -i -e MYSQL_PWD "$DB_CONTAINER" mariadb -u root <<SQL
DROP DATABASE IF EXISTS \`$DB_NAME\`;
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
SQL
gzip -dc "$DB_FILE" \
  | docker exec -i -e MYSQL_PWD "$DB_CONTAINER" mariadb -u root "$DB_NAME"
unset MYSQL_PWD

# ---- 3. Files ---------------------------------------------------------------
log "Restoring files into $WP_VOLUME ..."
docker run --rm -i \
  -v "$WP_VOLUME":/var/www/html \
  "$ALPINE_IMAGE" \
  sh -c 'find /var/www/html -mindepth 1 -delete && tar -xzf - -C /var/www' \
  < "$FILES_FILE"

# ---- 4. Start wordpress (via EXIT trap) -------------------------------------
log "Restore of $TS finished."
