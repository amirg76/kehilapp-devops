# Adding a project ("tenant") to the shared box

The box is one Ubuntu server with one public entry point: the Caddy in this
folder holds ports 80/443 and routes by hostname. Every project is a tenant
behind it. This page is what another project's Claude session (or a person)
needs in order to join — nothing here is kehilapp-specific.

Box facts (first run 2026-10-29): Hostinger KVM 4, Ubuntu 24.04, user `deploy`
(key only, passwordless sudo), Docker Engine + Compose from Docker's apt repo,
ufw allowing 22/80/443 only, `/opt/shared-proxy` = this folder, `/opt/<project>`
per tenant. The IP and SSH key name live in the owner's project registry, not
in this public repo.

## The four rules

1. **No `ports:` in your compose file.** Docker's published ports bypass ufw.
   Only `shared-proxy` publishes 80/443. A tenant that publishes a port is
   reachable from the internet with no TLS and no firewall — and it will be
   found within minutes (the Caddy log showed scanners hitting the box five
   minutes after the first DNS record went live).
2. **Exactly one of your containers joins the external network `edge`**, with
   a fixed `container_name` (for example `careerflow-web`). That is the
   container Caddy forwards to. Databases and workers stay on your project's
   own private network.
3. **One file here: `sites/<project>.caddy`.** Hostname → `reverse_proxy
   <container_name>:<port>`. Copy `sites/kehilapp.caddy` and change three
   things (hostname, container name, port). Keep the HSTS header.
4. **Your secrets live in `/opt/<project>/.env`, mode 600, owned by `deploy`.**
   Never in git, never in the compose file, never in the Caddy file.

## Compose overlay (what your project needs)

```yaml
services:
  web:                       # whatever your public-facing service is called
    container_name: careerflow-web
    networks: [default, edge]
    # no ports:
networks:
  edge:
    external: true
```

If your project already ships its own Caddy (like kehilapp does), put it
behind a compose profile so it does not start on this box — see
`docker-compose.netcup.yml` in the repo root for the pattern.

## Steps on the box (as `deploy`)

```bash
sudo mkdir -p /opt/<project> && sudo chown deploy:deploy /opt/<project>
git clone <repo> /opt/<project>
cd /opt/<project> && cp .env.example .env && chmod 600 .env && nano .env
docker compose up -d                      # plus your overlay -f if you have one
docker network inspect edge | grep <container_name>      # must be listed
```

Then the DNS record (an **A** record `<name>` → the box IP, at the registrar
that holds the domain; for `letstalkanddesign.com` that is Hostinger's panel),
then:

```bash
cp /opt/<project>/<path-to>/<project>.caddy /opt/shared-proxy/sites/
cd /opt/shared-proxy && docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose restart caddy
docker compose logs --since 2m caddy | grep -iE "certificate obtained|error"
```

**Done =** `certificate obtained successfully` for your hostname, and
`curl -sI https://<your-hostname>/` answers 200 with a
`strict-transport-security` header.

## Resource courtesy

16 GB RAM is shared. Put `mem_limit` (or `deploy.resources.limits.memory`) on
any container that loads a model or caches aggressively, so one tenant cannot
starve the others. Check the box before and after: `free -h` and
`docker stats --no-stream`.

## Domain not at Hostinger?

If your domain's DNS is at Cloudflare, a Cloudflare Tunnel is the alternative
(no inbound port, no `.caddy` file). Both mechanisms coexist on this box.
Decision record: orchestrator `OPEN-DECISIONS.md`, D-ORC-06.
