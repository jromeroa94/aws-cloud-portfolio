locals {
  lb = var.alb_arn_suffix

  base_widgets = [
    {
      type = "text", x = 0, y = 0, width = 24, height = 2
      properties = {
        markdown = "## ${var.service_name} (${var.environment}) · SLO de disponibilidad ${var.availability_slo * 100} % · p99 < ${var.latency_p99_threshold_s} s\nAlarmas en estado ALARM arriba a la derecha. Runbooks en `docs/runbooks/`."
      }
    },
    {
      type = "metric", x = 0, y = 2, width = 8, height = 6
      properties = {
        title  = "Disponibilidad (%)"
        region = var.region
        view   = "timeSeries"
        period = 300
        metrics = [
          [{ expression = "100 * (1 - (FILL(t5,0) + FILL(e5,0)) / FILL(req,1))", label = "Disponibilidad", id = "avail" }],
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb, { id = "req", stat = "Sum", visible = false }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.lb, { id = "t5", stat = "Sum", visible = false }],
          ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.lb, { id = "e5", stat = "Sum", visible = false }],
        ]
        yAxis       = { left = { min = 99, max = 100 } }
        annotations = { horizontal = [{ value = var.availability_slo * 100, label = "SLO", color = "#d62728" }] }
      }
    },
    {
      type = "metric", x = 8, y = 2, width = 8, height = 6
      properties = {
        title  = "Latencia (s)"
        region = var.region
        view   = "timeSeries"
        period = 60
        metrics = [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb, { stat = "p50", label = "p50" }],
          ["...", { stat = "p90", label = "p90" }],
          ["...", { stat = "p99", label = "p99" }],
        ]
        annotations = { horizontal = [{ value = var.latency_p99_threshold_s, label = "Umbral p99", color = "#d62728" }] }
      }
    },
    {
      type = "metric", x = 16, y = 2, width = 8, height = 6
      properties = {
        title  = "Tráfico y anomalías"
        region = var.region
        view   = "timeSeries"
        period = 300
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb, { id = "m1", stat = "Sum", label = "Peticiones" }],
          [{ expression = "ANOMALY_DETECTION_BAND(m1, 3)", label = "Banda esperada", id = "ad1" }],
        ]
      }
    },
    {
      type = "metric", x = 0, y = 8, width = 8, height = 6
      properties = {
        title  = "Capacidad"
        region = var.region
        view   = "timeSeries"
        period = 60
        metrics = [
          ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", local.lb, { stat = "Minimum", label = "Hosts sanos" }],
          ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", local.lb, { stat = "Maximum", label = "Hosts no sanos" }],
          ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", var.asg_name, { stat = "Average", label = "En servicio (ASG)" }],
          ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", var.asg_name, { stat = "Average", label = "Deseadas (ASG)" }],
        ]
      }
    },
    {
      type = "metric", x = 8, y = 8, width = 8, height = 6
      properties = {
        title  = "CPU de la flota (%)"
        region = var.region
        view   = "timeSeries"
        period = 60
        metrics = [
          ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name, { stat = "Average", label = "Media" }],
          ["...", { stat = "Maximum", label = "Máximo" }],
        ]
      }
    },
    {
      type = "alarm", x = 16, y = 8, width = 8, height = 6
      properties = {
        title = "Estado de alarmas"
        alarms = concat(
          [for a in aws_cloudwatch_composite_alarm.slo_burn : a.arn],
          [aws_cloudwatch_metric_alarm.latency_p99.arn, aws_cloudwatch_metric_alarm.healthy_hosts.arn],
          [for a in aws_cloudwatch_metric_alarm.dlq : a.arn],
        )
      }
    },
  ]

  db_widgets = var.db_cluster_identifier == null ? [] : [
    {
      type = "metric", x = 0, y = 14, width = 12, height = 6
      properties = {
        title  = "Aurora"
        region = var.region
        view   = "timeSeries"
        period = 60
        metrics = [
          ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", var.db_cluster_identifier, { label = "CPU %" }],
          [".", "DatabaseConnections", ".", ".", { label = "Conexiones", yAxis = "right" }],
          [".", "AuroraReplicaLag", ".", ".", { label = "Lag réplicas (ms)", yAxis = "right" }],
        ]
      }
    },
  ]

  lambda_widgets = length(var.lambda_function_names) == 0 ? [] : [
    {
      type = "metric", x = 12, y = 14, width = 12, height = 6
      properties = {
        title  = "Lambda: errores, throttles y duración p95"
        region = var.region
        view   = "timeSeries"
        period = 300
        metrics = flatten([
          for fn in var.lambda_function_names : [
            ["AWS/Lambda", "Errors", "FunctionName", fn, { stat = "Sum", label = "${fn} errores" }],
            [".", "Throttles", ".", ".", { stat = "Sum", label = "${fn} throttles" }],
            [".", "Duration", ".", ".", { stat = "p95", label = "${fn} p95 ms", yAxis = "right" }],
          ]
        ])
      }
    },
  ]

  queue_widgets = length(concat(var.queue_names, var.dlq_names)) == 0 ? [] : [
    {
      type = "metric", x = 0, y = 20, width = 24, height = 6
      properties = {
        title  = "Colas: antigüedad del mensaje más viejo (s) y mensajes en DLQ"
        region = var.region
        view   = "timeSeries"
        period = 60
        metrics = concat(
          [for q in var.queue_names : ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", q, { stat = "Maximum" }]],
          [for q in var.dlq_names : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q, { stat = "Maximum", yAxis = "right" }]],
        )
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "service" {
  dashboard_name = "${local.prefix}-overview"
  dashboard_body = jsonencode({
    widgets = concat(local.base_widgets, local.db_widgets, local.lambda_widgets, local.queue_widgets)
  })
}
