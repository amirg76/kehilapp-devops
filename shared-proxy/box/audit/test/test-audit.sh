#!/usr/bin/env bash
# Tests for box-audit.sh, runnable on any machine with bash (Git Bash included).
# compare: every warning is checked twice, present after the change and absent
# from the unchanged baseline, so a test cannot pass because the line is always
# there. run: three days end to end with a fake Telegram. collect: a smoke test
# on this machine, where most readers fail and must mark their section, not crash.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# BOX_AUDIT_UNDER_TEST: run the suite against a deliberately broken copy (mutation check).
AUDIT=${BOX_AUDIT_UNDER_TEST:-$HERE/../box-audit.sh}
WORK="$HERE/run-$(date +%s)-$$"
mkdir -p "$WORK"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -z "${2:-}" ] || printf '  got:\n%s\n' "$2" | sed 's/^/    /'; }
has() { if grep -qE -- "$2" <<<"$3"; then ok; else bad "$1 (missing: $2)" "$3"; fi; }
hasnt() { if grep -qE -- "$2" <<<"$3"; then bad "$1 (unexpected: $2)" "$3"; else ok; fi; }

# A snapshot from lines written as section|key|value.
snap() { local f=$1; shift; printf '%s\n' "$@" | tr '|' '\t' | LC_ALL=C sort -u > "$f"; }
BASE=(
  'pkg|_status|ok' 'pkg|openssl|3.0.13-0ubuntu3.5' 'pkg|curl|8.5.0-2ubuntu10.6'
  'kernel|_status|ok' 'kernel|running|6.8.0-147-generic' 'kernel|reboot_required|no'
  'ctr|_status|ok' 'ctr_image|web|example/web:1 0123456789ab' 'ctr_state|web|running/healthy' 'ctr_restarts|web|0'
  'ctr_image|db|example/db:1 ba9876543210' 'ctr_state|db|running/none' 'ctr_restarts|db|2'
  'port|_status|ok' 'port|tcp 0.0.0.0:22|listening'
  'pub|_status|ok' 'pub|proxy|0.0.0.0:443->443/tcp'
  'ufw|_status|ok' 'ufw|status|active' 'ufw|22/tcp ALLOW IN Anywhere|present'
  'user|_status|ok' 'user|root|uid=0 shell=/bin/bash' 'user|deploy|uid=1000 shell=/bin/bash'
  'key|_status|ok' 'key|deploy SHA256:aaaa|256 (ED25519)'
  'sshd|_status|ok' 'sshd|passwordauthentication|no'
  'file|_status|ok' 'file|/etc/ssh/sshd_config|0123456789abcdef'
  'secret|_status|ok' 'secret|/opt/web/.env|600 deploy'
  'timer|_status|ok' 'timer|box-backup.timer|enabled'
  'failed|_status|ok'
  'login|_status|ok' 'login|203.0.113.7 deploy|publickey' 'metric|ssh_failed_24h|57'
  'host|_status|ok' 'metric|disk_used_pct|4' 'metric|mem_avail_pct|90'
  'http|_status|ok' 'metric|http_total_24h|1200' 'metric|http_5xx_24h|2'
  'cert|_status|ok' 'metric|cert_days:demo.example.com|60'
)
printf '203.0.113.7\n' > "$WORK/known"
snap "$WORK/base" "${BASE[@]}"
cmp() { "$AUDIT" compare "$WORK/base" "$1" "$WORK/known"; }
# Base with lines replaced (key match) or added: variant name 'sec|key|value' ...
variant() {
  local f="$WORK/$1"; shift
  local lines=("${BASE[@]}") l i found
  for l in "$@"; do
    found=0
    for i in "${!lines[@]}"; do
      if [ "${lines[$i]%|*}" = "${l%|*}" ]; then
        if [ "${l##*|}" = DELETE ]; then unset 'lines[i]'; else lines[$i]=$l; fi
        found=1
      fi
    done
    [ $found = 1 ] || lines+=("$l")
  done
  snap "$f" "${lines[@]}"
  echo "$f"
}

