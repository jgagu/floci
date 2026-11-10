variable "environment" {
  description = "Entorno de la aplicación: dev o test."
  type        = string

  validation {
    condition     = contains(["dev", "test"], var.environment)
    error_message = "environment debe ser dev o test."
  }
}

variable "location" {
  description = "Región simulada por Floci-AZ."
  type        = string
  default     = "westeurope"
}

variable "vnet_address_space" {
  description = "Rangos de direcciones de la VNet."
  type        = list(string)
}

variable "subnets" {
  description = "Subredes de frontend y backend."
  type        = map(list(string))

  validation {
    condition     = contains(keys(var.subnets), "frontend") && contains(keys(var.subnets), "backend")
    error_message = "Deben definirse las subredes frontend y backend."
  }
}

variable "vm_size" {
  description = "Tamaño de la VM simulada."
  type        = string
  default     = "Standard_D4_v5"
}

variable "ssh_public_key" {
  description = "Clave pública SSH para la VM."
  type        = string
}

variable "floci_metadata_host" {
  description = "Host y puerto de metadatos de Floci-AZ."
  type        = string
  default     = "127.0.0.1:4577"
}

variable "subscription_id" {
  description = "Identificador ficticio de suscripción de Floci."
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"
}

variable "tenant_id" {
  description = "Identificador ficticio del tenant de Floci."
  type        = string
  default     = "00000000-0000-0000-0000-000000000002"
}

variable "client_id" {
  description = "Identificador ficticio de la aplicación en Floci."
  type        = string
  default     = "00000000-0000-0000-0000-000000000003"
}

variable "client_secret" {
  description = "Secreto ficticio del cliente de Floci."
  type        = string
  sensitive   = true
  default     = "floci-local-secret"
}
