#!/usr/bin/env bash
# Nightly encrypted backup of the shared box, stored off the box in Cloudflare R2.
# Runs ON the box as deploy, started by box-backup.timer. The box holds only the
# public key: a stolen box cannot read earlier backups. Prints sizes and steps only.
set -euo pipefail
umask 077
OPS=${BOX_OPS:-/opt/box-ops}
OPT=${BOX_OPT:-/opt}
# shellcheck disable=SC1091
. "$OPS/backup.conf"   # R2_ENDPOINT R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY TELEGRAM_*

STEP=start
# A SIGKILL skips the trap below and would leave plain secrets behind. The work
# folder sits in the mode-700 ops folder, not /tmp: docker must see the same path
# for the mongodump mount, so PrivateTmp is not an option here.
for old in "$OPS"/tmp.*; do
  [ -d "$old" ] || continue
  rm -f "$old"/* && rmdir "$old"
done
W=$(mktemp -d -p "$OPS")
NAME=box-$(date -u +%Y%m%d-%H%M%S).tar.gpg
PARTS="clinicdemo.sqlite clinicdemo-html.tar.gz kehilapp.archive.gz trading-journal.db trading-files.tar.gz config.tar.gz"

finish() {
  local rc=$?
  # The folder is flat, so no recursive delete: plain secrets live here for minutes.
  rm -f "${W:?}"/* && rmdir "$W"
  # Same key as the unit's OnFailure alert, so one failure sends one message.
  [ "$rc" = 0 ] || bash "$OPS/box-alert.sh" "box backup FAILED at step: $STEP" box-backup.service || true
  exit "$rc"
}
trap finish EXIT
trap 'exit 143' TERM

# printf is a shell builtin and curl reads the login from stdin, so the secret
# never appears in a process list.
r2() {
  printf 'user = "%s:%s"\n' "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" \
    | curl -sS --fail -m 900 -K - --aws-sigv4 'aws:amz:auto:s3' "$@"
}

at_least() { # file, bytes: an empty dump must not count as a backup
  [ "$(wc -c < "$1")" -ge "$2" ] || { echo "$1 is too small"; return 1; }
}

tolerant() { # tar exits 1 when a file changed while it was read: not a failure
  local rc=0
  "$@" || rc=$?
  [ "$rc" -le 1 ]
}

STEP=clinicdemo-database
# SQLite's own backup call: a plain copy of a file being written can be torn.
docker exec -u www-data clinicdemo-web php -r '
  $s = new SQLite3("/var/www/html/wp-content/database/.ht.sqlite", SQLITE3_OPEN_READONLY);
  $d = new SQLite3("/tmp/box-backup.sqlite");
  exit($s->backup($d) ? 0 : 1);' </dev/null
docker exec -u www-data clinicdemo-web sh -c 'cat /tmp/box-backup.sqlite; rm -f /tmp/box-backup.sqlite' </dev/null > "$W/clinicdemo.sqlite"
at_least "$W/clinicdemo.sqlite" 100000

STEP=clinicdemo-files
tolerant docker exec -u www-data clinicdemo-web tar -C /var/www/html --exclude=./wp-content/database/.ht.sqlite -czf - . </dev/null > "$W/clinicdemo-html.tar.gz"
at_least "$W/clinicdemo-html.tar.gz" 100000

STEP=kehilapp-database
# Atlas free has no backup of its own. The address goes through a mode-600 file,
# never the command line. Procedure proven by a restore on 3.11.2026 (runbook 00).
uri=$(grep -m1 '^MONGO_URI=' "$OPT/kehilapp/.env" | cut -d= -f2- | tr -d "\"'")
printf 'uri: "%s"\n' "${uri:?MONGO_URI missing}" > "$W/dump.yaml"
unset uri
docker run --rm --user "$(id -u):$(id -g)" -v "$W":/w mongo:7 \
  mongodump --quiet --config=/w/dump.yaml --db=kehilapp_demo --archive=/w/kehilapp.archive.gz --gzip </dev/null
rm -f "$W/dump.yaml"
at_least "$W/kehilapp.archive.gz" 1000

STEP=trading-desk
python3 - "$OPT/trading-desk/data/journal.db" "$W/trading-journal.db" <<'PY'
import sqlite3
import sys

src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()
src.close()
PY
at_least "$W/trading-journal.db" 4096
tolerant tar -C "$OPT/trading-desk" --exclude='data/journal.db*' -czf "$W/trading-files.tar.gz" data settings.json

STEP=config
tar -C "$OPT" -czf "$W/config.tar.gz" clinicdemo/.env kehilapp/.env trading-desk/.env \
  shared-proxy/.env shared-proxy/Caddyfile shared-proxy/sites

STEP=encrypt
# shellcheck disable=SC2086
(cd "$W" && sha256sum $PARTS > MANIFEST.sha256)
# shellcheck disable=SC2086
tar -C "$W" -cf - $PARTS MANIFEST.sha256 \
  | gpg --batch --quiet --trust-model always --compress-algo none \
      --recipient-file "$OPS/backup-public.asc" --encrypt --output "$W/$NAME"

STEP=upload
SHA=$(sha256sum "$W/$NAME" | cut -d' ' -f1)
URL="$R2_ENDPOINT/$R2_BUCKET/$NAME"
r2 -o /dev/null -H "x-amz-content-sha256: $SHA" -T "$W/$NAME" "$URL"

STEP=verify
SIZE=$(wc -c < "$W/$NAME")
LEN=$(r2 -I "$URL" | tr -d '\r' | awk 'tolower($1) == "content-length:" {print $2}')
[ "$LEN" = "$SIZE" ] || { echo "stored $LEN bytes, sent $SIZE"; exit 1; }

STEP=done
echo "stored $NAME, $SIZE bytes"
# A message every night: silence is the alarm when the box itself is down.
bash "$OPS/box-alert.sh" "box backup ok: $NAME, $((SIZE / 1024)) KB"
