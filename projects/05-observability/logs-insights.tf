# =============================================================================
# Consultas guardadas de CloudWatch Logs Insights (lo primero que se abre en un incidente)
# =============================================================================
resource "aws_cloudwatch_query_definition" "app_errors" {
  count = length(var.app_log_group_names) > 0 ? 1 : 0

  name            = "${local.prefix}/01-errores-agrupados"
  log_group_names = var.app_log_group_names

  query_string = <<-EOT
    fields @timestamp, message, reason, error, order_id
    | filter level in ["ERROR", "WARNING"]
    | stats count(*) as ocurrencias, latest(@timestamp) as ultima_vez by level, message, reason
    | sort ocurrencias desc
    | limit 25
  EOT
}

resource "aws_cloudwatch_query_definition" "lambda_cold_starts" {
  count = length(var.lambda_function_names) > 0 ? 1 : 0

  name            = "${local.prefix}/02-lambda-cold-starts-y-duracion"
  log_group_names = [for fn in var.lambda_function_names : "/aws/lambda/${fn}"]

  query_string = <<-EOT
    filter @type = "REPORT"
    | stats count(*) as invocaciones,
            sum(strcontains(@message, "Init Duration")) as cold_starts,
            pct(@duration, 50) as p50_ms,
            pct(@duration, 99) as p99_ms,
            max(@maxMemoryUsed / 1000 / 1000) as max_mem_mb,
            max(@memorySize / 1000 / 1000) as mem_configurada_mb
      by bin(15m)
  EOT
}

resource "aws_cloudwatch_query_definition" "vpc_rejected" {
  count = var.vpc_flow_log_group_name == null ? 0 : 1

  name            = "${local.prefix}/03-trafico-rechazado"
  log_group_names = [var.vpc_flow_log_group_name]

  query_string = <<-EOT
    filter action = "REJECT"
    | stats count(*) as intentos by srcAddr, dstAddr, dstPort, protocol
    | sort intentos desc
    | limit 25
  EOT
}

resource "aws_cloudwatch_query_definition" "access_denied" {
  count = var.cloudtrail_log_group_name == null ? 0 : 1

  name            = "${local.prefix}/04-accesos-denegados"
  log_group_names = [var.cloudtrail_log_group_name]

  query_string = <<-EOT
    filter errorCode like /AccessDenied|UnauthorizedOperation/
    | stats count(*) as denegaciones by userIdentity.arn, eventSource, eventName
    | sort denegaciones desc
    | limit 25
  EOT
}