# --- the baseline: nothing changed, nothing to report except figures
same=$(cmp "$WORK/base")
hasnt "unchanged: no warning" '^1 ' "$same"
hasnt "unchanged: no change line" '^2 ' "$same"
has "unchanged: figures line" '^3 24h: disk 4% used, memory 90% free, 1200 requests / 2 5xx, 57 failed ssh attempts' "$same"

check() { # name, expected pattern, variant lines...
  local name=$1 pat=$2; shift 2
  local out
  out=$(cmp "$(variant "$name" "$@")")
  has "$name" "$pat" "$out"
  hasnt "$name (control: not in the baseline)" "$pat" "$same"
}
check new-port        '^1 port added: tcp 0.0.0.0:8080 = listening'            'port|tcp 0.0.0.0:8080|listening'
check port-gone       '^1 port removed: tcp 0.0.0.0:22'                          'port|tcp 0.0.0.0:22|DELETE'
check published-port  '^1 pub added: web = 0.0.0.0:8080->80/tcp'                'pub|web|0.0.0.0:8080->80/tcp'
check ufw-rule        '^1 ufw added: 8080/tcp ALLOW IN Anywhere'                 'ufw|8080/tcp ALLOW IN Anywhere|present'
check ufw-off         '^1 firewall is inactive'                                  'ufw|status|inactive'
check new-user        '^1 user added: backup2'                                   'user|backup2|uid=1001 shell=/bin/bash'
check uid0            '^1 user toor has uid 0'                                   'user|toor|uid=0 shell=/bin/bash'
check new-key         '^1 key added: deploy SHA256:bbbb'                         'key|deploy SHA256:bbbb|256 (ED25519)'
check sshd-setting    '^1 sshd changed: passwordauthentication: no -> yes'       'sshd|passwordauthentication|yes'
check config-hash     '^1 file changed: /etc/ssh/sshd_config'                    'file|/etc/ssh/sshd_config|fedcba9876543210'
check secret-mode     '^1 secret file /opt/web/.env has mode 644 deploy'         'secret|/opt/web/.env|644 deploy'
check new-timer       '^1 timer added: evil.timer'                               'timer|evil.timer|enabled'
check failed-unit     '^1 unit box-backup.service is failed'                     'failed|box-backup.service|failed'
check ctr-exited      '^1 container web is exited/none'                          'ctr_state|web|exited/none'
check ctr-unhealthy   '^1 container web is running/unhealthy'                    'ctr_state|web|running/unhealthy'
check ctr-restarted   '^1 container db restarted 3 time\(s\)'                    'ctr_restarts|db|5'
check ctr-gone        '^1 container db is gone'                                  'ctr_image|db|DELETE' 'ctr_state|db|DELETE' 'ctr_restarts|db|DELETE'
check ctr-new-image   '^2 container web image example/web:1 0123456789ab -> example/web:2 cccccccccccc' 'ctr_image|web|example/web:2 cccccccccccc'
check ctr-new         '^2 new container cache'                                   'ctr_image|cache|example/cache:1 dddddddddddd' 'ctr_state|cache|running/none' 'ctr_restarts|cache|0'
check kernel          '^2 kernel changed: running: 6.8.0-147-generic -> 6.8.0-150-generic' 'kernel|running|6.8.0-150-generic'
check reboot-pending  '^2 a reboot is pending'                                   'kernel|reboot_required|yes'
check packages        '^2 packages: 1 upgraded, 1 added, 0 removed: '            'pkg|openssl|3.0.13-0ubuntu3.6' 'pkg|jq|1.7.1-3build1'
check new-ip          '^1 ssh login from a new address 198.51.100.9 as deploy'   'login|198.51.100.9 deploy|publickey'
check password-login  '^1 ssh login by password from 203.0.113.7 as root'        'login|203.0.113.7 root|password'
check no-traffic      '^1 no requests in the access log'                         'metric|http_total_24h|0'
check disk            '^1 disk / is 85% full'                                    'metric|disk_used_pct|85'
check memory          '^1 only 5% of memory is available'                        'metric|mem_avail_pct|5'
check cert-soon       '^1 certificate of demo.example.com expires in 5 days'     'metric|cert_days:demo.example.com|5'
check cert-unread     '^1 certificate of demo.example.com could not be read'     'metric|cert_days:demo.example.com|unreadable'
check http-errors     '^1 250 server errors'                                     'metric|http_5xx_24h|250'
check unreadable      '^1 could not read port'                                   'port|_status|unavailable' 'port|tcp 0.0.0.0:22|DELETE'

