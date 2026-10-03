# ---------- Identidades sin claves ----------
#
# En este proyecto no existe ninguna clave JSON de cuenta de servicio:
#   * GitHub Actions se federa con Workload Identity Federation (OIDC).
#   * Los Pods usan Workload Identity (KSA -> GSA).
#   * El auditor de claves (key-auditor.tf) vigila que siga siendo así.

# ---------- Workload Identity Federation para GitHub Actions ----------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-${var.environment}"
  display_name              = "GitHub Actions (${var.environment})"
  description               = "Identidades federadas de los workflows de GitHub Actions."

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  #checkov:skip=CKV_GCP_125:El check exige igualar assertion.sub completo. Aquí la condición fija el owner y cada binding de IAM restringe por repositorio y rama (attribute.repository_ref), lo que permite reutilizar el pool para varios repos del owner sin perder precisión.
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  # repository_ref combina repositorio y rama: permite autorizar "este repo, solo
  # desde main" con un único principalSet (cada binding admite un solo atributo).
  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.repository_ref"   = "assertion.repository + ':' + assertion.ref"
    "attribute.repository_env"   = "assertion.repository + ':' + (has(assertion.environment) ? assertion.environment : '')"
    "attribute.environment"      = "has(assertion.environment) ? assertion.environment : ''"
  }

  # Ningún token de otro owner puede siquiera intercambiarse: la condición se
  # evalúa antes que cualquier binding de IAM.
  attribute_condition = "assertion.repository_owner == '${var.github_owner}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  wif_pool    = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}"
  github_repo = "${var.github_owner}/${var.github_repo}"
}

# ---------- Cuenta de despliegue (bootstrap) ----------
#
# Solo la puede asumir el repositorio autorizado desde la rama main. Instala ARC
# (CRDs, ClusterRoles) y crea namespaces, por eso necesita container.admin: es la
# única cuenta "ancha" del proyecto y solo se usa en el bootstrap.

resource "google_service_account" "github_deployer" {
  account_id   = "github-deployer-${var.environment}"
  display_name = "GitHub Actions · bootstrap de la plataforma"
}

resource "google_service_account_iam_member" "github_deployer_wif" {
  service_account_id = google_service_account.github_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_pool}/attribute.repository_ref/${local.github_repo}:refs/heads/main"
}

resource "google_project_iam_member" "github_deployer" {
  for_each = toset([
    "roles/container.admin",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.github_deployer.member
}

# ---------- Cuenta de los runners self-hosted (Workload Identity) ----------
#
# Los runners construyen imágenes con kaniko y las publican en Artifact Registry;
# despliegan con Helm usando su token de Kubernetes (RBAC), no esta cuenta.

resource "google_service_account" "github_runners" {
  account_id   = "github-runners-${var.environment}"
  display_name = "Runners de GitHub Actions en GKE (ARC)"
}

resource "google_service_account_iam_member" "github_runners_wi" {
  service_account_id = google_service_account.github_runners.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[arc-runners/arc-runner]"
}

resource "google_artifact_registry_repository_iam_member" "github_runners_writer" {
  location   = google_artifact_registry_repository.platform.location
  repository = google_artifact_registry_repository.platform.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.github_runners.member
}

# ---------- Cuenta de la aplicación (Workload Identity) ----------
#
# Hoy la API no llama a ninguna API de Google: la cuenta existe para que el día
# que lo haga (Secret Manager, Pub/Sub) se le dé el permiso concreto, no Editor.

resource "google_service_account" "platform_api" {
  account_id   = "platform-api-${var.environment}"
  display_name = "platform-api (Pods del namespace platform)"
}

resource "google_service_account_iam_member" "platform_api_wi" {
  service_account_id = google_service_account.platform_api.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[platform/platform-api]"
}

# ---------- Política de organización: prohibir claves de SA ----------

resource "google_org_policy_policy" "disable_sa_keys" {
  count = var.enforce_no_sa_keys ? 1 : 0

  name   = "projects/${var.project_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }

  depends_on = [google_project_service.apis]
}
