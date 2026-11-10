environment        = "test"
vnet_address_space = ["10.20.0.0/16"]

subnets = {
  frontend = ["10.20.1.0/24"]
  backend  = ["10.20.2.0/24"]
}