# Packages: one line, never one line per package.
out=$(cmp "$(variant pkgs 'pkg|openssl|3.0.13-0ubuntu3.6' 'pkg|curl|8.5.0-2ubuntu10.7')")
[ "$(grep -c 'packages' <<<"$out")" = 1 ] && ok || bad "packages: a single line" "$out"
hasnt "packages: no per-package warning" '^1 pkg' "$out"

# A section unreadable today must not report its lines as removed.
out=$(cmp "$(variant unread-today 'key|_status|unavailable' 'key|deploy SHA256:aaaa|DELETE')")
has "unreadable today: warned" '^1 could not read key' "$out"
hasnt "unreadable today: no false removal" 'key removed' "$out"
# A section unreadable yesterday: today is a new baseline for it, not a list of additions.
snap "$WORK/old-unread" "${BASE[@]/#key|deploy SHA256:aaaa|256 (ED25519)/key|_status|unavailable}"
sed -i '/^key\t_status\tok$/d' "$WORK/old-unread"
out=$("$AUDIT" compare "$WORK/old-unread" "$WORK/base" "$WORK/known")
hasnt "unreadable yesterday: no false addition" 'key added' "$out"
hasnt "unreadable yesterday: no warning today" '^1 ' "$out"
# A container recreated by a deploy starts its count at 0: not a restart.
out=$(cmp "$(variant recreated 'ctr_restarts|db|0')")
hasnt "restart count reset: no warning" 'restarted' "$out"
# First run: no yesterday, so no changes, only today's state.
out=$("$AUDIT" compare /dev/null "$WORK/base" "$WORK/known")
hasnt "first run: no change lines" 'added|removed|changed' "$out"
# A known address with a new user is still known.
out=$(cmp "$(variant known-ip 'login|203.0.113.7 root|publickey')")
hasnt "known address: no warning" 'new address' "$out"

# --- run: three days, a fake Telegram, the state folder
ST="$WORK/state"; OPS="$WORK/ops"; mkdir -p "$ST" "$OPS"
: > "$OPS/backup.conf"
# Like the real box-alert.sh: silent when the message went out.
printf '#!/usr/bin/env bash\nprintf "%%s\\n----\\n" "$1" >> "%s/sent"\n' "$WORK" > "$OPS/box-alert.sh"
day() { BOX_AUDIT_STATE="$ST" BOX_OPS="$OPS" BOX_AUDIT_KEEP=2 BOX_AUDIT_DATE=$1 BOX_AUDIT_SNAPSHOT_FROM=$2 "$AUDIT" run; }
day 2026-11-10 "$WORK/base" >/dev/null || bad "run day 1 exit code"
sent=$(cat "$WORK/sent")
has "run day 1: baseline message" '^box audit 2026-11-10: first run, baseline saved' "$sent"
has "run day 1: address learned" '^203.0.113.7$' "$(cat "$ST/known-ips")"
d2=$(variant day2 'port|tcp 0.0.0.0:8080|listening' 'login|198.51.100.9 deploy|publickey')
: > "$WORK/sent"; day 2026-11-11 "$d2" >/dev/null || bad "run day 2 exit code"
sent=$(cat "$WORK/sent")
has "run day 2: header counts" '^box audit 2026-11-11: 2 warning\(s\), 0 change\(s\)' "$sent"
has "run day 2: port line" '^WARN port added: tcp 0.0.0.0:8080' "$sent"
has "run day 2: new address line" '^WARN ssh login from a new address 198.51.100.9' "$sent"
has "run day 2: figures last" '^24h: disk' "$(tail -n 2 "$WORK/sent")"
: > "$WORK/sent"; day 2026-11-12 "$d2" >/dev/null || bad "run day 3 exit code"
sent=$(cat "$WORK/sent")
has "run day 3: same as yesterday = OK" '^box audit 2026-11-12: OK, nothing changed' "$sent"
hasnt "run day 3: the address warns once" 'new address' "$sent"
[ "$(find "$ST" -name 'snapshot-*.tsv' | wc -l)" = 2 ] && ok || bad "run: keeps 2 snapshots" "$(ls "$ST")"
[ -e "$ST/snapshot-2026-11-10.tsv" ] && bad "run: oldest snapshot removed" || ok
# A missing state folder is a failure of the audit itself (OnFailure alerts on it).
BOX_AUDIT_STATE="$WORK/nope" BOX_OPS="$OPS" BOX_AUDIT_SNAPSHOT_FROM="$WORK/base" "$AUDIT" run >/dev/null 2>&1 \
  && bad "run: missing state folder must fail" || ok
