data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  prefix     = "${var.name}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}

# =============================================================================
# KMS: una clave del proyecto para S3, SQS, SNS, DynamoDB y logs
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

  # EventBridge (-> SQS de entrada) y SNS (-> colas de consumidores) necesitan
  # cifrar mensajes en colas protegidas con esta clave.
  statement {
    sid       = "AllowAwsServicesToEncryptMessages"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sns.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AllowCloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${local.prefix} pipeline de pedidos"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.prefix}"
  target_key_id = aws_kms_key.this.key_id
}

# =============================================================================
# S3: bandeja de entrada de pedidos -> EventBridge
# =============================================================================
resource "aws_s3_bucket" "inbox" {
  bucket_prefix = "${local.prefix}-inbox-"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_public_access_block" "inbox" {
  bucket                  = aws_s3_bucket.inbox.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "inbox" {
  bucket = aws_s3_bucket.inbox.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "inbox" {
  bucket = aws_s3_bucket.inbox.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "inbox" {
  bucket = aws_s3_bucket.inbox.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "inbox" {
  bucket = aws_s3_bucket.inbox.id

  rule {
    id     = "expire-processed-files"
    status = "Enabled"

    filter {
      prefix = "incoming/"
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
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

data "aws_iam_policy_document" "inbox" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.inbox.arn, "${aws_s3_bucket.inbox.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "inbox" {
  bucket     = aws_s3_bucket.inbox.id
  policy     = data.aws_iam_policy_document.inbox.json
  depends_on = [aws_s3_bucket_public_access_block.inbox]
}

resource "aws_s3_bucket_notification" "inbox" {
  bucket      = aws_s3_bucket.inbox.id
  eventbridge = true
}

# =============================================================================
# EventBridge -> SQS de entrada (con DLQ)
# =============================================================================
resource "aws_sqs_queue" "ingest_dlq" {
  name                      = "${local.prefix}-ingest-dlq"
  message_retention_seconds = 1209600 # 14 días: tiempo para investigar y redirigir
  kms_master_key_id         = aws_kms_key.this.arn
}

resource "aws_sqs_queue" "ingest" {
  name = "${local.prefix}-ingest"
  # AWS recomienda >= 6 x timeout de la función cuando SQS invoca Lambda.
  visibility_timeout_seconds = var.lambda_timeout_s * 6
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  kms_master_key_id          = aws_kms_key.this.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingest_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "ingest_dlq" {
  queue_url = aws_sqs_queue.ingest_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ingest.arn]
  })
}

resource "aws_cloudwatch_event_rule" "order_uploaded" {
  name        = "${local.prefix}-order-uploaded"
  description = "Nuevo archivo de pedido en incoming/"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.inbox.bucket] }
      object = { key = [{ prefix = "incoming/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "to_ingest_queue" {
  rule = aws_cloudwatch_event_rule.order_uploaded.name
  arn  = aws_sqs_queue.ingest.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }

  dead_letter_config {
    arn = aws_sqs_queue.ingest_dlq.arn
  }
}

data "aws_iam_policy_document" "ingest_queue" {
  statement {
    sid       = "AllowEventBridge"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ingest.arn, aws_sqs_queue.ingest_dlq.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.order_uploaded.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "ingest" {
  queue_url = aws_sqs_queue.ingest.id
  policy    = data.aws_iam_policy_document.ingest_queue.json
}

resource "aws_sqs_queue_policy" "ingest_dlq" {
  queue_url = aws_sqs_queue.ingest_dlq.id
  policy    = data.aws_iam_policy_document.ingest_queue.json
}

# =============================================================================
# DynamoDB: registro idempotente de pedidos
# =============================================================================
resource "aws_dynamodb_table" "orders" {
  name                        = "${local.prefix}-orders"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "order_id"
  deletion_protection_enabled = var.environment == "prod"

  attribute {
    name = "order_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.this.arn
  }
}

# =============================================================================
# SNS: fan-out hacia los servicios descendentes (cada uno con su cola y su DLQ)
# =============================================================================
resource "aws_sns_topic" "orders" {
  name              = "${local.prefix}-events"
  kms_master_key_id = aws_kms_key.this.arn
}

resource "aws_sqs_queue" "consumer_dlq" {
  for_each = var.consumers

  name                      = "${local.prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.this.arn
}

resource "aws_sqs_queue" "consumer" {
  for_each = var.consumers

  name                       = "${local.prefix}-${each.key}"
  visibility_timeout_seconds = 180
  receive_wait_time_seconds  = 20
  kms_master_key_id          = aws_kms_key.this.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.consumer_dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
}

data "aws_iam_policy_document" "consumer_queue" {
  for_each = var.consumers

  statement {
    sid       = "AllowOrdersTopic"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.consumer[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.orders.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "consumer" {
  for_each = var.consumers

  queue_url = aws_sqs_queue.consumer[each.key].id
  policy    = data.aws_iam_policy_document.consumer_queue[each.key].json
}

resource "aws_sns_topic_subscription" "consumer" {
  for_each = var.consumers

  topic_arn            = aws_sns_topic.orders.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.consumer[each.key].arn
  raw_message_delivery = true
  filter_policy        = jsonencode(each.value.filter_policy)
  filter_policy_scope  = "MessageAttributes"

  depends_on = [aws_sqs_queue_policy.consumer]
}

# =============================================================================
# Lambda (Python 3.13, Graviton)
# =============================================================================
data "archive_file" "order_processor" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/order_processor.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

resource "aws_cloudwatch_log_group" "order_processor" {
  name              = "/aws/lambda/${local.prefix}-order-processor"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
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

resource "aws_iam_role" "order_processor" {
  name_prefix        = "${local.prefix}-processor-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Mínimo privilegio: cada permiso está limitado al recurso concreto que se usa.
data "aws_iam_policy_document" "order_processor" {
  statement {
    sid       = "ConsumeIngestQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
    resources = [aws_sqs_queue.ingest.arn]
  }

  statement {
    sid       = "ReadIncomingOrders"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.inbox.arn}/incoming/*"]
  }

  statement {
    sid       = "WriteOrders"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.orders.arn]
  }

  statement {
    sid       = "PublishOrderEvents"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.orders.arn]
  }

  statement {
    sid       = "UseProjectKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.this.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.order_processor.arn}:*"]
  }

  statement {
    sid       = "XRayTracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "order_processor" {
  name   = "order-processor"
  role   = aws_iam_role.order_processor.id
  policy = data.aws_iam_policy_document.order_processor.json
}

resource "aws_lambda_function" "order_processor" {
  #checkov:skip=CKV_AWS_116:La DLQ está en la cola SQS de origen (redrive tras max_receive_count), que es donde se reintenta.
  #checkov:skip=CKV_AWS_115:La concurrencia se limita en el event source mapping (maximum_concurrency) sin reservar capacidad.
  function_name    = "${local.prefix}-order-processor"
  description      = "Valida pedidos, los registra de forma idempotente y publica eventos"
  role             = aws_iam_role.order_processor.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "order_processor.handler.handler"
  filename         = data.archive_file.order_processor.output_path
  source_code_hash = data.archive_file.order_processor.output_base64sha256
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_s

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.orders.name
      TOPIC_ARN  = aws_sns_topic.orders.arn
      LOG_LEVEL  = var.environment == "prod" ? "INFO" : "DEBUG"
    }
  }

  logging_config {
    log_format = "Text" # el handler ya emite JSON estructurado
    log_group  = aws_cloudwatch_log_group.order_processor.name
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy.order_processor]
}

resource "aws_lambda_event_source_mapping" "ingest" {
  event_source_arn                   = aws_sqs_queue.ingest.arn
  function_name                      = aws_lambda_function.order_processor.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.max_concurrency
  }
}

# =============================================================================
# Alarmas: nada se pierde en silencio
# =============================================================================
locals {
  dlqs = merge(
    { ingest = aws_sqs_queue.ingest_dlq.name },
    { for k, q in aws_sqs_queue.consumer_dlq : k => q.name },
  )
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = local.dlqs

  alarm_name          = "${local.prefix}-${each.key}-dlq-not-empty"
  alarm_description   = "Hay mensajes en la DLQ ${each.value}. Investigar la causa y redirigirlos (StartMessageMoveTask)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = compact([var.alarm_topic_arn])
  ok_actions    = compact([var.alarm_topic_arn])
}

resource "aws_cloudwatch_metric_alarm" "ingest_backlog_age" {
  alarm_name          = "${local.prefix}-ingest-backlog-age"
  alarm_description   = "Los pedidos esperan más de 5 minutos para procesarse."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.ingest.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = compact([var.alarm_topic_arn])
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.prefix}-order-processor-errors"
  alarm_description   = "La Lambda falla en más del 5 % de invocaciones."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(invocations > 0, 100 * errors / invocations, 0)"
    label       = "Error rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      dimensions  = { FunctionName = aws_lambda_function.order_processor.function_name }
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "invocations"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Invocations"
      dimensions  = { FunctionName = aws_lambda_function.order_processor.function_name }
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = compact([var.alarm_topic_arn])
}
