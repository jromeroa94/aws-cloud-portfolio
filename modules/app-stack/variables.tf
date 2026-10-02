variable "name" {
  description = "Prefijo de nombres (p. ej. portfolio-prod-sa)."
  type        = string
}

variable "role" {
  description = "Rol de la región en la estrategia de DR: primary o standby."
  type        = string

  validation {
    condition     = contains(["primary", "standby"], var.role)
    error_message = "role debe ser primary o standby."
  }
}

variable "vpc_id" {
  description = "VPC donde se despliega la aplicación."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subredes públicas para el ALB."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subredes privadas para las instancias."
  type        = list(string)
}

variable "instance_type" {
  description = "Tipo de instancia (Graviton por defecto: mejor precio/rendimiento)."
  type        = string
  default     = "t4g.small"
}

variable "min_size" {
  description = "Capacidad mínima del ASG."
  type        = number
}

variable "max_size" {
  description = "Capacidad máxima del ASG."
  type        = number
}

variable "desired_capacity" {
  description = "Capacidad deseada inicial. En standby se mantiene reducida (warm standby)."
  type        = number
}

variable "cpu_target" {
  description = "Objetivo de CPU media (%) para el escalado por seguimiento de objetivo."
  type        = number
  default     = 55
}

variable "certificate_arn" {
  description = "Certificado ACM para HTTPS. Si es null, el ALB solo escucha en HTTP (útil en laboratorio)."
  type        = string
  default     = null
}

variable "ssl_policy" {
  description = "Política TLS del listener HTTPS."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "alb_access_logs_bucket" {
  description = "Bucket S3 para access logs del ALB (opcional)."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Protección contra borrado del ALB (true en producción real)."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Protege el ALB con AWS WAF (reglas gestionadas + rate limiting)."
  type        = bool
  default     = true
}

variable "waf_rate_limit_per_5min" {
  description = "Peticiones máximas por IP en 5 minutos antes de bloquear."
  type        = number
  default     = 2000
}

variable "tags" {
  description = "Etiquetas comunes."
  type        = map(string)
  default     = {}
}
