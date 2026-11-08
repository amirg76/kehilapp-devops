# 00 — The shared box, from bare Ubuntu to a running demo

This is the guide for the **always-on demo** (runbook 01 is for the AWS showcase
box, where Terraform has already done steps 2–4 for you). A fresh VPS arrives
empty: Ubuntu, a root password, no Docker, no firewall.

Decided 2026-09-28 (one shared box for every small project) and 2026-10-11
(one shared public entry point, `shared-proxy/`, instead of a Caddy per project).

> **Status: ran end-to-end on 2026-10-29** on a Hostinger KVM 4 (not netcup —
> netcup replaced its G12 line and raised prices in 9/2026; the steps are
> provider-independent). `https://kehilapp.letstalkanddesign.com` answered
> 200 with HSTS, `/readyz` reported `db: up`, the demo seed ran. See
> "First-run notes" at the end for what differed from the dry text.
> Adding another project: `shared-proxy/ADDING-A-TENANT.md`.

**Hostinger-specific, before step 1:** in the panel's setup wizard choose the
location (Frankfurt was closest), **Ubuntu 24.04 LTS** (the wizard defaults to
the newest release; stay on the version these steps were verified on), set a
root password you will never use, and paste your **public** key under
"Add SSH key" — it lands in root's `authorized_keys`, so step 1 copies it
rather than pasting it. Leave "Docker manager" and the malware scanner off:
Docker is installed below from Docker's own repository and managed in code;
two managers of one Docker collide.

## 0. What you need in hand

- The provider's confirmation: IP address and root password (you'll stop using
  it in step 1). First run: Hostinger KVM 4, 4 vCPU / 16 GB / 200 GB NVMe.
- An SSH key on your laptop, **with a passphrase**, loaded in an agent:
  `ssh-keygen -t ed25519 -f ~/.ssh/<key-name> -C <label>`, then
  `ssh-add ~/.ssh/<key-name>`. Prove the file is locked:
  `ssh-keygen -y -f ~/.ssh/<key-name>` must *ask* for the passphrase.
  (`ssh-keygen -p` without `-f` defaults to a *different* key — always `-f`.)
- Hostinger DNS access for `letstalkanddesign.com`.
- The values for the kehilapp `.env` (README table "Server .env"): Atlas SRV
  string, Resend key, JWT secret, S3 bucket, Anthropic key (optional).

## 1. First login and a non-root user

```bash
ssh root@<IP>                      # with the key the panel installed for root
adduser --disabled-password --gecos "" deploy      # no password at all: the key is the credential
usermod -aG sudo deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
install -m 600 -o deploy -g deploy /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
printf 'deploy ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-deploy
chmod 440 /etc/sudoers.d/90-deploy && visudo -cf /etc/sudoers.d/90-deploy   # "parsed OK" or sudo is broken
ssh-keygen -lf /home/deploy/.ssh/authorized_keys   # fingerprint must equal `ssh-add -l` on your laptop
```
`deploy` has no password and sudo asks for none — the same shape as the
`ubuntu` user on an AWS image; the locked key on your laptop is the credential.
(It is also what lets an automation run these steps: nothing to type.)

From a **second** terminal, before closing the root one:
```bash
ssh deploy@<IP>                    # must log in with the key, no password prompt
```
Only once that works, disable password and root logins. **Not** by editing
`/etc/ssh/sshd_config`: on Ubuntu 22.04/24.04 that file starts with
`Include /etc/ssh/sshd_config.d/*.conf`, sshd keeps the **first** value it
meets, and cloud images ship a drop-in there (often `50-cloud-init.conf` with
`PasswordAuthentication yes`) that silently wins over anything below. A drop-in
that sorts first is the only edit that sticks:
```bash
printf 'PasswordAuthentication no\nPermitRootLogin no\nKbdInteractiveAuthentication no\nX11Forwarding no\nMaxAuthTries 3\nAllowUsers deploy\n' \
  | sudo tee /etc/ssh/sshd_config.d/00-hardening.conf
grep -rn -iE "PasswordAuthentication|PermitRootLogin" /etc/ssh/sshd_config.d/   # see what else is there
sudo sshd -t                                   # syntax check BEFORE restarting
sudo sshd -T | grep -iE "^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication)"
sudo systemctl restart ssh
```
`sshd -T` prints the configuration **as sshd resolves it**, not what one file
says. All three lines must read `no`. Then prove it from your laptop, with the
key switched off so only a password could get you in:
```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive deploy@<IP>
```
**Done =** that command is refused (`Permission denied (publickey)`),
`ssh root@<IP>` is refused, and `ssh deploy@<IP>` with the key still works.
Keep the root terminal open until all three hold.

