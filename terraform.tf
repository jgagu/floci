resource "azurerm_resource_group" "floci" {
  name     = var.resource_group_name
  location = var.location
}

module "network" {
  source = "./modules/network"

  name                = var.virtual_network_name
  address_space       = var.virtual_network_address_space
  location            = azurerm_resource_group.floci.location
  resource_group_name = azurerm_resource_group.floci.name
  subnets             = var.subnets
}

module "secondary_network" {
  source = "./modules/network"

  name                = var.secondary_virtual_network_name
  address_space       = var.secondary_virtual_network_address_space
  location            = azurerm_resource_group.floci.location
  resource_group_name = azurerm_resource_group.floci.name
  subnets             = var.secondary_subnets
}

moved {
  from = azurerm_virtual_network.public_red
  to   = module.network.azurerm_virtual_network.this
}

moved {
  from = azurerm_subnet.private_subnet
  to   = module.network.azurerm_subnet.this["frontend"]
}

resource "azurerm_network_interface" "eth0" {
  name                = "eth0"
  location            = azurerm_resource_group.floci.location
  resource_group_name = azurerm_resource_group.floci.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = module.network.subnets["frontend"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "vm-1" {
  name                = "vmone-1"
  resource_group_name = azurerm_resource_group.floci.name
  location            = azurerm_resource_group.floci.location
  size                = "Standard_D4_v5"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.eth0.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = file("${path.module}/keys/id_ed25519.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "${local.account_tier.standard}_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# Instala Nginx y copia el HTML dentro de la VM container-backed `vmone`.
# Floci-AZ no permite publicar puertos de una VM ya creada; un puente Socat
# local reenvía localhost:8080 al puerto 80 que Nginx escucha dentro de vmone.
resource "terraform_data" "html_status_server" {
  input = {
    ci_linux = var.floci_ci_linux
  }

  triggers_replace = [
    var.floci_ci_linux,
    filesha256("${path.module}/html-prueba.html"),
    filesha256("${path.module}/scripts/deploy-vm-web.ps1"),
    filesha256("${path.module}/scripts/deploy-vm-web-ci.sh"),
    filesha256("${path.module}/scripts/configure-vm-web.sh"),
  ]

  lifecycle {
    replace_triggered_by = [azurerm_linux_virtual_machine.vm]
  }

  provisioner "local-exec" {
    command = var.floci_ci_linux ? "bash '${path.module}/scripts/deploy-vm-web-ci.sh' start" : "powershell -NoProfile -ExecutionPolicy Bypass -Command \"& '${path.module}/scripts/deploy-vm-web.ps1' -HtmlPath '${path.module}/html-prueba.html' -VmName '${azurerm_linux_virtual_machine.vm.name}' -ResourceGroup '${azurerm_resource_group.floci.name}'\""
    environment = {
      FLOCI_VM_NAME        = azurerm_linux_virtual_machine.vm.name
      FLOCI_RESOURCE_GROUP = azurerm_resource_group.floci.name
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = try(self.input.ci_linux, false) ? "bash '${path.module}/scripts/deploy-vm-web-ci.sh' stop" : "powershell -NoProfile -ExecutionPolicy Bypass -Command \"& '${path.module}/scripts/deploy-vm-web.ps1' -HtmlPath '${path.module}/html-prueba.html' -Destroy\""
  }
}


resource "azurerm_key_vault" "kv" {
  name                        = "keyvault"
  location                    = azurerm_resource_group.floci.location
  resource_group_name         = azurerm_resource_group.floci.name
  rbac_authorization_enabled  = false
  enabled_for_disk_encryption = true
  tenant_id                   = var.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = true

  sku_name = "standard"

  access_policy {
    tenant_id = var.tenant_id
    object_id = var.client_id

    key_permissions = [
      "Get",
    ]

    secret_permissions = [
      "Get",
    ]

    storage_permissions = [
      "Get",
    ]
  }

  # Floci-AZ permite crear y consultar el Vault, pero su plano ARM no
  # implementa el PATCH que AzureRM usa para estos atributos tras importarlo.
  lifecycle {
    ignore_changes = [
      access_policy,
      enabled_for_disk_encryption,
      purge_protection_enabled,
      soft_delete_retention_days,
    ]
  }
}

resource "azurerm_storage_account" "storage" {
  name                = var.storage_account_name
  resource_group_name = azurerm_resource_group.floci.name

  location                 = azurerm_resource_group.floci.location
  account_tier             = local.account_tier.standard
  account_replication_type = "LRS"

  network_rules {
    default_action             = "Deny"
    ip_rules                   = ["100.0.0.1"]
    virtual_network_subnet_ids = [module.network.subnets["frontend"].id]
  }

  tags = local.storage_tags
}
