<#
  buka-scada.ps1 -- dijalankan di PC#1 (viewer) saat user login, lewat shortcut di folder Startup
  (dipasang oleh pasang-autostart.cmd). Tidak perlu admin.

  Yang dilakukan:
   1. tunggu sampai server FUXA di PC#2 bisa dijangkau. Dicoba LAN dulu (192.168.1.10, kalau PC#1
      sedang di jaringan ruang pompa -- lebih cepat & stabil), lalu Tailscale (100.122.186.109,
      kalau PC#1 di luar). Tailscale kadang baru siap 10-60 detik setelah login.
   2. buka pembungkus FUXA (http://<server>:1881/_widgets/scada-viewer.html, disajikan FUXA di
      PC#2) di jendela Edge/Chrome mode app dengan profil browser terpisah (login FUXA tersimpan).
      Pembungkus itu yang menampilkan spanduk merah OFFLINE saat server mati dan pulih sendiri.
      Tanpa pembungkus, FUXA tetap menampilkan nilai terakhir dan "Gateway online" walau server mati.
   Log: %LOCALAPPDATA%\scada-viewer\buka-scada.log
#>
param(
  [string]$Url = 'http://100.122.186.109:1881',   # Tailscale PC#2
  [string]$LanUrl = 'http://192.168.1.10:1881',   # LAN ruang pompa; '' untuk mematikan
  [switch]$Kiosk,            # layar penuh (keluar dengan Alt+F4)
  [switch]$Install           # buat shortcut di Startup + Desktop yang menjalankan skrip ini
)
$ErrorActionPreference = 'Continue'
$base = Join-Path $env:LOCALAPPDATA 'scada-viewer'

if ($Install) {
  $ws = New-Object -ComObject WScript.Shell
  $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $extra = if ($Kiosk) { ' -Kiosk' } else { '' }
  foreach ($dir in [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Desktop')) {
    $s = $ws.CreateShortcut((Join-Path $dir 'SCADA Mojokerto.lnk'))
    $s.TargetPath = $ps
    $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Url `"$Url`" -LanUrl `"$LanUrl`"$extra"
    $s.WindowStyle = 7
    $s.IconLocation = 'shell32.dll,13'
    $s.Save()
    Write-Output "shortcut: $($s.FullName)"
  }
  exit 0
}
$profileDir = Join-Path $base 'browser-profile'
$log = Join-Path $base 'buka-scada.log'
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
function Log($m) { "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m | Add-Content -Path $log -Encoding UTF8 }

function TcpUp([string]$address) {
  $u = [Uri]$address
  $c = New-Object Net.Sockets.TcpClient
  try { return $c.ConnectAsync($u.Host, $u.Port).Wait(3000) } catch { return $false } finally { $c.Close() }
}

$browser = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { Log 'Edge/Chrome tidak ditemukan'; exit 1 }
$exeName = Split-Path $browser -Leaf

function ViewerProcs {
  @(Get-CimInstance Win32_Process -Filter "Name='$exeName'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profileDir) })
}

# satu instance saja
$me = $PID
$other = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -match 'buka-scada\.ps1' }
if ($other) { Log 'sudah ada buka-scada lain yang jalan, keluar'; exit 0 }

if ((ViewerProcs).Count -gt 0) { Log 'jendela SCADA sudah terbuka'; exit 0 }

# --- 1. tunggu server; LAN dulu, lalu Tailscale --------------------------------------
$candidates = @($LanUrl, $Url) | Where-Object { $_ }
Log ("mulai; tunggu server: " + ($candidates -join ' / '))
$server = $null
while (-not $server) {
  foreach ($cand in $candidates) { if (TcpUp $cand) { $server = $cand.TrimEnd('/'); break } }
  if (-not $server) { Start-Sleep -Seconds 5 }
}
Log "server siap lewat $server"

# --- 2. buka pembungkus (disajikan FUXA; BUKAN file lokal -- dari file:// Edge PC#1 menolak
#        cek server sehingga selalu tampil OFFLINE palsu) ---------------------------------
$openUrl = "$server/_widgets/scada-viewer.html"
try { $null = Invoke-WebRequest $openUrl -UseBasicParsing -TimeoutSec 10 -Method Head }
catch { Log "pembungkus tidak ada di server ($openUrl), buka FUXA langsung"; $openUrl = "$server/" }

$mode = if ($Kiosk) { "--kiosk `"$openUrl`" --edge-kiosk-type=fullscreen" } else { "--app=`"$openUrl`"" }
$argLine = "--user-data-dir=`"$profileDir`" --no-first-run --no-default-browser-check --start-maximized $mode"
Start-Process -FilePath $browser -ArgumentList $argLine
Log "buka $openUrl ($exeName)"
