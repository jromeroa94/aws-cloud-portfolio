variable "name" {
  description = "Prefijo para nombrar los recursos de la VPC."
  type        = string
}

variable "cidr_block" {
  description = "CIDR de la VPC (se divide automáticamente en subredes /20)."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block debe ser un CIDR IPv4 válido."
  }
}

variable "az_count" {
  description = "Número de zonas de disponibilidad a usar (mínimo 2 para alta disponibilidad)."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count debe estar entre 2 y 4."
  }
}

variable "nat_gateway_mode" {
  description = <<-EOT
    Estrategia de NAT:
      - "per_az": una NAT Gateway por AZ (producción: sin punto único de fallo ni tráfico inter-AZ).
      - "single": una sola NAT Gateway (entornos no productivos: ahorra ~US$ 32/mes por AZ).
      - "none":   sin NAT (subredes privadas aisladas; acceso a AWS solo por VPC endpoints).
  EOT
  type        = string
  default     = "per_az"

  validation {
    condition     = contains(["per_az", "single", "none"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode debe ser per_az, single o none."
  }
}

variable "enable_s3_gateway_endpoint" {
  description = "Crea un VPC endpoint de tipo Gateway para S3 (gratuito; evita pasar el tráfico a S3 por la NAT)."
  type        = bool
  default     = true
}

variable "enable_dynamodb_gateway_endpoint" {
  description = "Crea un VPC endpoint de tipo Gateway para DynamoDB."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Días de retención de los VPC Flow Logs en CloudWatch Logs. 0 desactiva los Flow Logs."
  type        = number
  default     = 30
}

variable "flow_logs_kms_key_arn" {
  description = "ARN de la clave KMS para cifrar el log group de Flow Logs (opcional)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Etiquetas comunes."
  type        = map(string)
  default     = {}
}
