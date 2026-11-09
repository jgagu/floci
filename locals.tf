locals {
  # Etiquetas compartidas del laboratorio. Se conserva el valor ya desplegado.
  storage_tags = {
    environment = "floci-az"
  }
  account_tier = {
    standard = "Standard",
    default = "Standard"
  }
}
