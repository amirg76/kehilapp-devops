#!/usr/bin/env bash
# Uptime check of the shared box's public sites (wave 4, 14.11.2026).
# Runs every 2 minutes from box-uptime.timer as deploy. For each line of
# uptime-targets.txt it fetches the public address, as a visitor would (DNS,
# TLS, Caddy, the app), and checks the answer is 200 AND holds a marker text:
# a 200 error page or an empty shell is a failure too.
#
# Two failures in a row send one Telegram line through box-alert.sh ("DOWN");
# the first good answer after that sends one more ("UP", with the downtime).
# Nothing is sent while the state does not change. A message that did not go
# out is retried on the next run and fails this run (journal + OnFailure).
#
# Silence: with HC_UPTIME_URL in backup.conf, every run pings Healthchecks.io,
# whatever the sites answered. If the box, the timer or this script stops, the
# pings stop and Healthchecks alerts from outside. The address goes to curl on
# stdin, never on the command line.
#
# Prints only on a change or a problem. Never prints page content or secrets.
set -uo pipefail
OPS=${BOX_OPS:-/opt/box-ops}
STATE=${UPTIME_STATE:-/var/lib/box-uptime}
TARGETS=${UPTIME_TARGETS:-$OPS/uptime-targets.txt}
ALERT=${UPTIME_ALERT:-$OPS/box-alert.sh}
FAILS_TO_ALERT=2
rc=0

[ -d "$STATE" ] || { echo "state folder $STATE missing: run install.sh"; exit 1; }
[ -f "$TARGETS" ] || { echo "targets file $TARGETS missing"; exit 1; }
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# One Telegram line. Succeeds only when it really went out: box-alert.sh never
# fails its caller and is silent when backup.conf is missing.
send() {
  local out
  [ -f "$OPS/backup.conf" ] || { echo "backup.conf missing: no Telegram"; return 1; }
  out=$(bash "$ALERT" "$1" </dev/null 2>&1) # stdin is the targets file: keep it off
  [ -z "$out" ] || { echo "alert not sent: $out"; return 1; }
}

# Prints "" when the answer is good, otherwise a short reason.
probe() {
  local url=$1 marker=$2 code cerr
  : > "$TMP"
  code=$(curl -sS -m 20 -o "$TMP" -w '%{http_code}' -H 'User-Agent: box-uptime' "$url" </dev/null 2>/dev/null)
  cerr=$?
  if [ "$cerr" != 0 ]; then
    echo "no answer (curl exit $cerr)"
  elif [ "$code" != 200 ]; then
    echo "HTTP $code"
  elif ! grep -qF -- "$marker" "$TMP"; then
    echo "page without its expected content"
  fi
}

minutes_since() { echo $(( ( $(date +%s) - $1 + 59 ) / 60 )); }

seen=' '
# `|| [ -n "$name" ]`: a last line without a newline is still read (code review:
# without it, that site was silently never checked).
while read -r name url marker || [ -n "$name" ]; do
  marker=${marker%$'\r'} # a file saved on Windows: the CR would join the marker
  case "$name" in '' | \#*) continue ;; esac
  if ! [[ $name =~ ^[a-z0-9-]+$ ]] || ! [[ $url =~ ^https://[A-Za-z0-9./_?=-]+$ ]] || [ -z "$marker" ]; then
    echo "bad line in $TARGETS: $name"; rc=1; continue
  fi
  seen="$seen$name "
  f="$STATE/$name"
  status=up; fails=0; since=$(date +%s)
  [ -f "$f" ] && read -r status fails since < "$f"
  [[ $fails =~ ^[0-9]+$ ]] || fails=0
  [[ $since =~ ^[0-9]+$ ]] || since=$(date +%s)
  why=$(probe "$url" "$marker")
  now=$(date +%s)
  if [ -z "$why" ]; then
    if [ "$status" = down ]; then
      if send "UP $name: answering again after about $(minutes_since "$since") min"; then
        echo "UP $name"; echo "up 0 $now" > "$f"
      else
        rc=1
      fi
    elif [ "$fails" != 0 ] || [ ! -f "$f" ]; then
      echo "up 0 $now" > "$f"
    fi
  else
    fails=$((fails + 1))
    [ "$fails" = 1 ] && since=$now
    if [ "$status" != down ] && [ "$fails" -ge "$FAILS_TO_ALERT" ]; then
      if send "DOWN $name: $why ($url)"; then
        echo "DOWN $name: $why"; echo "down $fails $since" > "$f"
      else
        rc=1; echo "up $fails $since" > "$f"
      fi
    else
      [ "$status" = down ] || echo "$name failed once: $why"
      echo "$status $fails $since" > "$f"
    fi
  fi
done < "$TARGETS"

# A site taken off the list leaves no state behind: added back later, an old
# "down" would send a false UP at once.
for f in "$STATE"/*; do
  [ -f "$f" ] || continue
  n=${f##*/}
  case "$seen" in *" $n "*) ;; *) rm -f -- "$f"; echo "state of $n removed (no longer in the list)" ;; esac
done

# The ping says "the monitor ran", not "the sites are up".
hc=$(grep -m1 '^HC_UPTIME_URL=' "$OPS/backup.conf" 2>/dev/null | cut -d= -f2- | tr -d "\"' \r")
if [ -n "$hc" ]; then
  if [[ $hc =~ ^https://[A-Za-z0-9./_:-]+$ ]]; then
    printf 'url = "%s"\n' "$hc" | curl -fsS -m 10 --retry 2 -o /dev/null -K - \
      || echo "healthchecks ping failed (it alerts on its own when pings stop)"
  else
    echo "HC_UPTIME_URL is not a plain https address: no ping"; rc=1
  fi
fi
exit "$rc"
