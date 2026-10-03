terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }

  # El bucket se pasa con -backend-config (uno por cuenta/entorno); el prefijo fija
  # dónde vive el estado de este proyecto dentro de él.
  backend "gcs" {
    prefix = "projects/06-gcp-gke-platform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Etiquetas en todos los recursos que las admiten: imprescindibles para FinOps
  # (informes de facturación por etiqueta) y para saber quién gestiona cada cosa.
  default_labels = {
    project     = "cloud-portfolio"
    component   = "gke-platform"
    environment = var.environment
    managed_by  = "terraform"
    cost_center = "platform"
  }
}
