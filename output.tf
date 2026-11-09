output "html_status_url" {
  description = "URL local del panel de estado de la infraestructura Floci-AZ."
  value       = "http://localhost:8080/html-prueba.html"
}

output "resource_group" {
  description = "Nombre y región del grupo de recursos."
  value = {
    name     = azurerm_resource_group.floci.name
    location = azurerm_resource_group.floci.location
  }
}

output "virtual_network" {
  description = "Identificador y rangos de la red virtual."
  value       = module.network.virtual_network
}

output "private_subnet" {
  description = "Identificador y rangos de la subred existente frontend."
  value       = module.network.subnets["frontend"]
}

output "subnets" {
  description = "Subredes indexadas por su clave lógica."
  value       = module.network.subnets
}

output "secondary_virtual_network" {
  description = "Identificador, nombre y rangos de la segunda red virtual."
  value       = module.secondary_network.virtual_network
}

output "secondary_subnets" {
  description = "Subredes de la segunda red virtual."
  value       = module.secondary_network.subnets
}

output "storage_account" {
  description = "Identificador y nombre de la cuenta de almacenamiento, sin claves."
  value = {
    id   = azurerm_storage_account.storage.id
    name = azurerm_storage_account.storage.name
  }
}
