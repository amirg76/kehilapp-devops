#!/usr/bin/env bash
# Runs the real backup-box.sh, box-alert.sh and restore-check.sh with real gpg,
# tar, curl and SQLite against fake-r2.py. Only `docker` is a stub here.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
R=$D/test/run-$(date +%s)
PORT=$((20000 + RANDOM % 20000))
mkdir -p "$R/ops" "$R/opt" "$R/tmp" "$R/bin" "$R/r2" "$R/gnupg" "$R/fake/html/wp-content"
chmod 700 "$R/gnupg"
export GNUPGHOME=$R/gnupg TMPDIR=$R/tmp BOX_OPS=$R/ops BOX_OPT=$R/opt
export FAKE=$R/fake TELEGRAM_API=http://127.0.0.1:$PORT PATH=$R/bin:$PATH
MARK=SECRETMARKER-1234567890
R2KEY=test-key-id
R2SECRET=R2SECRETVALUE-abcdefghij
TGTOKEN=TGTOKENVALUE-abcdefghij
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1: got [$2] want [$3]"; fail=$((fail + 1)); fi; }

echo "== fixtures"
gpg --batch --quiet --passphrase '' --quick-generate-key 'box test <test@example.invalid>' future-default default never 2>/dev/null
gpg --batch --armor --export test@example.invalid > "$R/ops/backup-public.asc"
cp "$D/backup-box.sh" "$D/box-alert.sh" "$R/ops/"
cat > "$R/ops/backup.conf" <<EOF
R2_ENDPOINT="http://127.0.0.1:$PORT"
R2_BUCKET="box-backups"
R2_ACCESS_KEY_ID="$R2KEY"
R2_SECRET_ACCESS_KEY="$R2SECRET"
TELEGRAM_BOT_TOKEN="$TGTOKEN"
TELEGRAM_CHAT_ID="42"
HC_BACKUP_URL="http://127.0.0.1:$PORT/hc-ping/box-backup"
EOF
mkdir -p "$R/opt/clinicdemo" "$R/opt/kehilapp" "$R/opt/trading-desk/data" "$R/opt/shared-proxy/sites"
for t in clinicdemo trading-desk shared-proxy; do echo "PASS_WORD=$MARK" > "$R/opt/$t/.env"; done
# Built from parts on purpose: a literal user:password@host here trips push-time
# secret scanners, though the "password" is only the fake marker above.
SCHEME=mongodb+srv
echo "MONGO_URI=$SCHEME://u:$MARK@cluster.example/kehilapp_demo?a=b" > "$R/opt/kehilapp/.env"
echo '{}' > "$R/opt/trading-desk/settings.json"
echo '[]' > "$R/opt/trading-desk/data/x-brief.json"
echo ':80' > "$R/opt/shared-proxy/Caddyfile"
echo 'site' > "$R/opt/shared-proxy/sites/a.caddy"
python - "$R/opt/trading-desk/data/journal.db" "$FAKE/clinic.sqlite" <<'PY'
import sqlite3, sys
for p, rows in ((sys.argv[1], 300), (sys.argv[2], 9000)):
    c = sqlite3.connect(p)
    c.execute("create table t(a text)")
    c.executemany("insert into t values (?)", [("x" * 40,)] * rows)
    c.commit()
PY
echo '<?php' > "$FAKE/html/wp-config.php"
head -c 300000 /dev/urandom > "$FAKE/html/wp-content/blob.bin"

