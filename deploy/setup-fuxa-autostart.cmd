@echo off
setlocal
set LOG=%~dp0setup-fuxa-autostart.log
set NODE=C:\Users\AIOPC\Tools\node-v22.23.4-win-x64\node.exe
set MAIN=C:\Users\AIOPC\Tools\npm-global\node_modules\@frangoteam\fuxa\main.js
set TASK=FUXA
set DATA=C:\ProgramData\fuxa
set SRC=C:\Users\AIOPC\Tools\npm-global\node_modules\@frangoteam\fuxa

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
echo [1/5] Periksa berkas...
if not exist "%NODE%" ( echo   [X] node.exe tidak ada: %NODE% & exit /b 1 )
if not exist "%MAIN%" ( echo   [X] FUXA main.js tidak ada: %MAIN% & exit /b 1 )
echo   node dan FUXA ditemukan
if not exist "%DATA%\_appdata\project.fuxap.db" (
  echo   [!] %DATA%\_appdata\project.fuxap.db tidak ada.
  echo       FUXA akan mulai dengan proyek KOSONG. Salin dulu _appdata yang berisi
  echo       proyekmu ke %DATA%, atau import ulang setelah ini.
) else (
  echo   data proyek ditemukan di %DATA%\_appdata
)

echo.
echo [2/5] Hentikan FUXA yang sedang jalan supaya tidak rebutan port 1881...
taskkill /IM node.exe /F 2>&1

echo.
echo [3/5] Siapkan folder data di %DATA%...
REM --userDir memindahkan SEMUA folder data FUXA ke %DATA%, bukan hanya _appdata.
REM main.js: rootDir = parsedArgs.userDir, lalu _pkg/_db/_images/_widgets/_reports
REM di-resolve relatif ke rootDir. _pkg berisi plugin modbus-serial; kalau tidak
REM ikut dipindah, device PLC M221 gagal dimuat dengan "plugin is missing!".
REM Disalin hanya kalau belum ada, supaya menjalankan ulang script tidak menimpa
REM data yang sudah terkumpul. Dilakukan SETELAH node.exe mati supaya file
REM SQLite di _db tidak tersalin dalam keadaan setengah tertulis.
if not exist "%DATA%" mkdir "%DATA%"
for %%D in (_pkg _db _images _widgets) do (
  if exist "%DATA%\%%D" (
    echo   %%D sudah ada, dilewati
  ) else if exist "%SRC%\%%D" (
    echo   menyalin %%D...
    xcopy /E /I /Y /Q "%SRC%\%%D" "%DATA%\%%D" >nul
    if errorlevel 1 ( echo   [X] gagal menyalin %%D & exit /b 1 )
  )
)
if not exist "%DATA%\_pkg\runtime\node_modules\modbus-serial" (
  echo   [!] plugin modbus-serial tidak ada di %DATA%\_pkg.
  echo       Device PLC M221 akan gagal dimuat. Pasang ulang lewat
  echo       Settings -^> Plugins setelah FUXA jalan.
) else (
  echo   plugin modbus-serial siap
)

echo.
echo [4/5] Buat scheduled task "%TASK%" (ONSTART, akun SYSTEM)...
schtasks /delete /tn "%TASK%" /f >nul 2>&1
REM --userDir WAJIB. Tanpa itu FUXA menentukan folder datanya dari current
REM working directory (main.js: workDir = path.resolve(process.cwd(), '_appdata')).
REM Scheduled task berjalan dengan CWD C:\Windows\System32, sehingga FUXA akan
REM membuat _appdata baru yang KOSONG di sana dan proyeknya tampak hilang.
schtasks /create /tn "%TASK%" /tr "\"%NODE%\" \"%MAIN%\" --userDir \"%DATA%\"" /sc onstart /ru SYSTEM /rl HIGHEST /f
if errorlevel 1 ( echo   [X] gagal membuat task & exit /b 1 )

echo.
echo [5/5] Jalankan sekarang untuk menguji...
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
