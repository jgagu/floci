# energy-api

Proyecto Terraform para simular en Floci-AZ la infraestructura de una aplicación ficticia. No despliega la aplicación ni está preparado para conectarse a Azure real.

## Arquitectura

```text
Resource Group (energy-dev-rg o energy-test-rg)
├── VNet
│   ├── subnet frontend
│   └── subnet backend
│       └── NIC → VM Linux
├── Storage Account
└── Key Vault
```

El módulo local `modules/network` crea la VNet y las subredes. Los archivos `environments/dev.tfvars` y `environments/test.tfvars` seleccionan el entorno y rangos de red diferentes sin duplicar los recursos. Los nombres incluyen el entorno. La VM no instala ninguna aplicación.

El proveedor usa exclusivamente el endpoint local de Floci. Los identificadores y el secreto predeterminados son ficticios y solo sirven para el emulador. No se deben usar como credenciales reales.

## Requisitos

- Docker con el daemon iniciado y acceso al registro de imágenes.
- Terraform 1.5 o superior y menor que 2.0; CI utiliza 1.10.5.
- Bash, Python 3, `curl`, `ssh-keygen` y certificados de sistema. En Windows, usa Linux o WSL con Docker accesible.
- Acceso al registro de proveedores de Terraform.
- Puerto local 4577 libre. El proxy de Key Vault usa el puerto 18081.
- Ejecuta los comandos siguientes desde la **raíz del repositorio**, no desde `energy-api`.

La imagen de Floci se fija por digest y la versión de AzureRM en `main.tf`. El proveedor usa el estado local de Terraform: guarda los archivos de estado mientras necesites gestionar los recursos, pues contienen información sensible. No los subas a Git.

## Levantar un entorno

En una terminal Bash, selecciona `dev` o `test` y arranca un Floci limpio:

```bash
export ENERGY_ENV=dev
export FLOCI_CONTAINER="energy-api-${ENERGY_ENV}"
export ENERGY_TMP="$(mktemp -d)"
chmod 700 "$ENERGY_TMP"

docker run -d --name "$FLOCI_CONTAINER" \
  -p 127.0.0.1:4577:4577 \
  -e FLOCI_AZ_TLS_ENABLED=true \
  -e FLOCI_AZ_SERVICES_FUNCTIONS_ENABLED=false \
  -e FLOCI_AZ_SERVICES_VM_MOCKED=false \
  -v /var/run/docker.sock:/var/run/docker.sock \
  docker.io/floci/floci-az@sha256:0930cc3fe09014c40f266e261b93b0bd0ec99daa83b08d3b1ec0203caeb8e390

for attempt in $(seq 1 60); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:4577/_floci/health >/dev/null; then
    break
  fi
  sleep 2
done
curl --fail --silent --show-error http://127.0.0.1:4577/_floci/health
```

En la misma terminal, prepara la confianza TLS y una clave SSH efímera. Mantén estos archivos hasta terminar de destruir el entorno:

```bash
docker cp "$FLOCI_CONTAINER:/app/data/tls/floci-az-selfsigned-ca.crt" "$ENERGY_TMP/ca.crt"
docker cp "$FLOCI_CONTAINER:/app/data/tls/floci-az-selfsigned.crt" "$ENERGY_TMP/server.crt"
docker cp "$FLOCI_CONTAINER:/app/data/tls/floci-az-selfsigned.key" "$ENERGY_TMP/server.key"
cat /etc/ssl/certs/ca-certificates.crt "$ENERGY_TMP/ca.crt" > "$ENERGY_TMP/ca-bundle.crt"
export SSL_CERT_FILE="$ENERGY_TMP/ca-bundle.crt"
export FLOCI_KEYVAULT_TLS_CERT="$ENERGY_TMP/server.crt"
export FLOCI_KEYVAULT_TLS_KEY="$ENERGY_TMP/server.key"

ssh-keygen -q -t ed25519 -N "" -f "$ENERGY_TMP/id_ed25519"
export TF_VAR_ssh_public_key="$(cat "$ENERGY_TMP/id_ed25519.pub")"
```

Inicializa Terraform, selecciona un workspace local por entorno y revisa el plan antes de aplicarlo:

```bash
terraform -chdir=energy-api fmt -check -recursive
terraform -chdir=energy-api init
terraform -chdir=energy-api workspace select -or-create "$ENERGY_ENV"
terraform -chdir=energy-api validate
bash energy-api/scripts/terraform-floci.sh "$ENERGY_ENV" plan -var-file="environments/${ENERGY_ENV}.tfvars"
bash energy-api/scripts/terraform-floci.sh "$ENERGY_ENV" apply -var-file="environments/${ENERGY_ENV}.tfvars"
```

