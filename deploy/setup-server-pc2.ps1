<#
  setup-server-pc2.ps1 -- jadikan PC#2 (DESKTOP-3HEVBT2, ruang pompa) SERVER SCADA.
  PowerShell sebagai Administrator, di PC#2, SETELAH PC#1 berhenti jadi server
  (deploy\pc1-jadi-viewer.cmd) -- kalau tidak, dua broker/dua FUXA saling berebut.

  Langkah:
    0. cek: PC#1 sudah lepas dari 192.168.1.10 dan tidak ada broker lain di LAN
    1. (opsional -StaticIp) pasang IP statis 192.168.1.10 di adapter Ethernet
       -> ESP32 TIDAK perlu di-flash ulang, MQTT_HOST di secrets.h tetap .10
    2. Mosquitto: cek terpasang, salin mosquitto.conf + passwd, restart service
    3. Node portable + FUXA (versi sama dengan PC#1, dari manifest backup)
    4. pulihkan data FUXA dari zip backup ke C:\ProgramData\fuxa
    5. daftarkan task FUXA (SYSTEM, At startup + watchdog) lewat register-fuxa-task.ps1
    6. firewall 1883 + 1881 untuk LAN privat dan Tailscale (100.64.0.0/10)
    7. ringkasan + cek Tailscale

  Contoh:
    powershell -ExecutionPolicy Bypass -File .\setup-server-pc2.ps1 `
       -Backup C:\Users\Admin\Desktop\scada-server-backup-20261123-0900.zip -StaticIp
#>
param(
  [Parameter(Mandatory = $true)][string]$Backup,
  [switch]$StaticIp,
  [string]$ServerIp   = '192.168.1.10',
  [int]$PrefixLength  = 24,
  [string]$Gateway    = '192.168.1.1',
  [string]$Dns        = '192.168.1.1',
  [string]$Adapter    = 'Ethernet',
  [string]$Root       = 'C:\Tools',
  [string]$FuxaData   = 'C:\ProgramData\fuxa',
  [string]$MqInstall  = 'C:\Program Files\mosquitto',
  [string]$MqData     = 'C:\ProgramData\mosquitto',
  [string]$NodeVersion = '',
  [string]$FuxaVersion = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Step($n, $m) { Write-Host "`n[$n] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "    [!] $m" -ForegroundColor Yellow }

