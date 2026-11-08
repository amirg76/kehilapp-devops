#!/usr/bin/env bash
# Runs once after every boot (post-reboot-check.service). Proves the sites came
# back by CONTENT, not by status code alone (runbook 00: "200 is not proof").
# If a check fails it brings both stacks up once more and re-checks.
# Result: one line in /var/log/post-reboot-check.log and in the journal;
# exit 1 if still failing, so `systemctl status post-reboot-check` shows it and
# the OnFailure drop-in (post-reboot-check-alert.conf) sends a Telegram alert.
set -o pipefail
# The overrides exist for tests only; the service sets none of them.
LOG=${POST_REBOOT_LOG:-/var/log/post-reboot-check.log}
SITE=${POST_REBOOT_SITE:-https://kehilapp.letstalkanddesign.com}
CLINIC_HOST=$(grep -m1 -oE '^[a-z0-9.-]+[.][a-z]{2,}' /opt/shared-proxy/sites/clinicdemo.caddy 2>/dev/null)

# The page must carry its own marker and not the other app's. Both apps say
# dir="rtl", so that alone passed while / served the admin panel (2026-10-29).
page_is() { # url, text it must have, text it must not have
  local page
  page=$(curl -s --max-time 15 "$1") || return 1
  grep -q "$2" <<<"$page" && ! grep -q "$3" <<<"$page"
}

check() {
  local fail=""
  page_is "$SITE/" 'class="text-gray-800"' 'root fix for this panel' || fail="$fail kehilapp-home"
  page_is "$SITE/admin/" 'root fix for this panel' 'class="text-gray-800"' || fail="$fail kehilapp-admin"
  curl -s --max-time 15 "$SITE/readyz" | grep -q '"db":"up"' || fail="$fail kehilapp-db"
  if [ -n "$CLINIC_HOST" ]; then
    [ "$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "https://$CLINIC_HOST/")" = 200 ] || fail="$fail clinicdemo"
  fi
  echo "$fail"
}

# Let docker, the containers and the certificates settle. POST_REBOOT_SLEEP=0
# runs the same checks immediately (used to test the script without a reboot).
sleep "${POST_REBOOT_SLEEP:-120}"
running=$(docker ps -q | wc -l)
fail=$(check)
if [ -n "$fail" ]; then
  echo "$(date -Is) first check failed:$fail (running=$running), bringing stacks up" | tee -a "$LOG"
  (cd /opt/shared-proxy && docker compose up -d) >/dev/null 2>&1
  (cd /opt/kehilapp && docker compose -f docker-compose.prod.yml -f docker-compose.shared-box.yml --env-file .env up -d \
    && docker compose -f docker-compose.prod.yml -f docker-compose.shared-box.yml --env-file .env restart proxy) >/dev/null 2>&1
  sleep "${POST_REBOOT_RETRY_SLEEP:-60}"
  fail=$(check)
fi
running=$(docker ps -q | wc -l)
if [ -z "$fail" ]; then
  echo "$(date -Is) OK kernel=$(uname -r) containers=$running" | tee -a "$LOG"
  exit 0
fi
echo "$(date -Is) FAIL:$fail kernel=$(uname -r) containers=$running" | tee -a "$LOG"
exit 1
