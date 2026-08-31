#!/bin/bash
# ═════════════════════════════════════════════════════════════════════════════
# userdata.tpl — first-boot bootstrap script for the EC2 box.
#
# AWS runs this ONCE, as root, the very first time the instance boots. Its job:
#   1. install Docker Engine + the `docker compose` v2 plugin
#   2. pull this devops repo so docker-compose.prod.yml + the nginx/caddy configs
#      are on the box
#   3. leave the stack READY to start — it does NOT start automatically, because
#      the app needs a secrets file (.env) that we must never bake into an image.
#
# The ${...} placeholders are filled in by Terraform's templatefile() (see
# main.tf). Everything ELSE that looks like a shell variable is written as $${VAR}
# so Terraform leaves it alone and the shell expands it at runtime.
#
# Watch it run / debug:   sudo tail -f /var/log/cloud-init-output.log
# ═════════════════════════════════════════════════════════════════════════════
set -euxo pipefail

# ── 1. OS packages ───────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git ufw

# ── 2. Docker Engine + compose plugin (official Docker apt repo) ─────────────
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# dpkg --print-architecture returns arm64 on t4g, amd64 on t3 — repo auto-matches.
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$${VERSION_CODENAME}") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Let the normal 'ubuntu' user run docker without sudo (takes effect next login).
usermod -aG docker ubuntu

# ── 3. A tiny host firewall on top of the AWS security group (belt + braces) ──
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ── 4. Get the deploy files onto the box ─────────────────────────────────────
# We clone this devops repo so the server has docker-compose.prod.yml plus the
# docker/nginx/* and docker/caddy/* config files it mounts.
APP_DIR=/opt/kehilapp
if [ ! -d "$${APP_DIR}/.git" ]; then
  git clone "${repo_url}" "$${APP_DIR}" || mkdir -p "$${APP_DIR}"
fi
chown -R ubuntu:ubuntu "$${APP_DIR}"

# Record the environment + domain so the runbooks/operator know what this box is.
cat > "$${APP_DIR}/.deploy-info" <<EOF
environment=${environment}
domain=${domain}
provisioned=$(date -u +%FT%TZ)
EOF
chown ubuntu:ubuntu "$${APP_DIR}/.deploy-info"

# ── 5. Try to start the stack IF secrets are already present ─────────────────
# We NEVER put secrets in user_data. So on a fresh box there is no .env yet and
# we stop here — the operator adds /opt/kehilapp/.env then runs the deploy
# (see runbooks/01-initial-server-setup.md). If you pre-seeded .env some other
# way, this will bring the stack up automatically.
cd "$${APP_DIR}"
if [ -f .env ]; then
  docker compose -f docker-compose.prod.yml --env-file .env pull || true
  docker compose -f docker-compose.prod.yml --env-file .env up -d || true
else
  echo "No .env yet — stack not started. Add /opt/kehilapp/.env and run the deploy." \
    > "$${APP_DIR}/READY-BUT-NO-ENV.txt"
fi

echo "kehilapp bootstrap finished."