$role = [Security.Principal.WindowsBuiltInRole]::Administrator
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole($role)) { throw 'Bukan Administrator. Buka PowerShell dengan "Run as administrator".' }
if (-not (Test-Path $Backup)) { throw "Zip backup tidak ada: $Backup" }
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# --- buka backup ----------------------------------------------------------------------
$tmp = Join-Path $env:TEMP ('scada-restore-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Expand-Archive $Backup -DestinationPath $tmp -Force
$man = Get-Content (Join-Path $tmp 'manifest.json') -Raw | ConvertFrom-Json
if (-not $NodeVersion) { $NodeVersion = if ($man.node) { $man.node } else { 'v22.23.4' } }
if (-not $FuxaVersion) { $FuxaVersion = $man.fuxa }
Write-Host "Backup dari $($man.dari) ($($man.dibuat)); FUXA $FuxaVersion, Node $NodeVersion"

function TcpOpen($h, $p) {
  $c = New-Object Net.Sockets.TcpClient
  try { return $c.ConnectAsync($h, $p).Wait(1500) } catch { return $false } finally { $c.Close() }
}

# --- 0. pastikan PC#1 sudah lepas ------------------------------------------------------
Step 0 'Cek PC#1 sudah bukan server...'
$myIps = @(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object IPAddress)
if ($myIps -notcontains $ServerIp) {
  if (Test-Connection $ServerIp -Count 2 -Quiet) {
    throw "$ServerIp masih dipakai perangkat lain (PC#1?). Jalankan dulu deploy\pc1-jadi-viewer.cmd di PC#1 dan ubah IP-nya ke DHCP."
  }
  Write-Host "    $ServerIp kosong"
} else { Write-Host "    $ServerIp sudah milik PC ini" }

# --- 1. IP statis ------------------------------------------------------------------------
if ($StaticIp -and ($myIps -notcontains $ServerIp)) {
  Step 1 "Pasang IP statis $ServerIp/$PrefixLength di '$Adapter'..."
  Set-NetIPInterface -InterfaceAlias $Adapter -Dhcp Disabled
  Get-NetIPAddress -InterfaceAlias $Adapter -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false
  Get-NetRoute -InterfaceAlias $Adapter -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
  New-NetIPAddress -InterfaceAlias $Adapter -IPAddress $ServerIp -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
  Set-DnsClientServerAddress -InterfaceAlias $Adapter -ServerAddresses $Dns
  # adapter butuh beberapa detik setelah ganti IP; ping gagal di sini bukan alasan berhenti
  $gwOk = $false
  for ($i = 0; $i -lt 15 -and -not $gwOk; $i++) {
    Start-Sleep -Seconds 2
    try { $gwOk = Test-Connection $Gateway -Count 1 -Quiet -ErrorAction Stop } catch { $gwOk = $false }
  }
  Write-Host "    selesai. Cek: ping $Gateway -> $gwOk"
} else {
  Step 1 'IP statis dilewati'
  if ($myIps -notcontains $ServerIp) {
    Warn "PC ini BUKAN $ServerIp. ESP32 (secrets.h MQTT_HOST) harus di-flash ulang ke IP PC ini,"
    Warn 'atau buat DHCP reservation di router. Lebih mudah: jalankan ulang dengan -StaticIp.'
  }
}
if ((Get-NetConnectionProfile -InterfaceAlias $Adapter -ErrorAction SilentlyContinue).NetworkCategory -ne 'Private') {
  Set-NetConnectionProfile -InterfaceAlias $Adapter -NetworkCategory Private
  Write-Host "    profil jaringan '$Adapter' diset Private"
}

# --- 2. Mosquitto --------------------------------------------------------------------------
Step 2 'Mosquitto (broker MQTT)...'
if (-not (Test-Path (Join-Path $MqInstall 'mosquitto.exe'))) {
  throw "Mosquitto belum terpasang di $MqInstall. Unduh installer Windows 64-bit dari https://mosquitto.org/download/ , pasang (centang Service), lalu jalankan skrip ini lagi."
}
New-Item -ItemType Directory -Force -Path $MqData | Out-Null
$pw = Join-Path $tmp 'kredensial\passwd'
if (-not (Test-Path $pw)) { throw 'passwd Mosquitto tidak ada di backup.' }
Copy-Item $pw (Join-Path $MqData 'passwd') -Force
Copy-Item (Join-Path $repo 'broker\mosquitto.conf') (Join-Path $MqInstall 'mosquitto.conf') -Force
Get-Process mosquitto -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 } | Stop-Process -Force
Set-Service mosquitto -StartupType Automatic
Restart-Service mosquitto
Start-Sleep -Seconds 2
$l = Get-NetTCPConnection -State Listen -LocalPort 1883 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalAddress -Unique
Write-Host "    service: $((Get-Service mosquitto).Status), listen: $($l -join ', ')"
if ($l -notcontains '0.0.0.0') { Warn 'Tidak listen di 0.0.0.0:1883 -- ESP32 tidak akan bisa masuk. Cek mosquitto.conf.' }

# --- 3. Node + FUXA --------------------------------------------------------------------------
Step 3 "Node $NodeVersion + FUXA $FuxaVersion di $Root..."
$nodeDir = Join-Path $Root "node-$NodeVersion-win-x64"
if (-not (Test-Path (Join-Path $nodeDir 'node.exe'))) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  $zip = Join-Path $env:TEMP "node-$NodeVersion.zip"
  Invoke-WebRequest "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-x64.zip" -OutFile $zip -UseBasicParsing
  Expand-Archive $zip -DestinationPath $Root -Force
  Remove-Item $zip -Force
}
$npmGlobal = Join-Path $Root 'npm-global'
$fuxaMain = Join-Path $npmGlobal 'node_modules\@frangoteam\fuxa\main.js'
if (-not (Test-Path $fuxaMain)) {
  New-Item -ItemType Directory -Force -Path $npmGlobal | Out-Null
  $env:Path = "$nodeDir;$npmGlobal;$env:Path"
  & "$nodeDir\npm.cmd" config set prefix $npmGlobal
  $pkg = if ($FuxaVersion) { "@frangoteam/fuxa@$FuxaVersion" } else { '@frangoteam/fuxa' }
  & "$nodeDir\npm.cmd" install -g $pkg
  if (-not (Test-Path $fuxaMain)) { throw 'npm install FUXA gagal.' }
}
Write-Host "    $fuxaMain"

