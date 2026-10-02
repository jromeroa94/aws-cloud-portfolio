data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition
  trail_name = "${var.name}-trail"
  trail_arn  = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${local.trail_name}"
}

# Clave de auditoría: cifra CloudTrail, Config, el log group y el tema de alertas.
data "aws_iam_policy_document" "audit_key" {
  #checkov:skip=CKV_AWS_111:Política de clave KMS: Resource "*" se refiere a la propia clave.
  #checkov:skip=CKV_AWS_356:Política de clave KMS: Resource "*" se refiere a la propia clave.
  #checkov:skip=CKV_AWS_109:Política de clave KMS: administración delegada en IAM de la cuenta.
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudTrailEncrypt"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "CloudTrailDescribe"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  # Quien tenga permiso de lectura sobre el bucket de auditoría puede descifrar los logs.
  statement {
    sid       = "AllowLogDecryptionInAccount"
    actions   = ["kms:Decrypt", "kms:ReEncryptFrom"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"]
    }
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  statement {
    sid       = "ConfigDelivery"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # EventBridge (hallazgos de GuardDuty) y CloudWatch (alarmas CIS) publican en el tema cifrado.
  statement {
    sid       = "AlertPublishers"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "audit" {
  description             = "Logs de auditoría y alertas de seguridad"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.audit_key.json
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${var.name}-audit"
  target_key_id = aws_kms_key.audit.key_id
}
