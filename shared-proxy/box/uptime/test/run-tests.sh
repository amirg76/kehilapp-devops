#!/usr/bin/env bash
# Tests box-uptime.sh with a stand-in curl and a stand-in box-alert.sh.
# Run in Linux (bash, GNU date):  bash test/run-tests.sh
# Prints statuses only.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/../box-uptime.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if [ "$1" = 0 ]; then pass=$((pass+1)); echo "PASS $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }

mkdir -p "$T/bin" "$T/ops" "$T/state"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/args.log"
if [[ " $* " == *" -K - "* ]]; then cat >> "$FAKE/hc.log"; exit "${FAKE_HC_EXIT:-0}"; fi
out=''; url=''; prev=''
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; url=$a; done
line=$(grep -F -- "$url " "$FAKE/responses" | tail -1)
read -r _u code ex body <<<"$line"
[ -n "$out" ] && printf '%s' "${body:-}" > "$out"
[ "${ex:-0}" = 0 ] && printf '%s' "${code:-000}"
exit "${ex:-0}"
EOF
cat > "$T/alert.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$FAKE/alerts.log"
[ -e "$FAKE/alert-fail" ] && echo "telegram send failed"
exit 0
EOF
chmod +x "$T/bin/curl" "$T/alert.sh"
printf '%s\n' '# comment' 'site-a https://a.example/ok MARK-A' 'site-b https://b.example/x MARK-B' > "$T/targets"
: > "$T/ops/backup.conf"
export FAKE=$T
run() { PATH="$T/bin:$PATH" BOX_OPS="$T/ops" UPTIME_STATE="$T/state" UPTIME_TARGETS="$T/targets" UPTIME_ALERT="$T/alert.sh" bash "$S" 2>&1; }
resp() { printf '%s\n' "https://a.example/ok $1" "https://b.example/x $2" > "$T/responses"; }
alerts() { [ -f "$T/alerts.log" ] && grep -c . "$T/alerts.log" || echo 0; }

# 1. all good: silent, no alert, state up
resp "200 0 xxMARK-Axx" "200 0 MARK-B"
out=$(run); rc=$?
ok $rc "all up: exit 0"
[ -z "$out" ]; ok $? "all up: prints nothing"
[ "$(alerts)" = 0 ]; ok $? "all up: no alert"
grep -q '^up 0 ' "$T/state/site-a"; ok $? "all up: state up"

# 2. one failure: no alert yet
resp "500 0 x" "200 0 MARK-B"
out=$(run); rc=$?
ok $rc "first failure: exit 0"
[ "$(alerts)" = 0 ]; ok $? "first failure: no alert"
[[ $out == *"site-a failed once: HTTP 500"* ]]; ok $? "first failure: noted in the journal"

# 3. second failure: one DOWN
out=$(run)
[ "$(alerts)" = 1 ]; ok $? "second failure: one alert"
grep -q '^DOWN site-a: HTTP 500 (https://a.example/ok)$' "$T/alerts.log"; ok $? "DOWN names the site, the reason and the address"
grep -q '^down 2 ' "$T/state/site-a"; ok $? "state down"

# 4. still down: no repeat
run >/dev/null; run >/dev/null
[ "$(alerts)" = 1 ]; ok $? "still down: no repeated alert"

# 5. recovery: one UP
resp "200 0 MARK-A" "200 0 MARK-B"
out=$(run)
[ "$(alerts)" = 2 ]; ok $? "recovery: one more alert"
tail -1 "$T/alerts.log" | grep -qE '^UP site-a: answering again after about [0-9]+ min$'; ok $? "UP says how long it was down"
grep -q '^up 0 ' "$T/state/site-a"; ok $? "state up again"
out=$(run); [ -z "$out" ] && [ "$(alerts)" = 2 ]; ok $? "after recovery: quiet"

# 6. a failed send is retried next run and fails the run
resp "200 0 MARK-A" "200 0 no-marker-here"
run >/dev/null
touch "$T/alert-fail"
out=$(run); rc=$?
[ "$rc" != 0 ]; ok $? "send failed: run fails"
grep -q '^up 2 ' "$T/state/site-b"; ok $? "send failed: not marked down"
rm -f "$T/alert-fail"
n=$(alerts)
out=$(run); rc=$?
ok $rc "retry: exit 0"
[ "$(alerts)" = $((n + 1)) ] && tail -1 "$T/alerts.log" | grep -q '^DOWN site-b: page without its expected content'; ok $? "retry: DOWN sent, reason is the missing content"

# 7. no answer at all
resp "200 0 MARK-A" "000 28 x"
rm -f "$T/state/site-b"
run >/dev/null; run >/dev/null
tail -1 "$T/alerts.log" | grep -q '^DOWN site-b: no answer (curl exit 28)'; ok $? "timeout: reason is no answer"