# --- 4. data FUXA ------------------------------------------------------------------------------
Step 4 "Pulihkan data FUXA ke $FuxaData..."
Get-ScheduledTask -TaskName FUXA -ErrorAction SilentlyContinue | Stop-ScheduledTask
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'fuxa' -and $_.CommandLine -match 'main\.js' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
if (Test-Path (Join-Path $FuxaData '_appdata')) {
  $old = "$FuxaData.lama-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Move-Item $FuxaData $old
  Warn "data FUXA lama di PC ini dipindah ke $old"
}
New-Item -ItemType Directory -Force -Path $FuxaData | Out-Null
Copy-Item (Join-Path $tmp 'fuxa\*') $FuxaData -Recurse -Force
if (-not (Test-Path (Join-Path $FuxaData '_appdata\project.fuxap.db'))) { throw 'project.fuxap.db tidak ada setelah restore.' }
Write-Host '    proyek, user login, trend, plugin dipulihkan'
# pembungkus viewer (spanduk OFFLINE) disajikan FUXA di /_widgets/scada-viewer.html
New-Item -ItemType Directory -Force -Path (Join-Path $FuxaData '_widgets') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'pc1-viewer\scada-viewer.html') (Join-Path $FuxaData '_widgets\scada-viewer.html') -Force
Write-Host '    pembungkus viewer -> /_widgets/scada-viewer.html'

# --- 5. task FUXA --------------------------------------------------------------------------
Step 5 'Daftarkan task FUXA (SYSTEM, At startup + watchdog)...'
& (Join-Path $PSScriptRoot 'register-fuxa-task.ps1') -Node (Join-Path $nodeDir 'node.exe') -Main $fuxaMain -Data $FuxaData

# --- 6. firewall ---------------------------------------------------------------------------
Step 6 'Firewall 1883 (MQTT) dan 1881 (FUXA web)...'
foreach ($r in @(
  @{ n = 'Mosquitto 1883';           p = 1883; prof = 'Private'; ip = 'Any' },
  @{ n = 'Mosquitto 1883 Tailscale'; p = 1883; prof = 'Any';     ip = '100.64.0.0/10' },
  @{ n = 'FUXA 1881';                p = 1881; prof = 'Private'; ip = 'Any' },
  @{ n = 'FUXA 1881 Tailscale';      p = 1881; prof = 'Any';     ip = '100.64.0.0/10' })) {
  Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $r.p -Profile $r.prof -RemoteAddress $r.ip | Out-Null
  Write-Host "    $($r.n)"
}

# --- 7. ringkasan -----------------------------------------------------------------------------
Step 7 'Ringkasan'
$ts = 'C:\Program Files\Tailscale\tailscale.exe'
$tsIp = if (Test-Path $ts) { (& $ts ip -4 2>$null) } else { $null }
if ($tsIp) { Write-Host "    Tailscale PC#2   : $tsIp" }
else { Warn 'Tailscale belum terpasang/login. Pasang dari https://tailscale.com/download/windows, login ke tailnet yang SAMA dengan PC#1.' }
Write-Host "    FUXA lokal       : http://localhost:1881"
Write-Host "    FUXA dari PC#1   : http://$(if ($tsIp) { $tsIp } else { '<ip-tailscale-pc2>' }):1881"
Write-Host "    MQTT             : ${ServerIp}:1883 (LAN), $(if ($tsIp) { $tsIp } else { '<ip-tailscale-pc2>' }):1883 (Tailscale)"
Write-Host "    Kredensial       : $tmp\kredensial  (pindahkan ke broker\ dan firmware\include\ di repo PC ini, lalu HAPUS folder temp)" -ForegroundColor Yellow
Write-Host "`nCek ESP32 masuk:  `"$MqInstall\mosquitto_sub.exe`" -h $ServerIp -t scada/mojokerto/# -v -u fuxa -P <password>" -ForegroundColor Green
