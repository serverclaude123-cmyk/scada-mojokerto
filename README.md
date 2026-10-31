# SCADA 2 VSD ABB – Mojokerto

Target: ABB ACS550 (untuk tes dipakai ACS310). PLC-nya Schneider M221, tapi drive-nya ABB.

```
VSD1 ─┐  Modbus RTU (RS485)              LAN 192.168.1.0/24
VSD2 ─┴──────────────── ESP32-ETH ───────────┐
         baca freq/arus                      │
         + TULIS setpoint (REFERENCE 1)      │
                                             │
PLC M221 ────────────────────────────────────┤   ON/OFF hardwired ke DI VSD
                                             │
PC ini ──────────────────────────────────────┘
  ├─ broker MQTT   ◄── ESP32 publish, FUXA subscribe
  └─ FUXA HMI      ──► Modbus TCP ke M221 (tombol START/STOP)
        ▲
        └── PC remote / HP: subscribe ke broker yang sama
```

| Fungsi | Jalur |
|---|---|
| Monitoring freq out, setpoint, arus, run/fault/comm | VSD → ESP32 (Modbus RTU) → MQTT → **broker di PC ini** → FUXA / remote |
| **Setpoint frekuensi** | MQTT → ESP32 → Modbus RTU **REFERENCE 1 (40002)** → VSD |
| Perintah ON/OFF | FUXA → **Modbus TCP ke PLC M221** → output PLC → DI VSD (hardwired) |

Pembagian kewenangan yang penting: **ESP32 boleh mengatur kecepatan, tapi tidak boleh menjalankan atau
menghentikan motor.** Yang ditulisnya hanya REFERENCE 1 (`40002`), bukan Control Word (`40001`), dan ada
pagar `#error` di `config.h` yang mencegah salah arah. Start/stop sepenuhnya milik PLC M221 lewat kontak
hardwired, dengan interlock Local/Remote dan e-stop di sisi PLC.

Gambar lengkap (arsitektur, wiring RS485 dengan nomor terminal, jalur perintah PLC): **[`docs/arsitektur-wiring.html`](docs/arsitektur-wiring.html)** — buka di browser, bisa di-print A3.
Proyek FUXA siap import: **[`fuxa/`](fuxa/)**.

## IP plan (contoh, ubah sesuai LAN)
| Perangkat | IP |
|---|---|
| Router | 192.168.1.1 |
| PC ini — broker MQTT + FUXA | 192.168.1.10 |
| PLC M221 | 192.168.1.113 (terbaca di lapangan; rencana awal .20) |
| ESP32 | 192.168.1.11 (DHCP; `config.h` masih menyetel statis .50 — belum dipakai board) |

## 1. Firmware ESP32
Board: KhursLabs ESP32-S3 IoT Acquisition RS485-Ethernet (W5500: CS 5, MOSI 11, SCK 12, MISO 13, RST 21, INT 47; RS485 UART1 **TX 15 / RX 16**, auto-direction). Pin W5500 dan RS485 keduanya sesuai dokumentasi KhursLabs: W5500 dari silkscreen board, RS485 dari contoh resmi `Test_sht20_RS485.ino`. Folder: `firmware/` (PlatformIO, platform pioarduino / arduino-esp32 3.x). Ubah dulu:
1. `include/secrets.h` → host/user/password broker MQTT.
2. `include/config.h` → IP, baud (`MB_BAUD` harus sama dengan par 5303 drive), slave ID VSD, alamat register.
   Terminal sekrup "SERIAL 1" (17/18) **bukan** jalur RS485 — itu breakout UART TTL terpisah.

```bash
cd firmware
pio run -t upload
pio device monitor
```

### VSD ABB ACS550 – Modbus RTU on-board (EFB)
Tidak perlu modul fieldbus tambahan. Wiring di terminal X1:
```
ESP32 modul RS485        ACS550 #1 (X1)      ACS550 #2 (X1)
 A (-) ───────────────── 30 (A, negatif) ─── 30 (A)
 B (+) ───────────────── 29 (B, positif) ─── 29 (B)   (label modul bisa terbalik; tukar bila tak komunikasi)
 GND  ────────────────── 31 (AGND) ───────── 31 (AGND)
 shield ──────────────── 28 / 32 (SCR) — ground shield di satu ujung saja
```
- Kabel twisted pair berselubung. Terminasi 120 Ω di ujung bus (ACS550 punya switch terminasi di board kontrol – cek manual; satu lagi di modul RS485).
- Parameter di tiap drive:

