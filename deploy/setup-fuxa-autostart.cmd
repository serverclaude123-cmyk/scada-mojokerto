@echo off
setlocal
set LOG=%~dp0setup-fuxa-autostart.log
set NODE=C:\Users\AIOPC\Tools\node-v22.23.4-win-x64\node.exe
set MAIN=C:\Users\AIOPC\Tools\npm-global\node_modules\@frangoteam\fuxa\main.js
set TASK=FUXA
set DATA=C:\ProgramData\fuxa

REM ============================================================
REM  Pasang FUXA supaya hidup otomatis saat PC menyala, dan
REM  dihidupkan lagi kalau sempat mati.
REM  PERLU ADMINISTRATOR: klik kanan -> Run as administrator
REM
REM  Task berjalan sebagai SYSTEM, jadi FUXA hidup walau belum ada
REM  yang login. Detail (kenapa ada watchdog, kenapa tanpa batas
REM  waktu, kenapa Fast Startup menjebak) ada di
REM  register-fuxa-task.ps1 dan deploy\README.md.
REM
REM  Melepas kembali:  schtasks /delete /tn FUXA /f
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
echo [OK] Administrator

echo.
echo [1/3] Periksa berkas...
if not exist "%NODE%" ( echo   [X] node.exe tidak ada: %NODE% & exit /b 1 )
if not exist "%MAIN%" ( echo   [X] FUXA main.js tidak ada: %MAIN% & exit /b 1 )
if not exist "%~dp0register-fuxa-task.ps1" ( echo   [X] register-fuxa-task.ps1 tidak ada di %~dp0 & exit /b 1 )
echo   node dan FUXA ditemukan
if not exist "%DATA%\_appdata\project.fuxap.db" (
  echo   [!] %DATA%\_appdata\project.fuxap.db tidak ada.
  echo       FUXA akan mulai dengan proyek KOSONG. Salin dulu _appdata yang berisi
  echo       proyekmu ke %DATA%, atau import ulang setelah ini.
) else (
  echo   data proyek ditemukan di %DATA%\_appdata
)

echo.
echo [2/3] Daftarkan task "%TASK%" dan jalankan...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-fuxa-task.ps1" -Node "%NODE%" -Main "%MAIN%" -Data "%DATA%" -TaskName "%TASK%"
if errorlevel 1 ( echo   [X] register-fuxa-task.ps1 gagal & exit /b 1 )

echo.
echo [3/3] ===================== HASIL =====================
echo Listener port 1881 (harus 0.0.0.0:1881):
netstat -ano | findstr :1881 | findstr LISTENING
echo.
echo Kalau kosong, FUXA belum siap -- tunggu sebentar lalu cek lagi.
exit /b 0
