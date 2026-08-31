# ─────────────────────────────────────────────────────────────────────────────
# main.tf — the actual infrastructure: ONE small EC2 box that runs the whole
# Docker stack, plus the firewall (security group), a fixed IP (Elastic IP),
# and an SSH key so you can log in.
#
# Mental model: this file describes ONE virtual Linux server. Everything the app
# needs (backend, mongo, both frontends, nginx, caddy) runs as Docker containers
# ON that one server via docker-compose.prod.yml. We are NOT building a big
# multi-service AWS architecture — that would be far more expensive and is
# overkill for this app. (The old WeUnity terraform had ALBs + autoscaling +
# IAM; we deliberately keep it simple and cheap.)
# ─────────────────────────────────────────────────────────────────────────────

# ── 1. Find the newest official Ubuntu 24.04 AMI for the right CPU ────────────
# An AMI is a "disk image" you boot from. Instead of hard-coding an AMI id (they
# differ per region and go stale), we ASK AWS for Canonical's latest Ubuntu.
# The architecture filter is why var.cpu_architecture must match the instance:
# arm64 image for t4g.*, x86_64 image for t3.*.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account id

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-*-server-*"]
  }

  filter {
    name   = "architecture"
    values = [var.cpu_architecture]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── 2. Default VPC + subnet ───────────────────────────────────────────────────
# Every AWS account comes with a "default VPC" (a ready-made private network).
# For one box we just reuse it instead of building networking from scratch.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── 3. Firewall (security group) ──────────────────────────────────────────────
# A security group is a stateful firewall attached to the instance. We open:
#   22  (SSH)   → only from your IP (var.allowed_ssh_cidr)
#   80  (HTTP)  → the world (Caddy needs it to get Let's Encrypt certs + redirect)
#   443 (HTTPS) → the world (the real site)
# Everything else is closed. Mongo (27017) and the backend (5001) are NOT opened
# to the internet — they only talk over the private docker network inside the box.
resource "aws_security_group" "web" {
  name_prefix = "kehilapp-${var.environment}-"
  description = "kehilapp ${var.environment}: SSH from admin, HTTP/HTTPS from world"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH (locked to admin IP)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP - Caddy ACME challenge + redirect to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS - the public site"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound (pull docker images, OS updates, ACME)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "kehilapp-${var.environment}-sg" }

  # Replace-before-destroy so a firewall change never leaves the box unreachable.
  lifecycle {
    create_before_destroy = true
  }
}

# ── 4. SSH key pair ───────────────────────────────────────────────────────────
# Two modes (var.create_key_pair):
#   true  → Terraform uploads your LOCAL public key (~/.ssh/kehilapp.pub) as a
#           new EC2 key pair. Your PRIVATE key never leaves your machine.
#   false → you already made a key pair in the AWS console; we just reference it.
resource "aws_key_pair" "this" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = var.key_name
  public_key = file(pathexpand(var.public_key_path))
}

# ── 5. The server ─────────────────────────────────────────────────────────────
resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.web.id]

  # Use the key we created, or the pre-existing name if create_key_pair = false.
  key_name = var.create_key_pair ? aws_key_pair.this[0].key_name : var.key_name

  # The disk. gp3 is the current-gen SSD: cheaper and faster baseline than gp2.
  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags        = { Name = "kehilapp-${var.environment}-root" }
  }

  # user_data = a script AWS runs ONCE on first boot. It installs Docker + the
  # compose plugin and pulls this repo so docker-compose.prod.yml is on the box.
  # templatefile() injects our variables into userdata.tpl. base64 is required
  # by the API. A change to this rendered script REPLACES the instance, which is
  # usually what you want for a first-boot script.
  user_data_base64 = base64encode(templatefile("${path.module}/userdata.tpl", {
    repo_url    = var.repo_url
    domain      = var.domain
    environment = var.environment
  }))

  tags = { Name = "kehilapp-${var.environment}" }
}

# ── 6. Elastic IP (a fixed public IP) ─────────────────────────────────────────
# By default a stopped/started instance gets a NEW random public IP — bad,
# because your DNS record would break. An Elastic IP is a permanent IP you pin
# to the box. IMPORTANT COST NOTE: one EIP attached to a RUNNING instance is
# free; you are charged (~$3.6/mo) for an EIP that is NOT attached to anything,
# or for a 2nd EIP on the same instance. So: keep the box running, or release
# the EIP when you tear the box down.
resource "aws_eip" "app" {
  count    = var.assign_elastic_ip ? 1 : 0
  instance = aws_instance.app.id
  domain   = "vpc"
  tags     = { Name = "kehilapp-${var.environment}-eip" }
}
