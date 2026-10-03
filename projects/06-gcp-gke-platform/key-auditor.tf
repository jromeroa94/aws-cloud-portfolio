# ---------- Auditor de claves de cuentas de servicio ----------
#
# Un Cloud Run Job en Python (src/iam_key_auditor) que Cloud Scheduler lanza cada
# mañana. Lista las claves user-managed del proyecto, las clasifica por edad y
# escribe un hallazgo por clave en Cloud Logging (observability.tf los convierte
# en métrica y alerta). Por defecto solo informa; con key_auditor_enforce=true
# desactiva las claves que superan el periodo de gracia.

locals {
  key_auditor_job_name = "iam-key-auditor"
  key_auditor_image = var.key_auditor_image != "" ? var.key_auditor_image : (
    "${var.region}-docker.pkg.dev/${var.project_id}/platform/iam-key-auditor:latest-main"
  )
}

resource "google_service_account" "key_auditor" {
  account_id   = "iam-key-auditor-${var.environment}"
  display_name = "Auditor de claves de cuentas de servicio"
}

# Ver claves de todas las SAs del proyecto. Solo si enforce=true se le concede
# además el permiso de desactivarlas.
resource "google_project_iam_member" "key_auditor" {
  for_each = toset(concat(
    ["roles/iam.serviceAccountViewer"],
    var.key_auditor_enforce ? ["roles/iam.serviceAccountKeyAdmin"] : [],
  ))

  project = var.project_id
  role    = each.value
  member  = google_service_account.key_auditor.member
}

resource "google_cloud_run_v2_job" "key_auditor" {
  name                = local.key_auditor_job_name
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.key_auditor.email
      timeout         = "600s"
      max_retries     = 1

      containers {
        image = local.key_auditor_image

        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "MAX_KEY_AGE_DAYS"
          value = tostring(var.key_auditor_max_age_days)
        }
        env {
          name  = "GRACE_DAYS"
          value = tostring(var.key_auditor_grace_days)
        }
        env {
          name  = "ENFORCE"
          value = var.key_auditor_enforce ? "true" : "false"
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  depends_on = [google_project_service.apis, google_project_iam_member.key_auditor]
}

# Cloud Scheduler invoca el job con un token OAuth de una cuenta dedicada que
# solo puede ejecutar este job.
resource "google_service_account" "scheduler" {
  account_id   = "scheduler-invoker-${var.environment}"
  display_name = "Cloud Scheduler · invoca jobs de Cloud Run"
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  name     = google_cloud_run_v2_job.key_auditor.name
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.scheduler.member
}

resource "google_cloud_scheduler_job" "key_auditor" {
  name        = "${local.key_auditor_job_name}-daily"
  description = "Auditoría diaria de claves de cuentas de servicio."
  region      = var.region
  schedule    = var.key_auditor_schedule
  time_zone   = "America/Lima"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.key_auditor.name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoker]
}