| Param | Nilai |
|---|---|
| 9802 COMM PROT SEL | 1 (STD MODBUS) |
| 5302 EFB STATION ID | **1** (VSD1), **2** (VSD2) |
| 5303 EFB BAUD RATE | **19.2 kbps** — dikonfirmasi di lapangan; harus sama dengan `MB_BAUD` di `config.h` |
| 5304 EFB PARITY | 0 = 8 NONE 1 (default pabrik 1 = 8N2, harus diubah) |
| 5305 EFB CTRL PROFILE | **0** = ABB DRV LIM (profil ABB Drives; 1 = DCU, jangan dipakai) |

- Setelah ganti 9802, power-cycle / tunggu EFB restart. Cek par 5306–5309 (EFB OK/ERR frames) naik saat polling jalan.
- Start/stop dan referensi tetap lewat terminal/PLC (par 1001 dll), Modbus hanya dibaca.

Register yang dibaca (`config.h`). Alamat PDU = nomor register − 40001:

| Isi | Register | Alamat PDU | Skala |
|---|---|---|---|
| Status Word | `40004` | 3 | bit |
| par 0103 OUTPUT FREQ | `40103` | 102 | 0,1 Hz |
| par 0104 CURRENT | `40104` | 103 | 0,1 A |
| par 0107 DC BUS VOLTAGE | `40107` | 106 | 1 V |
| par 0109 OUTPUT VOLTAGE | `40109` | 108 | 1 V |
| par 0111 EXT REF 1 | `40111` | 110 | 0,1 Hz |

Bit status: `RDY_REF` = run, `TRIPPED` = fault.

Par 0103–0111 diambil dalam **satu** FC03 (alamat 102, 9 register) supaya lalu lintas RS485 turun dari 6 transaksi jadi 2 per VSD per siklus. Kalau drive menolak rentang itu (exception 02), firmware otomatis kembali membaca satu-satu dan mencatatnya di serial monitor — matikan permanen dengan `MB_BLOCK_READ 0`.

### Tulis setpoint frekuensi (AKTIF)
`ALLOW_SETPOINT_WRITE 1` di `config.h`. ESP32 menulis **REFERENCE 1** (`40002`, alamat PDU 1, FC06) dari topik MQTT `scada/mojokerto/vsd1/cmd/freq_set` (dan `vsd2/...`). Isi `0` kalau mau sementara mengembalikan firmware ke murni read-only.

- Yang ditulis hanya nilai referensi, **bukan Control Word** (`40001`) — jadi ESP32 tetap tidak bisa start/stop motor. Ada pagar `#error` di `config.h` kalau `REG_REF1` sampai diisi 0.
- Prasyarat di drive: par **1103 REF1 SELECT = 8 (COMM)** dan panel pada mode **REM**. Tanpa itu nilainya ditulis tapi diabaikan drive.
- Skala: `20000` = par **1105 REF1 MAX**. Isi `REF1_MAX_HZ` sesuai nilai 1105 di drive (resolusi 0,1 Hz: 500 = 50,0 Hz).
- Nilai dari MQTT di-clamp ke `REF_CLAMP_MIN_HZ`…`REF_CLAMP_MAX_HZ`.
- Publish perintah **tanpa retained** — perintah retained akan dipakai ulang tiap kali ESP32 reconnect.
- Echo: `vsd1/freq_cmd` (Hz yang benar-benar dikirim) dan `vsd1/cmd_ok` (1 = drive mengakui tulisan).

### Topik MQTT (payload angka/teks biasa, retained)
Basis: `scada/mojokerto`

| Topik | Isi |
|---|---|
| `gw/status` | `online` / `offline` (LWT) |
| `gw/ip`, `gw/uptime` | IP ESP32, uptime detik |
| `vsd1/freq_out`, `vsd2/freq_out` | frekuensi output (Hz) |
| `vsd1/freq_set`, `vsd2/freq_set` | setpoint frekuensi (Hz) |
| `vsd1/current`, `vsd2/current` | arus motor (A) |
| `vsd1/volt_dc`, `vsd2/volt_dc` | tegangan DC bus (V) |
| `vsd1/volt_out`, `vsd2/volt_out` | tegangan output (V) |
| `vsd1/running`, `vsd1/fault`, `vsd1/ready` (idem `vsd2/…`) | 0 / 1 |
| `vsd1/comm_ok`, `vsd2/comm_ok` | 1 = ESP32 berhasil baca VSD |
| `vsd1/status_word`, `vsd1/err_count` (idem `vsd2/…`) | diagnosa |
| `vsd1/cmd/freq_set`, `vsd2/cmd/freq_set` | **masuk** — setpoint Hz, hanya bila `ALLOW_SETPOINT_WRITE 1` |
| `vsd1/freq_cmd`, `vsd1/cmd_ok` (idem `vsd2/…`) | echo setpoint yang dikirim + hasilnya |

