#!/usr/bin/env bash
# Despliegue efímero de la web en la VM de Floci-AZ para un runner Linux.
set -euo pipefail

floci_container="${FLOCI_CONTAINER:?Falta FLOCI_CONTAINER}"
bridge_name="${floci_container}-web"
action="${1:-start}"

if [[ "$action" == "stop" ]]; then
  if docker container inspect "$bridge_name" >/dev/null 2>&1; then
    docker rm -f "$bridge_name" >/dev/null
  fi
  exit 0
fi

if [[ "$action" != "start" ]]; then
  echo "Uso: $0 start|stop" >&2
  exit 2
fi

vm_name="${FLOCI_VM_NAME:?Falta FLOCI_VM_NAME}"
resource_group="${FLOCI_RESOURCE_GROUP:?Falta FLOCI_RESOURCE_GROUP}"
subscription="${TF_VAR_subscription_id:?Falta TF_VAR_subscription_id}"

mapfile -t vm_ids < <(docker ps \
  --filter "label=io.floci.service=vm" \
  --filter "label=io.floci.resource-id=$vm_name" \
  --filter "label=io.floci.resource-group=$resource_group" \
  --filter "label=io.floci.subscription=$subscription" \
  --format '{{.ID}}')

if [[ "${#vm_ids[@]}" -ne 1 ]]; then
  echo "Se esperaba una VM respaldada por contenedor; encontradas: ${#vm_ids[@]}." >&2
  exit 1
fi

vm_id="${vm_ids[0]}"
vm_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$vm_id")"
floci_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$floci_container")"

if [[ -z "$vm_ip" || -z "$floci_ip" ]]; then
  echo "No se pudieron obtener las direcciones de red de los contenedores." >&2
  exit 1
fi

docker cp html-prueba.html "${vm_id}:/tmp/html-prueba.html"
docker cp scripts/configure-vm-web.sh "${vm_id}:/tmp/configure-vm-web.sh"
docker exec -e "ARM_ENDPOINT=https://${floci_ip}:4577" \
  "$vm_id" sh /tmp/configure-vm-web.sh "$subscription" "$resource_group" "$vm_name"

if docker container inspect "$bridge_name" >/dev/null 2>&1; then
  echo "Ya existe el puente $bridge_name; no se sobrescribirá." >&2
  exit 1
fi

docker run -d --name "$bridge_name" -p 127.0.0.1:8080:8080 \
  docker.io/alpine/socat \
  "TCP-LISTEN:8080,fork,reuseaddr" "TCP:${vm_ip}:80" >/dev/null
