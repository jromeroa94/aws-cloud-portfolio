# =============================================================================
# ELK gestionado (opcional): CloudWatch Logs -> Data Firehose -> Amazon OpenSearch
# =============================================================================
# Por qué Firehose y no una Lambda de reenvío: buffering, reintentos, copia de los
# documentos fallidos a S3 y descompresión/extracción nativas de los registros de
# CloudWatch Logs, sin código propio que mantener.

locals {
  os_enabled = var.opensearch.enabled
  os_name    = substr(replace("${local.prefix}-logs", "_", "-"), 0, 28)
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "opensearch" {
  count = local.os_enabled ? 1 : 0
  id    = var.opensearch.vpc_id
}

resource "aws_security_group" "opensearch" {
  count = local.os_enabled ? 1 : 0

  name_prefix = "${local.os_name}-"
  description = "OpenSearch: HTTPS solo desde la VPC"
  vpc_id      = var.opensearch.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_https" {
  count = local.os_enabled ? 1 : 0

  security_group_id = aws_security_group.opensearch[0].id
  cidr_ipv4         = coalesce(var.opensearch.allowed_cidr_block, data.aws_vpc.opensearch[0].cidr_block)
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "opensearch_all" {
  count = local.os_enabled ? 1 : 0

  security_group_id = aws_security_group.opensearch[0].id
  cidr_ipv4         = data.aws_vpc.opensearch[0].cidr_block
  ip_protocol       = "-1"
}

resource "aws_cloudwatch_log_group" "opensearch_app" {
  count = local.os_enabled ? 1 : 0

  name              = "/aws/opensearch/${local.os_name}/application"
  retention_in_days = 30
}

data "aws_iam_policy_document" "opensearch_logs" {
  count = local.os_enabled ? 1 : 0

  statement {
    actions   = ["logs:PutLogEvents", "logs:CreateLogStream"]
    resources = ["${aws_cloudwatch_log_group.opensearch_app[0].arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["es.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "opensearch" {
  count = local.os_enabled ? 1 : 0

  policy_name     = "${local.os_name}-logs"
  policy_document = data.aws_iam_policy_document.opensearch_logs[0].json
}

resource "aws_opensearch_domain" "logs" {
  #checkov:skip=CKV2_AWS_52:Dominio privado en VPC con acceso por IAM; FGAC se activa al abrir Dashboards a usuarios finales.
  #checkov:skip=CKV2_AWS_59:Nodos maestros dedicados a partir de 10 nodos de datos; este dominio usa 2.
  count = local.os_enabled ? 1 : 0

  domain_name    = local.os_name
  engine_version = "OpenSearch_2.17"

  cluster_config {
    instance_type          = var.opensearch.instance_type
    instance_count         = var.opensearch.instance_count
    zone_awareness_enabled = var.opensearch.instance_count > 1

    dynamic "zone_awareness_config" {
      for_each = var.opensearch.instance_count > 1 ? [1] : []
      content {
        availability_zone_count = 2
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.opensearch.volume_size_gb
  }

  vpc_options {
    subnet_ids         = slice(var.opensearch.subnet_ids, 0, var.opensearch.instance_count > 1 ? 2 : 1)
    security_group_ids = [aws_security_group.opensearch[0].id]
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-PFS-2023-10"
  }

  log_publishing_options {
    log_type                 = "ES_APPLICATION_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_app[0].arn
  }

  # Acceso por IAM: solo el rol de Firehose y los principales de la cuenta con permisos es:*.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "es:ESHttp*"
      Resource  = "arn:aws:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${local.os_name}/*"
    }]
  })

  depends_on = [aws_cloudwatch_log_resource_policy.opensearch]
}

# --- Copia de seguridad de documentos que OpenSearch rechace -----------------
resource "aws_s3_bucket" "firehose_backup" {
  count = local.os_enabled ? 1 : 0

  bucket_prefix = "${local.os_name}-failed-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "firehose_backup" {
  count = local.os_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.firehose_backup[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "firehose_backup" {
  count  = local.os_enabled ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_versioning" "firehose_backup" {
  count  = local.os_enabled ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firehose_backup" {
  count  = local.os_enabled ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# --- Rol de Firehose ---------------------------------------------------------
data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "firehose" {
  count = local.os_enabled ? 1 : 0

  name_prefix        = "${local.os_name}-fh-"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

data "aws_iam_policy_document" "firehose" {
  count = local.os_enabled ? 1 : 0

  statement {
    sid       = "WriteToOpenSearch"
    actions   = ["es:DescribeDomain", "es:DescribeDomains", "es:DescribeDomainConfig", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpGet"]
    resources = [aws_opensearch_domain.logs[0].arn, "${aws_opensearch_domain.logs[0].arn}/*"]
  }

  statement {
    sid       = "BackupFailedDocuments"
    actions   = ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject"]
    resources = [aws_s3_bucket.firehose_backup[0].arn, "${aws_s3_bucket.firehose_backup[0].arn}/*"]
  }

  # Firehose crea interfaces de red en la VPC para llegar al dominio privado.
  statement {
    sid = "VpcDelivery"
    actions = [
      "ec2:DescribeVpcs", "ec2:DescribeVpcAttribute", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
      "ec2:DescribeNetworkInterfaces", "ec2:CreateNetworkInterface", "ec2:CreateNetworkInterfacePermission",
      "ec2:DeleteNetworkInterface",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DeliveryLogs"
    actions   = ["logs:PutLogEvents", "logs:CreateLogStream"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  count = local.os_enabled ? 1 : 0

  role   = aws_iam_role.firehose[0].id
  policy = data.aws_iam_policy_document.firehose[0].json
}

resource "aws_kinesis_firehose_delivery_stream" "logs" {
  count = local.os_enabled ? 1 : 0

  name        = "${local.os_name}-to-opensearch"
  destination = "opensearch"

  server_side_encryption {
    enabled  = true
    key_type = "AWS_OWNED_CMK"
  }

  opensearch_configuration {
    domain_arn            = aws_opensearch_domain.logs[0].arn
    role_arn              = aws_iam_role.firehose[0].arn
    index_name            = "app-logs"
    index_rotation_period = "OneDay"
    buffering_interval    = 60
    buffering_size        = 5
    retry_duration        = 300
    s3_backup_mode        = "FailedDocumentsOnly"

    s3_configuration {
      role_arn           = aws_iam_role.firehose[0].arn
      bucket_arn         = aws_s3_bucket.firehose_backup[0].arn
      compression_format = "GZIP"
    }

    vpc_config {
      subnet_ids         = var.opensearch.subnet_ids
      security_group_ids = [aws_security_group.opensearch[0].id]
      role_arn           = aws_iam_role.firehose[0].arn
    }

    # Los registros llegan de CloudWatch Logs comprimidos y envueltos: Firehose los
    # descomprime y extrae cada evento de log como documento independiente.
    processing_configuration {
      enabled = true

      processors {
        type = "Decompression"
        parameters {
          parameter_name  = "CompressionFormat"
          parameter_value = "GZIP"
        }
      }

      processors {
        type = "CloudWatchLogProcessing"
        parameters {
          parameter_name  = "DataMessageExtraction"
          parameter_value = "true"
        }
      }
    }
  }

  depends_on = [aws_iam_role_policy.firehose]
}

# --- Suscripción de los log groups de la aplicación ---------------------------
data "aws_iam_policy_document" "logs_to_firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "logs_to_firehose" {
  count = local.os_enabled ? 1 : 0

  name_prefix        = "${local.os_name}-cwl-"
  assume_role_policy = data.aws_iam_policy_document.logs_to_firehose_assume.json
}

resource "aws_iam_role_policy" "logs_to_firehose" {
  count = local.os_enabled ? 1 : 0

  role = aws_iam_role.logs_to_firehose[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = aws_kinesis_firehose_delivery_stream.logs[0].arn
    }]
  })
}

resource "aws_cloudwatch_log_subscription_filter" "to_opensearch" {
  for_each = local.os_enabled ? toset(var.app_log_group_names) : toset([])

  name            = "to-opensearch"
  log_group_name  = each.value
  filter_pattern  = "" # todos los eventos
  destination_arn = aws_kinesis_firehose_delivery_stream.logs[0].arn
  role_arn        = aws_iam_role.logs_to_firehose[0].arn

  depends_on = [aws_iam_role_policy.logs_to_firehose]
}
