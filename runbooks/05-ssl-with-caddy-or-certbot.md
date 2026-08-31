# 05 — HTTPS / SSL

You have two options. **Caddy is the default and by far the easiest** — this
stack is already wired for it. Certbot is documented as a fallback.

---

## Option A — Caddy (recommended, already wired)

`docker-compose.prod.yml` runs a `caddy` service on ports 80/443. It reads
`docker/caddy/Caddyfile`, automatically requests a free Let's Encrypt
certificate for `$DOMAIN`, renews it forever, and reverse-proxies to the
internal nginx `proxy`. You do essentially nothing.

### Steps
1. **DNS first.** Point an A record: `your-domain → server public IP`. Confirm:
   ```bash
   dig +short your-domain      # must return the box's IP
   ```
2. **Set the vars** in `/opt/kehilapp/.env`:
   ```
   DOMAIN=your-domain
   ACME_EMAIL=you@example.com
   ```
3. **Bring the stack up** (or restart just Caddy):
   ```bash
   cd /opt/kehilapp
   docker compose -f docker-compose.prod.yml --env-file .env up -d
   docker compose -f docker-compose.prod.yml logs -f caddy   # watch it get the cert
   ```
4. **Verify:**
   ```bash
   curl -I https://your-domain/      # HTTP/2 200, valid cert
   ```

### Notes
- Certs are stored in the `caddy_data` docker volume — **do not delete it** or
  you'll re-request certs and can hit Let's Encrypt rate limits.
- Port **80 must stay open** to the world: Caddy uses it for the ACME challenge
  and to redirect HTTP→HTTPS. The Terraform security group already opens it.
- Test/staging to avoid rate limits: add `acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`
  in the Caddyfile global block, then remove it for the real cert.

---

## Option B — Certbot + nginx (fallback, no Caddy)

Use this only if you must not run Caddy. You'd stop the `caddy` service and
publish 80/443 from the `proxy` (nginx) service instead, then:

```bash
# On the box, get certs onto the host:
sudo apt-get update && sudo apt-get install -y certbot
sudo systemctl stop <whatever holds :80>       # certbot standalone needs :80
sudo certbot certonly --standalone -d your-domain -m you@example.com --agree-tos -n
# Certs land in /etc/letsencrypt/live/your-domain/{fullchain.pem,privkey.pem}
```
Then mount `/etc/letsencrypt` into the nginx container and add a `listen 443 ssl;`
server block referencing those two files. Renewal:
```bash
sudo certbot renew --dry-run          # test
# add a cron/systemd-timer: certbot renew && docker compose restart proxy
```

This is more moving parts (manual renewal wiring, cert mounts) — which is
exactly why Caddy is the default here.
