@echo off
setlocal
set LOG=%~dp0setup-fuxa-autostart.log
set NODE=C:\Users\AIOPC\Tools\node-v22.23.4-win-x64\node.exe
set MAIN=C:\Users\AIOPC\Tools\npm-global\node_modules\@frangoteam\fuxa\main.js
set TASK=FUXA

REM ============================================================
REM  Pasang FUXA supaya hidup otomatis saat PC menyala.
REM  PERLU ADMINISTRATOR: klik kanan -> Run as administrator
REM
REM  Memakai Task Scheduler dengan pemicu ONSTART dan akun SYSTEM,
REM  jadi FUXA jalan walau belum ada yang login -- penting untuk PC
REM  site yang bisa restart sendiri setelah listrik padam.
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
echo [1/4] Periksa berkas...
if not exist "%NODE%" ( echo   [X] node.exe tidak ada: %NODE% & exit /b 1 )
if not exist "%MAIN%" ( echo   [X] FUXA main.js tidak ada: %MAIN% & exit /b 1 )
echo   node dan FUXA ditemukan

echo.
echo [2/4] Hentikan FUXA yang sedang jalan supaya tidak rebutan port 1881...
taskkill /IM node.exe /F 2>&1

echo.
echo [3/4] Buat scheduled task "%TASK%" (ONSTART, akun SYSTEM)...
schtasks /delete /tn "%TASK%" /f >nul 2>&1
schtasks /create /tn "%TASK%" /tr "\"%NODE%\" \"%MAIN%\"" /sc onstart /ru SYSTEM /rl HIGHEST /f
if errorlevel 1 ( echo   [X] gagal membuat task & exit /b 1 )

echo.
echo [4/4] Jalankan sekarang untuk menguji...
schtasks /run /tn "%TASK%"
echo   menunggu FUXA siap...
timeout /t 35 /nobreak >nul

echo.
echo ===================== HASIL =====================
schtasks /query /tn "%TASK%" /fo list | findstr /i "TaskName Status Next"
echo.
echo Listener port 1881 (harus 0.0.0.0:1881):
netstat -ano | findstr :1881
echo.
echo Kalau kosong, FUXA belum siap -- tunggu sebentar lalu cek lagi.
exit /b 0
