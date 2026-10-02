locals {
  prefix       = "${var.service_name}-${var.environment}"
  error_budget = 1 - var.availability_slo

  # Alertas por tasa de consumo del presupuesto de error (SRE Workbook, cap. 5).
  # Dos ventanas por severidad: la larga confirma que el problema es significativo y
  # la corta que sigue ocurriendo ahora (así la alerta se apaga sola al resolverse).
  burn_rate_alerts = {
    fast = { burn_rate = 14.4, long_period = 3600, short_period = 300, topic = var.page_topic_arn }  # 2 % del presupuesto en 1 h
    slow = { burn_rate = 6, long_period = 21600, short_period = 1800, topic = var.ticket_topic_arn } # 5 % del presupuesto en 6 h
  }

  burn_rate_windows = merge([
    for severity, cfg in local.burn_rate_alerts : {
      "${severity}-long"  = { severity = severity, period = cfg.long_period, threshold = cfg.burn_rate * local.error_budget }
      "${severity}-short" = { severity = severity, period = cfg.short_period, threshold = cfg.burn_rate * local.error_budget }
    }
  ]...)
}

# =============================================================================
# SLO de disponibilidad: proporción de respuestas 5xx sobre el total
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "error_ratio" {
  #checkov:skip=CKV_AWS_319:Diseño intencionado: notifica la alarma compuesta (ventana larga AND corta), no cada ventana.
  for_each = local.burn_rate_windows

  alarm_name          = "${local.prefix}-slo-burn-${each.key}"
  alarm_description   = "Ratio de errores 5xx en ventana de ${each.value.period / 60} min por encima de ${each.value.threshold * 100} %."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"

  # Las alarmas individuales no notifican: lo hace la alarma compuesta.
  actions_enabled = false

  metric_query {
    id          = "error_ratio"
    expression  = "IF(requests > 0, (target_5xx + elb_5xx) / requests, 0)"
    label       = "Ratio de errores"
    return_data = true
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = each.value.period
      stat        = "Sum"
    }
  }

  metric_query {
    id = "target_5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = each.value.period
      stat        = "Sum"
    }
  }

  metric_query {
    id = "elb_5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = each.value.period
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_composite_alarm" "slo_burn" {
  for_each = local.burn_rate_alerts

  alarm_name        = "${local.prefix}-slo-burn-${each.key}"
  alarm_description = <<-EOT
    El servicio consume su presupuesto de error ${each.value.burn_rate}x más rápido de lo sostenible
    (SLO ${var.availability_slo * 100} %). Runbook: docs/runbooks/high-error-rate.md
  EOT

  alarm_rule = join(" AND ", [
    "ALARM(${aws_cloudwatch_metric_alarm.error_ratio["${each.key}-long"].alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.error_ratio["${each.key}-short"].alarm_name})",
  ])

  alarm_actions = compact([each.value.topic])
  ok_actions    = compact([each.value.topic])
}

# =============================================================================
# Latencia
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name          = "${local.prefix}-latency-p99"
  alarm_description   = "La latencia p99 supera ${var.latency_p99_threshold_s} s en 5 de los últimos 10 minutos."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 5
  threshold           = var.latency_p99_threshold_s
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = compact([var.page_topic_arn])
  ok_actions    = compact([var.page_topic_arn])
}

# =============================================================================
# Capacidad: hosts sanos y anomalías de tráfico
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "healthy_hosts" {
  alarm_name          = "${local.prefix}-healthy-hosts-low"
  alarm_description   = "Menos de 2 instancias sanas: se ha perdido la redundancia entre AZs."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 2
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = compact([var.page_topic_arn])
  ok_actions    = compact([var.page_topic_arn])
}

# Detección de anomalías: aprende el patrón semanal del tráfico y avisa de caídas
# bruscas (p. ej. un problema de DNS que deja de traer usuarios sin generar 5xx).
resource "aws_cloudwatch_metric_alarm" "traffic_anomaly" {
  alarm_name          = "${local.prefix}-traffic-drop-anomaly"
  alarm_description   = "El tráfico está muy por debajo de la banda esperada para esta hora."
  comparison_operator = "LessThanLowerThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold_metric_id = "band"
  treat_missing_data  = "breaching"

  metric_query {
    id          = "band"
    expression  = "ANOMALY_DETECTION_BAND(requests, 3)"
    label       = "Banda esperada"
    return_data = true
  }

  metric_query {
    id          = "requests"
    return_data = true
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = compact([var.ticket_topic_arn])
}

# =============================================================================
# Colas
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each = toset(var.queue_names)

  alarm_name          = "${local.prefix}-${each.value}-backlog-age"
  alarm_description   = "Mensajes esperando más de ${var.queue_max_age_s} s en ${each.value}."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.queue_max_age_s
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = compact([var.page_topic_arn])
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = toset(var.dlq_names)

  alarm_name          = "${local.prefix}-${each.value}-not-empty"
  alarm_description   = "Hay mensajes en ${each.value}."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = compact([var.ticket_topic_arn])
}

# =============================================================================
# Logs de aplicación: errores como métrica
# =============================================================================
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  for_each = toset(var.app_log_group_names)

  name           = "${local.prefix}-errors"
  log_group_name = each.value
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name          = "ApplicationErrors"
    namespace     = "Custom/${var.service_name}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}
