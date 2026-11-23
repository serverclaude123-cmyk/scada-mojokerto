<#
  backup-server-pc1.ps1 -- dijalankan di PC#1 (server LAMA, desktop-3n6b83h).
  PowerShell sebagai Administrator.

  Mengumpulkan semua yang dibutuhkan PC#2 untuk mengambil alih peran server:
    - folder data FUXA (C:\ProgramData\fuxa: _appdata proyek + user login, _db trend,
      _pkg plugin modbus-serial, _images, _widgets)
    - passwd Mosquitto (hash user esp32/fuxa/hp1/hp2/pc2)
    - KREDENSIAL-LOKAL.txt dan firmware\include\secrets.h (TIDAK di Git)
    - manifest: versi FUXA & Node yang terpasang, supaya PC#2 memasang versi yang sama
  Hasil: satu zip di Desktop. Bawa ke PC#2 dengan flashdisk -- JANGAN lewat Git/email,
  isinya kredensial.

  FUXA dihentikan sebentar (supaya SQLite tidak tersalin setengah tertulis) lalu
  dihidupkan lagi -- PC#1 tetap jadi server sampai PC#2 siap (lihat MIGRASI-PC2.md).

  Contoh:
    powershell -ExecutionPolicy Bypass -File .\backup-server-pc1.ps1
#>
param(
  [string]$FuxaData  = 'C:\ProgramData\fuxa',
  [string]$Mosquitto = 'C:\Users\AIOPC\Tools\mosquitto',
  [string]$ToolsDir  = 'C:\Users\AIOPC\Tools',
  [string]$RepoDir   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutDir    = [Environment]::GetFolderPath('Desktop')
)
$ErrorActionPreference = 'Stop'
$role = [Security.Principal.WindowsBuiltInRole]::Administrator
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole($role)) { throw 'Bukan Administrator. Buka PowerShell dengan "Run as administrator".' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$work  = Join-Path $env:TEMP "scada-backup-$stamp"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# --- 1. versi terpasang -----------------------------------------------------------
Write-Output '[1] Catat versi FUXA dan Node...'
$fuxaPkg = Get-ChildItem -Path $ToolsDir -Recurse -Filter package.json -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match '@frangoteam\\fuxa\\package\.json$' } | Select-Object -First 1
$fuxaVer = if ($fuxaPkg) { (Get-Content $fuxaPkg.FullName -Raw | ConvertFrom-Json).version } else { '' }
$nodeExe = Get-ChildItem -Path $ToolsDir -Filter node.exe -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
$nodeVer = if ($nodeExe) { (& $nodeExe.FullName --version) } else { '' }
Write-Output "    FUXA $fuxaVer, Node $nodeVer"

# --- 2. hentikan FUXA sebentar ------------------------------------------------------
Write-Output '[2] Hentikan FUXA sebentar...'
$task = Get-ScheduledTask -TaskName FUXA -ErrorAction SilentlyContinue
if ($task) { Stop-ScheduledTask -TaskName FUXA }
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'fuxa' -and $_.CommandLine -match 'main\.js' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Output "    dihentikan PID $($_.ProcessId)" }
Start-Sleep -Seconds 2

try {
  # --- 3. salin data ----------------------------------------------------------------
  Write-Output "[3] Salin data FUXA dari $FuxaData..."
  if (-not (Test-Path (Join-Path $FuxaData '_appdata\project.fuxap.db'))) {
    throw "Tidak ada $FuxaData\_appdata\project.fuxap.db -- proyek FUXA ada di tempat lain? Cek deploy\README.md (JEBAKAN folder data)."
  }
  $dst = Join-Path $work 'fuxa'
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  foreach ($d in '_appdata', '_db', '_pkg', '_images', '_widgets') {
    $s = Join-Path $FuxaData $d
    if (Test-Path $s) { Copy-Item $s (Join-Path $dst $d) -Recurse -Force; Write-Output "    $d" }
  }
  # log & peluncur lama tidak dibawa: path-nya milik PC#1

  Write-Output '[4] Salin kredensial (tidak ada di Git)...'
  $cred = Join-Path $work 'kredensial'
  New-Item -ItemType Directory -Force -Path $cred | Out-Null
  $items = @{
    'passwd'               = (Join-Path $Mosquitto 'passwd')
    'KREDENSIAL-LOKAL.txt' = (Join-Path $RepoDir 'broker\KREDENSIAL-LOKAL.txt')
    'secrets.h'            = (Join-Path $RepoDir 'firmware\include\secrets.h')
  }
  foreach ($k in $items.Keys) {
    if (Test-Path $items[$k]) { Copy-Item $items[$k] (Join-Path $cred $k); Write-Output "    $k" }
    else { Write-Output "    [!] tidak ditemukan: $($items[$k])" }
  }
} finally {
  # --- 5. hidupkan lagi FUXA di PC#1 (masih server sampai cut-over) ---------------------
  Write-Output '[5] Hidupkan lagi FUXA di PC#1...'
  if ($task) { Start-ScheduledTask -TaskName FUXA }
}

@{
  dibuat     = (Get-Date).ToString('s')
  dari       = $env:COMPUTERNAME
  fuxa       = $fuxaVer
  node       = $nodeVer
  catatan    = 'Backup server SCADA Mojokerto untuk migrasi ke PC#2. Berisi kredensial: jangan di-commit.'
} | ConvertTo-Json | Set-Content (Join-Path $work 'manifest.json') -Encoding UTF8

$zip = Join-Path $OutDir "scada-server-backup-$stamp.zip"
Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force
Remove-Item $work -Recurse -Force
Write-Output ''
Write-Output "SELESAI: $zip"
Write-Output 'Salin zip ini ke PC#2 (flashdisk), lalu jalankan deploy\setup-server-pc2.ps1 di sana.'
