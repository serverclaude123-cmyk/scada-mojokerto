@echo off
setlocal
set LOG=%~dp0setup-admin.log
set MQ=C:\Users\AIOPC\Tools\mosquitto

REM ============================================================
REM  Setup broker Mosquitto -- PERLU HAK ADMINISTRATOR
REM  Klik kanan file ini -> "Run as administrator" -> Yes
REM  Semua output juga ditulis ke setup-admin.log
REM ============================================================

call :main > "%LOG%" 2>&1
type "%LOG%"
echo.
echo (output lengkap tersimpan di %LOG%)
echo.
pause
exit /b 0

:main
net session >nul 2>&1
if errorlevel 1 (
  echo [X] BUKAN Administrator. Klik kanan -^> Run as administrator.
  exit /b 1
)
echo [OK] berjalan sebagai Administrator

echo.
echo [1/6] Bunuh instance mosquitto manual yang memegang port 1883...
taskkill /IM mosquitto.exe /F 2>&1

echo.
echo [2/6] Stop service...
net stop mosquitto 2>&1

echo.
echo [3/6] Salin passwd ke folder instalasi...
copy /Y "%~dp0passwd" "%MQ%\passwd" 2>&1

echo.
echo [4/6] Hapus log lama ber-ACL LocalSystem...
if exist "%MQ%\mosquitto.log" del /F /Q "%MQ%\mosquitto.log" 2>&1

echo.
echo [5/6] Start service...
net start mosquitto 2>&1
sc query mosquitto | findstr /i state

echo.
echo [6/6] Firewall port 1883 (profil privat)...
netsh advfirewall firewall delete rule name="Mosquitto 1883" >nul 2>&1
netsh advfirewall firewall add rule name="Mosquitto 1883" dir=in action=allow protocol=TCP localport=1883 profile=private 2>&1

echo.
echo ===================== HASIL =====================
sc query mosquitto | findstr /i state
echo Listener (harus 0.0.0.0:1883):
netstat -ano | findstr :1883
exit /b 0