## 2. Updates and firewall

```bash
sudo apt update && sudo apt -y upgrade
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp comment 'HTTP/3'
sudo ufw enable                     # answer y
sudo ufw status                     # 22, 80, 443 (tcp and udp) — nothing else
```
**Done =** those ports only, and your SSH session survived `ufw enable`.

> Docker publishes ports by writing iptables rules directly and **bypasses ufw**.
> That is why no project on this box may publish a port: only `shared-proxy`
> publishes 80/443, and every project talks to it over the `edge` network.

## 3. Docker, from Docker's own apt repository

Follow the current "Install using the apt repository" steps at
https://docs.docker.com/engine/install/ubuntu/ (they change; copy from the
page, not from memory — and not a `curl | sh` one-liner). Then:

```bash
sudo usermod -aG docker deploy
sudo dockerd --validate --config-file=/opt/kehilapp/shared-proxy/box/daemon.json
sudo install -m 644 /opt/kehilapp/shared-proxy/box/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
exit                                # log in again so the group applies
docker --version && docker compose version
docker info --format '{{.LiveRestoreEnabled}} {{.LoggingDriver}}'   # true local
```
**Done =** both print a version as `deploy`, without `sudo`, and the last line
reads `true local`. `live-restore` keeps containers running while the Docker
daemon restarts, so a Docker upgrade does not take the sites down; `local`
rotates the logs of any container that does not set its own driver.

## 4. The box-wide network and the shared entry point

> `git clone` fetches `main`. The files used below exist on `main` only once
> the pull request that added them (`shared-proxy/`, `docker-compose.shared-box.yml`,
> this runbook) has been merged. Check on GitHub first.

**What `edge` means:** every container on it can reach every other one on it
directly, by name, bypassing the shared Caddy (no TLS, no hostname check). It
is a **full-trust network between the tenants of this box** — all of them are
this owner's own projects. Databases and application containers stay on their
project's private network (kehilapp: `kehilnet`); only the edge/nginx container
of each project joins `edge`. If a tenant you do not fully trust ever lands
here, that assumption is gone and the admin paths need their own authentication
at nginx.

```bash
docker network create edge
# /opt belongs to root; create both folders as root and hand them to deploy,
# or the clone below fails with "Permission denied" (gate, 26.10).
sudo mkdir -p /opt/shared-proxy /opt/kehilapp && sudo chown deploy:deploy /opt/shared-proxy /opt/kehilapp
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
- `REGISTRY=ghcr.io/amirg76`, `TAG=latest` for the first start only (see "Deploying a new build")
- `APP_BASE_URL=https://kehilapp.letstalkanddesign.com`
- `ALLOWED_ORIGINS=https://kehilapp.letstalkanddesign.com`
- `MONGO_URI` = the Atlas SRV string for database `kehilapp_demo`
- `DOMAIN` / `ACME_EMAIL` may stay empty: the project's own Caddy is not
  started here (docker-compose.shared-box.yml), the shared one holds the certificate.

Then, in **Atlas → Network Access**, allow `<IP>/32` (replace the temporary
`0.0.0.0/0`).

```bash
docker compose -f docker-compose.prod.yml -f docker-compose.shared-box.yml --env-file .env pull
docker compose -f docker-compose.prod.yml -f docker-compose.shared-box.yml --env-file .env up -d
docker compose -f docker-compose.prod.yml -f docker-compose.shared-box.yml ps
```
**Done =** mongo, backend, frontend, admin, proxy are `Up`; **no** `caddy`
line (it sits behind the `standalone` profile); `docker ps` shows no project
port on the host, only shared-proxy's 80/443.