# 8. backup.conf missing: no silent loss
resp "200 0 MARK-A" "200 0 MARK-B"; run >/dev/null
resp "500 0 x" "200 0 MARK-B"
mv "$T/ops/backup.conf" "$T/ops/backup.off"
run >/dev/null; out=$(run); rc=$?
[ "$rc" != 0 ] && [[ $out == *"backup.conf missing"* ]]; ok $? "no backup.conf: run fails and says so"
grep -q '^up ' "$T/state/site-a"; ok $? "no backup.conf: not marked down"
mv "$T/ops/backup.off" "$T/ops/backup.conf"

# 9. Healthchecks
resp "200 0 MARK-A" "200 0 MARK-B"; run >/dev/null
: > "$T/args.log"; rm -f "$T/hc.log"
printf 'HC_UPTIME_URL="https://hc-ping.example/abc-123"\n' > "$T/ops/backup.conf"
run >/dev/null
grep -qx 'url = "https://hc-ping.example/abc-123"' "$T/hc.log"; ok $? "HC: pinged with the address on stdin"
! grep -q 'abc-123' "$T/args.log"; ok $? "HC: address never on a command line"
resp "500 0 x" "500 0 x"; rm -f "$T/hc.log"
run >/dev/null
[ -s "$T/hc.log" ]; ok $? "HC: pinged also when sites are down"
printf 'HC_UPTIME_URL="https://x.example/a b;rm"\n' > "$T/ops/backup.conf"; rm -f "$T/hc.log"
out=$(run); rc=$?
[ ! -e "$T/hc.log" ] && [ "$rc" != 0 ]; ok $? "HC: odd address refused, run fails"
: > "$T/ops/backup.conf"; rm -f "$T/hc.log"
run >/dev/null
[ ! -e "$T/hc.log" ]; ok $? "HC: not set, no ping"
printf 'HC_UPTIME_URL="https://hc-ping.example/abc-123"\n' > "$T/ops/backup.conf"
resp "200 0 MARK-A" "200 0 MARK-B"; run >/dev/null
out=$(FAKE_HC_EXIT=22 run); rc=$?
[ "$rc" = 0 ] && [[ $out == *"healthchecks ping failed"* ]]; ok $? "HC: failed ping is noted, does not fail the run"

# 10. bad target lines
printf '%s\n' 'Bad_Name https://a.example/ok MARK' 'site-c http://plain.example/ MARK' 'site-d https://d.example/' > "$T/targets"
out=$(run); rc=$?
[ "$rc" != 0 ] && [ "$(grep -c 'bad line' <<<"$out")" = 3 ]; ok $? "bad lines refused: name, plain http, no marker"
[ ! -e "$T/state/Bad_Name" ]; ok $? "bad name never becomes a state file"

# 11. missing setup
out=$(PATH="$T/bin:$PATH" BOX_OPS="$T/ops" UPTIME_STATE="$T/nope" UPTIME_TARGETS="$T/targets" bash "$S" 2>&1); rc=$?
[ "$rc" != 0 ] && [[ $out == *"state folder"* ]]; ok $? "no state folder: fails and says so"

# 12. a targets file saved with Windows line endings
printf 'site-a https://a.example/ok MARK-A\r\nsite-b https://b.example/x MARK-B\r\n' > "$T/targets"
rm -f "$T/state/"*
resp "200 0 MARK-A" "200 0 MARK-B"
run >/dev/null; out=$(run); rc=$?
ok $rc "CRLF targets: exit 0"
grep -q '^up 0 ' "$T/state/site-a" && grep -q '^up 0 ' "$T/state/site-b"; ok $? "CRLF targets: both sites up (CR not in the marker)"

# 13. last line without a newline is still checked
printf 'site-a https://a.example/ok MARK-A\nsite-b https://b.example/x MARK-B' > "$T/targets"
rm -f "$T/state/"*
resp "200 0 MARK-A" "200 0 MARK-B"
run >/dev/null
[ -f "$T/state/site-b" ]; ok $? "last line without newline: still checked"

# 14. a site taken off the list loses its state; added back, no false UP
printf '%s\n' 'site-a https://a.example/ok MARK-A' 'site-b https://b.example/x MARK-B' > "$T/targets"
echo "down 5 $(( $(date +%s) - 600 ))" > "$T/state/site-b"
printf '%s\n' 'site-a https://a.example/ok MARK-A' > "$T/targets"
out=$(run)
[ ! -e "$T/state/site-b" ] && [[ $out == *"state of site-b removed"* ]]; ok $? "removed site: state removed and noted"
printf '%s\n' 'site-a https://a.example/ok MARK-A' 'site-b https://b.example/x MARK-B' > "$T/targets"
n=$(alerts); run >/dev/null
[ "$(alerts)" = "$n" ]; ok $? "site added back: no false UP"

echo "box-uptime: $pass passed, $fail failed"
[ "$fail" = 0 ]
