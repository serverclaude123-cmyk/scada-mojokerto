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

Setelah mengubah config, service harus di-restart. Perlu **Command Prompt sebagai Administrator**:
```
net stop mosquitto
net start mosquitto
```

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

## Akses dari luar LAN
**Jangan port-forward 1883 apa adanya ke internet.** MQTT polos mengirim user dan password
sebagai teks biasa, dan topik `cmd/freq_set` di broker ini bisa mengubah kecepatan motor.
Pakai VPN (WireGuard/Tailscale) supaya HP seolah ada di LAN, atau aktifkan TLS di Mosquitto
(listener 8883 + sertifikat) lalu set `MQTT_USE_TLS 1` di `firmware/include/config.h`.