Publish tiap 2 detik dan langsung saat status run/fault/comm berubah.

### Hal yang HARUS dicek di hardware
- **Alamat register** sudah dicocokkan ke manual ACS550/ACS310 dan sebagian dibuktikan dengan Modbus Poll di ACS310 (Status Word terbaca). Tetap bandingkan nilai di serial monitor dengan panel drive (par 0103/0104/0111); kalau bergeser satu parameter, ubah offset ±1 di `config.h` (masalah 0-based vs 1-based).
- Dekode status memakai profil ABB Drives (par 5305 = 0). Kalau profil DCU (5305 = 1), bit-nya berbeda.
- **Rentang blok baca** 102..110: kalau drive menolak (exception 02), serial monitor mencetak `[MB] … ditolak, pakai baca satu-satu` dan firmware lanjut jalan — bukan kegagalan fatal.
- `freq_set` = par 0111 EXT REF 1. Kalau setpoint di sistem Anda lewat EXT REF 2 (%) atau panel, sesuaikan.
- TLS: broker lokal dipakai tanpa TLS (`MQTT_USE_TLS 0`, port 1883) — lalu lintasnya tidak keluar LAN. Kalau broker nanti diberi TLS, set `MQTT_USE_TLS 1` dan port 8883.

## 2. PLC M221 (SoMachine Basic)
1. Ethernet: IP 192.168.1.20, gateway 192.168.1.1. Modbus TCP server aktif (port 502, default).
2. Program (contoh):

| Alamat | Nama | Arah | Keterangan |
|---|---|---|---|
| `%M0` | START_VSD1 | FUXA→PLC | **pulse**, 1 = perintah start |
| `%M1` | STOP_VSD1 | FUXA→PLC | **pulse**, 1 = perintah stop |
| `%M2` | START_VSD2 | FUXA→PLC | **pulse** |
| `%M3` | STOP_VSD2 | FUXA→PLC | **pulse** |
| `%MW10` | HEARTBEAT | FUXA→PLC | ditulis FUXA tiap 1 s |
| `%I0.0` | SEL_REMOTE | input | selector Local/Remote |
| `%I0.1` | ESTOP_OK | input | NC e-stop |
| `%I0.2` / `%I0.3` | VSD1/VSD2 fault relay | input | dari relay VSD (opsional) |
| `%Q0.0` | RUN_VSD1 | output | ke DI forward VSD1 |
| `%Q0.1` | RUN_VSD2 | output | ke DI forward VSD2 |

Perintah dari FUXA bersifat **pulse**: START dan STOP adalah bit terpisah. Tombol di FUXA
menulis `1` saat ditekan (mousedown) dan `0` saat dilepas (mouseup), jadi bit-nya naik
selama tombol ditahan lalu turun sendiri.

PLC memakai SET/RESET langsung ke output:

```
(* STOP ditaruh SESUDAH START supaya menang dalam satu scan *)
IF %M0 THEN SET   %Q0.0        (* START VSD1 *)
IF %M1 THEN RESET %Q0.0        (* STOP VSD1  *)
IF %M2 THEN SET   %Q0.1        (* START VSD2 *)
IF %M3 THEN RESET %Q0.1        (* STOP VSD2  *)

(* PENGAMAN: bersihkan bit perintah sendiri, jangan bergantung pada HMI *)
RESET %M0 ; RESET %M1 ; RESET %M2 ; RESET %M3

(* interlock *)
IF NOT %I0.0 OR NOT %I0.1 THEN RESET %Q0.0 ; RESET %Q0.1   (* Local / e-stop *)
IF %I0.2 THEN RESET %Q0.0                                   (* fault VSD1 *)
IF %I0.3 THEN RESET %Q0.1                                   (* fault VSD2 *)
```

> **Baris `RESET %M0..%M3` itu wajib, bukan hiasan.** Kalau browser, PC, atau jaringan mati
> di antara mousedown dan mouseup, bit perintah akan tertinggal `1`. Dengan pola SET/RESET,
> `%M0` yang terus `1` akan me-SET ulang `%Q0.0` tiap scan sehingga **STOP tidak pernah bisa
> mematikan motor**. PLC yang membersihkan bitnya sendiri menghilangkan kegagalan itu
> secara struktural — jangan menggantungkannya pada HMI.

Watchdog komunikasi: FUXA menulis `%MW10` tiap 1 s; kalau nilainya tidak berubah selama 5 s,
PLC me-reset `%Q0.0`/`%Q0.1` supaya motor berhenti saat PC atau jaringan putus.
Mode Local (selector) tetap mengutamakan operator di panel.