## 7. Verify from the outside

First the certificate. Caddy answers plain HTTP on `:80` with a 404 for
unknown hosts (shared-proxy/Caddyfile); Let's Encrypt's HTTP-01 challenge for
a **known** host is handled by Caddy before any site block, and TLS-ALPN-01 on
443 is the fallback. Neither was exercised before the first real box, so look:
```bash
docker compose -f /opt/shared-proxy/docker-compose.yml logs caddy | grep -iE "certificate obtained|obtaining|error"
```
**Done =** a `certificate obtained successfully` line for the hostname, no
`error` lines after it. If the challenge fails, the usual causes are the A
record not resolving to this box yet, or port 80 closed.

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
docker compose -f docker-compose.prod.yml -f docker-compose.shared-box.yml --env-file .env \
  exec -T -e NODE_ENV=development backend node scripts/seedDemo.js
```
Two guards, both on purpose: it refuses `NODE_ENV=production` (compose sets
that for the backend, hence the one-off `-e NODE_ENV=development` on the
`exec` only — the running container is untouched), and it refuses any
database whose name does not end in `_demo`. The second one is also your
proof that `MONGO_URI` names the right database: on the first run (29.10) the
pasted Atlas string ended in `/` with no database name, Mongo silently used
`test`, `/api/messages` answered 500, and this script would have refused.
Check before seeding: `grep -c 'mongodb.net/kehilapp_demo?' .env` must be 1.

## Deploying a new build

`build-images.yml` tags every run `build-<run number>`; the number is on the run's
Actions page. On the box:
```bash
cd /opt/kehilapp
git pull --ff-only
bash scripts/deploy-shared-box.sh build-57
```
**Done =** the last line is `DEPLOY OK`. The script pulls first, so a tag that does
not exist changes nothing. It then waits for health and checks by content: each
app's own text at its address, every asset in the page, and `db: up` from `/readyz`.
A status code alone stayed green for 41 hours on 29.10.

**Undo:** `bash scripts/deploy-shared-box.sh rollback` returns to the last good tag,
even after several failed attempts. After a good deploy, a second rollback swaps back.
It changes the application images only. nginx for `proxy` comes from the compose file,
so undoing that means reverting the commit and `git pull`.

The script refuses `latest`. When the box is still on `latest`, it keeps the running
images under a local `pre-<date>` tag first, so the first rollback has a target.

`reverse-proxy.conf` looks service names up again every 10 seconds, so a recreated
service needs no `restart proxy`. Proved locally with addresses swapped on purpose.
Changing that file itself is different: it is a mount, so `up -d` does not notice.
After such a change run `docker compose ... exec proxy nginx -s reload`.

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

Full checklist for a new tenant: `shared-proxy/ADDING-A-TENANT.md`.

## Hardening pass 2026-11-03

Checked against current guidance (Docker engine security, logging and
resource-constraint docs, OWASP Docker cheat sheet, Caddy releases) and
measured on the box before anything changed:

- **Logs never rotated.** Docker's default `json-file` driver keeps
  everything. The idle `kehilapp-mongo-1` (unused: the backend talks to Atlas)
  had written **312 MB in 5 days**. No `/etc/docker/daemon.json` existed.
- **No container had limits.** `HostConfig.Memory=0`, no `pids_limit`, no
  `cap_drop`, no `no-new-privileges` on any kehilapp or shared-proxy
  container. Idle usage: mongo 107 MiB/35 pids, backend 54 MiB/12, each
  nginx ~4.5 MiB/5, Caddy 14 MiB/10, of 16 GB.
- **Caddy 2.10.2**, while 2.11.7 (3.10.2026) carries the 2.11.x security fixes.
- **`Server: nginx/1.27.5`** on every public response (measured from outside).
- Already fine, measured: unattended-upgrades enabled and active (security
  updates daily, `Automatic-Reboot` unset = off), no reboot pending, Docker
  29.9.2 = latest 29.x, only 22/80/443 answer from outside (16 ports probed).

**What changed** (compose + nginx config only, same images):

1. Every kehilapp service merges `x-baseline` in `docker-compose.prod.yml`:
   `no-new-privileges`, `cap_drop: [ALL]`, `local` log driver (3 x 10 MB).
   Each service adds back only what it was shown to need, and gets a
   `mem_limit`/`pids_limit` with headroom over the measurement.
2. `shared-proxy`: `caddy:2.11-alpine` with the same baseline, keeping only
   `NET_BIND_SERVICE`.
3. `server_tokens off;` in both nginx conf.d files.

**How the capability sets were found:** throwaway containers on the box
(names `t-*`, no published ports, removed afterwards; live containers
untouched), each started with the new flags:

```
T1 nginx:1.27-alpine + reverse-proxy.conf on kehilnet, caps CHOWN SETUID SETGID NET_BIND_SERVICE
   HTTP/1.1 200 OK, Server: nginx, resident marker 1, admin marker 1, {"status":"ok","db":"up"}
