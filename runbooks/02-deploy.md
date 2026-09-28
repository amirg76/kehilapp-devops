# 02 — Deploying a new version

Two steps: **build** (GitHub Actions, on demand) and **deploy** (manual, on the
server).

About `deploy.yml`, which this page used to describe as the automatic path: it
exists, ran once on 2026-08-31, and failed — it checks out a repo named
`kehilapp-backend-hardened`, which is the local folder name, not the GitHub
repo. It builds only the backend, for arm64, and its SSH jobs need secrets that
were never created. It is parked on manual trigger (see the note at the top of
the file). The secrets list at the end of this page belongs to it, for the day
there is a server.

## Step 1 — Build the images (GitHub Actions)

`.github/workflows/build-images.yml` builds the backend, frontend and admin
images from each app repo's `main` and pushes them to GHCR, tagged `latest`
and with this repo's short commit SHA.

- Runs on **Actions → Build images → Run workflow** (optional extra tag), and
  automatically when anything under `docker/` changes on `main`.
- It does **not** run when an app repo changes. After merging app code, run it
  by hand. Each app repo's own CI has already tested that code.

Watch it in the **Actions** tab. A red job means no image was pushed for that
service; the others are unaffected.
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
