#!/usr/bin/env bash
# Runs ON the box as deploy (passwordless sudo), from the folder holding these
# files. The first run creates /opt/box-ops and stops: put backup.conf (mode 600)
# and backup-public.asc there, then run it again. It never handles a secret.
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
OPS=/opt/box-ops
[ -d "$OPS" ] || sudo install -d -o deploy -g deploy -m 700 "$OPS"
[ -f "$OPS/backup.conf" ] || { echo "$OPS/backup.conf missing"; exit 1; }
[ "$(stat -c %a "$OPS/backup.conf")" = 600 ] || { echo "backup.conf must be mode 600"; exit 1; }
[ -f "$OPS/backup-public.asc" ] || { echo "$OPS/backup-public.asc missing"; exit 1; }
install -m 700 "$SRC/backup-box.sh" "$SRC/box-alert.sh" "$OPS/"
sudo install -m 644 "$SRC/box-backup.service" "$SRC/box-backup.timer" "$SRC/box-alert@.service" /etc/systemd/system/
sudo install -d -m 755 /etc/systemd/system/clinicdemo-cron.service.d
sudo install -m 644 "$SRC/clinicdemo-cron-alert.conf" /etc/systemd/system/clinicdemo-cron.service.d/alert.conf
sudo systemctl daemon-reload
sudo systemctl enable --now box-backup.timer
echo "== timer: $(systemctl is-active box-backup.timer), next: $(systemctl show box-backup.timer -p NextElapseUSecRealtime --value)"
