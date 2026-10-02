variable "region" {
  description = "Región de despliegue."
  type        = string
  default     = "sa-east-1"
}

variable "name" {
  description = "Nombre base."
  type        = string
  default     = "orders"
}

variable "environment" {
  description = "Entorno."
  type        = string
  default     = "dev"
}

variable "cost_center" {
  description = "Centro de coste (etiqueta CostCenter)."
  type        = string
  default     = "platform"
}

variable "lambda_memory_mb" {
  description = "Memoria de la Lambda (la CPU escala proporcionalmente)."
  type        = number
  default     = 256
}

variable "lambda_timeout_s" {
  description = "Timeout de la Lambda."
  type        = number
  default     = 30
}

variable "max_concurrency" {
  description = "Concurrencia máxima del event source mapping: protege a DynamoDB y a los consumidores."
  type        = number
  default     = 10

  validation {
    condition     = var.max_concurrency >= 2 && var.max_concurrency <= 1000
    error_message = "max_concurrency debe estar entre 2 y 1000 (límite de SQS event source mapping)."
  }
}

variable "max_receive_count" {
  description = "Intentos antes de mover un mensaje a la DLQ."
  type        = number
  default     = 5
}

variable "log_retention_days" {
  description = "Retención de logs de la Lambda."
  type        = number
  default     = 30
}

variable "consumers" {
  description = <<-EOT
    Servicios descendentes suscritos al tema de pedidos (fan-out SNS -> SQS).
    filter_policy filtra por atributos del mensaje: cada servicio recibe solo lo que necesita.
  EOT
  type = map(object({
    filter_policy = map(list(string))
  }))
  default = {
    shipping = {
      filter_policy = { event_type = ["order.accepted"], requires_shipping = ["true"] }
    }
    inventory = {
      filter_policy = { event_type = ["order.accepted"] }
    }
    analytics = {
      filter_policy = { event_type = ["order.accepted", "order.rejected"] }
    }
  }
}

variable "alarm_topic_arn" {
  description = "Tema SNS de alertas operativas (opcional)."
  type        = string
  default     = null
}
