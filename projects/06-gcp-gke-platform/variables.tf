variable "project_id" {
  description = "ID del proyecto de Google Cloud donde se despliega la plataforma."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "El ID de proyecto debe tener entre 6 y 30 caracteres: minúsculas, dígitos y guiones."
  }
}

variable "region" {
  description = "Región de GCP. southamerica-east1 (São Paulo) es la de menor latencia para Sudamérica."
  type        = string
  default     = "southamerica-east1"
}

variable "environment" {
  description = "Entorno (dev, staging, prod). Forma parte del nombre del clúster y de las etiquetas."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment debe ser dev, staging o prod."
  }
}

variable "github_owner" {
  description = "Usuario u organización de GitHub cuyos repositorios pueden federarse (condición del proveedor OIDC)."
  type        = string
  default     = "jromeroa94"
}

variable "github_repo" {
  description = "Repositorio de GitHub autorizado a desplegar (sin el owner)."
  type        = string
  default     = "aws-cloud-portfolio"
}

# ---------- Red ----------

variable "subnet_cidr" {
  description = "Rango primario de la subred de GKE (nodos)."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Rango secundario para Pods (alias IP). /16 permite ~110 Pods por nodo en 250 nodos."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Rango secundario para Services (ClusterIP)."
  type        = string
  default     = "10.30.0.0/20"
}

variable "master_cidr" {
  description = "Rango /28 reservado para el plano de control privado de GKE."
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = endswith(var.master_cidr, "/28")
    error_message = "GKE exige un /28 para el plano de control."
  }
}

variable "authorized_networks" {
  description = "CIDRs con acceso al endpoint público del plano de control (oficina, VPN). Vacío = solo el endpoint DNS autenticado con IAM."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

# ---------- GKE ----------

variable "apps_machine_type" {
  description = "Tipo de máquina del pool de aplicaciones."
  type        = string
  default     = "e2-standard-2"
}

variable "apps_min_nodes" {
  description = "Mínimo total de nodos del pool de aplicaciones (sumando zonas)."
  type        = number
  default     = 2
}

variable "apps_max_nodes" {
  description = "Máximo total de nodos del pool de aplicaciones."
  type        = number
  default     = 6
}

variable "runners_machine_type" {
  description = "Tipo de máquina del pool de runners de GitHub Actions (Spot)."
  type        = string
  default     = "e2-standard-4"
}

variable "runners_max_nodes" {
  description = "Máximo de nodos Spot para runners. El mínimo es siempre 0: sin trabajos, sin coste."
  type        = number
  default     = 4
}

variable "enable_binary_authorization" {
  description = "Exigir imágenes atestadas (Binary Authorization). Desactivado por defecto para no bloquear el primer despliegue; el README explica cómo activarlo."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Protección contra borrado del clúster. true en producción real; false en laboratorio para poder destruir."
  type        = bool
  default     = false
}

# ---------- Observabilidad y coste ----------

variable "alert_email" {
  description = "Correo para alertas de SLO, GKE, auditoría IAM y presupuesto. Vacío = sin canal de notificación."
  type        = string
  default     = ""
}

variable "availability_slo" {
  description = "Objetivo de disponibilidad del servicio (ratio de respuestas no 5xx en el balanceador)."
  type        = number
  default     = 0.999

  validation {
    condition     = var.availability_slo > 0.9 && var.availability_slo < 1
    error_message = "El SLO debe estar entre 0.9 y 1 (exclusivo)."
  }
}

variable "latency_threshold_ms" {
  description = "Latencia máxima (ms) para considerar una petición 'rápida' en el SLO de latencia."
  type        = number
  default     = 500
}

variable "latency_slo" {
  description = "Fracción de peticiones que deben responder por debajo de latency_threshold_ms."
  type        = number
  default     = 0.95
}

variable "billing_account_id" {
  description = "Cuenta de facturación (XXXXXX-XXXXXX-XXXXXX) para el presupuesto. Vacío = sin presupuesto (requiere permisos de Billing Admin)."
  type        = string
  default     = ""
}

variable "budget_amount_usd" {
  description = "Presupuesto mensual en USD para este proyecto."
  type        = number
  default     = 150
}

# ---------- Auditor de claves IAM ----------

variable "key_auditor_schedule" {
  description = "Cron (hora de America/Lima) del auditor de claves de cuentas de servicio."
  type        = string
  default     = "0 7 * * *"
}

variable "key_auditor_max_age_days" {
  description = "Edad a partir de la cual una clave user-managed debe rotarse."
  type        = number
  default     = 90
}

variable "key_auditor_grace_days" {
  description = "Días de gracia tras max_age antes de recomendar (o ejecutar) la desactivación."
  type        = number
  default     = 14
}

variable "key_auditor_enforce" {
  description = "Si es true, el auditor desactiva las claves que superan la gracia. Por defecto solo informa."
  type        = bool
  default     = false
}

variable "key_auditor_image" {
  description = "Imagen del auditor. Vacío = la publicada por la CI en Artifact Registry con la etiqueta latest-main."
  type        = string
  default     = ""
}

variable "enforce_no_sa_keys" {
  description = "Aplicar la política de organización iam.disableServiceAccountKeyCreation en el proyecto (requiere orgpolicy.policyAdmin)."
  type        = bool
  default     = false
}
