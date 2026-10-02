variable "region" {
  description = "Región principal (aquí se registran también los recursos globales de IAM en AWS Config)."
  type        = string
  default     = "sa-east-1"
}

variable "environment" {
  description = "Entorno de la cuenta."
  type        = string
  default     = "prod"
}

variable "name" {
  description = "Prefijo de nombres."
  type        = string
  default     = "security-baseline"
}

variable "security_alert_emails" {
  description = "Correos suscritos a las alertas de seguridad (requieren confirmación)."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "Retención del log group de CloudTrail en CloudWatch (el bucket S3 guarda el histórico completo)."
  type        = number
  default     = 90
}

variable "audit_log_retention_days" {
  description = "Días que se conservan los logs de auditoría en S3 antes de expirar (Glacier a los 90)."
  type        = number
  default     = 2555 # ~7 años
}

variable "required_tags" {
  description = "Etiquetas obligatorias que AWS Config verifica en los recursos (máx. 6 por la regla gestionada)."
  type        = list(string)
  default     = ["Project", "Environment", "CostCenter", "ManagedBy"]

  validation {
    condition     = length(var.required_tags) <= 6
    error_message = "La regla REQUIRED_TAGS admite como máximo 6 etiquetas."
  }
}

variable "guardduty_alert_min_severity" {
  description = "Severidad mínima de GuardDuty que dispara alerta (7 = alta)."
  type        = number
  default     = 7
}

variable "enable_security_hub_cis" {
  description = "Suscribir también el estándar CIS AWS Foundations Benchmark v3.0.0."
  type        = bool
  default     = true
}

variable "enable_object_lock" {
  description = <<-EOT
    Activa S3 Object Lock (modo GOVERNANCE, 365 días) en el bucket de auditoría para que
    los logs no puedan borrarse ni alterarse. Solo se puede activar al crear el bucket.
    false por defecto para que el laboratorio se pueda destruir; true en una cuenta real.
  EOT
  type        = bool
  default     = false
}
