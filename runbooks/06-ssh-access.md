# 06 — SSH access

How to log in, add teammates, and stay locked down.

## Log in

```bash
# The exact command is printed by Terraform:
cd terraform && terraform output ssh_command
# e.g.:
ssh -i ~/.ssh/kehilapp ubuntu@<IP>
```
- Default user on Ubuntu AMIs is **`ubuntu`**.
- `-i ~/.ssh/kehilapp` is your **private** key (the one WITHOUT `.pub`).

## Make your key (if you don't have one yet)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/kehilapp -C "kehilapp"
# creates ~/.ssh/kehilapp (private, keep secret) and ~/.ssh/kehilapp.pub (public)
```
Terraform uploads the `.pub` as the EC2 key pair (`create_key_pair = true`).

## Common problems

| Symptom | Cause / fix |
|---------|-------------|
| `Permission denied (publickey)` | Wrong key file, or wrong user (use `ubuntu`). |
| Connection just hangs / times out | Security group `allowed_ssh_cidr` isn't your current IP. Update `*.tfvars` → `terraform apply`. Your home IP may have changed — recheck `curl ifconfig.me`. |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | You rebuilt the box (new host key). Remove the old line: `ssh-keygen -R <IP>`. |

## Lock SSH down (do this)

- Keep `allowed_ssh_cidr` set to **your IP /32**, never `0.0.0.0/0`.
- The box already uses key-only auth (Ubuntu AMIs disable password login).

## Add another person's key (without sharing your private key)

Get their **public** key, then on the box:
```bash
ssh -i ~/.ssh/kehilapp ubuntu@<IP>
echo "ssh-ed25519 AAAA...their-public-key... teammate" >> ~/.ssh/authorized_keys
```
To revoke, delete that line from `~/.ssh/authorized_keys`.

> Cleaner long-term: add their key to Terraform (a second `aws_key_pair` or an
> `authorized_keys` block in `userdata.tpl`) so access is version-controlled
> instead of hand-edited on the box.

## A convenient shortcut (optional)

Add to `~/.ssh/config` on your laptop:
```
Host kehilapp-prod
    HostName <PROD_IP>
    User ubuntu
    IdentityFile ~/.ssh/kehilapp
```
Then just: `ssh kehilapp-prod`.

## Copy files to/from the box

```bash
scp -i ~/.ssh/kehilapp ./somefile ubuntu@<IP>:/opt/kehilapp/    # up
scp -i ~/.ssh/kehilapp ubuntu@<IP>:/opt/kehilapp/backup.gz .    # down
```
