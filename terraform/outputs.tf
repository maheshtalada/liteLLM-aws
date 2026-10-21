output "gateway_url" {
  description = "With HTTPS, point a DNS name matching your ACM cert at alb_dns_name."
  value = (
    local.https_enabled ? "https://${aws_lb.this[0].dns_name}" :
    local.caddy_enabled ? "https://${var.public_hostname != "" ? var.public_hostname : "${replace(aws_eip.litellm[0].public_ip, ".", "-")}.sslip.io"}" :
    var.associate_public_ip ? "http://${aws_eip.litellm[0].public_ip}:4000" :
    "http://${aws_instance.litellm.private_ip}:4000"
  )
}

output "alb_dns_name" {
  value = local.https_enabled ? aws_lb.this[0].dns_name : null
}

output "instance_id" {
  value = aws_instance.litellm.id
}

output "bundle_bucket" {
  value = aws_s3_bucket.bundle.id
}

output "master_key_secret_name" {
  value = aws_secretsmanager_secret.generated["LITELLM_MASTER_KEY"].name
}

output "provider_secret_names" {
  value = [for s in aws_secretsmanager_secret.provider : s.name]
}

output "log_group" {
  value = aws_cloudwatch_log_group.litellm.name
}

output "ssm_shell" {
  description = "Open a shell on the host (needs the Session Manager plugin)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.litellm.id}"
}
