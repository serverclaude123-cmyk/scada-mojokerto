@echo off
setlocal
set LOG=%~dp0setup-admin.log
REM Server = PC#2. Instalasi Mosquitto di Program Files, data (passwd) di ProgramData.
set MQINST=C:\Program Files\mosquitto
set MQ=C:\ProgramData\mosquitto
if not exist "%MQ%" mkdir "%MQ%"

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
echo [3/6] Salin passwd ke %MQ% dan mosquitto.conf ke %MQINST%...
copy /Y "%~dp0passwd" "%MQ%\passwd" 2>&1
copy /Y "%~dp0mosquitto.conf" "%MQINST%\mosquitto.conf" 2>&1

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
echo [6b] Izinkan 1883 dari peer Tailscale (100.64.0.0/10), profil apa pun...
REM Adapter Tailscale biasanya dikenali Windows sebagai jaringan Public, jadi
REM aturan profile=private di atas TIDAK berlaku untuknya. Aturan ini dibatasi
REM ke rentang alamat Tailscale saja -- 1883 tetap tertutup untuk jaringan lain.
netsh advfirewall firewall delete rule name="Mosquitto 1883 Tailscale" >nul 2>&1
netsh advfirewall firewall add rule name="Mosquitto 1883 Tailscale" dir=in action=allow protocol=TCP localport=1883 remoteip=100.64.0.0/10 2>&1

echo.
echo [6c] FUXA web 1881: LAN privat + peer Tailscale (PC#1 sekarang melihat lewat browser)...
netsh advfirewall firewall delete rule name="FUXA 1881" >nul 2>&1
netsh advfirewall firewall add rule name="FUXA 1881" dir=in action=allow protocol=TCP localport=1881 profile=private 2>&1
netsh advfirewall firewall delete rule name="FUXA 1881 Tailscale" >nul 2>&1
netsh advfirewall firewall add rule name="FUXA 1881 Tailscale" dir=in action=allow protocol=TCP localport=1881 remoteip=100.64.0.0/10 2>&1

echo.
echo ===================== HASIL =====================
sc query mosquitto | findstr /i state
echo Listener (harus 0.0.0.0:1883):
netstat -ano | findstr :1883
exit /b 0
