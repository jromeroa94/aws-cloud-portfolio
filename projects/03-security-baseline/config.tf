# =============================================================================
# AWS Config: inventario continuo + reglas de cumplimiento
# =============================================================================
data "aws_iam_policy_document" "config_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name_prefix        = "aws-config-recorder-"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "this" {
  name     = "default"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true # IAM se registra solo en esta región
  }

  recording_mode {
    recording_frequency = "CONTINUOUS"
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "default"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "config"
  s3_kms_key_arn = aws_kms_key.audit.arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.audit]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

locals {
  # Reglas gestionadas: identificador de AWS => parámetros de entrada.
  config_rules = {
    "s3-bucket-public-read-prohibited"      = { id = "S3_BUCKET_PUBLIC_READ_PROHIBITED", params = null }
    "s3-bucket-ssl-requests-only"           = { id = "S3_BUCKET_SSL_REQUESTS_ONLY", params = null }
    "s3-default-encryption-kms"             = { id = "S3_DEFAULT_ENCRYPTION_KMS", params = null }
    "encrypted-volumes"                     = { id = "ENCRYPTED_VOLUMES", params = null }
    "rds-storage-encrypted"                 = { id = "RDS_STORAGE_ENCRYPTED", params = null }
    "rds-instance-public-access-check"      = { id = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK", params = null }
    "iam-root-access-key-check"             = { id = "IAM_ROOT_ACCESS_KEY_CHECK", params = null }
    "root-account-mfa-enabled"              = { id = "ROOT_ACCOUNT_MFA_ENABLED", params = null }
    "mfa-enabled-for-iam-console-access"    = { id = "MFA_ENABLED_FOR_IAM_CONSOLE_ACCESS", params = null }
    "iam-user-unused-credentials-check"     = { id = "IAM_USER_UNUSED_CREDENTIALS_CHECK", params = { maxCredentialUsageAge = "90" } }
    "access-keys-rotated"                   = { id = "ACCESS_KEYS_ROTATED", params = { maxAccessKeyAge = "90" } }
    "restricted-ssh"                        = { id = "INCOMING_SSH_DISABLED", params = null }
    "vpc-flow-logs-enabled"                 = { id = "VPC_FLOW_LOGS_ENABLED", params = null }
    "cloudtrail-enabled"                    = { id = "CLOUD_TRAIL_ENABLED", params = null }
    "ec2-imdsv2-check"                      = { id = "EC2_IMDSV2_CHECK", params = null }
    "lambda-function-public-access-blocked" = { id = "LAMBDA_FUNCTION_PUBLIC_ACCESS_PROHIBITED", params = null }
    "required-tags" = {
      id     = "REQUIRED_TAGS"
      params = { for i, tag in var.required_tags : "tag${i + 1}Key" => tag }
    }
  }
}

resource "aws_config_config_rule" "managed" {
  for_each = local.config_rules

  name             = each.key
  input_parameters = each.value.params == null ? null : jsonencode(each.value.params)

  source {
    owner             = "AWS"
    source_identifier = each.value.id
  }

  depends_on = [aws_config_configuration_recorder_status.this]
}
