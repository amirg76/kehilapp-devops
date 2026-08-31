# ─────────────────────────────────────────────────────────────────────────────
# outputs.tf — the useful values Terraform prints AFTER `terraform apply`.
# Think of these as "how do I actually reach the thing I just built".
# See them again anytime with:  terraform output
# ─────────────────────────────────────────────────────────────────────────────

output "public_ip" {
  description = "The server's public IP. Point your DNS A-record here. (Elastic IP if enabled, else the instance's own IP.)"
  value       = var.assign_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
}

output "instance_id" {
  description = "AWS id of the EC2 box (handy for the console / aws CLI)."
  value       = aws_instance.app.id
}

output "ssh_command" {
  description = "Copy-paste this to log in. Assumes your private key matches public_key_path. Ubuntu's default user is 'ubuntu'."
  value = format(
    "ssh -i %s ubuntu@%s",
    trimsuffix(pathexpand(var.public_key_path), ".pub"),
    var.assign_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
  )
}

output "ami_id" {
  description = "Which Ubuntu AMI was chosen (for the record; changes over time as Canonical publishes new ones)."
  value       = data.aws_ami.ubuntu.id
}

output "site_url" {
  description = "Where the site will answer once the stack is up. Uses your domain over HTTPS if set, else plain HTTP by IP."
  value = var.domain != "" ? "https://${var.domain}" : format(
    "http://%s",
    var.assign_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
  )
}
