# ---------- Clúster GKE privado y regional ----------
#
# Decisiones (ver también ADR-0005):
#   * Nodos privados, plano de control con endpoint DNS autenticado por IAM: sin
#     IPs públicas en los nodos y sin abrir redes autorizadas a 0.0.0.0/0.
#   * Regional (3 zonas): el plano de control y los nodos sobreviven a la caída de
#     una zona; es el equivalente a Multi-AZ en AWS.
#   * Workload Identity: los Pods obtienen credenciales de GCP sin claves JSON.
#   * Dataplane V2 (Cilium): NetworkPolicy nativa y logs de política de red.
#   * Secrets de etcd cifrados con una clave propia de Cloud KMS con rotación.
#   * Dos pools: "apps" (on-demand) y "runners" (Spot, a 0 cuando no hay CI).

locals {
  cluster_name = "platform-${var.environment}"
  node_tag     = "gke-platform-${var.environment}"
}

# ---------- Cuenta de servicio de los nodos ----------
#
# Nunca la cuenta de Compute por defecto (es Editor del proyecto). Solo lo que el
# nodo necesita: escribir logs y métricas, y leer imágenes del registro.

resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes-${var.environment}"
  display_name = "Nodos de GKE ${local.cluster_name}"
  description  = "Cuenta mínima para los nodos: logs, métricas y lectura de Artifact Registry."
}

locals {
  node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/autoscaling.metricsWriter",
    "roles/artifactregistry.reader",
  ]
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset(local.node_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.gke_nodes.member
}

# ---------- Cifrado de secretos de Kubernetes (etcd) ----------

resource "google_kms_key_ring" "platform" {
  name     = "platform-${var.environment}"
  location = var.region

  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "gke_etcd" {
  #checkov:skip=CKV_GCP_82:Laboratorio desechable: prevent_destroy impediría terraform destroy. En producción real se activa junto con un destroy_scheduled_duration de 30 días.
  name            = "gke-etcd"
  key_ring        = google_kms_key_ring.platform.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 días

  # En laboratorio la clave se destruye con el resto; en producción real se
  # protegería con prevent_destroy y un periodo de destrucción programada largo.
  destroy_scheduled_duration = "86400s"
}

resource "google_kms_crypto_key_iam_member" "gke_etcd" {
  crypto_key_id = google_kms_crypto_key.gke_etcd.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = local.gke_service_agent
}

# ---------- Clúster ----------

resource "google_container_cluster" "platform" {
  #checkov:skip=CKV_GCP_12:Dataplane V2 (datapath_provider=ADVANCED_DATAPATH) implementa NetworkPolicy de forma nativa; el bloque network_policy es para el add-on Calico y no aplica.
  #checkov:skip=CKV_GCP_66:Binary Authorization es opt-in (enable_binary_authorization): exigir atestaciones requiere firmar las imágenes en la CI, documentado como siguiente paso en el README.
  #checkov:skip=CKV_GCP_65:Google Groups for GKE requiere un dominio de Google Workspace; este proyecto se despliega en una cuenta individual.
  name     = local.cluster_name
  location = var.region

  network    = google_compute_network.platform.id
  subnetwork = google_compute_subnetwork.gke.id

  # Los pools se gestionan aparte; el pool por defecto se elimina tras crear el clúster.
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = var.deletion_protection

  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH" # Dataplane V2: NetworkPolicy sin add-on Calico

  # Flow logs también entre Pods del mismo nodo: sin esto, ese tráfico es invisible
  # en una investigación.
  enable_intranode_visibility = true

  # Sin certificados de cliente: la autenticación es siempre IAM (gcloud, WIF).
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr

    master_global_access_config {
      enabled = true
    }
  }

  # Endpoint DNS del plano de control: se autentica con IAM y no requiere redes
  # autorizadas. Es lo que usa el job de bootstrap desde los runners de GitHub.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
    ip_endpoints_config {
      enabled = true
    }
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  enable_shielded_nodes = true

  binary_authorization {
    evaluation_mode = var.enable_binary_authorization ? "PROJECT_SINGLETON_POLICY_ENFORCE" : "DISABLED"
  }

  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.gke_etcd.id
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
    gcs_fuse_csi_driver_config {
      enabled = false
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER", "DEPLOYMENT", "HPA", "POD"]

    managed_prometheus {
      enabled = true # PodMonitoring del chart y métricas de ARC
    }
  }

  vertical_pod_autoscaling {
    enabled = true # recomendaciones de requests/limits: insumo de FinOps
  }

  cost_management_config {
    enabled = true # asignación de coste por namespace y etiqueta en Billing
  }

  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC"
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T03:00:00Z"
      end_time   = "2026-01-03T09:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU" # madrugada del fin de semana, hora de Lima
    }
  }

  # Configuración del pool temporal por defecto: también sin la SA por defecto.
  node_config {
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    tags            = [local.node_tag]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  resource_labels = {
    environment = var.environment
    component   = "gke-platform"
  }

  depends_on = [
    google_project_service.apis,
    google_kms_crypto_key_iam_member.gke_etcd,
    google_project_iam_member.gke_nodes,
  ]

  lifecycle {
    ignore_changes = [node_config, initial_node_count]
  }
}

# ---------- Pool de aplicaciones ----------

resource "google_container_node_pool" "apps" {
  name     = "apps"
  cluster  = google_container_cluster.platform.id
  location = var.region

  autoscaling {
    total_min_node_count = var.apps_min_nodes
    total_max_node_count = var.apps_max_nodes
    location_policy      = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.apps_machine_type
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    tags            = [local.node_tag]

    labels = {
      workload = "apps"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ---------- Pool de runners de GitHub Actions ----------
#
# Spot + taint: solo los runners se programan aquí, y el autoescalador baja a cero
# nodos cuando no hay trabajos. Un runner que pierde su VM Spot simplemente
# reintenta el job; la plataforma de aplicaciones no se ve afectada.

resource "google_container_node_pool" "runners" {
  name     = "runners"
  cluster  = google_container_cluster.platform.id
  location = var.region

  autoscaling {
    total_min_node_count = 0
    total_max_node_count = var.runners_max_nodes
    location_policy      = "ANY" # recomendado para Spot: usa la zona con capacidad
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.runners_machine_type
    spot            = true
    disk_type       = "pd-balanced"
    disk_size_gb    = 100 # capas de imágenes y caché de kaniko
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    tags            = [local.node_tag]

    labels = {
      workload = "runners"
    }

    taint {
      key    = "dedicated"
      value  = "runners"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}
