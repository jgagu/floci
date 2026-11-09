environment = "floci-az"

location             = "westeurope"
resource_group_name  = "rg-floci-local"
storage_account_name = "storageaccountname"

virtual_network_name          = "floci-vnet"
virtual_network_address_space = ["10.0.0.0/16"]

subnets = {
  frontend = {
    name             = "private-subnet"
    address_prefixes = ["10.0.1.0/24"]
    delegate_to_aci  = true
  }
  backend = {
    name             = "backend"
    address_prefixes = ["10.0.2.0/24"]
    delegate_to_aci  = false
  }
}
