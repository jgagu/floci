[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$HtmlPath,

  [string]$VmName = "vmone",

  [string]$ResourceGroup = "rg-floci-local",

  [string]$PodmanMachine,

  [switch]$Destroy
)

$ErrorActionPreference = "Stop"
$bridgeName = "floci-az-web-bridge"
$tunnelPidFile = Join-Path $env:LOCALAPPDATA "floci-az-web-tunnel.pid"

function Remove-WebTunnel {
  if (-not (Test-Path -LiteralPath $tunnelPidFile)) { return }
  $tunnelId = 0
  $pidText = Get-Content -LiteralPath $tunnelPidFile -Raw
  if ([int]::TryParse($pidText.Trim(), [ref]$tunnelId)) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $tunnelId" -ErrorAction SilentlyContinue
    if ($process -and $process.Name -eq "ssh.exe" -and $process.CommandLine -like "*127.0.0.1:8080:127.0.0.1:8080*") {
      Stop-Process -Id $tunnelId -Force -ErrorAction Stop
    }
  }
  Remove-Item -LiteralPath $tunnelPidFile -Force
}

function Remove-WebBridge {
  Remove-WebTunnel
  & podman rm -f $bridgeName 2>$null | Out-Null
}

function Start-WebTunnel {
  $machines = @(& podman machine list --format json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) {
    throw "No se pudieron consultar las máquinas Podman."
  }
  $runningMachines = @($machines | Where-Object { $_.Running })
  if ($PodmanMachine) {
    $runningMachines = @($runningMachines | Where-Object { $_.Name -eq $PodmanMachine })
  }
  if ($runningMachines.Count -ne 1) {
    throw "Debe haber una máquina Podman activa. Si hay varias, indica -PodmanMachine."
  }
  $sshConfig = $runningMachines[0]

  $tunnel = Start-Process -FilePath "ssh.exe" -ArgumentList @(
    "-N",
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ExitOnForwardFailure=yes",
    "-L", "127.0.0.1:8080:127.0.0.1:8080",
    "-p", $sshConfig.Port,
    "-i", ('"{0}"' -f $sshConfig.IdentityPath),
    "$($sshConfig.RemoteUsername)@127.0.0.1"
  ) -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath $tunnelPidFile -Value $tunnel.Id

  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 500

    if (Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
      return
    }
  }

  Remove-WebTunnel
  throw "No se pudo crear el túnel SSH de localhost:8080 hacia la máquina Podman. Comprueba OpenSSH y la conexión SSH de Podman."
}

if ($Destroy) {
  Remove-WebBridge
  exit 0
}

if (-not (Test-Path -LiteralPath $HtmlPath -PathType Leaf)) {
  throw "No se encontró el archivo HTML: $HtmlPath"
}

$vmContainerIds = @(& podman ps `
  --filter "label=io.floci.service=vm" `
  --filter "label=io.floci.resource-id=$VmName" `
  --filter "label=io.floci.resource-group=$ResourceGroup" `
  --format "{{.ID}}")

if ($LASTEXITCODE -ne 0) {
  throw "No se pudieron consultar los contenedores de Podman."
}

if ($vmContainerIds.Count -ne 1) {
  throw "Se esperaba un contenedor activo para la VM '$VmName' del grupo '$ResourceGroup'; se encontraron $($vmContainerIds.Count)."
}

$vmContainerId = $vmContainerIds[0].Trim()

$inspectionJson = & podman inspect $vmContainerId
if ($LASTEXITCODE -ne 0) {
  throw "No se pudo inspeccionar el contenedor de la VM."
}
$inspection = @($inspectionJson | ConvertFrom-Json)[0]
$subscriptionId = $inspection.Config.Labels.'io.floci.subscription'
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
  throw "No se pudo obtener la suscripción de las etiquetas de la VM."
}

$runtimeVmIp = (& podman inspect $vmContainerId --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}").Trim()

if ([string]::IsNullOrWhiteSpace($runtimeVmIp)) {
  throw "No se pudo obtener la IP de runtime del contenedor de vmone."
}

$setupScriptPath = Join-Path $PSScriptRoot "configure-vm-web.sh"

if (-not (Test-Path -LiteralPath $setupScriptPath -PathType Leaf)) {
  throw "No se encontró el script de configuración: $setupScriptPath"
}

& podman cp $HtmlPath "${vmContainerId}:/tmp/html-prueba.html"
if ($LASTEXITCODE -ne 0) {
  throw "No se pudo copiar el HTML dentro de vmone."
}

& podman cp $setupScriptPath "${vmContainerId}:/tmp/configure-vm-web.sh"
if ($LASTEXITCODE -ne 0) {
  throw "No se pudo copiar el script de configuración dentro de vmone."
}

& podman exec $vmContainerId sh /tmp/configure-vm-web.sh $subscriptionId $ResourceGroup $VmName
if ($LASTEXITCODE -ne 0) {
  throw "No se pudo instalar o iniciar Nginx dentro de vmone."
}

Remove-WebBridge

if (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
  throw "El puerto 8080 ya está ocupado. Libéralo antes de iniciar el puente; no se cerrarán procesos ajenos."
}

& podman run -d --replace --name $bridgeName -p "127.0.0.1:8080:8080" docker.io/alpine/socat `
  "TCP-LISTEN:8080,fork,reuseaddr" "TCP:${runtimeVmIp}:80"

if ($LASTEXITCODE -ne 0) {
  throw "No se pudo crear el puente localhost:8080 hacia vmone."
}

$directAccess = $false
try {
  $directResponse = Invoke-WebRequest -Uri "http://127.0.0.1:8080/html-prueba.html" -UseBasicParsing -TimeoutSec 3
  $directAccess = $directResponse.StatusCode -eq 200
} catch {
  $directAccess = $false
}
if (-not $directAccess) {
  Start-WebTunnel
}

for ($attempt = 0; $attempt -lt 20; $attempt++) {
  try {
    $htmlResponse = Invoke-WebRequest -Uri "http://127.0.0.1:8080/html-prueba.html" -UseBasicParsing -TimeoutSec 3
    $statusResponse = Invoke-WebRequest -Uri "http://127.0.0.1:8080/status.json" -UseBasicParsing -TimeoutSec 3
    $status = $statusResponse.Content | ConvertFrom-Json
    if ($htmlResponse.StatusCode -eq 200 -and $status.vmName -eq $VmName -and $status.resourceGroup -eq $ResourceGroup) {
      Write-Host "HTML desplegado dentro de ${VmName}: /var/www/html/html-prueba.html"
      Write-Host "URL local: http://localhost:8080/html-prueba.html"
      exit 0
    }
  } catch {
    # Se vuelve a intentar mientras arranca el puente.
  }
  Start-Sleep -Milliseconds 500
}

throw "El puente se ha creado, pero la página o el estado de la VM no responden correctamente en localhost:8080."
