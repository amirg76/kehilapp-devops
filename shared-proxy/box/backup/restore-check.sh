#!/usr/bin/env bash
# Proves a backup can be read. Runs on the PC, which holds the private key.
#   restore-check.sh <box-....tar.gpg> [--mongo]
# Decrypts into a temporary flat folder, checks every hash, opens both SQLite
# files and lists the archives. --mongo also restores into a throwaway mongo:7.
# The folder holds plain secrets, so it is emptied at the end, pass or fail.
#
# Anyone with the public key can write a valid-looking file, and backups are not
# signed. Before trusting one, compare its date and size with the nightly Telegram
# line. Only the named parts are extracted, so a forged file cannot write elsewhere.
set -euo pipefail
umask 077
F=${1:?usage: restore-check.sh <file> [--mongo]}
MONGO=${2:-}
PARTS="clinicdemo.sqlite clinicdemo-html.tar.gz kehilapp.archive.gz trading-journal.db trading-files.tar.gz config.tar.gz MANIFEST.sha256"
PY=python3
"$PY" -c '' 2>/dev/null || PY=python
W=$(mktemp -d)
RESTORE=t-box-restore

finish() {
  local rc=$?
  docker rm -f -v "$RESTORE" >/dev/null 2>&1 || true
  rm -f "${W:?}"/* && rmdir "$W"
  if [ "$rc" = 0 ]; then echo "RESTORE CHECK PASSED"; else echo "RESTORE CHECK FAILED"; fi
  exit "$rc"
}
trap finish EXIT

has() { # archive, text: a whole listing into a file, so grep cannot cut tar short
  tar -tzf "$W/$1" > "$W/listing.txt"
  grep -c "$2" "$W/listing.txt" > /dev/null || { echo "$1 has no $2"; return 1; }
}

echo "file: $(basename "$F"), $(wc -c < "$F") bytes"
# shellcheck disable=SC2086
gpg --batch --quiet --decrypt "$F" | tar -C "$W" --no-same-owner -xf - $PARTS
for p in $PARTS; do
  [ -f "$W/$p" ] && [ ! -L "$W/$p" ] || { echo "$p is not a plain file"; exit 1; }
done
(cd "$W" && sha256sum --quiet -c MANIFEST.sha256)
echo "hashes: ok"

for db in clinicdemo.sqlite trading-journal.db; do
  "$PY" - "$W/$db" <<'PY'
import os
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
state = con.execute("PRAGMA integrity_check").fetchone()[0]
tables = con.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
print(f"{os.path.basename(sys.argv[1])}: {state}, {tables} tables")
con.close()
sys.exit(0 if state == "ok" and tables > 0 else 1)
PY
done

for t in clinicdemo-html trading-files config; do
  echo "$t: $(tar -tzf "$W/$t.tar.gz" | wc -l) entries"
done
has clinicdemo-html.tar.gz wp-config.php
has config.tar.gz kehilapp/
echo "key files: present"

if [ "$MONGO" = --mongo ]; then
  # Git Bash would rewrite /tmp/... into a Windows path on the way to docker.
  export MSYS_NO_PATHCONV=1
  docker run -d --network none --name "$RESTORE" mongo:7 >/dev/null
  for i in $(seq 1 30); do docker exec "$RESTORE" mongosh --quiet --eval 1 >/dev/null 2>&1 && break; sleep 1; done
  docker exec -i "$RESTORE" mongorestore --quiet --archive --gzip < "$W/kehilapp.archive.gz"
  docker exec "$RESTORE" mongosh --quiet kehilapp_demo --eval \
    'db.getCollectionNames().sort().forEach(c => print(c + ": " + db[c].countDocuments()))'
fi
