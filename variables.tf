variable "environment" {
  description = "Entorno de despliegue usado en los nombres de recursos."
  type        = string
  default     = "floci-az"

  validation {
    condition     = contains(["dev", "test", "prod", "floci-az"], var.environment)
    error_message = "El entorno debe ser dev, test o prod."
  }
}

variable "location" {
  description = "Región de Azure o Floci-AZ donde se crean los recursos."
  type        = string
}

variable "resource_group_name" {
  description = "Nombre del Resource Group."
  type        = string
}

variable "virtual_network_name" {
  description = "Nombre de la Virtual Network."
  type        = string
}

variable "virtual_network_address_space" {
  description = "Rangos CIDR asignados a la Virtual Network."
  type        = list(string)
}

variable "subnets" {
  description = "Subredes de la red virtual, indexadas por una clave estable."
  type = map(object({
    name             = string
    address_prefixes = list(string)
    delegate_to_aci  = bool
  }))

  validation {
    condition     = contains(keys(var.subnets), "frontend")
    error_message = "Debe existir la subred frontend, usada por la NIC y Storage."
  }
}

variable "storage_account_name" {
  description = "Nombre de la cuenta de almacenamiento: entre 3 y 24 caracteres, solo letras minúsculas y números."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "El nombre debe tener entre 3 y 24 caracteres y contener solo letras minúsculas y números."
  }
}

variable "floci_metadata_host" {
  description = "Host y puerto del endpoint de metadatos de Floci-AZ."
  type        = string
  default     = "127.0.0.1:4577"
}

variable "enable_key_vault" {
  description = "Habilita el recurso Key Vault. Se desactiva por defecto en Floci-AZ por la limitación actual de GetCertificateContacts."
  type        = bool
  default     = false
}

variable "subscription_id" {
  description = "ID de la suscripción Azure o Floci-AZ."
  type        = string
}

variable "tenant_id" {
  description = "ID del tenant de Microsoft Entra ID o Floci-AZ."
  type        = string
}

variable "client_id" {
  description = "ID de la aplicación o service principal usada por AzureRM."
  type        = string
}

variable "client_secret" {
  description = "Secreto del service principal. Debe inyectarse mediante TF_VAR_client_secret o desde el gestor de secretos del CI."
  type        = string
  sensitive   = true
}
