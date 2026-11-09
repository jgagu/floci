output "virtual_network" {
  description = "Identificador, nombre y rangos de la red virtual."
  value = {
    id            = azurerm_virtual_network.this.id
    name          = azurerm_virtual_network.this.name
    address_space = azurerm_virtual_network.this.address_space
  }
}

output "subnets" {
  description = "Subredes indexadas por las claves de entrada."
  value = {
    for key, subnet in azurerm_subnet.this : key => {
      id               = subnet.id
      name             = subnet.name
      address_prefixes = subnet.address_prefixes
    }
  }
}
