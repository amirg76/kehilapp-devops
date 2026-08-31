# Terraform — kehilapp infrastructure

This folder builds **one small EC2 server** that runs the whole Docker stack
(`docker-compose.prod.yml`). It is deliberately simple and cheap: no load
balancers, no autoscaling, no managed database. One box, both frontends, the
backend, Mongo, nginx and Caddy — all as containers.

## Files

| File | What it is |
|------|-----------|
| `providers.tf` | Which cloud (AWS) + pinned provider version. |
| `variables.tf` | Every knob (region, size, SSH IP, domain…). Read the comments — the cost tradeoffs live here. |
| `main.tf` | The server, firewall, Elastic IP, SSH key. |
| `outputs.tf` | What you get back: `public_ip`, `ssh_command`, `site_url`. |
| `userdata.tpl` | First-boot script: installs Docker + compose, clones this repo. |
| `dev.tfvars.example` / `prod.tfvars.example` | Copy to `dev.tfvars` / `prod.tfvars` and edit. |
| `backend.tf.example` | Optional S3+DynamoDB remote state (documented, not enforced). |

## Prerequisites (once)

```bash
# 1. Terraform CLI + AWS CLI installed.
# 2. AWS credentials on your machine (kept OUT of this code):
aws configure           # paste an access key/secret for an IAM user
# 3. An SSH key pair on your machine:
ssh-keygen -t ed25519 -f ~/.ssh/kehilapp
```

## Two environments — how they stay separate

Pick ONE of these approaches:

### A) Workspaces (recommended, single folder)
Terraform "workspaces" keep dev and prod **state** apart while sharing the code.

```bash
terraform init

# --- DEV ---
terraform workspace new dev          # first time only
terraform workspace select dev
cp dev.tfvars.example dev.tfvars     # edit your IP/domain
terraform apply -var-file="dev.tfvars"

# --- PROD ---
terraform workspace new prod         # first time only
terraform workspace select prod
cp prod.tfvars.example prod.tfvars
terraform apply -var-file="prod.tfvars"
```

Check which one you're on: `terraform workspace show`.

### B) Separate directories
If you prefer total isolation, copy this folder to `envs/dev` and `envs/prod`,
each with its own `terraform.tfstate`. More files, zero chance of cross-wiring.

## Everyday commands

```bash
terraform fmt        # auto-format (run before committing)
terraform validate   # syntax/logic check, no cloud calls
terraform plan  -var-file="dev.tfvars"   # preview: what WOULD change
terraform apply -var-file="dev.tfvars"   # do it (asks yes/no)
terraform output                         # show IP / ssh command again
terraform destroy -var-file="dev.tfvars" # tear it all down (stops the bill)
```

## After `apply`

`terraform output ssh_command` → log in → follow
`runbooks/01-initial-server-setup.md` to drop the `.env` on the box and start
the stack. The server does **not** auto-start the app on a fresh box because the
secrets file (`.env`) is never baked into infrastructure.

## Cost

See the repo-root [`COST-ESTIMATE.md`](../COST-ESTIMATE.md). Short version: a
single ARM `t4g.small` running dev+prod colocated with Atlas M0 is roughly
**$18/month** (≈$12 on a `t4g.micro`); two separate boxes is roughly
**$31/month** — before free credits. New AWS accounts in 2026 get $100–200 in
credits (≈6 months), so early on this can be **$0**.
