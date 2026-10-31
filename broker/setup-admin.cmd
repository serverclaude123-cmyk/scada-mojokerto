@echo off
REM ============================================================
REM  Setup broker Mosquitto -- PERLU HAK ADMINISTRATOR
REM  Cara pakai: klik kanan file ini -> "Run as administrator"
REM              lalu klik Yes pada dialog UAC (tidak minta password)
REM ============================================================

net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo  [X] Jendela ini BUKAN Administrator.
  echo      Tutup, lalu klik kanan setup-admin.cmd -^> Run as administrator.
  echo.
  pause
  exit /b 1
)

echo [1/3] Restart service mosquitto supaya membaca config baru...
net stop mosquitto
net start mosquitto
echo.

echo [2/3] Buka port 1883 di firewall untuk jaringan privat...
netsh advfirewall firewall delete rule name="Mosquitto 1883" >nul 2>&1
netsh advfirewall firewall add rule name="Mosquitto 1883" dir=in action=allow protocol=TCP localport=1883 profile=private
echo.

echo [3/3] Periksa hasil...
echo --- listener port 1883 (harus 0.0.0.0, BUKAN 127.0.0.1) ---
netstat -ano | findstr :1883
echo.
echo Kalau yang muncul 0.0.0.0:1883 saja, berarti sudah benar.
echo Kalau masih ada 127.0.0.1:1883, config belum terbaca.
echo.
pause