T2 kehilapp-frontend image + spa conf, same caps      -> Server: nginx, marker 1
T3 mongo:7, caps CHOWN SETUID SETGID                  -> ping ok after 5 s
T4 caddy:2.11-alpine (v2.11.7), cap NET_BIND_SERVICE  -> :80 answered
T5 caddy validate, REAL Caddyfile + sites/*.caddy, 2.11 -> Valid configuration
```

Caddy 2.11.6 tightened defaults (16 KiB request headers, 1-minute idle
read/write timeouts, request headers containing `.` dropped). Neither site
file sets headers with dots, timeouts or streaming, and both validated.

**Rollback:** revert the commit, `git pull` on the box, `up -d` for both
stacks. No data changes; volumes are untouched.

### Deploy result (3.11, ~15:53–15:56 UTC)

**About 3 minutes of downtime for kehilapp.** The first `up -d` put mongo in a
restart loop: `find: '/data/db/journal': Permission denied`. The mongo
entrypoint runs `find /data/db ! -user mongodb` as root, and the existing
data directories are mode 700 owned by uid 999; with `cap_drop: [ALL]` root
can no longer traverse them. The backend waits for a healthy mongo, so the
API was down. Fixed by adding `DAC_OVERRIDE` to mongo (commit 656b3f2),
then `git pull` + `up -d`: all five healthy in 10 s.
**Lesson:** T3 passed only because the throwaway mongo had an empty volume.
Test a stateful service against a copy of its real data, not a fresh one.

Second trap, same day: the deploy script was streamed with
`ssh ... bash -s`, and `docker compose exec -T caddy caddy validate` read
stdin and swallowed the rest of the script, so the verification part never
ran. Every `exec` in a streamed script gets `</dev/null`.

Verified after the fix (from the box and from outside):

```
caddy v2.11.7, Valid configuration, 0 error log lines since the switch
/ 200 resident marker 1 · /admin/ 200 admin marker 1 · all /assets/ 200
Server: nginx  (no version) · HSTS 1 · CSP 1 · certificate unchanged (to 27.1.2027)
clinicdemo (the other tenant behind the shared Caddy): 200 before and after
every kehilapp + caddy container: no-new-privileges, CapDrop ALL, its cap_add,
  mem/pids limits, log driver local, restarts 0, OOMKilled false
CapBnd of PID 1 (negative control; was a80425fb): nginx 4c1, caddy 400,
  mongo c3, backend 0 · NoNewPrivs 1 everywhere
upload through the real stack: 4,841,538-byte PNG → POST 200 → signed URL
  200, identical bytes → DELETE 200; backend restarts 0, OOMKilled false
memory now: mongo 78 MiB/1 GiB, backend 50/512, nginx ~4.5/64, caddy 13/256
from outside: 22/80/443 open; 2375, 3000, 5001, 6379, 8080, 27017 closed
```

The 312 MB json log went with the old mongo container. One json-file log
remains on the box: `clinicdemo-web`, another tenant. Rule 5 of
ADDING-A-TENANT applies to it; that change belongs to its own project.

## Database: no local mongo, and a backup that was actually restored (3.11)

**The local mongo is gone from this box.** The backend has always talked to
Atlas. Measured first: inside the backend `MONGO_URI` contains `mongodb.net`
(count 1) and not `mongo:27017` (count 0); the local mongo held only
`admin`/`config`/`local`; its only connections in 24 h were its own
healthcheck. `docker-compose.shared-box.yml` now puts it behind the `local-db`
profile and resets the backend's `depends_on`. Removal: `rm -s -f mongo`,
`up -d` (nothing recreated, backend restarts 0), then the 360 MB
`kehilapp_mongo_data` volume. `/`, `/admin/`, `/readyz` (`db: up`) and
`/api/messages` all answered correctly afterwards. Freed ~400 MB disk and
~80 MiB RAM.

**Atlas free (M0) has no backup of its own** (Atlas docs: "Atlas backups are
not available for Free clusters"; an optional $0.10/day snapshot add-on is in
private preview only). MongoDB's own recommendation is `mongodump` /
`mongorestore`, so the drill used exactly that:

```bash
# On the box. The connection string goes from .env into a mode-600 YAML file
# and mongodump reads it with --config: it never appears on a command line.
umask 077; W=$(mktemp -d)
printf 'uri: "%s"\n' "$(grep -m1 '^MONGO_URI=' /opt/kehilapp/.env | cut -d= -f2-)" > "$W/dump.yaml"
docker run --rm --user "$(id -u):$(id -g)" -v "$W":/w mongo:7 \
  mongodump --config=/w/dump.yaml --db=kehilapp_demo --archive=/w/k.archive --gzip
rm "$W/dump.yaml"
docker run -d --name t-restore mongo:7          # throwaway target
docker cp "$W/k.archive" t-restore:/tmp/ && docker exec t-restore \
  mongorestore --archive=/tmp/k.archive --gzip
docker rm -f -v t-restore; rm -rf "$W"          # -v: no orphan volumes
```

Result: `messages 24, users 7, categories 7` dumped (1 s, 5,119 bytes),
`38 document(s) restored successfully. 0 failed`, the same counts in the
restored copy, and the live API agreeing (19 public + 5 members-only = 24
messages, 7 categories). Two traps on the way: the container could not read
a 600 file owned by `deploy` until it ran as `--user deploy`, and
`docker rm -f` without `-v` left four anonymous volumes (removed).

Since 5.11 the same dump runs every night inside the off-box backup (next
section).

**Atlas access list closed (3.11, in the Atlas UI).** `0.0.0.0/0` (any
address) was deleted. Before that, the owner's current PC address was added
(comment "amir-pc, added 3.11.2026"), because it was reachable ONLY through
`0.0.0.0/0`. Left in the list: this box `/32`, the PC, the old
`EC2-BACKEND-DEV` address, and an older "Auto Setup" address. Users: the
box's `kehilapp_demo_srv` (`readWrite@kehilapp_demo` only) and an older
admin user. Proof: `restart backend` forces new connections → healthy in 9 s,
`DB connected`, `/readyz` `db: up`, `/api/messages` 200. A home IP that
changes will need re-adding ("Add Current IP Address").

## Off-box backup and Telegram alerts (5.11)

Everything is in `shared-proxy/box/backup/`; its README has the setup order,
the tests and the accepted limits. In short: every night at 00:20 UTC the box
copies the clinicdemo and trading SQLite files through SQLite's own backup
call, the kehilapp Atlas dump from the section above, every tenant's `.env`
and the Caddy files, encrypts them to a public key whose private half is not
on the box, uploads to an R2 bucket with a 14-day lock, checks the stored
size, and sends one Telegram line. Silence is the alarm.

```bash
B=/opt/kehilapp/shared-proxy/box/backup
bash $B/install.sh          # first run creates /opt/box-ops and stops
# put backup.conf (mode 600) and backup-public.asc in /opt/box-ops, then:
bash $B/install.sh          # installs the scripts, units and the timer
sudo systemctl start box-backup.service   # one real run, then restore-check on the PC
```

`box-alert@.service` is the shared alert: `box-backup`, `clinicdemo-cron` and
`post-reboot-check` all reach it through `OnFailure`. Proven: a full restore
of a downloaded backup (5.11), the timer's own run (8.11, exit 0), and a unit
failing on purpose reaching Telegram (7.11).

## Reboots after kernel updates (3.11)

Security updates install daily (unattended-upgrades). A kernel update only
runs after a reboot, and Ubuntu's default never reboots. Now:
`shared-proxy/box/52unattended-upgrades-local` → `/etc/apt/apt.conf.d/`
turns on `Automatic-Reboot` at **01:30 UTC**, only when an update asked for
it. `post-reboot-check.sh` + `.service` run after every boot: wait 2 min,
check kehilapp `/`, `/admin/` and `/readyz` by content and clinicdemo by 200,
bring both stacks up once more if anything failed, and log one line to
`/var/log/post-reboot-check.log`.

```bash
B=/opt/kehilapp/shared-proxy/box
sudo install -m 644 $B/52unattended-upgrades-local /etc/apt/apt.conf.d/
sudo install -m 755 $B/post-reboot-check.sh /usr/local/sbin/
sudo install -m 644 $B/post-reboot-check.service /etc/systemd/system/
sudo install -D -m 644 $B/post-reboot-check-alert.conf \
  /etc/systemd/system/post-reboot-check.service.d/alert.conf   # needs box-alert@ (backup/install.sh)
sudo systemctl daemon-reload && sudo systemctl enable post-reboot-check
apt-config dump | grep -i automatic-reboot      # three lines, "true"/"01:30"
sudo POST_REBOOT_SLEEP=0 /usr/local/sbin/post-reboot-check.sh   # test, no reboot
```

Proven on 3.11. Negative control first: a copy pointed at a wrong site failed
on all three kehilapp checks and exited 1. Then one controlled reboot: boot
17:59:01 UTC, SSH back on the 4th attempt, all six containers healthy, the
check logged `2026-11-03T18:01:21 OK kernel=6.8.0-147-generic containers=6`,
and kehilapp and clinicdemo answered with the right content. Downtime
under two minutes.

Since 7.11 a failed check sends a Telegram alert through `box-alert@`
(the OnFailure drop-in above). The same day the home check was found too
weak: it looked for `dir="rtl"`, which the admin panel also carries, so it
would have passed during the 29.10 swap. Now each page must carry its own
marker and not the other app's. Proven against a local server that serves
the two live pages swapped: the old script flagged only the admin page, the
new one both.

## Maintenance pass 2026-11-07

Applied in one run on Saturday 7.11 (market closed), each step stopping the
run on failure, with a one-request-a-second probe of both sites throughout.

1. **SSH:** `X11Forwarding no`, `MaxAuthTries 3`, `AllowUsers deploy` added to
   `00-hardening.conf`. Before `systemctl reload ssh`, a transient timer
   (`systemd-run --on-active=180`) was armed to put the old file back; a fresh
   login then cancelled it. The dashboard tunnel (`ssh -L`) still opens, so
   TCP forwarding stays on. A client that offers more than three keys now
   fails with `Too many authentication failures`: give it `IdentitiesOnly yes`
   and the one key.
2. **Docker:** `shared-proxy/box/daemon.json` installed and applied with
   `systemctl reload docker` (live-restore is reloadable), then
   `apt-get install --only-upgrade docker-ce docker-ce-cli
   docker-ce-rootless-extras docker-compose-plugin`: Engine 29.9.2 → 29.9.3,
   Compose 5.6.1 → 5.7.0, containerd unchanged. The `StartedAt` of all 8
   containers was identical before and after: **no container restarted**,
   the trading engine included.
3. **HTTP/3:** Caddy announced `h3` in `Alt-Svc` while UDP 443 was neither
   published nor allowed. Now published (`443:443/udp`) and allowed in ufw.
   Caddy logged `enabling HTTP/3 listener`; three UDP probes from the laptop
   reached `eth0` (tcpdump), so Hostinger does not filter UDP 443; an
   `aioquic` client got `HTTP/3 status 200` from both sites. Chrome stayed on
   h2 for the first half hour, likely because it had marked h3 broken while
   the port was closed. Caddy warned that the UDP receive buffer was small;
   `shared-proxy/box/60-quic-buffers.conf` goes to `/etc/sysctl.d/` and
   applies at Caddy's next start.
4. **Access log:** the `access_log` snippet in `Caddyfile`, imported by each
   site. It drops the query string and the Referer, because verification and
   password-reset links carry their token there. Checked locally with a
   control (without the filter the token appears in the log, with it 0
   times) and live (`?token=` request → 0 matches).

Measured cost: 1 of 43 probes failed, during the Caddy recreate. Previous
files: `/root/00-hardening.conf.pre-20261107` and
`/opt/shared-proxy/backup-20261107/`.

## First-run notes (2026-10-29, Hostinger KVM 4, Ubuntu 24.04.5)

What the dry text above did not know, recorded from the real outputs:

- **The sshd trap was real.** The image shipped *two* drop-ins:
  `50-cloud-init.conf: PasswordAuthentication yes` and
  `60-cloudimg-settings.conf: PasswordAuthentication no`. First value wins, so
  password login was **on** until `00-hardening.conf` existed. `sshd -T`
  before the restart showed all three `no`; after the restart the negative
  test printed `Permission denied (publickey)` for both the password-only and
  the root attempts, and the key login still worked.
- **How the steps were run:** each step as a script file on the laptop,
  streamed with `ssh -o BatchMode=yes deploy@<IP> bash -s < step.sh`. On
  Windows use `C:\Windows\System32\OpenSSH\ssh.exe` (the only client that
  talks to the Windows ssh-agent holding the passphrase-locked key), and strip
  the BOM and CRLF first (`tr -d '\r'`, drop a leading `EF BB BF`) — bash
  chokes on both. Piping from PowerShell adds them back; pipe from Git Bash.
- **Firewall:** `ufw --force enable` (non-interactive); the SSH session
  survived; from outside 22 answered, 80 and 8080 did not (nothing listened
  yet). `apt upgrade` needed no reboot.
- **Docker:** 29.9.2 + Compose v5.6.1 from Docker's apt repo (`noble`);
  `docker ps` as `deploy` without sudo on the next login.
- **Shared proxy:** up first try; `caddy validate` → `Valid configuration`;
  bare-IP HTTP from outside → `404 shared demo box — nothing at this hostname`.
- **DNS:** the A record form in Hostinger's panel was filled by the automation
  but the *Add Record* click was refused by its permission classifier (account
  change) — the owner clicked. Resolved within a minute at Hostinger's
  nameserver and at 8.8.8.8. A `docker compose restart caddy` triggered
  issuance immediately instead of waiting out the backoff:
  `certificate obtained successfully … issuer acme-v02.api.letsencrypt.org`.
  Before kehilapp was up, https answered **502** (Caddy could not resolve
  `kehilapp-proxy` yet) — expected.
- **Scanners arrive in minutes.** Five minutes after the DNS record, the Caddy
  log already showed requests from unrelated IPs. Rule 1 of ADDING-A-TENANT.md
  (no published ports) is not theoretical.
- **`.env` was written with `umask 077`** and a `JWT_SECRET` generated on the
  box (`openssl rand -hex 48`), never displayed. `MONGO_URI` and
  `RESEND_API_KEY` were left as `__FILL__` for the owner. Images were pulled
  before the secrets existed (pull needs only `REGISTRY`/`TAG`).
- **Gap found:** `.env.example` lacks `APP_BASE_URL`, `EMAIL_PROVIDER`,
  `RESEND_API_KEY`, `MAIL_FROM` although the README table and the backend
  require them. Fix the template when next touching it.
- **Step 6/7, the database-name trap:** Atlas's "Connect → Drivers" string
  ends in `/` with no database. Pasted as-is, Mongo connects fine and uses
  `test`; the backend logged `DB connected`, `/readyz` said `db: up`, and the
  only symptom was `/api/messages` → 500. Caught with count-only greps
  (`grep -c 'mongodb.net/ ' .env` = 1), fixed with an in-place `sed -i` (a
  `.env.bak-<date>` copy first), backend recreated, API → 200. Always end the
  string with `/kehilapp_demo?retryWrites=true&w=majority`.
- **Step 7 timing:** `up -d` to all five services healthy: 36 s. Step 8 as
  rewritten above (NODE_ENV override on the exec). Demo logins printed by the
  seed were saved to `/opt/kehilapp/.demo-logins` (mode 600).
