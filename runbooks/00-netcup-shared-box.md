# 00 — The shared netcup box, from bare Ubuntu to a running demo

This is the guide for the **always-on demo** (runbook 01 is for the AWS showcase
box, where Terraform has already done steps 2–4 for you). A netcup server
arrives empty: Ubuntu, a root password in an email, no Docker, no firewall.

Decided 2026-09-28 (one shared box for every small project) and 2026-10-11
(one shared public entry point, `shared-proxy/`, instead of a Caddy per project).

> **Status: written before the server was bought, never run end-to-end.**
> Each step says what "done" looks like so you can tell where it stopped.
> Cross off the line above after the first successful run and note the date.

## 0. What you need in hand

- The netcup order confirmation: IP address, root password (you'll change it),
  and which line you bought — the README's cost note says *verify RS vs VPS at
  purchase*; write the answer here: `__________`.
- An SSH key on your laptop: `ls ~/.ssh/id_ed25519.pub` (make one with
  `ssh-keygen -t ed25519` if missing).
- Hostinger DNS access for `letstalkanddesign.com`.
- The values for the kehilapp `.env` (README table "Server .env"): Atlas SRV
  string, Resend key, JWT secret, S3 bucket, Anthropic key (optional).

## 1. First login and a non-root user

```bash
ssh root@<IP>                      # password from the netcup email
adduser deploy                     # choose a password; it is only for sudo
usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
nano /home/deploy/.ssh/authorized_keys     # paste your id_ed25519.pub, one line
chmod 600 /home/deploy/.ssh/authorized_keys && chown -R deploy:deploy /home/deploy/.ssh
```

From a **second** terminal, before closing the root one:
```bash
ssh deploy@<IP>                    # must log in with the key, no password prompt
```
Only once that works, disable password logins:
```bash
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```
**Done =** `ssh root@<IP>` is refused, `ssh deploy@<IP>` works.

## 2. Updates and firewall

```bash
sudo apt update && sudo apt -y upgrade
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable                     # answer y
sudo ufw status                     # 22, 80, 443 — nothing else
```
**Done =** three allowed ports, and your SSH session survived `ufw enable`.

> Docker publishes ports by writing iptables rules directly and **bypasses ufw**.
> That is why no project on this box may publish a port: only `shared-proxy`
> publishes 80/443, and every project talks to it over the `edge` network.

## 3. Docker, from Docker's own apt repository

Follow the current "Install using the apt repository" steps at
https://docs.docker.com/engine/install/ubuntu/ (they change; copy from the
page, not from memory — and not a `curl | sh` one-liner). Then:

```bash
sudo usermod -aG docker deploy
exit                                # log in again so the group applies
docker --version && docker compose version
```
**Done =** both print a version as `deploy`, without `sudo`.

## 4. The box-wide network and the shared entry point

```bash
docker network create edge
sudo mkdir -p /opt/shared-proxy && sudo chown deploy:deploy /opt/shared-proxy
git clone https://github.com/amirg76/kehilapp-devops.git /opt/kehilapp
cp -r /opt/kehilapp/shared-proxy/. /opt/shared-proxy/
cd /opt/shared-proxy
printf 'ACME_EMAIL=you@example.com\n' > .env     # Let's Encrypt notices
docker compose up -d
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
curl -sI http://<IP>/ | head -1                   # HTTP/1.1 404 — the "nothing here" answer
```
**Done =** `caddy validate` prints no error, bare-IP HTTP answers 404.

`/opt/shared-proxy` is a copy on purpose: it belongs to the box, not to one
project. When a project's `.caddy` file changes in git, copy it over and
`docker compose restart caddy`.

## 5. DNS at Hostinger

Add an **A record**: name `kehilapp`, points to `<IP>`, TTL the default.
Wait until it resolves from your laptop:
```bash
nslookup kehilapp.letstalkanddesign.com     # must show <IP>
```
**Done =** resolves. Caddy cannot issue a certificate before this.

## 6. kehilapp's own stack

```bash
cd /opt/kehilapp
cp .env.example .env
nano .env
```
Fill in every "yes" row of the README table ("Server .env"). On this box:
- `REGISTRY=ghcr.io/amirg76`, `TAG=latest`
- `APP_BASE_URL=https://kehilapp.letstalkanddesign.com`
- `ALLOWED_ORIGINS=https://kehilapp.letstalkanddesign.com`
- `MONGO_URI` = the Atlas SRV string for database `kehilapp_demo`
- `DOMAIN` / `ACME_EMAIL` may stay empty: the project's own Caddy is not
  started here (docker-compose.netcup.yml), the shared one holds the certificate.

Then, in **Atlas → Network Access**, allow `<IP>/32` (replace the temporary
`0.0.0.0/0`).

```bash
docker compose -f docker-compose.prod.yml -f docker-compose.netcup.yml --env-file .env pull
docker compose -f docker-compose.prod.yml -f docker-compose.netcup.yml --env-file .env up -d
docker compose -f docker-compose.prod.yml -f docker-compose.netcup.yml ps
```
**Done =** mongo, backend, frontend, admin, proxy are `Up`; **no** `caddy`
line (it sits behind the `standalone` profile); `docker ps` shows no project
port on the host, only shared-proxy's 80/443.

## 7. Verify from the outside

```bash
curl -sI https://kehilapp.letstalkanddesign.com/ | grep -iE "^HTTP|strict-transport"
curl -s  https://kehilapp.letstalkanddesign.com/healthz
curl -s  https://kehilapp.letstalkanddesign.com/readyz          # 200 only when Mongo is connected
curl -sI https://kehilapp.letstalkanddesign.com/admin/ | head -1
curl -s  https://kehilapp.letstalkanddesign.com/api/messages | head -c 200
```
**Done =** 200 on all, HSTS header present, `/api/messages` returns JSON.
Then the real test: register with a real address, receive the Resend email,
verify, log in. If the verification link points at the wrong host,
`APP_BASE_URL` is wrong.

## 8. Seed demo data (once)

```bash
docker compose -f docker-compose.prod.yml -f docker-compose.netcup.yml exec backend node scripts/seedDemo.js
```
It refuses any database whose name is not `*_demo` — that is the guard, not a bug.

## When something is wrong

- `proxy` is `Up` but the site times out → is `kehilapp-proxy` on `edge`?
  `docker network inspect edge` must list it.
- Certificate errors → DNS not resolving to this IP yet, or port 80 blocked;
  `docker compose -f /opt/shared-proxy/docker-compose.yml logs caddy`.
- Everyone locked out after a few wrong passwords → `TRUST_PROXY_HOPS` is not
  `2`; the chain is still client → Caddy → nginx → backend.
- Next deploys: runbook 02, step 2 (same two `-f` files).

## Adding the next project to this box

1. Its compose: no `ports:`, its edge container joins `edge` under a fixed
   `container_name`.
2. One file `/opt/shared-proxy/sites/<project>.caddy` with its hostname and
   `reverse_proxy <container_name>:<port>`.
3. A record at Hostinger → `docker compose restart caddy` in `/opt/shared-proxy`.
