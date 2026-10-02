# =============================================================================
# Controles a nivel de cuenta (secure by default)
# =============================================================================
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}

# Ningún bucket de la cuenta puede hacerse público, aunque alguien lo intente.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Todo volumen EBS nuevo nace cifrado.
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# Ninguna AMI ni snapshot de EBS puede compartirse públicamente.
resource "aws_ebs_snapshot_block_public_access" "this" {
  state = "block-all-sharing"
}

resource "aws_ec2_image_block_public_access" "this" {
  state = "block-new-sharing"
}

# Valores por defecto de metadatos: IMDSv2 obligatorio en instancias nuevas.
resource "aws_ec2_instance_metadata_defaults" "this" {
  http_tokens                 = "required"
  http_put_response_hop_limit = 2 # 2 permite contenedores sobre EC2
}

# =============================================================================
# Detección
# =============================================================================
resource "aws_guardduty_detector" "this" {
  #checkov:skip=CKV2_AWS_3:Baseline de una sola cuenta; en una Organization se delega a la cuenta de seguridad.
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = toset([
    "S3_DATA_EVENTS",
    "EBS_MALWARE_PROTECTION",
    "RDS_LOGIN_EVENTS",
    "LAMBDA_NETWORK_LOGS",
  ])

  detector_id = aws_guardduty_detector.this.id
  name        = each.value
  status      = "ENABLED"
}

resource "aws_securityhub_account" "this" {
  enable_default_standards  = false # se suscriben explícitamente abajo
  auto_enable_controls      = true
  control_finding_generator = "SECURITY_CONTROL" # un hallazgo por control, no por estándar
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:${local.partition}:securityhub:${local.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.this]
}

resource "aws_securityhub_standards_subscription" "cis" {
  count = var.enable_security_hub_cis ? 1 : 0

  standards_arn = "arn:${local.partition}:securityhub:${local.region}::standards/cis-aws-foundations-benchmark/v/3.0.0"
  depends_on    = [aws_securityhub_account.this]
}

# Detecta recursos compartidos con entidades externas a la cuenta.
resource "aws_accessanalyzer_analyzer" "external" {
  analyzer_name = "${var.name}-external-access"
  type          = "ACCOUNT"
}

# Detecta permisos concedidos y no usados en los últimos 90 días.
resource "aws_accessanalyzer_analyzer" "unused" {
  analyzer_name = "${var.name}-unused-access"
  type          = "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = 90
    }
  }
}
