output "state_bucket" {
  description = "Bucket para el backend S3 de cada proyecto."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "Clave KMS del estado (usar en backend.hcl como kms_key_id)."
  value       = aws_kms_key.state.arn
}

output "plan_role_arn" {
  description = "Guardar como variable de repositorio AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Guardar como variable del environment 'production': AWS_APPLY_ROLE_ARN."
  value       = aws_iam_role.apply.arn
}
