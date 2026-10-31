# SCADA 2 VSD Schneider – Mojokerto

```
VSD1 ─┐ Modbus RTU (RS485)
VSD2 ─┴────────────────── ESP32-ETH ──LAN──┐
                                           ├── Router/Gateway ── Internet ── Broker MQTT (free tier)
PLC M221 ───────────────────────── LAN ────┤                                   │
PC FUXA ────────────────────────── LAN ────┘◄──────────── subscribe MQTT ──────┘
```

| Fungsi | Jalur |
|---|---|
| Monitoring freq out, freq setpoint, arus, run/fault/comm | VSD → ESP32 (Modbus RTU) → MQTT → FUXA |
| Perintah ON/OFF remote | FUXA → **Modbus TCP ke PLC M221** → output PLC → DI VSD (hardwired) |

ESP32 hanya **membaca** VSD (aman, tidak bisa menjalankan motor). Perintah ON/OFF tetap lewat PLC.

## IP plan (contoh, ubah sesuai LAN)
| Perangkat | IP |
|---|---|
| Router | 192.168.1.1 |
| PC FUXA | 192.168.1.10 |
| PLC M221 | 192.168.1.20 |
| ESP32 | 192.168.1.50 (static, di `config.h`) |

## 1. Firmware ESP32
Board: KhursLabs ESP32-S3 IoT Acquisition RS485-Ethernet (W5500: CS 5, MOSI 11, SCK 12, MISO 13, RST 21, INT 47; RS485 UART1 pin 17/18, dianggap auto-direction). Pin dibaca dari silkscreen board, belum diuji. Folder: `firmware/` (PlatformIO, platform pioarduino / arduino-esp32 3.x). Ubah dulu:
1. `include/secrets.h` → host/user/password broker MQTT.
2. `include/config.h` → IP, baud (`MB_BAUD` harus sama dengan par 5303 drive), slave ID VSD, alamat register. Kalau RS485 tidak ada balasan, tukar `RS485_TX_PIN`/`RS485_RX_PIN`.

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
| 5303 EFB BAUD RATE | 19.2 kbps |
| 5304 EFB PARITY | 0 = 8 NONE 1 (default pabrik 1 = 8N2, harus diubah) |
| 5305 EFB CTRL PROFILE | ABB DRV LIM/FULL (profil ABB Drives) |

- Setelah ganti 9802, power-cycle / tunggu EFB restart. Cek par 5306–5309 (EFB OK/ERR frames) naik saat polling jalan.
- Start/stop dan referensi tetap lewat terminal/PLC (par 1001 dll), Modbus hanya dibaca.

Register yang dibaca (`config.h`): Status Word `40004`, par 0103 OUTPUT FREQ (`40103`), par 0104 CURRENT (`40104`), par 0111 EXT REF 1 (`40111`). Alamat PDU = nomor − 40001 (jadi 3, 102, 103, 110). Bit status: RDY_REF = run, TRIPPED = fault.

### Topik MQTT (payload angka/teks biasa, retained)
Basis: `scada/mojokerto`

| Topik | Isi |
|---|---|
| `gw/status` | `online` / `offline` (LWT) |
| `gw/ip`, `gw/uptime` | IP ESP32, uptime detik |
| `vsd1/freq_out`, `vsd2/freq_out` | frekuensi output (Hz) |
| `vsd1/freq_set`, `vsd2/freq_set` | setpoint frekuensi (Hz) |
| `vsd1/current`, `vsd2/current` | arus motor (A) |
| `vsd1/volt_dc`, `vsd1/volt_out` | tegangan DC bus / output (V) |
| `vsd1/running`, `vsd1/fault`, `vsd1/ready` | 0 / 1 |
| `vsd1/comm_ok` | 1 = ESP32 berhasil baca VSD |
| `vsd1/status_word`, `vsd1/err_count` | diagnosa |

Publish tiap 2 detik dan langsung saat status run/fault/comm berubah.

### Hal yang HARUS dicek (belum bisa saya verifikasi tanpa tipe VSD)
- **Alamat register ACS550** saya tulis dari ingatan manual ACS550 (EFB), belum dicocokkan. Uji dengan membandingkan nilai di serial monitor dengan panel drive (par 0103/0104/0111). Kalau bergeser satu parameter, ubah offset ±1 di `config.h` (masalah 0-based vs 1-based).
- Dekode status memakai profil ABB Drives (par 5305). Kalau profil DCU, bit-nya berbeda.
- `freq_set` = par 0111 EXT REF 1. Kalau setpoint di sistem Anda lewat EXT REF 2 (%) atau panel, sesuaikan.
- TLS: default `MQTT_TLS_INSECURE=1` (terenkripsi, tapi sertifikat broker tidak diverifikasi). Untuk produksi tempel root CA broker dan matikan flag itu.

## 2. PLC M221 (SoMachine Basic)
1. Ethernet: IP 192.168.1.20, gateway 192.168.1.1. Modbus TCP server aktif (port 502, default).
2. Program (contoh):

| Alamat | Nama | Arah | Keterangan |
|---|---|---|---|
| `%M0` | CMD_VSD1_RUN | FUXA→PLC | 1 = run, 0 = stop |
| `%M1` | CMD_VSD2_RUN | FUXA→PLC | |
| `%I0.0` | SEL_REMOTE | input | selector Local/Remote |
| `%I0.1` | ESTOP_OK | input | NC e-stop |
| `%I0.2` / `%I0.3` | VSD1/VSD2 fault relay | input | dari relay VSD (opsional) |
| `%Q0.0` | RUN_VSD1 | output | ke DI forward VSD1 |
| `%Q0.1` | RUN_VSD2 | output | ke DI forward VSD2 |

```
%Q0.0 := %M0 AND %I0.0 AND %I0.1 AND NOT %I0.2
%Q0.1 := %M1 AND %I0.0 AND %I0.1 AND NOT %I0.3
```
Tambahkan watchdog komunikasi (mis. FUXA menulis `%MW10` heartbeat tiap 1 s; timeout 5 s → reset `%M0/%M1`) supaya motor stop bila PC/jaringan putus. Mode Local (selector) tetap mengutamakan operator di panel.

## 3. FUXA (PC lokal)
**Device 1 – MQTT (monitoring)**
- Connections → Add → *MQTT client*; URL `mqtts://<host-broker>:8883`, isi user/password.
- Tambahkan tag dengan tipe *Subscription*, topik penuh, mis. `scada/mojokerto/vsd1/freq_out`, untuk semua topik di tabel di atas.

**Device 2 – Modbus TCP (perintah)**
- Add → *Modbus TCP*; `192.168.1.20:502`, Slave ID 1 (atau 255 untuk M221).
- Tag `CMD_VSD1_RUN`: Coil, address 0 (`%M0`); `CMD_VSD2_RUN`: Coil, address 1 (`%M1`). Tag heartbeat: Holding Register address 10 (`%MW10`).
- Beri konfirmasi (dialog) pada tombol START/STOP di FUXA.

**Layar**: 2 panel (VSD1/VSD2) berisi lampu RUN/FAULT/COMM, nilai Hz out, Hz set, Arus, tombol START/STOP, indikator `gw/status`. Alarm: `fault=1`, `comm_ok=0`, `gw/status=offline`.

Menu/nama field FUXA bisa sedikit berbeda antar versi.

## Status
Firmware **belum dikompilasi/diuji** (PlatformIO belum terpasang di PC ini, dan belum ada hardware). Proyek FUXA (.json) belum dibuat, menunggu tag tersambung supaya bisa diverifikasi.
