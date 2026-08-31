# 02 — Deploying a new version

There are two ways: **automatic** (normal) and **manual** (when CI is down or
you're testing).

## Automatic (recommended)

The pipeline in `.github/workflows/deploy.yml` does everything:

| You push to… | CI does… | Lands on… |
|--------------|----------|-----------|
| `develop`    | test → build image `:dev` → SSH deploy | the **dev** box |
| `main`       | test → build image `:latest` → SSH deploy | the **prod** box |

```bash
git checkout develop && git push     # ships to dev
# open a PR develop → main, merge     # ships to prod
```

Watch it in the repo's **Actions** tab. A red `test` job means nothing shipped.
For prod you can add a required reviewer on the GitHub `prod` environment so a
human clicks "approve" before it deploys.

### One-time secrets CI needs
Repo → Settings → Secrets and variables → Actions (per environment):
- `SSH_HOST_DEV` / `SSH_HOST_PROD` — the box IP (`terraform output public_ip`)
- `SSH_USER_DEV` / `SSH_USER_PROD` — `ubuntu`
- `SSH_PRIVATE_KEY_DEV` / `SSH_PRIVATE_KEY_PROD` — the **private** key text
- `SSH_PORT_*` — optional, defaults to 22
- `BACKEND_REPO_TOKEN` — only if the backend repo is private

## Manual deploy (on the box)

```bash
ssh -i ~/.ssh/kehilapp ubuntu@<IP>
cd /opt/kehilapp
git pull --ff-only                    # refresh compose/nginx/caddy configs

# Pick the image tag you want:
export REGISTRY=ghcr.io/<owner-lowercase>
export TAG=latest                     # or dev, or a specific 7-char git sha

docker compose -f docker-compose.prod.yml --env-file .env pull
docker compose -f docker-compose.prod.yml --env-file .env up -d
docker image prune -f                 # free disk from the old image
```

## Verify the deploy

```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml exec -T backend wget -qO- http://127.0.0.1:5001/readyz
curl https://your-domain/api/healthz
```

## Deploy a specific version (pin a SHA)

Every CI build also tags the image with the 7-char commit SHA. To deploy an
exact past build, set `TAG=<sha>` and re-run the pull/up commands. This is also
how you **roll forward** to a known-good build — see `03-rollback.md`.
