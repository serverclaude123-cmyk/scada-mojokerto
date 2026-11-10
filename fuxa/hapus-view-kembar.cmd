@echo off
rem Hapus view kembar di FUXA yang sedang jalan, saat editor FUXA tidak bisa dipakai
rem karena ada dua view bernama sama. Lihat README.md.
rem Password diketik di jendela ini, tidak disimpan. Tiap penghapusan minta konfirmasi.
setlocal
set "PY=C:\Users\AIOPC\Tools\python\python.exe"

echo.
echo Melihat dulu tanpa mengubah apa pun...
echo.
"%PY%" "%~dp0hapus_view_kembar.py" --dry-run
echo.
set "LANJUT="
set /p LANJUT=Lanjut menghapus? ketik y lalu Enter:
if /i not "%LANJUT%"=="y" (
  echo Dibatalkan, tidak ada yang dihapus.
  pause
  exit /b 0
)

set /p FUXA_USER=User FUXA [admin]:
if "%FUXA_USER%"=="" set "FUXA_USER=admin"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$p=Read-Host 'Password FUXA' -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p))"`) do set "FUXA_PASS=%%P"
"%PY%" "%~dp0hapus_view_kembar.py"
set FUXA_PASS=
echo.
pause
