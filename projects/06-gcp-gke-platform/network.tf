# ---------- VPC y subred de GKE ----------
#
# VPC personalizada (nunca la red "default"): una sola subred regional con dos
# rangos secundarios para Pods y Services (clúster VPC-native) y acceso privado a
# las APIs de Google, de modo que los nodos no necesitan IP pública para hablar
# con Artifact Registry, Cloud Logging o Secret Manager.

resource "google_compute_network" "platform" {
  name                            = "platform-${var.environment}"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "gke" {
  name                     = "gke-${var.environment}"
  region                   = var.region
  network                  = google_compute_network.platform.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  # Flow logs muestreados: suficientes para investigar un incidente de red sin
  # pagar por registrar el 100 % del tráfico.
  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------- Salida a internet: Cloud NAT ----------
#
# Los nodos son privados. Cloud NAT da salida (ghcr.io, GitHub, PyPI, base de
# datos de Trivy...) sin exponer ninguna IP de entrada.

resource "google_compute_router" "platform" {
  name    = "platform-${var.environment}"
  region  = var.region
  network = google_compute_network.platform.id
}

resource "google_compute_router_nat" "platform" {
  name                               = "platform-${var.environment}"
  router                             = google_compute_router.platform.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Asignación dinámica de puertos: los runners abren muchas conexiones cortas
  # (git, descargas de paquetes) y con puertos fijos agotarían el NAT.
  enable_dynamic_port_allocation      = true
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = 64
  max_ports_per_vm                    = 4096

  log_config {
    enable = true
    filter = "ERRORS_ONLY" # solo caídas de puertos: es lo que importa en un incidente
  }
}

# ---------- Firewall ----------
#
# GKE crea sus propias reglas para el tráfico nodo-nodo y para los health checks
# del balanceador. Añadimos solo lo que no crea por defecto: los puertos de los
# webhooks de admisión (ARC, Gateway API) desde el plano de control.

resource "google_compute_firewall" "master_webhooks" {
  name        = "gke-${var.environment}-master-webhooks"
  network     = google_compute_network.platform.name
  description = "Plano de control -> webhooks de admisión en los nodos (ARC, Gateway API, Managed Prometheus)."
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.master_cidr]
  target_tags   = [local.node_tag]

  allow {
    protocol = "tcp"
    ports    = ["8443", "9443", "10250", "15017"]
  }
}

# Denegación explícita del resto del tráfico entrante hacia los nodos, por debajo
# de las reglas que GKE y el balanceador crean con prioridad 1000.
resource "google_compute_firewall" "deny_ingress" {
  name        = "gke-${var.environment}-deny-ingress"
  network     = google_compute_network.platform.name
  description = "Deniega cualquier otro tráfico entrante a los nodos."
  direction   = "INGRESS"
  priority    = 65000

  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.node_tag]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# ---------- Borde: IP estable y Cloud Armor ----------

# IP global para el Gateway (el chart la referencia por nombre). Sin ella, cada
# recreación del Gateway cambiaría la IP y rompería el DNS.
resource "google_compute_global_address" "gateway" {
  name         = "platform-gateway-${var.environment}"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

# Política WAF delante del balanceador: límite de peticiones por IP, reglas
# preconfiguradas OWASP (SQLi, XSS) y protección adaptativa contra DDoS L7.
resource "google_compute_security_policy" "platform_edge" {
  name        = "platform-edge"
  description = "WAF y rate limiting del borde de la plataforma."
  type        = "CLOUD_ARMOR"

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }

  rule {
    priority    = 1000
    description = "Máximo 300 peticiones por IP cada 60 s; bloqueo de 10 min si se supera."
    action      = "rate_based_ban"

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action   = "allow"
      exceed_action    = "deny(429)"
      enforce_on_key   = "IP"
      ban_duration_sec = 600

      rate_limit_threshold {
        count        = 300
        interval_sec = 60
      }
    }
  }

  rule {
    priority    = 2000
    description = "OWASP CRS: inyección SQL."
    action      = "deny(403)"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    priority    = 2010
    description = "OWASP CRS: cross-site scripting."
    action      = "deny(403)"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    priority    = 2020
    description = "Firmas de CVEs conocidas (Log4Shell y similares)."
    action      = "deny(403)"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('cve-canary')"
      }
    }
  }

  rule {
    priority    = 2147483647
    description = "Regla por defecto: permitir."
    action      = "allow"

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}
