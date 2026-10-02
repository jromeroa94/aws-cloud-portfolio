variable "region" {
  description = "Región donde corre el escáner."
  type        = string
  default     = "sa-east-1"
}

variable "environment" {
  description = "Entorno."
  type        = string
  default     = "prod"
}

variable "name" {
  description = "Prefijo de nombres."
  type        = string
  default     = "finops"
}

variable "scan_regions" {
  description = "Regiones que revisa el escáner."
  type        = list(string)
  default     = ["sa-east-1", "us-east-1"]
}

variable "required_tags" {
  description = "Etiquetas de asignación de costes obligatorias."
  type        = list(string)
  default     = ["CostCenter", "Environment", "Project"]
}

variable "snapshot_max_age_days" {
  description = "Antigüedad a partir de la cual un snapshot sin AMI se considera candidato."
  type        = number
  default     = 90
}

variable "stopped_max_days" {
  description = "Días detenida a partir de los cuales una instancia se reporta."
  type        = number
  default     = 14
}

variable "tag_candidates" {
  description = "Etiquetar los candidatos con finops:review-requested (nunca se borra nada)."
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "Cuándo corre el escáner (EventBridge Scheduler)."
  type        = string
  default     = "cron(0 8 ? * MON *)"
}

variable "schedule_timezone" {
  description = "Zona horaria del schedule."
  type        = string
  default     = "America/Santiago"
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual de la cuenta en USD."
  type        = number
  default     = 500
}

variable "anomaly_threshold_usd" {
  description = "Impacto mínimo (USD) para notificar una anomalía de coste."
  type        = number
  default     = 50
}

variable "notification_emails" {
  description = "Destinatarios de presupuestos, anomalías e informes."
  type        = list(string)
  default     = []
}

variable "activate_cost_allocation_tags" {
  description = <<-EOT
    Activa las required_tags como etiquetas de asignación de costes en Billing.
    Solo funciona si las etiquetas ya existen en algún recurso (AWS tarda hasta 24 h en verlas).
  EOT
  type        = bool
  default     = false
}
