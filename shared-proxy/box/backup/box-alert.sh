#!/usr/bin/env bash
# Sends one line to Telegram. Usage: box-alert.sh "text" [key]
# With a key, a repeat inside an hour is dropped, so a unit that fails every
# 5 minutes sends one message. Never fails its caller.
set -uo pipefail
OPS=${BOX_OPS:-/opt/box-ops}
# shellcheck disable=SC1091
. "$OPS/backup.conf" || exit 0
TEXT=$1
KEY=${2:-}
STAMP="$OPS/.alert-$KEY"

if [ -n "$KEY" ] && [ -e "$STAMP" ] && [ $(($(date +%s) - $(date -r "$STAMP" +%s))) -lt 3600 ]; then
  exit 0
fi

# The token is part of the address: curl reads it from stdin, not the command line.
if printf 'url = "%s/bot%s/sendMessage"\n' "${TELEGRAM_API:-https://api.telegram.org}" "${TELEGRAM_BOT_TOKEN:-}" \
  | curl -sS --fail -m 20 -o /dev/null -K - \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID:-}" --data-urlencode "text=$TEXT"; then
  # Only after a real send: a failed one must not silence the next hour.
  [ -z "$KEY" ] || : > "$STAMP"
else
  echo "telegram send failed"
fi
exit 0
