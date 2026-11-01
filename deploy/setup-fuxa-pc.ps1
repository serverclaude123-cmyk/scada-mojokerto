<#
  Pasang FUXA + muat proyek SCADA Mojokerto ke PC baru.

  Dirancang untuk PC di site yang mungkin tidak punya hak admin:
  Node dipasang sebagai zip portable, FUXA lewat npm, dan proyeknya
  dimuat lewat REST API FUXA -- tidak perlu klik import di UI.

  Contoh:
    .\setup-fuxa-pc.ps1 -BrokerHost 192.168.1.10 -MqttUser fuxa
    .\setup-fuxa-pc.ps1 -BrokerHost 192.168.1.10 -MqttUser fuxa -PlcAddress 192.168.1.113:502
#>
param(
  [Parameter(Mandatory = $true)][string]$BrokerHost,
  [int]$BrokerPort = 1883,
  [Parameter(Mandatory = $true)][string]$MqttUser,
  [string]$PlcAddress = "192.168.1.113:502",
  [string]$Root = "C:\Tools",
  [string]$NodeVersion = "v22.23.4"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$proj = Join-Path $PSScriptRoot "..\fuxa\scada-mojokerto.fuxap" | Resolve-Path

function Step($n, $m) { Write-Host "`n[$n] $m" -ForegroundColor Cyan }

# --- Node portable (tanpa admin) ---
$nodeDir = Join-Path $Root "node-$NodeVersion-win-x64"
if (Test-Path (Join-Path $nodeDir "node.exe")) {
  Step 1 "Node sudah ada: $nodeDir"
} else {
  Step 1 "Unduh Node $NodeVersion (zip portable, tanpa admin)..."
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $zip = Join-Path $env:TEMP "node-$NodeVersion.zip"
  Invoke-WebRequest "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-x64.zip" -OutFile $zip -UseBasicParsing
  Expand-Archive $zip -DestinationPath $Root -Force
  Remove-Item $zip -Force
}
$env:Path = "$nodeDir;$Root\npm-global;$env:Path"

# --- FUXA ---
$fuxaMain = Join-Path $Root "npm-global\node_modules\@frangoteam\fuxa\main.js"
if (Test-Path $fuxaMain) {
  Step 2 "FUXA sudah terpasang"
} else {
  Step 2 "Pasang FUXA lewat npm (beberapa menit)..."
  New-Item -ItemType Directory -Force -Path "$Root\npm-global" | Out-Null
  & "$nodeDir\npm.cmd" config set prefix "$Root\npm-global"
  & "$nodeDir\npm.cmd" install -g @frangoteam/fuxa
}

# --- jalankan FUXA ---
Step 3 "Jalankan FUXA dan tunggu port 1881..."
if (-not (Get-NetTCPConnection -State Listen -LocalPort 1881 -ErrorAction SilentlyContinue)) {
  Start-Process -FilePath "$nodeDir\node.exe" -ArgumentList $fuxaMain -WindowStyle Minimized
}
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
  if (Get-NetTCPConnection -State Listen -LocalPort 1881 -ErrorAction SilentlyContinue) { break }
  Start-Sleep -Seconds 2
}
if (-not (Get-NetTCPConnection -State Listen -LocalPort 1881 -ErrorAction SilentlyContinue)) {
  throw "FUXA tidak pernah mendengar di port 1881"
}

# --- kredensial broker (diketik di sini, tidak disimpan di Git) ---
Step 4 "Kredensial broker"
$sec = Read-Host "Password MQTT untuk user '$MqttUser'" -AsSecureString
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))

# --- muat proyek lewat REST API ---
Step 5 "Muat proyek ke FUXA lewat REST API..."
$p = Get-Content $proj -Raw | ConvertFrom-Json
foreach ($d in $p.devices.PSObject.Properties.Value) {
  if ($d.type -eq "MQTTclient") {
    $d.property.address  = "mqtt://${BrokerHost}:$BrokerPort"
    $d.property.username = $MqttUser
    $d.property.password = $pw
    Write-Host "    MQTT  -> mqtt://${BrokerHost}:$BrokerPort sebagai $MqttUser"
  } elseif ($d.type -eq "ModbusTCP") {
    $d.property.address = $PlcAddress
    Write-Host "    Modbus-> $PlcAddress"
  }
}
$body = [Text.Encoding]::UTF8.GetBytes(($p | ConvertTo-Json -Depth 64 -Compress))
Invoke-WebRequest "http://127.0.0.1:1881/api/project" -Method Post -Body $body `
  -ContentType "application/json" -UseBasicParsing | Out-Null

Write-Host "`nSELESAI. Buka http://localhost:1881" -ForegroundColor Green
Write-Host "Plugin Modbus belum tentu ada: Settings -> Plugins -> modbus-serial." -ForegroundColor Yellow
