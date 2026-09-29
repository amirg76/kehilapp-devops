# 02 — Deploying a new version

Two steps: **build** (GitHub Actions, on demand) and **deploy** — by hand on
the netcup demo box, or through the `deploy (AWS showcase)` workflow on a box
Terraform just created. Two targets, one set of images; see the README.

About `deploy.yml`: its first version (31.8) tested, built and SSH-deployed on
every push, ran once and failed on a wrong repo name. It is now only the AWS
showcase deploy, run by hand: pick the tag, and it pulls and restarts on the
box named in the `aws-showcase` environment secrets (listed at the top of the
file). Building moved to `build-images.yml`.

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

## Step 2b — Deploy to the AWS showcase box (`deploy (AWS showcase)` workflow)

Only for the demonstration run: after `terraform apply`, before `destroy`.

One-time, Repo → Settings → Environments → **aws-showcase** → secrets:
- `SSH_HOST` — the box IP (`terraform output public_ip`)
- `SSH_USER` — `ubuntu`
- `SSH_PRIVATE_KEY` — the **private** key text of the pair Terraform uploaded
- `SSH_PORT` — optional, defaults to 22

Then Actions → **deploy (AWS showcase)** → Run workflow → tag (`latest` or a
short SHA from a build-images run). It pulls, restarts, and checks `/readyz`
from inside the docker network. The box must already have `/opt/kehilapp`
with the compose file and a filled `.env` (runbook 01).

## Step 2a — Deploy to the netcup demo box (by hand, on the box)

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
