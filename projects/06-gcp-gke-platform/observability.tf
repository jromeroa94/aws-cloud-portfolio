# ---------- Observabilidad basada en SLOs ----------
#
# Mismo enfoque que el proyecto 05 en AWS, con las primitivas nativas de Cloud
# Monitoring: un servicio, dos SLOs (disponibilidad y latencia medidas en el
# balanceador, es decir, lo que ve el usuario) y alertas por tasa de consumo del
# presupuesto de error en lugar de umbrales fijos.

locals {
  has_alert_channel     = var.alert_email != ""
  notification_channels = local.has_alert_channel ? [google_monitoring_notification_channel.email[0].id] : []

  # Filtros del balanceador HTTPS externo creado por el Gateway. El proyecto solo
  # tiene un balanceador, así que no hace falta acotar por url_map.
  lb_requests  = "metric.type=\"loadbalancing.googleapis.com/https/request_count\" resource.type=\"https_lb_rule\""
  lb_latencies = "metric.type=\"loadbalancing.googleapis.com/https/total_latencies\" resource.type=\"https_lb_rule\""

  # Ventanas de burn rate (Google SRE Workbook): rápida para despertar a alguien,
  # lenta para abrir un ticket.
  burn_rates = {
    fast = { lookback = "60m", threshold = 14.4 }
    slow = { lookback = "360m", threshold = 6 }
  }

  error_budget_minutes_per_30d = floor((1 - var.availability_slo) * 30 * 24 * 60)
}

resource "google_monitoring_notification_channel" "email" {
  count = local.has_alert_channel ? 1 : 0

  display_name = "Plataforma · correo de guardia"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_custom_service" "platform_api" {
  service_id   = "platform-api-${var.environment}"
  display_name = "platform-api (${var.environment})"

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_slo" "availability" {
  service             = google_monitoring_custom_service.platform_api.service_id
  slo_id              = "availability"
  display_name        = "Disponibilidad: ${var.availability_slo * 100} % de respuestas sin 5xx (30 días)"
  goal                = var.availability_slo
  rolling_period_days = 30

  request_based_sli {
    good_total_ratio {
      good_service_filter  = "${local.lb_requests} metric.label.response_code_class!=\"500\""
      total_service_filter = local.lb_requests
    }
  }
}

resource "google_monitoring_slo" "latency" {
  service             = google_monitoring_custom_service.platform_api.service_id
  slo_id              = "latency"
  display_name        = "Latencia: ${var.latency_slo * 100} % de peticiones en menos de ${var.latency_threshold_ms} ms (30 días)"
  goal                = var.latency_slo
  rolling_period_days = 30

  request_based_sli {
    distribution_cut {
      distribution_filter = local.lb_latencies

      range {
        max = var.latency_threshold_ms
      }
    }
  }
}

# Alertas por burn rate del SLO de disponibilidad.
resource "google_monitoring_alert_policy" "availability_burn_rate" {
  for_each = local.burn_rates

  display_name = "platform-api · burn rate ${each.key} (${each.value.threshold}x en ${each.value.lookback})"
  combiner     = "OR"
  severity     = each.key == "fast" ? "CRITICAL" : "WARNING"

  conditions {
    display_name = "El presupuesto de error se consume ${each.value.threshold} veces más rápido de lo sostenible"

    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.availability.name}\", \"${each.value.lookback}\")"
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold
      duration        = "0s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      El servicio está gastando su presupuesto de error ${each.value.threshold}x más rápido de lo que permite el SLO.
      Con ${local.error_budget_minutes_per_30d} minutos de presupuesto al mes, a este ritmo se agota en ${each.key == "fast" ? "unas 2 días" : "unos 5 días"}.

      Runbook: projects/06-gcp-gke-platform/runbooks/gke-incidente-despliegue.md
    EOT
  }

  notification_channels = local.notification_channels
}

# Latencia: solo ventana lenta. Una degradación de latencia rara vez justifica
# despertar a alguien; sí abrir un ticket al día siguiente.
resource "google_monitoring_alert_policy" "latency_burn_rate" {
  display_name = "platform-api · latencia, burn rate lento (6x en 6 h)"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Demasiadas peticiones por encima de ${var.latency_threshold_ms} ms"

    condition_threshold {
      filter          = "select_slo_burn_rate(\"${google_monitoring_slo.latency.name}\", \"360m\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 6
      duration        = "0s"
    }
  }

  notification_channels = local.notification_channels
}

# ---------- Salud del clúster ----------

resource "google_monitoring_alert_policy" "container_restarts" {
  display_name = "GKE · contenedores reiniciándose en el namespace platform"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Más de 3 reinicios en 10 minutos (CrashLoopBackOff probable)"

    condition_threshold {
      filter          = "metric.type=\"kubernetes.io/container/restart_count\" resource.type=\"k8s_container\" resource.label.namespace_name=\"platform\""
      comparison      = "COMPARISON_GT"
      threshold_value = 3
      duration        = "0s"

      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.container_name"]
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Un contenedor reinicia en bucle. Runbook: projects/06-gcp-gke-platform/runbooks/gke-incidente-despliegue.md"
  }

  notification_channels = local.notification_channels
}

# ---------- Hallazgos del auditor de claves IAM ----------
#
# El auditor escribe un JSON por hallazgo en Cloud Logging; esta métrica basada en
# logs los cuenta por severidad, y la alerta avisa cuando hay claves vencidas.

resource "google_logging_metric" "iam_key_findings" {
  name        = "iam_key_findings"
  description = "Hallazgos del auditor de claves de cuentas de servicio, por severidad y tipo."
  filter      = "resource.type=\"cloud_run_job\" resource.labels.job_name=\"${local.key_auditor_job_name}\" jsonPayload.finding!=\"\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"

    labels {
      key         = "severity"
      value_type  = "STRING"
      description = "WARNING, ERROR o CRITICAL"
    }

    labels {
      key         = "finding"
      value_type  = "STRING"
      description = "user_managed_key, key_too_old o key_expired_grace"
    }
  }

  label_extractors = {
    severity = "EXTRACT(jsonPayload.severity)"
    finding  = "EXTRACT(jsonPayload.finding)"
  }
}

resource "google_monitoring_alert_policy" "iam_keys_expired" {
  display_name = "IAM · claves de cuentas de servicio fuera de política"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "Al menos una clave supera la edad máxima"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.iam_key_findings.name}\" resource.type=\"cloud_run_job\" metric.label.severity!=\"WARNING\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "86400s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Hay claves user-managed que superan los ${var.key_auditor_max_age_days} días. Sustituirlas por Workload Identity o impersonación; si no es posible, rotarlas. El detalle está en los logs del job `${local.key_auditor_job_name}`."
  }

  notification_channels = local.notification_channels
}

# ---------- Presupuesto ----------

resource "google_billing_budget" "platform" {
  count = var.billing_account_id != "" ? 1 : 0

  billing_account = var.billing_account_id
  display_name    = "Plataforma GKE ${var.environment}"

  budget_filter {
    projects               = ["projects/${local.project_number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  # La previsión avisa a mitad de mes de que se va a superar, cuando aún hay margen.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = local.notification_channels
    disable_default_iam_recipients   = local.has_alert_channel
  }

  depends_on = [google_project_service.apis]
}
