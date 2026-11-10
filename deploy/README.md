# Memasang FUXA di PC baru (terutama PC di site)

## Keputusan arsitektur dulu: broker pindah ke site

Hari ini terbukti kenapa ini penting. PC yang memegang broker berpindah Wi-Fi, dan
seketika seluruh sistem putus — ESP32 dan PLC tidak kehilangan apa pun dari sisi mereka,
tapi tidak ada lagi broker yang bisa dituju.

**Taruh broker di PC site**, satu LAN dengan ESP32 dan PLC:

```
SITE                                     MANA SAJA
  VSD -- RS485 -- ESP32 ------+
                              |
  PLC M221 ------------------+--- PC SITE                 PC/HP lain
                              |     - Mosquitto (broker)  ---> subscribe
                              |     - FUXA (HMI)               ke broker site
                              +-----------------------------/
```

Keuntungannya: internet putus atau PC kantor dimatikan, pabrik tetap terpantau dan
terkendali dari PC site. PC lain hanya penonton. Kalau broker ditaruh di PC kantor,
setiap gangguan jaringan kantor membutakan seluruh sistem.

## Cara inject program ke PC baru

Tidak perlu klik import di UI FUXA. FUXA punya REST API `POST /api/project` yang
menerima file proyek utuh — itu yang dipakai skrip di sini.

Di PC baru:

```
git clone https://github.com/serverclaude123-cmyk/scada-mojokerto.git
cd scada-mojokerto\deploy
powershell -ExecutionPolicy Bypass -File .\setup-fuxa-pc.ps1 -BrokerHost <ip-broker> -MqttUser fuxa
```

Skrip itu akan:
1. mengunduh **Node portable** (zip, tanpa admin) kalau belum ada
2. memasang FUXA lewat `npm i -g @frangoteam/fuxa`
3. menjalankan FUXA dan menunggu port 1881 siap
4. **menanyakan password MQTT** (diketik saat itu, tidak pernah masuk Git)
5. memuat `fuxa/scada-mojokerto.fuxap` lewat REST API, sambil mengganti alamat broker
   dan alamat PLC sesuai parameter

Parameter lain: `-BrokerPort` (default 1883), `-PlcAddress` (default `192.168.1.113:502`),
`-Root` (default `C:\Tools`), `-NodeVersion`.

## Auto-start FUXA

FUXA yang dipasang lewat npm hanyalah proses node biasa — kalau PC restart atau prosesnya
berhenti, dia tidak hidup lagi sendiri. Mosquitto selamat karena terpasang sebagai Windows
service; FUXA tidak.

Jalankan **`setup-fuxa-autostart.cmd` sebagai Administrator** (klik kanan → Run as administrator).
Skrip itu membuat scheduled task bernama `FUXA` dengan akun **SYSTEM**, jadi FUXA hidup walau
belum ada yang login — penting untuk PC site yang bisa restart sendiri setelah listrik padam.
Pemicunya **dua**, bukan satu: *At startup* **dan** pemicu berulang (watchdog) tiap 2 menit.
Alasannya ada di bagian Fast Startup di bawah. Kerja sebenarnya dilakukan
`register-fuxa-task.ps1`; `setup-fuxa-autostart.cmd` hanya memeriksa Administrator dan berkas.

Melepasnya kembali:
```
schtasks /delete /tn FUXA /f
```

### JEBAKAN: folder data FUXA ditentukan oleh current directory
`main.js` menentukan folder datanya begini:

```js
var workDir = path.resolve(process.cwd(), '_appdata');
```

