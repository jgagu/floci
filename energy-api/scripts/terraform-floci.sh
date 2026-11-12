#!/usr/bin/env bash
# Ejecuta Terraform de energy-api con el proxy Key Vault de Floci.
set -euo pipefail

if [[ $# -lt 2 ]] || [[ "$1" != "dev" && "$1" != "test" ]]; then
  echo "Uso: bash energy-api/scripts/terraform-floci.sh <dev|test> <comando terraform> [argumentos...]" >&2
  exit 2
fi

environment="$1"
shift
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cert="${FLOCI_KEYVAULT_TLS_CERT:?Define FLOCI_KEYVAULT_TLS_CERT con el certificado de servidor de Floci}"
key="${FLOCI_KEYVAULT_TLS_KEY:?Define FLOCI_KEYVAULT_TLS_KEY con la clave de servidor de Floci}"
: "${SSL_CERT_FILE:?Define SSL_CERT_FILE con un bundle que incluya la CA de Floci}"
port="${FLOCI_KEYVAULT_PROXY_PORT:-18081}"
log_file="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/energy-api-keyvault-proxy-${environment}.log"

python3 "$root_dir/scripts/floci_keyvault_tls_proxy.py" \
  --vault "energy-${environment}-kv" \
  --port "$port" \
  --cert "$cert" \
  --key "$key" >"$log_file" 2>&1 &
proxy_pid=$!

cleanup() {
  kill "$proxy_pid" 2>/dev/null || true
  wait "$proxy_pid" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1
if ! kill -0 "$proxy_pid" 2>/dev/null; then
  echo "No se pudo iniciar el proxy de Key Vault:" >&2
  cat "$log_file" >&2
  exit 1
fi

export HTTPS_PROXY="http://127.0.0.1:${port}"
export https_proxy="$HTTPS_PROXY"
unset HTTP_PROXY http_proxy
export NO_PROXY="localhost,127.0.0.1"
export no_proxy="$NO_PROXY"

terraform -chdir="$root_dir/energy-api" "$@"
