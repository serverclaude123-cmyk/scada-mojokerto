# Broker MQTT (Mosquitto)

Broker berjalan di PC FUXA (`192.168.1.10`). ESP32 publish ke sini; FUXA dan
klien remote (PC lain / HP) subscribe dari sini.

## Membuat user
```
mosquitto_passwd -c passwd esp32
mosquitto_passwd passwd fuxa
```
`-c` membuat file baru — **jangan** pakai `-c` untuk user kedua, nanti file lama tertimpa.

Isi user/password yang sama di:
- `firmware/include/secrets.h` → `MQTT_USER`, `MQTT_PASS`
- FUXA → Connections → `MQTT Broker`

## Menjalankan
Installer Mosquitto memasang **Windows service** bernama `mosquitto` (Automatic, jalan sebagai
LocalSystem) yang membaca `C:\Users\AIOPC\Tools\mosquitto\mosquitto.conf`.
Itu yang dipakai sehari-hari -- otomatis hidup saat PC dinyalakan, cocok untuk PC SCADA.

Setelah mengubah config, service harus di-restart, dan itu perlu hak Administrator.
Paling mudah: klik kanan **`setup-admin.cmd`** di folder ini -> **Run as administrator** -> **Yes**.
Skrip itu me-restart service, membuka port 1883 di firewall, lalu menampilkan hasilnya.

Manual-nya, dari Command Prompt yang dijalankan sebagai Administrator:
```
net stop mosquitto
net start mosquitto
netsh advfirewall firewall add rule name="Mosquitto 1883" dir=in action=allow protocol=TCP localport=1883 profile=private
```

Catatan: akun `AIOPC` memang anggota grup Administrators, tapi Windows menjalankannya dengan
token terbatas sampai di-elevate. UAC di PC ini diset `ConsentPromptBehaviorAdmin = 5`, jadi
yang muncul hanya dialog **Yes/No** -- tidak perlu mengetik password.

### JEBAKAN: dua broker sekaligus
Kalau `mosquitto -c ...` dijalankan manual sementara service juga hidup, akan ada **dua broker
di port 1883**: service memegang `127.0.0.1` dan `::1`, instance manual memegang `0.0.0.0`.
Keduanya tidak berbagi pesan sama sekali -- FUXA yang menyambung ke `localhost` masuk ke service,
ESP32 dari LAN masuk ke instance manual, dan datanya tidak akan pernah bertemu. Lebih buruk lagi,
config default service mengizinkan anonim.

Jalankan **salah satu saja**. Untuk pemakaian normal: pakai service, jangan jalankan manual.

## Memeriksa
```
mosquitto_sub -h 192.168.1.10 -t "scada/mojokerto/#" -v -u <user> -P <pass>
```
Kalau ESP32 jalan, dalam 2 detik akan muncul `scada/mojokerto/vsd2/volt_dc` dan kawan-kawan.

## Jebakan yang sudah terbukti
- **`MQTT_HOST` di ESP32 jangan `localhost`.** Dari sudut pandang ESP32 itu dirinya sendiri.
  Isi IP LAN PC: `192.168.1.10`. FUXA boleh `localhost` karena satu PC dengan broker.
- **Buka port 1883 di Windows Firewall** untuk profil jaringan privat, kalau tidak ESP32 tertolak diam-diam.
- `rc=5` di log ESP32 = `MQTT_CONNECT_UNAUTHORIZED` → user/password salah, bukan masalah jaringan.
- PC ini harus menyala. Kalau broker mati, FUXA dan klien remote buta, walau ESP32 dan PLC tetap jalan.

## Akses dari luar LAN (lewat Tailscale, broker tetap lokal)

Koneksi site ini berada di belakang **double NAT + CGNAT** (traceroute:
`192.168.1.1 -> 192.168.0.1 -> 10.57.0.1 -> 172.16.19.185 -> ...`), jadi port forwarding
tidak mungkin — paket dari internet tidak pernah sampai ke router site.

Arah **keluar** terbuka (sudah diuji: `broker.hivemq.com:1883` dan TLS 8886 tembus),
jadi Tailscale bisa dipakai. Tailscale **bukan** broker cloud: data tetap mengalir
langsung antara HP dan PC ini, Tailscale hanya menyatukan keduanya dalam satu
jaringan privat.

Setelah Tailscale terpasang dan login di PC ini dan di HP:
- HP memakai **alamat Tailscale PC ini** (`100.x.y.z`) sebagai host MQTT, port 1883
- user `fuxa`, password sama seperti di `KREDENSIAL-LOKAL.txt`

### Firewall untuk Tailscale
Adapter Tailscale biasanya dikenali Windows sebagai jaringan **Public**, sehingga aturan
`profile=private` untuk port 1883 TIDAK berlaku untuknya dan koneksi dari HP akan ditolak
diam-diam. `setup-admin.cmd` karena itu menambahkan aturan kedua yang dibatasi ke rentang
alamat Tailscale saja:

```
netsh advfirewall firewall add rule name="Mosquitto 1883 Tailscale" ^
  dir=in action=allow protocol=TCP localport=1883 remoteip=100.64.0.0/10
```

Dibatasi ke `100.64.0.0/10` supaya 1883 tetap tertutup untuk jaringan lain —
bukan dibuka ke profil Public begitu saja.

## Kalau suatu saat dipertimbangkan port forwarding
**Jangan port-forward 1883 apa adanya ke internet.** MQTT polos mengirim user dan password
sebagai teks biasa, dan topik `cmd/freq_set` di broker ini bisa mengubah kecepatan motor.
Pakai VPN (WireGuard/Tailscale) supaya HP seolah ada di LAN, atau aktifkan TLS di Mosquitto
(listener 8883 + sertifikat) lalu set `MQTT_USE_TLS 1` di `firmware/include/config.h`.