# Telegram down: the run fails, and the new address is NOT learned, so it warns again tomorrow.
OPS2="$WORK/ops2"; mkdir -p "$OPS2"; : > "$OPS2/backup.conf"
printf '#!/usr/bin/env bash\necho "telegram send failed"\n' > "$OPS2/box-alert.sh"
d4=$(variant day4 'login|192.0.2.44 deploy|publickey')
BOX_AUDIT_STATE="$ST" BOX_OPS="$OPS2" BOX_AUDIT_DATE=2026-11-13 BOX_AUDIT_SNAPSHOT_FROM="$d4" "$AUDIT" run >/dev/null 2>&1 \
  && bad "run: a failed Telegram send must fail the run" || ok
hasnt "run: address not learned when the message was lost" '^192.0.2.44$' "$(cat "$ST/known-ips")"
hasnt "run: no _status line among the addresses" '_status' "$(cat "$ST/known-ips")"
# No backup.conf: box-alert.sh would exit 0 without a word. The run must fail instead.
OPS3="$WORK/ops3"; mkdir -p "$OPS3"; cp "$OPS/box-alert.sh" "$OPS3/"
BOX_AUDIT_STATE="$ST" BOX_OPS="$OPS3" BOX_AUDIT_DATE=2026-11-13 BOX_AUDIT_SNAPSHOT_FROM="$d4" "$AUDIT" run >/dev/null 2>&1 \
  && bad "run: missing backup.conf must fail" || ok

# --- Healthchecks ping: only after the message went out; the address never on argv.
HCBIN="$WORK/hcbin"; mkdir -p "$HCBIN"
printf '#!/usr/bin/env bash\necho "argv: $*" >> "%s/curl.log"\ncat >> "%s/curl.log"\n' "$WORK" "$WORK" > "$HCBIN/curl"
chmod +x "$HCBIN/curl"
HC='https://hc-ping.com/aaaa-test-ping'
hcrun() { # ops-folder state-folder: one run with the fake curl first on PATH
  : > "$WORK/curl.log"
  PATH="$HCBIN:$PATH" BOX_AUDIT_STATE="$2" BOX_OPS="$1" BOX_AUDIT_DATE=2026-11-10 \
    BOX_AUDIT_SNAPSHOT_FROM="$WORK/base" "$AUDIT" run >/dev/null 2>&1
}
OPS4="$WORK/ops4"; ST4="$WORK/state4"; mkdir -p "$OPS4" "$ST4"
cp "$OPS/box-alert.sh" "$OPS4/"
# Quotes and a comment, as in backup.conf.example: read like the backup reads it.
printf 'TELEGRAM_CHAT_ID="1"\nHC_AUDIT_URL="%s"  # audit check\nHC_BACKUP_URL="https://hc-ping.com/bbbb-other"\n' "$HC" > "$OPS4/backup.conf"
hcrun "$OPS4" "$ST4" || bad "ping: run exit code"
log=$(cat "$WORK/curl.log")
has "ping: the audit address, after the message" "^url = \"$HC\"$" "$log"
hasnt "ping: not the backup address" 'bbbb-other' "$log"
hasnt "ping: the address is not on the command line" 'hc-ping' "$(grep '^argv' <<<"$log")"
# Without -K - the real curl ignores stdin and the ping silently never happens.
has "ping: curl reads its config from stdin" '^argv: .* -K -$' "$log"
# An address with a quote would break curl's config line: refused, not sent.
OPS8="$WORK/ops8"; ST8="$WORK/state8"; mkdir -p "$OPS8" "$ST8"
cp "$OPS/box-alert.sh" "$OPS8/"
printf '%s\n' "HC_AUDIT_URL='https://hc-ping.com/a\"b'" > "$OPS8/backup.conf"
hcrun "$OPS8" "$ST8" || bad "ping: a bad address must not fail the run"
[ -s "$WORK/curl.log" ] && bad "ping: a bad address is not sent" "$(cat "$WORK/curl.log")" || ok
# Message lost: no ping, so Healthchecks alerts as well.
OPS5="$WORK/ops5"; ST5="$WORK/state5"; mkdir -p "$OPS5" "$ST5"
cp "$OPS2/box-alert.sh" "$OPS5/"; cp "$OPS4/backup.conf" "$OPS5/"
hcrun "$OPS5" "$ST5" && bad "ping: lost message must still fail the run" || ok
[ -s "$WORK/curl.log" ] && bad "ping: no ping when the message was lost" "$(cat "$WORK/curl.log")" || ok
# No address configured: no curl at all.
OPS6="$WORK/ops6"; ST6="$WORK/state6"; mkdir -p "$OPS6" "$ST6"
cp "$OPS/box-alert.sh" "$OPS6/"; printf 'TELEGRAM_CHAT_ID=1\n' > "$OPS6/backup.conf"
hcrun "$OPS6" "$ST6" || bad "ping: run without an address must pass"
[ -s "$WORK/curl.log" ] && bad "ping: no curl without an address" "$(cat "$WORK/curl.log")" || ok
# The ping service is down: the run still passes (Healthchecks alerts on its own).
printf '#!/usr/bin/env bash\necho "failing curl ran" >> "%s/curl.log"\ncat > /dev/null; exit 7\n' "$WORK" > "$HCBIN/curl"
ST7="$WORK/state7"; mkdir -p "$ST7"
hcrun "$OPS4" "$ST7" || bad "ping: a failed ping must not fail the run"
# Control: the failing curl really ran, so the line above did not pass by skipping it.
has "ping: the failing curl was called" '^failing curl ran$' "$(cat "$WORK/curl.log")"