cat > "$R/bin/python3" <<'EOF'
#!/usr/bin/env bash
exec python "$@"
EOF
cat > "$R/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/docker-args.log"
[ "$1" = exec ] && [ -e "$FAKE/container-down" ] && { echo 'No such container' >&2; exit 1; }
case "$*" in
  *'php -r'*) exit 0 ;;
  *'sh -c'*) cat "$FAKE/clinic.sqlite" ;;
  exec*tar*) tar -C "$FAKE/html" -czf - . ;;
  *mongodump*)
    while [ $# -gt 0 ]; do [ "$1" = -v ] && w=${2%:/w}; shift; done
    grep -q '^uri: "mongodb+srv://' "$w/dump.yaml" || { echo 'no uri' >&2; exit 1; }
    if [ -e "$FAKE/mongo-empty" ]; then : > "$w/kehilapp.archive.gz"
    elif [ -e "$FAKE/real-archive" ]; then cp "$FAKE/real-archive" "$w/kehilapp.archive.gz"
    else head -c 5000 /dev/urandom > "$w/kehilapp.archive.gz"; fi ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$R/bin/python3" "$R/bin/docker"
# restore-check --mongo needs the real docker: the stub hands those calls over.
if [ -n "${REAL_ARCHIVE:-}" ]; then
  cp "$REAL_ARCHIVE" "$FAKE/real-archive"
  REALD=$(PATH=${PATH#*:} command -v docker)
  sed -i "2i case \"\$1\" in rm|cp) exec \"$REALD\" \"\$@\";; run) case \"\$*\" in *mongodump*) ;; *) exec \"$REALD\" \"\$@\";; esac;; exec) case \"\$2\" in t-box-restore) exec \"$REALD\" \"\$@\";; esac;; esac" "$R/bin/docker"
fi

python "$D/test/fake-r2.py" "$PORT" "$R2KEY" "$R2SECRET" "$R/r2" &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 2

tg() { grep -c "$1" "$R/r2/telegram.log" 2>/dev/null || true; }
objs() { ls "$R/r2" | grep -c '^box-' || true; }
hc() { grep -c '^/hc-ping/box-backup$' "$R/r2/hc.log" 2>/dev/null || true; }
left() { echo $(($(ls -A "$R/tmp" | wc -l) + $(ls -d "$R"/ops/tmp.* 2>/dev/null | wc -l))); }
# Each case is a new failure: forget the hour-long repeat filter.
run() { rm -f "$R/ops/.alert-box-backup.service"; bash "$R/ops/backup-box.sh" > "$R/out.txt" 2>&1; echo $?; }
# Builds a validly encrypted bundle from a good one, after a change in folder $2.
forge() { # good file, output file, shell command run inside the extracted folder
  local d; d=$(mktemp -d)
  gpg --batch --quiet --decrypt "$1" | tar -C "$d" -xf -
  (cd "$d" && eval "$3")
  # Plain member names, exactly like backup-box.sh, and a fresh output every time.
  rm -f "$2"
  (cd "$d" && tar -cf - *) | gpg --batch --quiet --trust-model always --recipient-file "$R/ops/backup-public.asc" --encrypt --output "$2"
  rm -f "$d"/*; rmdir "$d"
}

echo "== 1 success"
ok "exit" "$(run)" 0
ok "one object stored" "$(objs)" 1
ok "telegram ok" "$(tg 'box backup ok')" 1
ok "healthchecks ping after the verified upload" "$(hc)" 1
ok "temp folder gone" "$(left)" 0
F=$(ls "$R"/r2/box-* | head -1)
ok "no secret in the encrypted file" "$(grep -c "$MARK" "$F")" 0
ok "no secret in the output" "$(grep -cE "$MARK|$R2SECRET|$TGTOKEN" "$R/out.txt")" 0
ok "no secret in docker arguments" "$(grep -cE "$MARK|$R2SECRET" "$FAKE/docker-args.log")" 0
bash "$D/restore-check.sh" "$F" ${REAL_ARCHIVE:+--mongo} > "$R/restore.txt" 2>&1; ok "restore check" "$?" 0
sed 's/^/   /' "$R/restore.txt" | grep -v '^   $' | cut -c1-70
ok "restore left nothing" "$(left)" 0

echo "== 2 tampered backup is refused"
cp "$F" "$R/tampered.gpg"; printf 'X' | dd of="$R/tampered.gpg" bs=1 seek=4000 conv=notrunc 2>/dev/null
bash "$D/restore-check.sh" "$R/tampered.gpg" > "$R/restore2.txt" 2>&1; rc=$?
ok "tampered fails" "$([ "$rc" != 0 ] && echo yes || echo no)" yes
ok "tamper left nothing" "$(left)" 0

echo "== 2b validly encrypted but wrong inside: each must fail the check"
SUMS='sha256sum clinicdemo.sqlite clinicdemo-html.tar.gz kehilapp.archive.gz trading-journal.db trading-files.tar.gz config.tar.gz > MANIFEST.sha256'
chk() { # label, command in the folder, the reason the check must give
  forge "$F" "$R/forged.gpg" "$2"
  bash "$D/restore-check.sh" "$R/forged.gpg" > "$R/forged.txt" 2>&1; rc=$?
  ok "$1: refused" "$([ "$rc" != 0 ] && echo refused || echo accepted)" refused
  ok "$1: for the right reason" "$(grep -cE "$3" "$R/forged.txt" | sed 's/^[1-9].*/found/')" found
  ok "$1: says FAILED" "$(grep -c 'RESTORE CHECK FAILED' "$R/forged.txt")" 1
  ok "$1: left nothing" "$(left)" 0
}
forge "$F" "$R/control.gpg" ':'
bash "$D/restore-check.sh" "$R/control.gpg" > "$R/control.txt" 2>&1
ok "control: an unchanged forge passes" "$?" 0
chk "changed part" 'printf x >> trading-journal.db' 'trading-journal.db: FAILED'
chk "missing part" "rm -f config.tar.gz; $SUMS 2>/dev/null; grep -v config.tar.gz MANIFEST.sha256 > m; mv m MANIFEST.sha256" 'Not found in archive'
chk "no wp-config" "mkdir h; echo a > h/other; tar -czf clinicdemo-html.tar.gz -C h other; rm -f h/other; rmdir h; $SUMS" 'has no wp-config'
chk "broken sqlite, true hash" "head -c 5000 /dev/urandom > trading-journal.db; $SUMS" 'not a database|malformed'
forge "$F" "$R/extra.gpg" 'echo owned > extra-file'
bash "$D/restore-check.sh" "$R/extra.gpg" > "$R/extra.txt" 2>&1
ok "an extra member is ignored, check passes" "$?" 0
ok "extra left nothing" "$(left)" 0

echo "== 2c plain secrets from a killed run are swept"
mkdir "$R/ops/tmp.stale"; echo "$MARK" > "$R/ops/tmp.stale/config.tar.gz"
ok "exit" "$(run)" 0
ok "stale folder gone" "$(left)" 0

echo "== 2d healthchecks unreachable: the backup still succeeds"
sed -i "s|^HC_BACKUP_URL=.*|HC_BACKUP_URL=\"http://127.0.0.1:9/hc-ping/box-backup\"|" "$R/ops/backup.conf"
oks=$(tg 'box backup ok')
ok "exit" "$(run)" 0
ok "telegram ok sent" "$(tg 'box backup ok')" "$((oks + 1))"
ok "says the ping failed" "$(grep -c 'healthchecks ping failed' "$R/out.txt")" 1
ok "no ping recorded" "$(hc)" 2
sed -i "s|^HC_BACKUP_URL=.*|HC_BACKUP_URL=\"http://127.0.0.1:$PORT/hc-ping/box-backup\"|" "$R/ops/backup.conf"

echo "== 3 wrong R2 secret"
sed -i 's/R2SECRETVALUE-abcdefghij/WRONGWRONG/' "$R/ops/backup.conf"
before=$(objs)
ok "exit" "$(run)" 22
ok "alert names the step" "$(tg 'FAILED at step: upload')" 1
ok "nothing new stored" "$(objs)" "$before"
ok "temp folder gone" "$(left)" 0
bash "$R/ops/box-alert.sh" "unit box-backup.service failed on the shared box" box-backup.service
ok "the unit's alert does not repeat the script's" "$(tg 'unit box-backup.service failed')" 0
sed -i 's/WRONGWRONG/R2SECRETVALUE-abcdefghij/' "$R/ops/backup.conf"

echo "== 4 stored object is short"
echo truncate > "$R/r2/mode"
ok "exit" "$(run)" 1
ok "alert names the step" "$(tg 'FAILED at step: verify')" 1
rm -f "$R/r2/mode"

echo "== 5 empty kehilapp dump"
: > "$FAKE/mongo-empty"; before=$(objs)
ok "exit" "$(run)" 1
ok "alert names the step" "$(tg 'FAILED at step: kehilapp-database')" 1
ok "nothing stored" "$(objs)" "$before"
ok "temp folder gone" "$(left)" 0
rm -f "$FAKE/mongo-empty"

echo "== 6 container down"
: > "$FAKE/container-down"
ok "exit" "$(run)" 1
ok "alert names the step" "$(tg 'FAILED at step: clinicdemo-database')" 1
rm -f "$FAKE/container-down"
# Cases 1 and 2c pinged, 2d could not, 3 to 6 failed: a failed run must never ping.
ok "pings only from the two good runs" "$(hc)" 2

echo "== 7 repeat alerts are dropped for an hour, other keys pass"
for i in 1 2 3; do bash "$R/ops/box-alert.sh" "unit cron failed" cron.service; done
ok "one message" "$(tg 'unit cron failed')" 1
bash "$R/ops/box-alert.sh" "unit other failed" other.service
ok "other key" "$(tg 'unit other failed')" 1

echo "== 8 telegram down does not fail the backup"
# Wait for the fake server to be gone: on Windows a fixed 1 s sleep sometimes
# left it answering, and the two checks below failed on a send that worked.
kill $SRV; wait $SRV 2>/dev/null || true
out=$(bash "$R/ops/box-alert.sh" "x" unsent.key); ok "alert exit" "$?" 0
ok "says so" "$(echo "$out" | grep -c 'telegram send failed')" 1
ok "a failed send does not silence the next hour" "$(ls -A "$R/ops" | grep -c 'alert-unsent')" 0

echo "RESULT pass=$pass fail=$fail  run folder: $R"
