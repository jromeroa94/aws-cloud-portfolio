data "aws_caller_identity" "current" {}

locals {
  prefix     = "${var.name}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
}

# =============================================================================
# Notificaciones (tema cifrado que pueden usar Budgets y Cost Anomaly Detection)
# =============================================================================
data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_111:Política de clave KMS: Resource "*" se refiere a la propia clave.
  #checkov:skip=CKV_AWS_356:Política de clave KMS: Resource "*" se refiere a la propia clave.
  #checkov:skip=CKV_AWS_109:Política de clave KMS: administración delegada en IAM de la cuenta.
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:*"]
    }
  }

  statement {
    sid       = "BillingServicesPublish"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "costalerts.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "finops" {
  description             = "${local.prefix} notificaciones e informes"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_sns_topic" "finops" {
  name              = "${local.prefix}-alerts"
  kms_master_key_id = aws_kms_key.finops.arn
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AllowBillingServices"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.finops.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "costalerts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "finops" {
  arn    = aws_sns_topic.finops.arn
  policy = data.aws_iam_policy_document.topic.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.finops.arn
  protocol  = "email"
  endpoint  = each.value
}

# =============================================================================
# Presupuesto mensual con alertas reales y de pronóstico
# =============================================================================
resource "aws_budgets_budget" "monthly" {
  name         = "${local.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
    include_tax    = true
  }

  # Aviso temprano: el pronóstico supera el presupuesto mucho antes de fin de mes.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.finops.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.finops.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.finops.arn]
  }

  depends_on = [aws_sns_topic_policy.finops]
}

# =============================================================================
# Detección de anomalías de coste (ML de AWS sobre el gasto por servicio)
# =============================================================================
resource "aws_ce_anomaly_monitor" "services" {
  name              = "${local.prefix}-by-service"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "alerts" {
  name             = "${local.prefix}-anomalies"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.finops.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  depends_on = [aws_sns_topic_policy.finops]
}

resource "aws_ce_cost_allocation_tag" "required" {
  for_each = var.activate_cost_allocation_tags ? toset(var.required_tags) : toset([])

  tag_key = each.value
  status  = "Active"
}

# =============================================================================
# Informes del escáner
# =============================================================================
resource "aws_s3_bucket" "reports" {
  bucket_prefix = "${local.prefix}-reports-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.finops.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-old-reports"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# =============================================================================
# Lambda del escáner + EventBridge Scheduler
# =============================================================================
data "archive_file" "scanner" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/cost_hygiene.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

resource "aws_cloudwatch_log_group" "scanner" {
  name              = "/aws/lambda/${local.prefix}-cost-hygiene"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.finops.arn
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scanner" {
  name_prefix        = "${local.prefix}-scanner-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "scanner" {
  statement {
    sid = "ReadInventory"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeAddresses",
      "ec2:DescribeSnapshots",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
    ]
    resources = ["*"] # las acciones Describe* de EC2 no admiten restricción por recurso
  }

  # Solo puede escribir UNA etiqueta concreta; no puede modificar ni borrar nada más.
  statement {
    sid       = "TagReviewCandidatesOnly"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:${local.account_id}:volume/*", "arn:aws:ec2:*:${local.account_id}:snapshot/*", "arn:aws:ec2:*:${local.account_id}:instance/*"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["finops:review-requested"]
    }
  }

  statement {
    sid       = "WriteReports"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/reports/*"]
  }

  statement {
    sid       = "EncryptReportsAndMessages"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.finops.arn]
  }

  statement {
    sid       = "PublishSummary"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.finops.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.scanner.arn}:*"]
  }

  statement {
    sid       = "XRayTracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "scanner" {
  name   = "cost-hygiene-scanner"
  role   = aws_iam_role.scanner.id
  policy = data.aws_iam_policy_document.scanner.json
}

resource "aws_lambda_function" "scanner" {
  #checkov:skip=CKV_AWS_116:Invocación asíncrona desde Scheduler con política de reintentos; un fallo se reintenta la semana siguiente.
  function_name    = "${local.prefix}-cost-hygiene"
  description      = "Informe semanal de recursos ociosos y sin etiquetas de coste"
  role             = aws_iam_role.scanner.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "cost_hygiene.handler.handler"
  filename         = data.archive_file.scanner.output_path
  source_code_hash = data.archive_file.scanner.output_base64sha256
  memory_size      = 256
  timeout          = 300

  # Una sola ejecución a la vez: evita informes duplicados si se invoca a mano.
  reserved_concurrent_executions = 1

  environment {
    variables = {
      REPORT_BUCKET         = aws_s3_bucket.reports.bucket
      TOPIC_ARN             = aws_sns_topic.finops.arn
      SCAN_REGIONS          = join(",", var.scan_regions)
      REQUIRED_TAGS         = join(",", var.required_tags)
      SNAPSHOT_MAX_AGE_DAYS = tostring(var.snapshot_max_age_days)
      STOPPED_MAX_DAYS      = tostring(var.stopped_max_days)
      TAG_CANDIDATES        = tostring(var.tag_candidates)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.scanner.name
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.scanner]
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name_prefix        = "${local.prefix}-scheduler-"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.scanner.arn
    }]
  })
}

resource "aws_scheduler_schedule" "weekly" {
  #checkov:skip=CKV_AWS_297:El schedule no lleva payload; cifrarlo con CMK no protege ningún dato.
  name                         = "${local.prefix}-weekly-scan"
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.scanner.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}