# --- parsers: fake tools print the documented output formats of the real ones.
# Replace these samples with captures from the box after the first install.
FAKE="$WORK/fakebin"; mkdir -p "$FAKE"
fake() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$FAKE/$1"; chmod +x "$FAKE/$1"; }
fake sudo 'if [ "$1" = -n ]; then shift; fi; exec "$@"'
fake journalctl "cat <<'L'
Accepted publickey for deploy from 203.0.113.7 port 51234 ssh2: ED25519 SHA256:abcdefghijklmnop
Accepted password for root from 198.51.100.9 port 40000 ssh2
Accepted keyboard-interactive/pam for deploy from 192.0.2.10 port 40001 ssh2
Invalid user admin from 192.0.2.5 port 3333
Failed password for invalid user admin from 192.0.2.5 port 3333 ssh2
Invalid user Accepted publickey for x from 192.0.2.66 port 1
Connection closed by invalid user admin 192.0.2.5 port 3333 [preauth]
L"
fake systemctl 'case "$*" in
  *--state=failed*) printf "%s\n" "● box-backup.service loaded failed failed Encrypted backup" "other.service loaded failed failed Other" ;;
  *list-unit-files*) printf "%s\n" "box-backup.timer enabled enabled" ;;
esac'
fake ss "printf '%s\n' 'tcp   LISTEN 0      4096         0.0.0.0:22        0.0.0.0:*' 'udp   UNCONN 0      0      127.0.0.53%lo:53        0.0.0.0:*'"
fake ufw "cat <<'L'
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp (OpenSSH)           ALLOW IN    Anywhere
80/tcp                     ALLOW IN    Anywhere
L"
fake sshd "printf '%s\n' 'port 22' 'port 2222' 'passwordauthentication no' 'usedns no' 'authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2'"
fake docker 'exit 1'
mkdir -p "$WORK/sites"; printf '(snippet) {\n}\n' > "$WORK/sites/snippet.caddy"
out=$(PATH="$FAKE:$PATH" BOX_AUDIT_SITES="$WORK/sites" BOX_OPS="$WORK/no-ops" "$AUDIT" collect 2>/dev/null)
T=$'\t'
has "parse login: key login" "^login${T}203.0.113.7 deploy${T}publickey$" "$out"
has "parse login: password login" "^login${T}198.51.100.9 root${T}password$" "$out"
has "parse login: keyboard-interactive login" "^login${T}192.0.2.10 deploy${T}keyboard-interactive/pam$" "$out"
hasnt "parse login: a hostile user name is not a login" '192.0.2.66' "$out"
has "parse login: failed attempts counted" "^metric${T}ssh_failed_24h${T}3$" "$out"
has "parse failed: bullet stripped" "^failed${T}box-backup.service${T}failed$" "$out"
has "parse failed: plain line" "^failed${T}other.service${T}failed$" "$out"
hasnt "parse failed: no bullet as a unit" "^failed${T}●" "$out"
has "parse timer" "^timer${T}box-backup.timer${T}enabled$" "$out"
has "parse ss: tcp" "^port${T}tcp 0.0.0.0:22${T}listening$" "$out"
has "parse ss: udp" "^port${T}udp 127.0.0.53%lo:53${T}listening$" "$out"
has "parse ufw: status" "^ufw${T}status${T}active$" "$out"
has "parse ufw: rule" "^ufw${T}80/tcp ALLOW IN Anywhere${T}present$" "$out"
hasnt "parse ufw: table header skipped" "^ufw${T}(To |--)" "$out"
has "parse sshd: repeated setting kept whole" "^sshd${T}port${T}22,2222$" "$out"
hasnt "parse sshd: settings outside the list ignored" 'usedns' "$out"
has "parse sshd: where keys are read from" "^sshd${T}authorizedkeysfile${T}.ssh/authorized_keys .ssh/authorized_keys2$" "$out"
# Keys: only the names sshd reads. Real keys made here, with the real ssh-keygen.
KR="$WORK/keyroots"; mkdir -p "$KR/root/.ssh" "$KR/home/alice/.ssh"
for k in r0 r1 a1 a2; do ssh-keygen -q -t ed25519 -N '' -C "test-$k" -f "$WORK/$k" >/dev/null; done
cp "$WORK/r0.pub" "$KR/root/.ssh/authorized_keys"
cp "$WORK/r1.pub" "$KR/root/.ssh/authorized_keys.disabled-20261110"
cp "$WORK/a1.pub" "$KR/home/alice/.ssh/authorized_keys"
cp "$WORK/a2.pub" "$KR/home/alice/.ssh/authorized_keys2"
# Base64 holds "+", a regex operator for has/hasnt: escaped, or a check passes by luck.
fpr() { ssh-keygen -lf "$WORK/$1.pub" | awk '{print $2}' | sed 's/+/[+]/g'; }
out=$(PATH="$FAKE:$PATH" BOX_AUDIT_KEY_ROOTS="$KR/root $KR/home" BOX_AUDIT_SITES="$WORK/sites" \
  BOX_OPS="$WORK/no-ops" "$AUDIT" collect 2>/dev/null)
