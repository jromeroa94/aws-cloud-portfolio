# ---------- Artifact Registry ----------
#
# Un repositorio Docker regional para la API, el auditor y la caché de kaniko.
# El análisis de vulnerabilidades es automático al habilitar containerscanning.
# Las políticas de limpieza son FinOps aplicado al registro: un portfolio de CI
# genera cientos de capas de caché e imágenes de ramas que nadie vuelve a usar.

resource "google_artifact_registry_repository" "platform" {
  #checkov:skip=CKV_GCP_84:Las imágenes no contienen datos sensibles; CMEK añadiría una dependencia del agente de servicio de Artifact Registry sin reducir ningún riesgo real aquí. Los secretos de etcd sí van con CMEK (gke.tf).
  location      = var.region
  repository_id = "platform"
  format        = "DOCKER"
  description   = "Imágenes de la plataforma: api, iam-key-auditor y caché de kaniko."

  docker_config {
    # latest-main es una etiqueta móvil (la mueve cada build de main); las etiquetas
    # inmutables impedirían eso. El despliegue usa siempre el SHA del commit.
    immutable_tags = false
  }

  cleanup_policy_dry_run = false

  # Las reglas KEEP tienen prioridad sobre las DELETE: nada etiquetado con un SHA
  # reciente o con latest-main se borra.
  cleanup_policies {
    id     = "keep-recent-tagged"
    action = "KEEP"

    most_recent_versions {
      package_name_prefixes = ["api", "iam-key-auditor"]
      keep_count            = 10
    }
  }

  cleanup_policies {
    id     = "keep-latest-main"
    action = "KEEP"

    condition {
      tag_state    = "TAGGED"
      tag_prefixes = ["latest-main"]
    }
  }

  cleanup_policies {
    id     = "delete-untagged-7d"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 días
    }
  }

  cleanup_policies {
    id     = "delete-stale-tags-90d"
    action = "DELETE"

    condition {
      tag_state  = "TAGGED"
      older_than = "7776000s" # 90 días: imágenes de commits antiguos que ya no están desplegadas
    }
  }

  depends_on = [google_project_service.apis]
}

# ---------- Secretos de la GitHub App de ARC ----------
#
# Terraform crea los secretos vacíos; los valores se añaden a mano una vez
# (gcloud secrets versions add) para que nunca pasen por el estado de Terraform.

locals {
  arc_secrets = {
    "arc-github-app-id"              = "ID numérico de la GitHub App de ARC"
    "arc-github-app-installation-id" = "ID de la instalación de la GitHub App en el repositorio"
    "arc-github-app-private-key"     = "Clave privada PEM de la GitHub App"
  }
}

resource "google_secret_manager_secret" "arc" {
  for_each = local.arc_secrets

  secret_id = each.key

  annotations = {
    purpose = each.value
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

# Solo la cuenta de bootstrap puede leerlos (crea el Secret de Kubernetes).
resource "google_secret_manager_secret_iam_member" "arc_deployer" {
  for_each = google_secret_manager_secret.arc

  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.github_deployer.member
}
