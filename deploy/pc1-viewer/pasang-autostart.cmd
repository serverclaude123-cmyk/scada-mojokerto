@echo off
setlocal
REM ============================================================
REM  PC#1 viewer: buka FUXA otomatis setiap login Windows.
REM  TIDAK perlu Administrator -- cukup klik dua kali.
REM
REM  - menyalin buka-scada.ps1 ke %LOCALAPPDATA%\scada-viewer
REM    (jadi tidak bergantung pada flashdisk / folder ini)
REM  - membuat shortcut "SCADA Mojokerto" di folder Startup dan di Desktop
REM  - langsung menjalankannya sekali sekarang
REM
REM  Melepas: hapus shortcut "SCADA Mojokerto" dari folder Startup
REM           (Win+R -> shell:startup)
REM ============================================================
set DST=%LOCALAPPDATA%\scada-viewer
if not exist "%DST%" mkdir "%DST%"
copy /Y "%~dp0buka-scada.ps1" "%DST%\buka-scada.ps1" >nul
if errorlevel 1 ( echo [X] gagal menyalin buka-scada.ps1 & pause & exit /b 1 )
copy /Y "%~dp0scada-viewer.html" "%DST%\scada-viewer.html" >nul
if errorlevel 1 ( echo [X] gagal menyalin scada-viewer.html & pause & exit /b 1 )

powershell -NoProfile -ExecutionPolicy Bypass -File "%DST%\buka-scada.ps1" -Install
if errorlevel 1 ( echo [X] gagal membuat shortcut & pause & exit /b 1 )

echo.
echo Menjalankan sekarang... jendela FUXA muncul begitu server PC#2 terjangkau.
start "" "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\SCADA Mojokerto.lnk"
echo.
echo SELESAI. Mulai sekarang setiap login Windows, FUXA terbuka sendiri.
echo Log: %DST%\buka-scada.log
pause
