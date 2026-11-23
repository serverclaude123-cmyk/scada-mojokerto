@echo off
setlocal
set LOG=%~dp0pc1-jadi-viewer.log

REM ============================================================
REM  PC#1 (desktop-3n6b83h) BERHENTI jadi server -> hanya browser.
REM  Jalankan SETELAH backup-server-pc1.ps1 dan zip-nya sudah di PC#2.
REM  PERLU ADMINISTRATOR: klik kanan -> Run as administrator
REM
REM  Yang dilakukan (semua bisa dibalik, tidak ada yang dihapus):
REM   1. task FUXA dimatikan (disable), proses FUXA dihentikan
REM   2. service mosquitto distop dan diset Disabled
REM   3. aturan firewall 1883/1881 dimatikan
REM   4. adapter Ethernet dikembalikan ke DHCP -> melepas 192.168.1.10
REM      supaya PC#2 bisa memakainya (ESP32 tidak perlu di-flash ulang)
REM  Data C:\ProgramData\fuxa TIDAK dihapus: itu cadangan kalau perlu rollback.
REM
REM  ROLLBACK (PC#1 jadi server lagi):
REM    schtasks /change /tn FUXA /enable  &  schtasks /run /tn FUXA
REM    sc config mosquitto start= auto    &  net start mosquitto
REM    lalu set IP statis 192.168.1.10 lagi di Ethernet.
REM ============================================================

call :main > "%LOG%" 2>&1
type "%LOG%"
echo.
echo (log: %LOG%)
echo.
pause
exit /b 0

:main
net session >nul 2>&1
if errorlevel 1 (
  echo [X] BUKAN Administrator. Klik kanan -^> Run as administrator.
  exit /b 1
)

echo [1/4] Matikan FUXA...
schtasks /end /tn FUXA 2>&1
schtasks /change /tn FUXA /disable 2>&1
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'node.exe' -and $_.CommandLine -match 'fuxa' -and $_.CommandLine -match 'main\.js' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; 'dihentikan PID ' + $_.ProcessId }"

echo.
echo [2/4] Matikan broker Mosquitto...
net stop mosquitto 2>&1
sc config mosquitto start= disabled 2>&1
taskkill /IM mosquitto.exe /F 2>&1

echo.
echo [3/4] Nonaktifkan aturan firewall server...
netsh advfirewall firewall set rule name="Mosquitto 1883" new enable=no 2>&1
netsh advfirewall firewall set rule name="Mosquitto 1883 Tailscale" new enable=no 2>&1
netsh advfirewall firewall set rule name="FUXA 1881" new enable=no 2>&1
netsh advfirewall firewall set rule name="FUXA 1881 Tailscale" new enable=no 2>&1

echo.
echo [4/4] Ethernet -^> DHCP (melepas 192.168.1.10)...
netsh interface ipv4 set address name="Ethernet" source=dhcp 2>&1
netsh interface ipv4 set dnsservers name="Ethernet" source=dhcp 2>&1
REM kalau PC#1 pakai Wi-Fi atau nama adapter lain, ganti "Ethernet" di atas.

echo.
echo ===================== HASIL =====================
echo Port 1881/1883 (harus KOSONG):
netstat -ano | findstr /R /C:":1881 .*LISTENING" /C:":1883 .*LISTENING"
echo.
ipconfig | findstr IPv4
echo.
echo Sekarang buka di browser PC#1:  http://^<ip-tailscale-pc2^>:1881
echo (Tailscale di PC#1 TETAP dipakai - jangan logout.)
exit /b 0
