variable "name" {
  description = "Nombre base de la aplicación."
  type        = string
  default     = "portfolio"
}

variable "environment" {
  description = "Entorno (dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "cost_center" {
  description = "Centro de coste para la asignación de gastos (etiqueta CostCenter)."
  type        = string
  default     = "platform"
}

variable "primary_region" {
  description = "Región activa. sa-east-1 (São Paulo) es la de menor latencia hacia Chile."
  type        = string
  default     = "sa-east-1"
}

variable "dr_region" {
  description = "Región de recuperación (warm standby)."
  type        = string
  default     = "us-east-1"
}

variable "primary_vpc_cidr" {
  description = "CIDR de la VPC primaria."
  type        = string
  default     = "10.10.0.0/16"
}

variable "dr_vpc_cidr" {
  description = "CIDR de la VPC de DR (no debe solaparse con la primaria, por si se conectan con peering o TGW)."
  type        = string
  default     = "10.20.0.0/16"
}

# --- Capacidad ---------------------------------------------------------------
variable "primary_capacity" {
  description = "Capacidad del ASG en la región primaria."
  type = object({
    min     = number
    max     = number
    desired = number
  })
  default = { min = 2, max = 6, desired = 2 }
}

variable "dr_capacity" {
  description = "Capacidad reducida en DR. El runbook la eleva a la de producción durante el failover."
  type = object({
    min     = number
    max     = number
    desired = number
  })
  default = { min = 1, max = 6, desired = 1 }
}

variable "instance_type" {
  description = "Tipo de instancia de la aplicación."
  type        = string
  default     = "t4g.small"
}

# --- Base de datos -------------------------------------------------------------
variable "db_engine_version" {
  description = "Versión de Aurora PostgreSQL compatible con Global Database."
  type        = string
  default     = "16.6"
}

variable "db_instance_class" {
  description = "Clase de instancia (Global Database no admite clases burstable db.t*)."
  type        = string
  default     = "db.r6g.large"
}

variable "db_primary_instance_count" {
  description = "Instancias en la región primaria (1 writer + N readers en otras AZ)."
  type        = number
  default     = 2
}

variable "db_dr_instance_count" {
  description = "Instancias en DR (1 reader que se promueve en el failover)."
  type        = number
  default     = 1
}

variable "db_password_version" {
  description = "Incrementar para rotar la contraseña maestra (atributo write-only: no queda en el estado)."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Protección contra borrado de la base de datos y los ALB."
  type        = bool
  default     = true
}

variable "replication_lag_threshold_ms" {
  description = "Umbral de lag de replicación global (ms) para alertar de riesgo de RPO."
  type        = number
  default     = 30000
}

variable "alarm_topic_arns" {
  description = "Temas SNS por región a los que se envían las alarmas (us_east_1 recibe la alarma de Route 53)."
  type = object({
    primary   = optional(string)
    dr        = optional(string)
    us_east_1 = optional(string)
  })
  default = {}
}

# --- DNS -------------------------------------------------------------------------
variable "route53_zone_id" {
  description = "Hosted zone pública. Si es null, no se crean registros de failover."
  type        = string
  default     = null
}

variable "app_fqdn" {
  description = "Nombre DNS de la aplicación (p. ej. app.ejemplo.cl)."
  type        = string
  default     = null
}

variable "certificate_arns" {
  description = "Certificados ACM por región para HTTPS (opcional)."
  type = object({
    primary = optional(string)
    dr      = optional(string)
  })
  default = {}
}
