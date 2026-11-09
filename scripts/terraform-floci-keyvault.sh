#!/usr/bin/env bash
# Ejecuta Terraform contra Floci-AZ usando el proxy temporal necesario
# para el plano de datos de Azure Key Vault.
#
# Uso:
#   export TF_VAR_subscription_id="00000000-0000-0000-0000-000000000001"
#   export TF_VAR_tenant_id="00000000-0000-0000-0000-000000000002"
#   export TF_VAR_client_id="00000000-0000-0000-0000-000000000003"
#   export TF_VAR_client_secret="floci-local-secret"
#   ./scripts/terraform-floci-keyvault.sh apply -var-file=terraform.tfvars
#
# No requiere permisos de administrador y no modifica hosts, DNS o netsh.

set -euo pipefail

PROXY_PORT="${FLOCI_KEYVAULT_PROXY_PORT:-18081}"
PROXY_LOG="${FLOCI_KEYVAULT_PROXY_LOG:-/tmp/floci-keyvault-proxy.log}"

required_vars=(
  TF_VAR_subscription_id
  TF_VAR_tenant_id
  TF_VAR_client_id
  TF_VAR_client_secret
)

for variable_name in "${required_vars[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Falta la variable de entorno requerida: ${variable_name}" >&2
    exit 2
  fi
done

if ! command -v python >/dev/null 2>&1; then
  echo "No se encontró Python en PATH." >&2
  exit 2
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "No se encontró Terraform en PATH." >&2
  exit 2
fi

python scripts/floci_keyvault_tls_proxy.py \
  --vault keyvault \
  --port "${PROXY_PORT}" \
  >"${PROXY_LOG}" 2>&1 &

proxy_pid=$!

cleanup() {
  kill "${proxy_pid}" 2>/dev/null || true
  wait "${proxy_pid}" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

sleep 1

if ! kill -0 "${proxy_pid}" 2>/dev/null; then
  echo "No se pudo iniciar el proxy de Key Vault. Log: ${PROXY_LOG}" >&2
  cat "${PROXY_LOG}" >&2 || true
  exit 1
fi

# AzureRM/Go necesita ambas capitalizaciones para su cliente de Key Vault.
export HTTPS_PROXY="http://127.0.0.1:${PROXY_PORT}"
export https_proxy="http://127.0.0.1:${PROXY_PORT}"

# El proxy solo admite Key Vault HTTPS; no debe recibir tráfico HTTP de Storage.
unset HTTP_PROXY http_proxy
export NO_PROXY="localhost,127.0.0.1"
export no_proxy="localhost,127.0.0.1"

terraform "$@"
