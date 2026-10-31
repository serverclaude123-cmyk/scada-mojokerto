@echo off
setlocal
REM ============================================================
REM  Setup broker Mosquitto -- PERLU HAK ADMINISTRATOR
REM  Klik kanan file ini -> "Run as administrator" -> Yes
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

echo [1/5] Hentikan instance mosquitto manual yang mungkin memegang port 1883...
taskkill /IM mosquitto.exe /F >nul 2>&1
echo.

echo [2/5] Hentikan service...
net stop mosquitto 2>nul
echo.

echo [3/5] Hapus file log lama yang ber-ACL LocalSystem (kalau ada)...
if exist "C:\Users\AIOPC\Tools\mosquitto\mosquitto.log" (
  del /F /Q "C:\Users\AIOPC\Tools\mosquitto\mosquitto.log"
  echo    dihapus.
) else (
  echo    tidak ada, lewati.
)
echo.

echo [4/5] Start service...
net start mosquitto
if errorlevel 1 (
  echo.
  echo  [X] GAGAL start. Penyebab paling sering: port 1883 masih dipegang proses lain.
  echo      Cek dengan:  netstat -ano ^| findstr :1883
  echo.
  pause
  exit /b 1
)
echo.

echo [5/5] Buka port 1883 di firewall untuk jaringan privat...
netsh advfirewall firewall delete rule name="Mosquitto 1883" >nul 2>&1
netsh advfirewall firewall add rule name="Mosquitto 1883" dir=in action=allow protocol=TCP localport=1883 profile=private
echo.

echo ============================================================
echo  HASIL
echo ============================================================
sc query mosquitto | findstr /i state
echo.
echo Listener port 1883 (harus 0.0.0.0, BUKAN 127.0.0.1):
netstat -ano | findstr :1883
echo.
pause
