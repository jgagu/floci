environment        = "dev"
vnet_address_space = ["10.10.0.0/16"]

subnets = {
  frontend = ["10.10.1.0/24"]
  backend  = ["10.10.2.0/24"]
}
