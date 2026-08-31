# 04 — Logs & monitoring

Everything runs as Docker containers, so `docker compose logs` is your main
window. Run these from `/opt/kehilapp` on the box.

## Live logs

```bash
# Everything, following:
docker compose -f docker-compose.prod.yml logs -f

# One service (backend is the usual one):
docker compose -f docker-compose.prod.yml logs -f backend
docker compose -f docker-compose.prod.yml logs -f caddy     # TLS / cert issues
docker compose -f docker-compose.prod.yml logs -f proxy     # routing / 404s
docker compose -f docker-compose.prod.yml logs -f mongo

# Last 100 lines, no follow:
docker compose -f docker-compose.prod.yml logs --tail=100 backend
```

The backend logs JSON in production (winston). Pipe through `jq` to read:
```bash
docker compose -f docker-compose.prod.yml logs --no-log-prefix backend | jq .
```

## Container health at a glance

```bash
docker compose -f docker-compose.prod.yml ps        # status + health column
docker stats --no-stream                            # live CPU / RAM per container
```

The backend image has a built-in HEALTHCHECK hitting `/healthz`, so an unhealthy
backend shows up in `ps` without any extra tooling.

## Health endpoints (what they mean)

| Endpoint | Question it answers | Touches Mongo? |
|----------|---------------------|----------------|
| `/healthz` | Is the process alive? | No (liveness) |
| `/readyz`  | Can it do real work?  | Yes (readiness) |

```bash
# From the box:
docker compose -f docker-compose.prod.yml exec -T backend wget -qO- http://127.0.0.1:5001/healthz
docker compose -f docker-compose.prod.yml exec -T backend wget -qO- http://127.0.0.1:5001/readyz
# Publicly (proxied):
curl https://your-domain/healthz
curl https://your-domain/readyz
```

## Free external uptime monitor

Point a free monitor (UptimeRobot, BetterStack, Hetzner, etc.) at
`https://your-domain/readyz` every 1–5 min. `readyz` returns non-200 when Mongo
is down, so you get alerted on real outages, not just "server pingable".

## Disk & memory (the two things that bite small boxes)

```bash
df -h /                 # disk. Docker images + Mongo data grow over time.
free -m                 # RAM. On t4g.micro (1 GB) watch this closely.
docker system df        # how much docker is using
docker image prune -f   # reclaim space from old images (CI does this too)
```

## System-level logs

```bash
sudo journalctl -u docker --since "1 hour ago"     # docker daemon
sudo tail -f /var/log/cloud-init-output.log        # the first-boot bootstrap
```

## Optional: ship logs somewhere

For a single small box, `docker compose logs` is usually enough. If you outgrow
it, add a lightweight agent (Grafana Alloy / Vector / the CloudWatch agent) to
forward container logs — but don't add this complexity until you actually need
searchable history.
