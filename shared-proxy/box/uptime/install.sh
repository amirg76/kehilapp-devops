#!/usr/bin/env bash
# Runs ON the box as deploy (passwordless sudo), from the folder holding these
# files. Needs the backup's install first: it reuses /opt/box-ops/box-alert.sh,
# backup.conf (Telegram) and box-alert@.service. It never handles a secret.
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
OPS=/opt/box-ops
STATE=/var/lib/box-uptime
[ -f "$OPS/box-alert.sh" ] || { echo "$OPS/box-alert.sh missing: run ../backup/install.sh first"; exit 1; }
[ -f /etc/systemd/system/box-alert@.service ] || { echo "box-alert@.service missing: run ../backup/install.sh first"; exit 1; }
sudo install -d -o deploy -g deploy -m 700 "$STATE"
install -m 700 "$SRC/box-uptime.sh" "$OPS/"
install -m 600 "$SRC/uptime-targets.txt" "$OPS/"
sudo install -m 644 "$SRC/box-uptime.service" "$SRC/box-uptime.timer" /etc/systemd/system/
sudo systemctl daemon-reload
# First run by hand, so a broken install shows here and not two minutes later.
sudo systemctl start box-uptime.service && echo "== first run: ok" || { echo "== first run failed:"; sudo journalctl -u box-uptime -n 20 --no-pager; exit 1; }
sudo systemctl enable --now box-uptime.timer
echo "== timer: $(systemctl is-active box-uptime.timer), next: $(systemctl show box-uptime.timer -p NextElapseUSecRealtime --value)"
echo "== state: $(ls "$STATE" | tr '\n' ' ')"
grep -q '^HC_UPTIME_URL=' "$OPS/backup.conf" && echo "== Healthchecks: set" || echo "== Healthchecks: not set yet (set-uptime-hc.ps1)"
