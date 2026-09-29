# 01 — Initial server setup (zero → running)

Do this **once**, right after `terraform apply` created the box. It gets the
secrets file onto the server and brings the stack up for the first time.

> The Terraform `userdata.tpl` already installed Docker + the compose plugin and
> cloned this repo to `/opt/kehilapp`. It did **not** start the app, because the
> secrets file (`.env`) is never baked into infrastructure. That's this guide.

## 1. Get the server address

```bash
cd terraform
terraform output ssh_command     # e.g. ssh -i ~/.ssh/kehilapp ubuntu@<IP>
terraform output public_ip
```

## 2. Point DNS at the box (prod)

Create an **A record** for your domain → the `public_ip`. Wait for it to
resolve (`ping your-domain`) before you rely on HTTPS — Caddy needs the domain
pointing at the box to get a certificate.

## 3. Log in

```bash
ssh -i ~/.ssh/kehilapp ubuntu@<IP>
# If "permission denied": wrong key, or the security group SSH CIDR isn't your IP.
```

## 4. Confirm Docker is ready

```bash
docker --version
docker compose version
cd /opt/kehilapp && ls        # you should see docker-compose.prod.yml, docker/
```

If the repo folder is empty (clone failed on boot), pull it manually:
```bash
sudo git clone https://github.com/OWNER/kehilapp-devops.git /opt/kehilapp
sudo chown -R ubuntu:ubuntu /opt/kehilapp
```

## 5. Create the secrets file

```bash
cd /opt/kehilapp
cp .env.example .env
nano .env
```
Fill in at minimum:
- `REGISTRY=ghcr.io/<your-owner-lowercase>` and `TAG=latest` (prod) / `dev`
- `JWT_SECRET=` → `openssl rand -hex 48`
- `MONGO_URI` → leave as-is for self-hosted Mongo, or paste an Atlas SRV string
- `ALLOWED_ORIGINS=https://your-domain`
- `DOMAIN` + `ACME_EMAIL` (so Caddy can issue the cert)
- `BUCKET_*` if you use uploads

## 6. (Only if GHCR packages are private) log in to the registry

```bash
echo <YOUR_GHCR_PAT> | docker login ghcr.io -u <your-github-user> --password-stdin
```
Public images need no login.

## 7. Start the stack

```bash
cd /opt/kehilapp
docker compose -f docker-compose.prod.yml --env-file .env pull
docker compose -f docker-compose.prod.yml --env-file .env up -d
docker compose -f docker-compose.prod.yml ps      # all should be "running/healthy"
```

## 8. Verify

```bash
# Backend ready (inside the network):
docker compose -f docker-compose.prod.yml exec -T backend wget -qO- http://127.0.0.1:5001/readyz
# From your laptop, once DNS + cert are ready:
curl -I https://your-domain/            # 200/301
curl https://your-domain/healthz    # {"status":"ok"}
```

Done. From now on, deploys are automatic via CI (see `02-deploy.md`).
