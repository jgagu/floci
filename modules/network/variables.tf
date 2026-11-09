variable "name" {
  description = "Nombre de la red virtual."
  type        = string
}

variable "address_space" {
  description = "Rangos CIDR de la red virtual."
  type        = list(string)
}

variable "location" {
  description = "Región donde se crea la red."
  type        = string
}

variable "resource_group_name" {
  description = "Grupo de recursos donde se crea la red."
  type        = string
}

variable "subnets" {
  description = "Subredes indexadas por una clave estable, con delegación opcional a ACI."
  type = map(object({
    name             = string
    address_prefixes = list(string)
    delegate_to_aci  = bool
  }))
}