> **Jangan aktifkan watchdog sebelum heartbeat-nya jalan.** FUXA tidak menulis `%MW10` dengan
> sendirinya — tag-nya ada, tapi nilainya harus dinaikkan oleh *script* FUXA (Scripts → jadwal 1 s,
> `$setTag('plc_heartbeat', ($getTag('plc_heartbeat') + 1) % 32767)`). Kalau watchdog dinyalakan di PLC
> tapi script-nya belum ada, motor tidak akan pernah bisa run.

## 3. Broker MQTT (di PC ini)

Broker adalah simpul tengah arsitektur ini: ESP32 publish ke sini, FUXA dan klien remote subscribe dari sini.
**Belum terpasang** — per 1 Nov 2026 tidak ada yang listen di 1883/8883 di PC ini dan Mosquitto belum ada.

Pilihan paling sederhana: **Eclipse Mosquitto**. Yang perlu ada di `mosquitto.conf`:

```
listener 1883 0.0.0.0
allow_anonymous false
password_file C:\Program Files\mosquitto\passwd
```

- `listener 1883 0.0.0.0` — tanpa ini Mosquitto hanya mendengar di localhost dan **ESP32 tidak akan bisa masuk**.
- Buat user dengan `mosquitto_passwd -c passwd esp32`, lalu isi user/password yang sama di `firmware/include/secrets.h`.
- Buka port 1883 di Windows Firewall untuk jaringan privat.
- `MQTT_HOST` di `secrets.h` diisi **IP LAN PC ini** (`192.168.1.10`), bukan `localhost`.

PC ini harus tetap menyala: kalau broker mati, FUXA dan semua klien remote kehilangan data,
walaupun ESP32 dan PLC tetap jalan sendiri.

### Akses dari luar (PC remote / HP)
Selama semua klien ada di LAN yang sama, cukup arahkan ke `192.168.1.10:1883`.

Untuk akses dari luar jaringan, **jangan port-forward 1883 apa adanya ke internet**. Port MQTT polos
tanpa TLS berarti user dan password lewat sebagai teks biasa, dan broker yang terbuka akan discan
dalam hitungan jam — padahal topik `cmd/freq_set` di broker ini bisa mengubah kecepatan motor.
Dua jalan yang aman: VPN (WireGuard/Tailscale) sehingga HP seolah berada di LAN, atau aktifkan
TLS di Mosquitto (port 8883, sertifikat) lalu set `MQTT_USE_TLS 1` di `config.h`.

## 4. FUXA (PC lokal)
**Device 1 – MQTT (monitoring)**
- Connections → Add → *MQTT client*; URL `mqtts://<host-broker>:8883`, isi user/password.
- Tambahkan tag dengan tipe *Subscription*, topik penuh, mis. `scada/mojokerto/vsd1/freq_out`, untuk semua topik di tabel di atas.

**Device 2 – Modbus TCP (perintah)**
- Add → *Modbus TCP*; `192.168.1.20:502`, Slave ID 1 (atau 255 untuk M221).
- Tag Coil: `%M0`–`%M3` (START1, STOP1, START2, STOP2). Tag heartbeat: Holding Register `%MW10`.
  **Catatan alamat:** FUXA memakai alamat 1-based dan mengurangi 1 sebelum mengirim ke bus,
  jadi `%M0` diisi address **1**, `%M1` → **2**, `%M2` → **3**, `%M3` → **4**, `%MW10` → **11**.
- Tombol START/STOP memakai aksi *set value* = `1` ke coil masing-masing (pulse).
- Beri konfirmasi (dialog) pada tombol START/STOP di FUXA.
- Semua tag di atas sudah jadi di `fuxa/scada-mojokerto.fuxap` — tinggal import, lihat `fuxa/README.md`.

**Layar**: 2 panel (VSD1/VSD2) berisi lampu RUN/FAULT/COMM, nilai Hz out, Hz set, Arus, tombol START/STOP, indikator `gw/status`. Alarm: `fault=1`, `comm_ok=0`, `gw/status=offline`.

Menu/nama field FUXA bisa sedikit berbeda antar versi.

## Status
Firmware **sudah dikompilasi bersih** (arduino-esp32 3.3.12 — RAM 9.7%, Flash 56.7%, tanpa warning),
tapi **belum pernah dijalankan di hardware**: W5500, RS485 TX15/RX16, MQTT, dan blok baca 102..110
semuanya masih belum terbukti.

Proyek FUXA sudah jadi dan sudah diuji import ke FUXA 1.3.5 — lihat `fuxa/README.md`.
Program PLC M221 belum dibuat; ladder contohnya ada di bagian 2 di atas.
