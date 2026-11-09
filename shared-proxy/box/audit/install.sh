#!/usr/bin/env bash
# Runs ON the box as deploy (passwordless sudo), from the folder holding these
# files. Needs the backup's install first: it reuses /opt/box-ops/box-alert.sh,
# backup.conf (Telegram) and box-alert@.service. It never handles a secret.
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
OPS=/opt/box-ops
STATE=/var/lib/box-audit
[ -f "$OPS/box-alert.sh" ] || { echo "$OPS/box-alert.sh missing: run ../backup/install.sh first"; exit 1; }
[ -f /etc/systemd/system/box-alert@.service ] || { echo "box-alert@.service missing: run ../backup/install.sh first"; exit 1; }
sudo install -d -o deploy -g deploy -m 700 "$STATE"
install -m 700 "$SRC/box-audit.sh" "$OPS/"
sudo install -m 644 "$SRC/box-audit.service" "$SRC/box-audit.timer" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now box-audit.timer
echo "== timer: $(systemctl is-active box-audit.timer), next: $(systemctl show box-audit.timer -p NextElapseUSecRealtime --value)"
echo "== first run (baseline): sudo systemctl start box-audit.service && journalctl -u box-audit -n 5 --no-pager"
