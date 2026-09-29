# 03 — Rolling back a bad deploy

A deploy went out and something broke. Get back to the last good version fast.

## The idea

Every CI build pushes the backend image with **two** tags:
- a moving tag (`latest` for prod, `dev` for dev), and
- an **immutable** 7-char git SHA tag (e.g. `a1b2c3d`).

Rolling back = telling the server to run a **previous SHA** instead of `latest`.

## 1. Find the previous good SHA

From your machine (looks at the container registry):
```bash
# List tags on the backend package (GitHub → your profile → Packages also shows them).
gh api /users/OWNER/packages/container/kehilapp-backend/versions \
  --jq '.[].metadata.container.tags[]' | head
```
Or just use the commit SHA of the last known-good merge from `git log`.

## 2. Deploy that SHA on the box

```bash
ssh -i ~/.ssh/kehilapp ubuntu@<IP>
cd /opt/kehilapp

export REGISTRY=ghcr.io/<owner-lowercase>
export TAG=<previous-good-sha>        # e.g. a1b2c3d

docker compose -f docker-compose.prod.yml --env-file .env pull backend
docker compose -f docker-compose.prod.yml --env-file .env up -d backend
```

## 3. Verify it recovered

```bash
docker compose -f docker-compose.prod.yml exec -T backend wget -qO- http://127.0.0.1:5001/readyz
curl https://your-domain/api/healthz
docker compose -f docker-compose.prod.yml logs --tail=50 backend
```

## 4. Make the rollback stick

Nothing deploys automatically any more (deploys are by hand, or the manual
AWS showcase workflow), but the next `build-images` run re-tags `latest` from
the app repos' `main`. So after rolling back, also **revert the bad commit**
in the app repo so the next build can't reship it:
```bash
git revert <bad-commit-sha>
git push
```

## Notes / gotchas

- **Database migrations**: rolling the *image* back does **not** undo schema or
  data changes. If the bad release changed Mongo data, restore from a backup
  (see below) — code rollback alone may not be enough.
- **Mongo data safety**: data lives in the `mongo_data` docker volume, which
  survives container restarts. Take periodic dumps:
  ```bash
  docker compose -f docker-compose.prod.yml exec -T mongo \
    mongodump --archive --gzip > backup-$(date +%F).gz
  ```
  Restore:
  ```bash
  docker compose -f docker-compose.prod.yml exec -T mongo \
    mongorestore --archive --gzip < backup-YYYY-MM-DD.gz
  ```
- **Whole box gone?** `terraform apply` rebuilds it, then follow
  `01-initial-server-setup.md`. (Your Mongo volume is gone with the box unless
  you had a dump — keep backups off-box for prod.)
