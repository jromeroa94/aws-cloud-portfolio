variable "region" {
  description = "Región donde vive el estado de Terraform."
  type        = string
  default     = "sa-east-1"
}

variable "state_bucket_name" {
  description = "Nombre globalmente único del bucket de estado (p. ej. tfstate-<account-id>-sa-east-1)."
  type        = string
}

variable "github_repository" {
  description = "Repositorio autorizado a asumir el rol, formato owner/repo."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Usa el formato owner/repo."
  }
}

variable "plan_allowed_refs" {
  description = "Claims 'sub' de GitHub que pueden ejecutar plan (solo lectura)."
  type        = list(string)
  default     = ["pull_request"]
}

variable "apply_environment" {
  description = "Environment de GitHub con aprobación obligatoria desde el que se permite apply."
  type        = string
  default     = "production"
}

variable "create_oidc_provider" {
  description = "false si la cuenta ya tiene el proveedor OIDC de GitHub (solo puede existir uno)."
  type        = bool
  default     = true
}
