@echo off
rem Menerapkan view dari scada-mojokerto.fuxap (label "Gateway" + lampu PLC M221) ke FUXA yang jalan.
rem Device dan kredensial broker tidak disentuh. Password diketik di jendela ini, tidak disimpan.
set "PY=C:\Users\AIOPC\Tools\python\python.exe"
set /p FUXA_USER=User FUXA [admin]:
if "%FUXA_USER%"=="" set "FUXA_USER=admin"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$p=Read-Host 'Password FUXA' -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p))"`) do set "FUXA_PASS=%%P"
"%PY%" "%~dp0patch_live_view.py"
set FUXA_PASS=
echo.
pause
