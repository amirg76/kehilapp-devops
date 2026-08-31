# ─────────────────────────────────────────────────────────────────────────────
# providers.tf — which "cloud plugins" Terraform is allowed to talk to, and
# which versions. Pinning versions means a `terraform init` next year builds the
# SAME thing as today (no surprise breaking changes from a newer AWS provider).
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  # The Terraform CLI itself. >= 1.5 gives us the stable `import{}` blocks etc.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 5.0 means "any 5.x, but not 6.0". Safe minor upgrades, no major jumps.
      version = "~> 5.0"
    }
  }

  # ── OPTIONAL remote state (commented out on purpose) ──────────────────────
  # By default Terraform writes state to a LOCAL file (terraform.tfstate) that
  # holds a map of "what I created in AWS". That file is fine for one person on
  # one laptop. For a team, put it in S3 (shared) + DynamoDB (a lock so two
  # people can't apply at once). See terraform/backend.tf.example for a ready
  # block and the exact bucket/table you must create FIRST. It is NOT enforced.
  #
  # backend "s3" {
  #   bucket         = "kehilapp-tfstate-<youraccountid>"
  #   key            = "kehilapp/terraform.tfstate"
  #   region         = "eu-central-1"
  #   dynamodb_table = "kehilapp-tflock"
  #   encrypt        = true
  # }
}

# The AWS provider reads the region from var.region (see variables.tf).
# Credentials are NEVER put here — Terraform picks them up from your
# environment: `aws configure` (~/.aws/credentials) or AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY env vars. Keeping keys out of code is the whole point.
provider "aws" {
  region = var.region

  # Every resource gets these tags automatically — makes the AWS bill and the
  # console readable ("who made this? which env?").
  default_tags {
    tags = {
      Project     = "kehilapp"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
