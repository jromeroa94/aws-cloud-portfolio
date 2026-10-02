output "audit_bucket" {
  description = "Bucket de auditoría (CloudTrail + Config)."
  value       = aws_s3_bucket.audit.bucket
}

output "audit_kms_key_arn" {
  description = "Clave KMS de auditoría."
  value       = aws_kms_key.audit.arn
}

output "cloudtrail_arn" {
  description = "Trail multirregión."
  value       = aws_cloudtrail.this.arn
}

output "security_alerts_topic_arn" {
  description = "Tema SNS de alertas de seguridad."
  value       = aws_sns_topic.security_alerts.arn
}

output "guardduty_detector_id" {
  description = "Detector de GuardDuty."
  value       = aws_guardduty_detector.this.id
}

output "developer_permissions_boundary_arn" {
  description = "Boundary que deben adjuntar los roles app-* creados por los equipos."
  value       = aws_iam_policy.developer_boundary.arn
}

output "config_rules" {
  description = "Reglas de AWS Config activas."
  value       = sort(keys(aws_config_config_rule.managed))
}
