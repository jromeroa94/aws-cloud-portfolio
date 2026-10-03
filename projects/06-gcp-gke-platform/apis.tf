# APIs que necesita la plataforma. Se declaran aquí para que el proyecto sea
# reproducible desde cero; disable_on_destroy=false evita que un destroy del
# laboratorio apague APIs que otros recursos del proyecto puedan estar usando.

locals {
  apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "containerscanning.googleapis.com", # análisis de vulnerabilidades de las imágenes
    "cloudkms.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com", # intercambio de tokens para Workload Identity Federation
    "cloudresourcemanager.googleapis.com",
    "orgpolicy.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "billingbudgets.googleapis.com",
    "binaryauthorization.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  service            = each.value
  disable_on_destroy = false
}

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  project_number = data.google_project.this.number

  # Agentes de servicio de Google que necesitan permisos sobre recursos nuestros.
  gke_service_agent = "serviceAccount:service-${local.project_number}@container-engine-robot.iam.gserviceaccount.com"
}
