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
Skrip itu membuat scheduled task bernama `FUXA` dengan pemicu **ONSTART** dan akun **SYSTEM**,
jadi FUXA hidup begitu PC menyala walau belum ada yang login — penting untuk PC site yang bisa
restart sendiri setelah listrik padam.

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

Karena itu task selalu dibuat dengan `--userDir "C:\ProgramDatauxa"`. Dengan itu folder
datanya pasti, tidak peduli siapa yang menjalankan dan dari mana. Skrip juga memeriksa
keberadaan `project.fuxap.db` di sana dan memperingatkan kalau belum ada.

Kalau proyek pernah tersimpan di tempat lain, salin dulu isinya:
```
xcopy /E /I /Y C:\_appdata C:\ProgramDatauxa\_appdata
```

### Jangan campur dengan menjalankan FUXA manual
Setelah task ini aktif, FUXA berjalan sebagai **SYSTEM**. Jangan lagi menjalankannya manual
sebagai user biasa: selain berebut port 1881, berkas yang dibuat SYSTEM bisa ber-ACL yang
menolak akun biasa. Masalah persis seperti itu sudah pernah terjadi di sini dengan
`mosquitto.log` dan sempat membuat Mosquitto gagal start — lihat `../broker/README.md`.

## Yang TIDAK dikerjakan skrip, dan kenapa

- **Plugin `modbus-serial`.** Paket npm FUXA tidak menyertakan driver Modbus. Pasang lewat
  Settings → Plugins. Tanpa itu device PLC hanya menulis `plugin is missing` di log dan diam.
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
