# Monthly cost estimate — kehilapp on AWS

> **One-line caveat:** all prices below are approximate, **region-dependent, and
> change** — verify the live numbers in the AWS pricing pages / calculator for
> your region at purchase time. Figures here use **eu-central-1 (Frankfurt)** /
> us-east-1 as of early 2026 and assume a month = **730 hours**.

## The big levers

1. **Instance size** — the biggest line item.
2. **How many boxes** — one shared box (cheap) vs. two separate boxes (proper).
3. **Where Mongo lives** — free Atlas M0 vs. self-hosted on the EC2 (also $0
   extra, but uses the box's RAM/disk).

**Prefer ARM / Graviton (`t4g.*`).** It is ~20% cheaper than the equivalent
Intel `t3.*` size, and every image in this stack has native arm64 builds — so
there is no downside. That's why it's the default.

---

## Unit prices used

| Item | Price | Notes |
|------|-------|-------|
| EC2 `t4g.micro` (1 vCPU/1 GB, ARM) | ~$0.0084/hr → **~$6.13/mo** | cheapest; dev-grade |
| EC2 `t4g.small` (2 vCPU/2 GB, ARM) | ~$0.0168/hr → **~$12.26/mo** | recommended for anything running Mongo |
| EC2 `t3.micro` (2 vCPU/1 GB, Intel) | ~$0.0104/hr → **~$7.59/mo** | x86 alternative; only if you need x86 images |
| EBS **gp3** storage | ~$0.08–0.096 /GB-mo | 20 GB ≈ **$1.7–1.9**, 30 GB ≈ **$2.5–2.9** |
| **Public IPv4 address** | ~$0.005/hr → **~$3.60/mo each** | Since Feb 2024 AWS charges for **every** public IPv4, *even one attached to a running instance*. An unattached Elastic IP or a 2nd EIP costs the same ~$3.60/mo. |
| Route 53 hosted zone | **$0.50/mo** per domain | + trivial per-query cost |
| Data transfer OUT | first **100 GB/mo free**, then ~$0.09/GB | a small app is almost always $0 here |
| MongoDB Atlas **M0** | **$0** | free shared tier, ~512 MB storage |
| Self-hosted Mongo on the box | **$0 extra** | uses the box's disk/RAM instead |
| S3 (uploads bucket, `BUCKET_*`) | usage-based | a few GB + light traffic ≈ **<$1/mo** |
| Terraform remote state (S3+DynamoDB, optional) | ~**$0** | pennies at this scale |

> **Reserved/Savings note:** the numbers above are **on-demand**. A 1-year
> Compute Savings Plan or Reserved Instance cuts EC2 ~30–40% if you commit.

---

## Option 1 — LOW / cheapest viable (one small ARM box)

One `t4g.small` runs **both** dev and prod stacks colocated (two compose
projects on the same box, different ports/domains), Mongo via free Atlas M0.

| Line | Monthly |
|------|--------:|
| 1× `t4g.small` | $12.26 |
| 1× gp3 20 GB | $1.80 |
| 1× public IPv4 | $3.60 |
| Route 53 (1 zone) | $0.50 |
| Data transfer (<100 GB) | $0.00 |
| Mongo Atlas M0 | $0.00 |
| **Total** | **≈ $18.16 / mo** |

**Even cheaper** — swap the box for a `t4g.micro` (fine if you run *one* env or
very light dev): **≈ $12 / mo**. That is the floor for a real, always-on setup.

---

## Option 2 — PROPER (two separate boxes)

Full isolation: a dedicated dev box and a dedicated prod box, each self-hosting
its own Mongo (data stays on-box, nothing shared with dev).

| Line | Dev | Prod |
|------|----:|-----:|
| EC2 | `t4g.micro` $6.13 | `t4g.small` $12.26 |
| gp3 storage | 20 GB $1.80 | 30 GB $2.70 |
| Public IPv4 | $3.60 | $3.60 |
| Route 53 | shared $0.50 | — |
| Mongo | self-host $0 | self-host $0 |
| Data transfer | ~$0 | ~$0 |
| **Subtotal** | **$12.03** | **$18.56** |

**Total ≈ $30.59 / mo** (both boxes). Use `t4g.small` for dev too and it's
**≈ $36.7 / mo**. Move prod's Mongo to Atlas (paid M10 ~$57/mo) only when you
need managed backups/HA — not needed at this stage.

---

## 2026 AWS Free Tier (new accounts)

As of 2026 AWS restructured the free tier: a **new account gets credits
(commonly $100, up to ~$200 if you complete activities) usable for ~6 months**,
plus some always-free allowances. In practice a brand-new account can run
**Option 1 at effectively $0 for the first several months** while the credits
last, then it converts to the numbers above. Don't architect around free credits
running out — treat them as a runway, not a plan. **Verify current free-tier
terms at signup; they change.**

---

## Quick recommendation

- **Just launching / learning:** Option 1 on a `t4g.micro` or `t4g.small`,
  Atlas M0. ~$12–18/mo (or ~$0 on new-account credits).
- **Real users, want dev/prod isolation:** Option 2, ~$31/mo.
- **Always** keep the box on ARM Graviton, keep only one public IPv4 per box,
  and release Elastic IPs you're not using (they bill even when idle).
