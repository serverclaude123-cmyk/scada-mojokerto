<#
  reset-fuxa-login.ps1 -- kalau password admin FUXA lupa. PowerShell sebagai Administrator, di PC server.

  FUXA membuat ulang akun bawaan admin / 123456 saat users.fuxap.db tidak ada
  (runtime/users/usrstorage.js, setDefault). Skrip ini:
    1. menghentikan task FUXA (SYSTEM) + proses node FUXA saja
    2. MENGGANTI NAMA users.fuxap.db (tidak dihapus) -> users.fuxap.db.lupa-<tanggal>
    3. menjalankan task FUXA lagi dan menunggu port 1881
  Proyek, alarm, trend TIDAK tersentuh. Akun lain (operator) ikut hilang dari daftar user;
  file lama tetap ada kalau perlu dikembalikan (hentikan FUXA, ganti nama balik).

  Contoh:
    powershell -ExecutionPolicy Bypass -File .\reset-fuxa-login.ps1
#>
param([string]$Data = 'C:\ProgramData\fuxa', [int]$Port = 1881)
$ErrorActionPreference = 'Stop'
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Bukan Administrator. Buka PowerShell dengan "Run as administrator".' }
$db = Join-Path $Data '_appdata\users.fuxap.db'
if (-not (Test-Path $db)) { throw "Tidak ada $db" }

Write-Host '[1] Hentikan FUXA...'
Get-ScheduledTask -TaskName FUXA -ErrorAction SilentlyContinue | Stop-ScheduledTask
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'fuxa' -and $_.CommandLine -match 'main\.js' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "    dihentikan PID $($_.ProcessId)" }
Start-Sleep -Seconds 2

$new = "$db.lupa-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
Write-Host "[2] Ganti nama users.fuxap.db -> $(Split-Path $new -Leaf)"
Rename-Item $db $new

Write-Host '[3] Jalankan FUXA lagi...'
Start-ScheduledTask -TaskName FUXA
$deadline = (Get-Date).AddSeconds(90)
do { Start-Sleep -Seconds 2; $up = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) } until ($up -or (Get-Date) -gt $deadline)
if (-not $up) { throw "FUXA belum mendengarkan di port $Port. Cek Task Scheduler -> FUXA." }

Write-Host ''
Write-Host 'SELESAI. Login FUXA sekarang:  user admin  /  password 123456' -ForegroundColor Green
Write-Host 'SEGERA ganti password: editor FUXA -> Settings/Users -> admin.' -ForegroundColor Yellow
