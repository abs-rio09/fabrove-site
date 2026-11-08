#!/usr/bin/env bash
# =============================================================================
# FabRove backup script
#
# Backs up the local WordPress + WooCommerce site (compose project
# "clothing-shop"):
#   1. Database  -> ~/Fabrove/backups/db-YYYYMMDD-HHMMSS.sql.gz
#   2. Files     -> ~/Fabrove/backups/files-YYYYMMDD-HHMMSS.tar.gz
#   3. Verifies both archives (gzip -t / tar -tzf) and that they are not empty
#   4. Rotates: keeps only the newest 7 of each type, deletes older ones
#
# Safety rules:
#   - The data volumes (clothing-shop_db_data, clothing-shop_wp_data) are only
#     READ. The wp volume is mounted ":ro"; the database is read via
#     mariadb-dump --single-transaction.
#   - fabrove_db_data / fabrove_wp_data (old, abandoned site) are never touched.
#   - Passwords are read from .env and handed to the container through an
#     environment variable (MYSQL_PWD). They are never printed or written
#     to any file.
#   - Rotation only deletes files in ~/Fabrove/backups whose names exactly
#     match db-YYYYMMDD-HHMMSS.sql.gz or files-YYYYMMDD-HHMMSS.tar.gz.
# =============================================================================
set -euo pipefail

# ---- Settings ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_PROJECT="clothing-shop"
WP_VOLUME="clothing-shop_wp_data"
BACKUP_DIR="$HOME/Fabrove/backups"
KEEP=7
ALPINE_IMAGE="alpine:3.20"

TS="$(date +%Y%m%d-%H%M%S)"
DB_FILE="$BACKUP_DIR/db-$TS.sql.gz"
FILES_FILE="$BACKUP_DIR/files-$TS.tar.gz"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# Read one KEY=value from .env without sourcing the file (nothing is printed).
env_value() {
  local key="$1" line
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 || true)"
  [[ -n "$line" ]] || die "$key not found in $ENV_FILE"
  line="${line#*=}"
  line="${line%$'\r'}"
  # strip optional surrounding quotes
  if [[ "$line" =~ ^\"(.*)\"$ || "$line" =~ ^\'(.*)\'$ ]]; then
    line="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$line"
}

# Human-readable file size
size_of() { du -h "$1" | cut -f1; }

# ---- Pre-flight checks ------------------------------------------------------
command -v docker >/dev/null || die "docker not found"
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE"

DB_NAME="$(env_value DB_NAME)"
DB_USER="$(env_value DB_USER)"
MYSQL_PWD="$(env_value DB_PASSWORD)"
export MYSQL_PWD   # passed into the container by name only (docker exec -e MYSQL_PWD)

# Find the running db container of THIS compose project only.
DB_CONTAINER="$(docker ps -q \
  --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
  --filter "label=com.docker.compose.service=db")"
[[ -n "$DB_CONTAINER" ]] || die "db container of project '$COMPOSE_PROJECT' is not running"

docker volume inspect "$WP_VOLUME" >/dev/null 2>&1 || die "volume $WP_VOLUME not found"

# ---- 1. Backup directory ----------------------------------------------------
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
umask 077   # backup files readable only by the current user

# Write to *.partial first; rename only after success. A failed run therefore
# leaves at most a *.partial file, which rotation never counts or deletes.
DB_TMP="$DB_FILE.partial"
FILES_TMP="$FILES_FILE.partial"

# ---- 2. Database dump -------------------------------------------------------
log "Dumping database '$DB_NAME' ..."
docker exec -i -e MYSQL_PWD "$DB_CONTAINER" \
  mariadb-dump --single-transaction --quick --routines --triggers \
  --no-tablespaces --default-character-set=utf8mb4 \
  -u "$DB_USER" "$DB_NAME" \
  | gzip -9 > "$DB_TMP"
unset MYSQL_PWD

# ---- 3. Files archive (volume mounted read-only) ----------------------------
log "Archiving $WP_VOLUME (/var/www/html, read-only) ..."
docker run --rm \
  -v "$WP_VOLUME":/var/www/html:ro \
  "$ALPINE_IMAGE" \
  tar -czf - -C /var/www html \
  > "$FILES_TMP"

# ---- 4. Verify --------------------------------------------------------------
log "Verifying archives ..."
[[ -s "$DB_TMP" ]]    || die "database dump is empty: $DB_TMP"
[[ -s "$FILES_TMP" ]] || die "files archive is empty: $FILES_TMP"

gzip -t "$DB_TMP" || die "database dump is corrupt: $DB_TMP"
# A real dump ends with "-- Dump completed"; make sure it is not truncated.
# (Output is captured first: piping into "grep -q" would close the pipe early
#  and, with pipefail, make the producer look like it failed.)
DB_TAIL="$(gzip -dc "$DB_TMP" | tail -n 5)"
[[ "$DB_TAIL" == *"Dump completed"* ]] \
  || die "database dump looks incomplete: $DB_TMP"

TAR_LIST="$(tar -tzf "$FILES_TMP")" || die "files archive is corrupt: $FILES_TMP"
FILE_COUNT="$(printf '%s\n' "$TAR_LIST" | grep -c .)" || true
[[ "$FILE_COUNT" -gt 0 ]] || die "files archive has no entries: $FILES_TMP"
printf '%s\n' "$TAR_LIST" | grep -x 'html/wp-config.php' >/dev/null \
  || die "files archive does not contain html/wp-config.php: $FILES_TMP"
unset TAR_LIST

mv "$DB_TMP" "$DB_FILE"
mv "$FILES_TMP" "$FILES_FILE"

echo "    db    : $(size_of "$DB_FILE")  $DB_FILE"
echo "    files : $(size_of "$FILES_FILE")  $FILES_FILE  ($FILE_COUNT entries)"

# ---- 5. Rotation: keep newest $KEEP of each type ----------------------------
# Only exact names like db-20261108-201500.sql.gz / files-...tar.gz in
# $BACKUP_DIR itself (no subfolders). Names sort chronologically.
rotate() {
  local regex="$1" f
  local -a all=()
  while IFS= read -r f; do all+=("$f"); done < <(
    find "$BACKUP_DIR" -maxdepth 1 -type f -printf '%f\n' \
      | grep -E "$regex" | sort
  )
  local excess=$(( ${#all[@]} - KEEP ))
  (( excess > 0 )) || return 0
  for f in "${all[@]:0:excess}"; do
    log "Rotating out old backup: $f"
    rm -f -- "$BACKUP_DIR/$f"
  done
}
rotate '^db-[0-9]{8}-[0-9]{6}\.sql\.gz$'
rotate '^files-[0-9]{8}-[0-9]{6}\.tar\.gz$'

# ---- 6. Summary -------------------------------------------------------------
echo "Backup OK [$TS]: database $(size_of "$DB_FILE") + files $(size_of "$FILES_FILE") -> $BACKUP_DIR"
