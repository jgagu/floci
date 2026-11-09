#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive

ARM_ENDPOINT="https://host.containers.internal:4577"
ARM_API_VERSION="2023-09-01"
subscription_id="${1:?Falta la suscripción}"
resource_group="${2:?Falta el grupo de recursos}"
vm_name="${3:?Falta el nombre de la VM}"

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v nginx >/dev/null 2>&1; then
  apt-get update
  apt-get install -y curl jq nginx
fi
install -D -m 0644 /tmp/html-prueba.html /var/www/html/html-prueba.html

vm_json="$(curl -fkSs "${ARM_ENDPOINT}/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Compute/virtualMachines/${vm_name}?api-version=${ARM_API_VERSION}")"
vm_id="$(printf '%s' "$vm_json" | jq -r '.id')"

if [ -z "$vm_id" ] || [ "$vm_id" = "null" ]; then
  echo "No se encontró ninguna VM Azure en la API ARM de Floci-AZ." >&2
  exit 1
fi

nic_id="$(printf '%s' "$vm_json" | jq -r '.properties.networkProfile.networkInterfaces[0].id')"
nic_json="$(curl -ksS "${ARM_ENDPOINT}${nic_id}?api-version=${ARM_API_VERSION}")"
subnet_id="$(printf '%s' "$nic_json" | jq -r '.properties.ipConfigurations[0].properties.subnet.id')"
vnet_id="${subnet_id%/subnets/*}"

subnet_json="$(curl -ksS "${ARM_ENDPOINT}${subnet_id}?api-version=${ARM_API_VERSION}")"
vnet_json="$(curl -ksS "${ARM_ENDPOINT}${vnet_id}?api-version=${ARM_API_VERSION}")"

vm_name="$(printf '%s' "$vm_json" | jq -r '.name')"
resource_group="$(printf '%s' "$vm_id" | jq -Rr 'split("/")[4]')"
location="$(printf '%s' "$vm_json" | jq -r '.location')"
vm_size="$(printf '%s' "$vm_json" | jq -r '.properties.hardwareProfile.vmSize')"
provisioning_state="$(printf '%s' "$vm_json" | jq -r '.properties.provisioningState')"
os_image="$(printf '%s' "$vm_json" | jq -r '.properties.storageProfile.imageReference | "\(.publisher)/\(.offer):\(.sku)"')"
network_interface="$(printf '%s' "$nic_json" | jq -r '.name')"
azure_private_ip="$(printf '%s' "$nic_json" | jq -r '.properties.ipConfigurations[0].properties.privateIPAddress')"
virtual_network="$(printf '%s' "$vnet_json" | jq -r '.name')"
virtual_network_address_space="$(printf '%s' "$vnet_json" | jq -r '.properties.addressSpace.addressPrefixes | join(", ")')"
subnet="$(printf '%s' "$subnet_json" | jq -r '.name')"
subnet_address_prefix="$(printf '%s' "$subnet_json" | jq -r '.properties.addressPrefix // (.properties.addressPrefixes | join(", "))')"

jq -n \
  --arg vmName "$vm_name" \
  --arg provisioningState "$provisioning_state" \
  --arg resourceGroup "$resource_group" \
  --arg location "$location" \
  --arg virtualNetwork "$virtual_network" \
  --arg virtualNetworkAddressSpace "$virtual_network_address_space" \
  --arg subnet "$subnet" \
  --arg subnetAddressPrefix "$subnet_address_prefix" \
  --arg networkInterface "$network_interface" \
  --arg azurePrivateIp "$azure_private_ip" \
  --arg vmSize "$vm_size" \
  --arg osImage "$os_image" \
  '{
    vmName: $vmName,
    provisioningState: $provisioningState,
    resourceGroup: $resourceGroup,
    location: $location,
    virtualNetwork: $virtualNetwork,
    virtualNetworkAddressSpace: $virtualNetworkAddressSpace,
    subnet: $subnet,
    subnetAddressPrefix: $subnetAddressPrefix,
    networkInterface: $networkInterface,
    azurePrivateIp: $azurePrivateIp,
    vmSize: $vmSize,
    osImage: $osImage
  }' > /var/www/html/status.json

nginx -t

if ! pgrep -x nginx >/dev/null 2>&1; then
  nginx
fi
