variable "region" {
  description = "Región de la aplicación observada."
  type        = string
  default     = "sa-east-1"
}

variable "environment" {
  description = "Entorno."
  type        = string
  default     = "prod"
}

variable "service_name" {
  description = "Nombre del servicio (prefijo de alarmas y dashboard)."
  type        = string
  default     = "portfolio"
}

# --- Recursos observados (salidas de los proyectos 01 y 02) ------------------
variable "alb_arn_suffix" {
  description = "Sufijo del ARN del ALB (output alb_arn_suffix del módulo app-stack)."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Sufijo del ARN del target group."
  type        = string
}

variable "asg_name" {
  description = "Auto Scaling Group de la aplicación."
  type        = string
}

variable "db_cluster_identifier" {
  description = "Cluster Aurora (opcional)."
  type        = string
  default     = null
}

variable "lambda_function_names" {
  description = "Funciones Lambda a incluir en el dashboard."
  type        = list(string)
  default     = []
}

variable "queue_names" {
  description = "Colas SQS de trabajo (se vigila la antigüedad del mensaje más viejo)."
  type        = list(string)
  default     = []
}

variable "dlq_names" {
  description = "Colas de mensajes fallidos (cualquier mensaje es una alerta)."
  type        = list(string)
  default     = []
}

variable "app_log_group_names" {
  description = "Log groups de la aplicación con logs JSON (campo level)."
  type        = list(string)
  default     = []
}

variable "vpc_flow_log_group_name" {
  description = "Log group de VPC Flow Logs (para la consulta de tráfico rechazado)."
  type        = string
  default     = null
}

variable "cloudtrail_log_group_name" {
  description = "Log group de CloudTrail (para la consulta de accesos denegados)."
  type        = string
  default     = null
}

# --- Objetivos de nivel de servicio ------------------------------------------
variable "availability_slo" {
  description = "Objetivo de disponibilidad (fracción de peticiones sin 5xx). 0.999 = 43 min/mes de presupuesto de error."
  type        = number
  default     = 0.999

  validation {
    condition     = var.availability_slo > 0.9 && var.availability_slo < 1
    error_message = "availability_slo debe estar entre 0.9 y 1 (exclusivo)."
  }
}

variable "latency_p99_threshold_s" {
  description = "Latencia p99 máxima aceptable (segundos)."
  type        = number
  default     = 1.0
}

variable "queue_max_age_s" {
  description = "Antigüedad máxima tolerada del mensaje más viejo en las colas de trabajo."
  type        = number
  default     = 300
}

# --- Notificaciones -------------------------------------------------------------
variable "page_topic_arn" {
  description = "Tema SNS para alertas que requieren acción inmediata (guardia)."
  type        = string
  default     = null
}

variable "ticket_topic_arn" {
  description = "Tema SNS para alertas que pueden esperar a horario laboral."
  type        = string
  default     = null
}

# --- ELK opcional (Amazon OpenSearch Service) ------------------------------------
variable "opensearch" {
  description = <<-EOT
    Envío de los logs de la aplicación a Amazon OpenSearch (stack ELK gestionado) mediante
    CloudWatch Logs -> Data Firehose -> OpenSearch. Desactivado por defecto por su coste.
  EOT
  type = object({
    enabled            = bool
    vpc_id             = optional(string)
    subnet_ids         = optional(list(string), [])
    instance_type      = optional(string, "t3.small.search")
    instance_count     = optional(number, 2)
    volume_size_gb     = optional(number, 20)
    allowed_cidr_block = optional(string)
  })
  default = { enabled = false }

  validation {
    condition     = !var.opensearch.enabled || (var.opensearch.vpc_id != null && length(var.opensearch.subnet_ids) >= 2)
    error_message = "Con opensearch.enabled = true hay que indicar vpc_id y al menos 2 subnet_ids privadas."
  }
}