Jadi **lokasi data mengikuti dari mana FUXA dijalankan**, bukan dari mana dia terpasang.
Ini sudah menggigit sekali di sini: FUXA yang dijalankan dengan CWD `C:\` menyimpan proyek di
`C:\_appdata`, lalu begitu scheduled task menjalankannya dengan CWD `C:\Windows\System32`,
FUXA membuat `_appdata` baru yang kosong di sana dan **proyeknya tampak hilang** — padahal
datanya masih utuh di tempat lama.

Karena itu task selalu dibuat dengan `--userDir "C:\ProgramData\fuxa"`. Dengan itu folder
datanya pasti, tidak peduli siapa yang menjalankan dan dari mana. Skrip juga memeriksa
keberadaan `project.fuxap.db` di sana dan memperingatkan kalau belum ada.

Kalau proyek pernah tersimpan di tempat lain, salin dulu isinya:
```
xcopy /E /I /Y C:\_appdata C:\ProgramData\fuxa\_appdata
```

### `--userDir` memindahkan SEMUA folder data, bukan hanya `_appdata`
Ini bagian yang mudah terlewat. Setelah `--userDir` dipakai, `main.js` juga menggeser
`rootDir`, dan folder-folder ini di-resolve relatif ke sana:

```js
rootDir = parsedArgs.userDir;
settings.packageDir     = path.resolve(rootDir, '_pkg');
settings.imagesFileDir  = path.resolve(rootDir, '_images');
settings.widgetsFileDir = path.resolve(rootDir, '_widgets');
settings.dbDir          = path.resolve(rootDir, settings.dbDir || '_db');
```

Tanpa `--userDir`, `rootDir = __dirname`, jadi semuanya ada di dalam folder paket npm.
`_pkg` itulah tempat plugin terpasang — di PC ini plugin Modbus ada di
`<paket>/_pkg/runtime/node_modules/modbus-serial`. Kalau `_pkg` tidak ikut dipindah,
device PLC M221 gagal dimuat dengan `plugin is missing!` padahal plugin-nya jelas
sudah terpasang. Begitu juga `_db` (data trend/DAQ) akan mulai dari kosong.

Karena itu skrip menyalin `_pkg`, `_db`, `_images`, dan `_widgets` dari folder paket ke
`--userDir` (langkah [b] di `register-fuxa-task.ps1`) — **hanya kalau belum ada**, supaya
menjalankan ulang skrip tidak menimpa data yang sudah terkumpul. Penyalinan sengaja ditaruh
**setelah** FUXA dihentikan agar berkas SQLite di `_db` tidak tersalin dalam keadaan setengah
tertulis. FUXA dihentikan dengan mencocokkan command line (`fuxa` + `main.js`), bukan
`taskkill /IM node.exe`, supaya proses node lain di PC ini tidak ikut mati. Sisi baiknya: seluruh data yang bisa berubah jadi terkumpul di satu folder,
sehingga memindahkan FUXA ke PC site hanya perlu menyalin satu folder itu.

### JEBAKAN: Fast Startup membuat "At startup" tidak pernah menyala
Windows 10 menyalakan **Fast Startup** secara bawaan (`HiberbootEnabled=1`). Dengan itu
"Shut down" bukan mati sungguhan: sesi user ditutup, lalu *kernel* di-hibernate. Menyalakan PC
berikutnya hanya memulihkan image itu. Di PC ini terbukti dari log sistem:

- `Kernel-Boot` event 27 mencatat jenis boot. Semua "boot" sejak 6 Nov bertipe `0x1`
  (fast startup), bukan `0x0` (boot penuh).
- Event `6005` (*Event log service started*) hanya muncul di boot penuh. Di keempat fast startup
  (6 Nov, 9 Nov dua kali, 10 Nov) tidak ada — artinya **layanan Windows tidak di-restart**,
  termasuk Task Scheduler, sehingga pemicu *At startup* tidak pernah menyala.
- Proses milik **SYSTEM** (task FUXA, Mosquitto, Tailscale) ikut tersimpan di hibernate dan
  muncul lagi. Log FUXA membuktikannya: celahnya persis sama dengan PC mati, lalu lanjut tanpa
  baris `FUXA started!` baru.
- Proses milik **user biasa** ikut mati di tiap shutdown karena sesinya ditutup.

Akibatnya: selama FUXA SYSTEM tidak pernah mati, semuanya tampak baik-baik saja. Begitu
prosesnya mati sekali saja, tidak ada yang menghidupkannya — sampai ada boot penuh.

Kejadian nyata 9 Nov ~12:30: FUXA SYSTEM dihentikan untuk mereset login, lalu diganti
`Start-Process node.exe` dari sesi user. Sejak itu setiap PC dimatikan lalu dinyalakan, FUXA
hilang: prosesnya mati bersama sesi user dan tidak ada yang menyalakannya lagi.
Gejala sampingan yang menyesatkan: `fuxa.log` **berhenti** padahal FUXA hidup, karena berkas
log milik SYSTEM dan `BUILTIN\Users` hanya punya hak baca.

Obatnya ada di task: pemicu berulang tiap 2 menit memulai FUXA lagi kapan pun ia tidak jalan,
termasuk setelah Fast Startup. Peluncurnya (`C:\ProgramData\fuxa\start-fuxa.cmd`, dibuat
installer) tidak berbuat apa-apa kalau port 1881 sudah dipakai, jadi tidak ada instance ganda.
Opsi tambahan, tidak dipasang otomatis karena mengubah pengaturan daya Windows: mematikan Fast
Startup (Control Panel → Power Options → *Choose what the power buttons do* → hilangkan centang
*Turn on fast startup*) supaya setiap menyalakan PC adalah boot penuh.

### JEBAKAN: batas waktu 72 jam
Task yang dibuat `schtasks /create` mendapat batas waktu jalan bawaan 72 jam, jadi di PC yang
menyala terus node FUXA akan dibunuh scheduler tiap 3 hari. Versi lama skrip ini terkena itu.
Sekarang task dibuat lewat `Register-ScheduledTask` dengan `ExecutionTimeLimit = 0` (tanpa batas).

### Jangan menjalankan FUXA manual
Setelah task ini aktif, FUXA berjalan sebagai **SYSTEM**. Jangan menjalankannya manual sebagai
user biasa:

- prosesnya mati di shutdown berikutnya dan task tidak tahu ia pernah ada (lihat Fast Startup);
- selain berebut port 1881, berkas yang dibuat SYSTEM ber-ACL yang menolak akun biasa, jadi
  log berhenti tertulis tanpa pesan galat. Masalah serupa pernah terjadi dengan `mosquitto.log`
  dan sempat membuat Mosquitto gagal start — lihat `../broker/README.md`.

Kalau FUXA perlu dihentikan (mis. mereset `users.fuxap.db`), dari PowerShell Administrator:
`Stop-ScheduledTask -TaskName FUXA`, kerjakan perubahannya, lalu `Start-ScheduledTask -TaskName FUXA`.
Watchdog akan menyalakannya sendiri dalam 2 menit kalau lupa.

## Yang TIDAK dikerjakan skrip, dan kenapa

- **Memasang plugin `modbus-serial`.** Paket npm FUXA tidak menyertakan driver Modbus.
  Pasang lewat Settings → Plugins. Tanpa itu device PLC hanya menulis `plugin is missing`
  di log dan diam. Skrip hanya **menyalin** plugin yang sudah terpasang ke `--userDir`
  (lihat di atas); kalau belum pernah dipasang, tidak ada yang bisa disalin dan skrip
  akan memperingatkan.
- **Mosquitto.** Kalau PC ini yang jadi broker, pasang terpisah — lihat `../broker/README.md`.
  Installer-nya memasang Windows service, dan konfigurasinya butuh langkah admin satu kali.
- **Kredensial.** Tidak ada password di repo. Skrip menanyakannya saat jalan dan
  menyuntikkannya langsung ke instance FUXA yang berjalan, bukan ke file di Git.

## Kalau PC site tidak bisa diakses langsung

CGNAT membuat port forwarding tidak berguna di koneksi ini (sudah dicek: hop setelah gateway
masih alamat privat). Untuk mengelola PC site dari jauh, pakai VPN seperti Tailscale — PC site
dan PC/HP kamu masuk jaringan privat yang sama, lalu semuanya memakai alamat Tailscale.
Ini sekaligus jalan paling aman, karena tidak ada port yang dibuka ke internet — padahal
broker ini punya topik `cmd/freq_set` yang bisa mengubah kecepatan motor.
