<#
  register-fuxa-task.ps1 -- daftarkan task "FUXA" yang tahan Fast Startup.
  Dipanggil oleh setup-fuxa-autostart.cmd (yang sudah memeriksa Administrator).
  Tanpa -DryRun skrip ini mengubah task SYSTEM dan menghentikan FUXA yang jalan.

  Kenapa bukan sekadar "schtasks /create /sc onstart":
   1. Fast Startup (HiberbootEnabled=1, bawaan Windows 10) membuat "Shut down" lalu
      menyalakan PC BUKAN boot sungguhan. Layanan Windows tidak di-restart (event
      Event log service 6005 tidak muncul), jadi pemicu "At startup" tidak pernah
      menyala. FUXA yang sudah jalan sebagai SYSTEM ikut tersimpan di hibernate dan
      muncul lagi, tapi begitu prosesnya sempat mati tidak ada yang menghidupkannya.
      Proses yang dijalankan sebagai user biasa mati di tiap shutdown.
   2. schtasks /create memberi batas waktu jalan 72 jam. Di PC yang menyala terus
      node FUXA akan dibunuh scheduler tiap 3 hari.
  Maka: pemicu At startup + pemicu berulang (watchdog), tanpa batas waktu jalan.
  Peluncurnya tidak berbuat apa-apa kalau port FUXA sudah dipakai.
#>
param(
  [Parameter(Mandatory = $true)][string]$Node,
  [Parameter(Mandatory = $true)][string]$Main,
  [Parameter(Mandatory = $true)][string]$Data,
  [string]$TaskName = 'FUXA',
  [int]$Port = 1881,
  [int]$WatchdogMinutes = 2,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$AppDir = Split-Path -Parent $Main

if (-not $DryRun) {
  $role = [Security.Principal.WindowsBuiltInRole]::Administrator
  $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $me.IsInRole($role)) { throw 'Bukan Administrator.' }
} else {
  Write-Output '*** DRY-RUN: tidak menghentikan proses, tidak mendaftarkan task ***'
}

# --- a. hentikan FUXA yang sedang jalan (hanya node.exe milik FUXA) ---------------
Write-Output '[a] Hentikan FUXA yang sedang jalan (hanya node.exe milik FUXA)...'
$procs = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'fuxa' -and $_.CommandLine -match 'main\.js' })
if ($procs.Count -eq 0) { Write-Output '    tidak ada proses FUXA yang berjalan' }
foreach ($p in $procs) {
  if ($DryRun) { Write-Output ('    (dry-run) akan menghentikan PID {0}' -f $p.ProcessId) }
  else { Stop-Process -Id $p.ProcessId -Force; Write-Output ('    dihentikan PID {0}' -f $p.ProcessId) }
}

# --- b. folder data. Disalin SETELAH node mati supaya SQLite di _db tidak setengah tertulis
Write-Output ('[b] Siapkan folder data di {0}...' -f $Data)
New-Item -ItemType Directory -Force -Path $Data | Out-Null
foreach ($d in '_pkg', '_db', '_images', '_widgets') {
  $src = Join-Path $AppDir $d
  $dst = Join-Path $Data $d
  if (Test-Path $dst) { Write-Output ('    {0} sudah ada, dilewati' -f $d) }
  elseif (Test-Path $src) {
    Write-Output ('    menyalin {0}...' -f $d)
    Copy-Item -Path $src -Destination $dst -Recurse -Force
  }
}
if (Test-Path (Join-Path $Data '_pkg\runtime\node_modules\modbus-serial')) {
  Write-Output '    plugin modbus-serial siap'
} else {
  Write-Output '    [!] plugin modbus-serial tidak ada: device PLC M221 akan gagal dimuat.'
}

# --- c. peluncur. Tidak berbuat apa-apa kalau FUXA sudah mendengarkan di port itu ---
$launcher = Join-Path $Data 'start-fuxa.cmd'
Write-Output ('[c] Tulis peluncur {0}...' -f $launcher)
$lines = @(
  '@echo off',
  'rem Dibuat oleh register-fuxa-task.ps1. Jangan diedit tangan; jalankan ulang installer.',
  'rem Dipanggil task FUXA saat boot dan tiap beberapa menit. Kalau sesuatu sudah',
  'rem mendengarkan di port FUXA (siapa pun yang menjalankannya), tidak berbuat apa-apa.',
  ('netstat -ano | findstr /R /C:":{0} .*LISTENING" >nul && exit /b 0' -f $Port),
  ('"{0}" "{1}" --userDir "{2}"' -f $Node, $Main, $Data)
)
Set-Content -Path $launcher -Value $lines -Encoding ASCII

# --- d. task ------------------------------------------------------------------------
Write-Output ('[d] Susun task "{0}" (At startup + watchdog tiap {1} menit, tanpa batas waktu)...' -f $TaskName, $WatchdogMinutes)
$action = New-ScheduledTaskAction -Execute $env:ComSpec -Argument ('/c ""{0}""' -f $launcher) -WorkingDirectory $Data
$trgBoot = New-ScheduledTaskTrigger -AtStartup
$trgTick = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes $WatchdogMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
  -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Write-Output ('    aksi              : {0} {1}' -f $action.Execute, $action.Arguments)
Write-Output ('    watchdog          : tiap {0}' -f $trgTick.Repetition.Interval)
Write-Output ('    batas waktu jalan : {0} (00:00:00 = tanpa batas)' -f $settings.ExecutionTimeLimit)
Write-Output ('    instance ganda    : {0}' -f $settings.MultipleInstances)

if ($DryRun) { Write-Output '*** DRY-RUN selesai ***'; exit 0 }

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trgBoot, $trgTick) `
  -Settings $settings -Principal $principal -Force `
  -Description 'FUXA SCADA HMI Mojokerto: start saat boot + watchdog (tahan Fast Startup)' | Out-Null
Write-Output '    task terdaftar'

# --- e. jalankan sekarang dan tunggu port ---------------------------------------------
Write-Output ('[e] Jalankan task dan tunggu port {0}...' -f $Port)
Start-ScheduledTask -TaskName $TaskName
$deadline = (Get-Date).AddSeconds(60)
do {
  Start-Sleep -Seconds 2
  $up = [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
} until ($up -or (Get-Date) -gt $deadline)

$t = Get-ScheduledTask -TaskName $TaskName
Write-Output ('    status task       : {0}' -f $t.State)
Write-Output ('    batas waktu jalan : {0}' -f $t.Settings.ExecutionTimeLimit)
Write-Output ('    jumlah pemicu     : {0}' -f @($t.Triggers).Count)
if ($up) { Write-Output ('    FUXA mendengarkan di port {0}' -f $Port) }
else { throw ('FUXA belum mendengarkan di port {0} setelah 60 detik.' -f $Port) }