Confirma el `apply` cuando Terraform lo solicite. Para usar `test`, repite el procedimiento con `ENERGY_ENV=test` y un Floci separado. El ejemplo publica el mismo puerto, por lo que los dos contenedores no pueden ejecutarse simultáneamente en ese puerto. Los workspaces separan los estados, pero **no** crean ni aíslan instancias de Floci por sí mismos.

El wrapper inicia un proxy TLS temporal para el plano de datos de Key Vault y reutiliza `scripts/floci_keyvault_tls_proxy.py` del repositorio. Es específico de Floci, no de Azure real.

## Destruir

En la misma terminal, con el contenedor y las variables TLS aún activos, selecciona el mismo entorno y destruye antes de eliminar Floci:

```bash
terraform -chdir=energy-api workspace select "$ENERGY_ENV"
bash energy-api/scripts/terraform-floci.sh "$ENERGY_ENV" destroy -var-file="environments/${ENERGY_ENV}.tfvars"
docker rm -fv "$FLOCI_CONTAINER"
rm -rf "$ENERGY_TMP"
```

Confirma el `destroy` cuando se solicite. Comprueba su resultado antes de borrar el contenedor: las VM de Floci pueden ser contenedores Docker independientes. Si la operación falla, revisa `docker ps -a` y los logs antes de limpiar los recursos restantes. Eliminar solo Floci no equivale a un `terraform destroy`.

## Pipeline de pull request

`.github/workflows/energy-api.yml` ejecuta una matriz para `dev` y `test`. Cada job hace checkout, prepara Terraform, inicia un Floci aislado, espera a `/_floci/health`, prepara TLS y SSH y ejecuta:

```text
terraform fmt -check → terraform init → terraform validate → terraform plan
```

Al finalizar, incluso tras un fallo, intenta eliminar el contenedor Floci. No ejecuta `apply` ni necesita secretos reales de Azure. Cada job de `ubuntu-latest` tiene su propia máquina; por eso Floci y Terraform comparten un mismo job. Un contenedor iniciado en otro job alojado no estaría disponible en `localhost`.

### Cómo añadir apply tras merge a main

Añade un trigger `push` a `main` y un paso `apply` condicionado a `github.event_name == 'push' && github.ref == 'refs/heads/main'`, nunca a `pull_request`. Genera un plan nuevo después del merge con `-out=...` y aplica ese archivo en el **mismo job** donde está Floci. Añade pruebas posteriores y limpieza incluso si fallan.

Para una infraestructura persistente real, no uses el Floci efímero de CI como destino: configura un backend remoto con bloqueo, permisos mínimos, autenticación segura (por ejemplo OIDC), entornos protegidos y aprobación antes de aplicar. Cada entorno debe tener su propio estado. Un plan creado en una PR no debe aplicarse ciegamente tras el merge porque el código o el estado pueden haber cambiado.

## Defensa técnica

- **`terraform init`** prepara el directorio, instala proveedores y módulos y configura el backend. El **state** relaciona recursos declarados con objetos creados y ayuda a calcular cambios; puede contener datos sensibles.
- **VNet frente a subnet**: la VNet es la red virtual completa; una subnet es una subdivisión de su rango de direcciones. Aquí la VM se conecta a `backend`.
- **Pull request**: permite revisar código y resultados automáticos antes de incorporar cambios a la rama principal. El plan informa de los cambios previstos sin aplicarlos.
- **Job frente a step**: un job es una unidad de ejecución con su runner; los steps son operaciones secuenciales dentro de ese job y comparten su entorno. Los jobs alojados no comparten automáticamente máquina, archivos ni contenedores.
- **Floci frente a Azure**: Floci emula APIs y recursos de Azure localmente; no reproduce todas las operaciones, tiempos, seguridad o comportamientos de Azure. Un plan o apply exitoso en Floci no garantiza que funcione en Azure real.

## Diagnóstico

- **GitHub Actions**: revisa el step fallido, el checkout, permisos, disponibilidad de Docker y los logs del runner.
- **Terraform**: `fmt` señala formato; `init`, dependencias/backend; `validate`, configuración y esquema; `plan`, evaluación y comunicación con el proveedor.
- **Provider AzureRM**: comprueba la versión, el mensaje de error, los parámetros y el endpoint de metadatos.
- **Floci**: revisa `/_floci/health`, `docker logs "$FLOCI_CONTAINER"`, certificados y soporte de la API o recurso. Si falla Key Vault, revisa también el log del proxy en el directorio temporal.

La reproducibilidad de extremo a extremo debe comprobarse ejecutando la pipeline y un ciclo local completo de `plan`, `apply` y `destroy`; la configuración por sí sola no demuestra que todos los recursos estén soportados por la versión de Floci utilizada.