has "parse key: root's authorized_keys, named root" "^key${T}root $(fpr r0)${T}256 \(ED25519\)$" "$out"
has "parse key: authorized_keys" "^key${T}alice $(fpr a1)${T}256 \(ED25519\)$" "$out"
has "parse key: authorized_keys2" "^key${T}alice $(fpr a2)${T}256 \(ED25519\)$" "$out"
hasnt "parse key: a renamed file is not a key" "$(fpr r1)" "$out"
has "parse key: section read" "^key${T}_status${T}ok$" "$out"
has "parse docker down: section unavailable" "^ctr${T}_status${T}unavailable$" "$out"
has "parse cert: site file without a host name is reported" "^metric${T}cert_days:snippet.caddy${T}unreadable$" "$out"

# --- collect: on this machine most readers fail; every section still gets a status
out=$(BOX_AUDIT_SITES="$WORK/no-sites" BOX_OPS="$WORK/no-ops" "$AUDIT" collect 2>/dev/null)
bad_lines=$(awk -F'\t' 'NF != 3' <<<"$out")
[ -z "$bad_lines" ] && ok || bad "collect: three fields on every line" "$bad_lines"
for s in pkg kernel ctr port pub ufw user key sshd file secret timer failed login host http cert; do
  grep -qE "^$s"$'\t'"_status"$'\t'"(ok|unavailable)$" <<<"$out" && ok || bad "collect: status line for $s"
done

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
