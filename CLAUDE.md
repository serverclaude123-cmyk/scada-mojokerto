# SCADA Mojokerto – 2 VSD ABB via ESP32, MQTT, FUXA

Bahasa kerja: Indonesia. Proyek dikerjakan bergantian di PC Windows (hari kerja) dan Mac mini (Sabtu–Minggu).
Percakapan Claude tidak ikut pindah komputer; file ini adalah catatan serah-terima. Perbarui bagian "Status" setiap selesai sesi.

## Arsitektur
- VSD ×2 (target ABB ACS550; untuk tes dipakai ACS310) –Modbus RTU RS485– ESP32 (hanya MEMBACA) –LAN– router/gateway –Internet– broker MQTT free tier (HiveMQ Cloud/EMQX Serverless, TLS 8883).
- PLC M221 (LAN, Modbus TCP server) mengirim ON/OFF ke VSD lewat output hardwired. FUXA (PC lokal) subscribe MQTT untuk monitoring dan menulis coil ke PLC untuk perintah remote.
- Detail wiring, parameter drive, topik MQTT, program PLC, setup FUXA: lihat `README.md`. PDF seting drive: `docs/Setting_VSD_ACS550_Modbus.pdf`, `docs/Setting_VSD_ACS310_Modbus_TEST.pdf`.
- Gambar arsitektur + wiring RS485 + jalur perintah PLC: `docs/arsitektur-wiring.html` (buka di browser, bisa di-print A3).
- Proyek FUXA siap import: `fuxa/scada-mojokerto.fuxap`, dibuat oleh `fuxa/make_project.py`. Lihat `fuxa/README.md`.
  Sudah diuji import ke FUXA 1.3.5: kedua device dimuat tanpa error, view ter-render, alarm masuk.
  Empat jebakan yang sudah ketemu dan terpakai di generator: (1) driver Modbus tidak ikut paket npm,
  harus pasang plugin `modbus-serial`; (2) `memaddress` coil harus `'000000'`, bukan `'0'`;
  (3) tombol butuh `<foreignObject>` + `<BUTTON id="B-<gid>">`, `<rect>` saja tampil tanpa teks;
  (4) nama event memakai bentuk PENDEK (`mousedown`, `onSetValue`) — bentuk `shapes.event-*` di
  `hmi.ts` master belum dirilis dan membuat event mati diam-diam di 1.3.5.
  Cara memastikan format apa pun di FUXA: atur lewat editor, lalu baca `GET /api/project`.
- Tombol START/STOP = momentary: `mousedown` tulis 1, `mouseup` tulis 0. PLC tetap wajib
  `RESET %M0..%M3` sendiri; kalau browser mati di tengah tekanan, bit tertinggal 1 dan
  dengan pola SET/RESET itu bikin STOP tidak pernah bisa mematikan motor.

## Hardware ESP32
KhursLabs "ESP32-S3 IoT Acquisition RS485 Modbus-Ethernet" (ESP32-S3-WROOM-1 + modul W5500 Lite).
Pin dari silkscreen board (belum dikonfirmasi ke dokumentasi vendor, tidak ada dokumentasi online):
- W5500: CS 5, MOSI 11, SCK 12, MISO 13, RST 21, INT 47 (SPI sama dengan slot TF card).
- RS485 transceiver: **TX 15 / RX 16** di UART1, dari contoh resmi KhursLabs `Test_sht20_RS485.ino`
  (`rxPin = 16 // RX2`, `txPin = 15 // TX2`, `HardwareSerial modul(1)`, 9600 8N1).
  Terminal sekrup "SERIAL 1" (17/18) di casing adalah breakout UART TTL yang TERPISAH, bukan jalur RS485 —
  asumsi lama yang memakai 17/18 untuk RS485 itu keliru dan tidak akan pernah dapat balasan.
  Contoh vendor tidak menggerakkan DE/RE sama sekali -> transceiver auto-direction (`RS485_DE_PIN = -1`), terkonfirmasi.
  Hati-hati: komentar header di file contoh itu salah (menulis RX 18 / TX 19 / RTS 14); percayai kodenya, bukan komentarnya.
- Terminal lain: I2C SDA/SCL, ADC A0–A3, digital 14/38.

## Firmware (`firmware/`, PlatformIO, platform pioarduino = arduino-esp32 3.x)
- `include/config.h`: pin, IP statis (192.168.1.50), baud (`MB_BAUD`, harus sama dengan par 5303 drive), alamat register, topik MQTT.
- `include/secrets.h`: tidak ada di Git. Salin dari `secrets.example.h` dan isi data broker.
- Alamat register (PDU, 0-based = nomor 4xxxx − 40001), terverifikasi di manual ACS550/ACS310 dan sebagian dengan Modbus Poll di ACS310:
  Status Word 40004→3, par 0103 freq out→102, 0104 arus→103, 0107 DC bus→106, 0109 volt out→108, 0111 EXT REF1 (0,1 Hz)→110.
- Bit Status Word (profil ABB, 5305 = ABB DRV LIM): bit0 RDY_ON, bit1 RDY_RUN, bit2 RDY_REF (run), bit3 TRIPPED.
- Referensi frekuensi via Modbus: tulis register 40002 (alamat 1, FC06); 20000 = par 1105 REF1 MAX; butuh par 1103 = 8 (COMM) dan panel REM.
  Sudah diimplementasikan di firmware tapi **default MATI** (`ALLOW_SETPOINT_WRITE 0`). Saat diaktifkan, perintah masuk lewat MQTT
  `scada/mojokerto/vsdN/cmd/freq_set` (publish tanpa retained), ditulis di `pollAll()` bukan di callback MQTT, dan di-clamp
  ke `REF_CLAMP_MIN_HZ`…`REF_CLAMP_MAX_HZ`. Ada `#error` kalau `REG_REF1` sampai 0 (itu Control Word 40001).
- Par 0103..0111 dibaca satu FC03 (`MB_BLOCK_READ 1`, alamat 102 × 9 register). Kalau drive menolak rentangnya,
  firmware otomatis balik ke pembacaan satu-satu dan mencetak `[MB] … ditolak` di serial monitor.
- Build: `cd firmware && pio run` (Mac: `brew install platformio`; Windows: Python + `pip install platformio`).
  Di Windows PC kantor unduhan lambat/DNS bermasalah; set `PLATFORMIO_DEFAULT_REQUESTS_TIMEOUT=300`.
- Toolchain di PC Windows ini (tanpa hak admin, MSI per-user diblokir 0x80070003):
  Git portable `C:\Users\AIOPC\PortableGit`, Python standalone `C:\Users\AIOPC\Tools\python` (python-build-standalone 3.12.16),
  PlatformIO 6.2.0 via `pip`. Ketiganya sudah masuk PATH user. Core yang terpasang: espressif32@55.3.312 / arduino-esp32 3.3.12.
  DNS `github.com` di jaringan ini memang putus-putus (unduhan core libs pernah mandek di 0 byte lalu
  gagal `getaddrinfo failed`). Kalau terulang: unduh file-nya manual dengan `curl -L -C - --retry 20`
  ke `<core>/.cache/downloads/<sha1(url)>` — PlatformIO menamai cache dengan `sha1(url + checksum)`
  dan langsung memakainya tanpa menyentuh GitHub lagi.
- **Core PlatformIO dipindah ke `C:\pio`** (`PLATFORMIO_CORE_DIR` di env user), BUKAN `~/.platformio`.
  Sebabnya batas 260 karakter path Windows: `esp32-arduino-libs/esp32c5/include/espressif__esp_matter/
  connectedhomeip/connectedhomeip/src/app/clusters/camera-av-settings-user-level-management-server/...`
  sudah pas 260 karakter dari `C:\Users\AIOPC\.platformio`, jadi unpack gagal dengan `FileNotFoundError`.
  Long path di registry butuh admin (tidak ada di PC ini), jadi jalan keluarnya memperpendek akar path.
  Jangan dikembalikan ke `~/.platformio` di Windows.
- FUXA untuk uji coba di PC ini: Node 22 portable `C:\Users\AIOPC\Tools\node-v22.23.4-win-x64`,
  FUXA via `npm i -g @frangoteam/fuxa` di `C:\Users\AIOPC\Tools\npm-global`, dijalankan lewat
  `C:\Users\AIOPC\Tools\start-fuxa.cmd` (skrip ini mengisi PATH supaya FUXA bisa memanggil `npm`
  saat memasang plugin). Buka http://localhost:1881.

## Temuan penting soal drive (dari sesi tes)
- ACS310: parameter group 53 baru terlihat bila `1611 PARAMETER VIEW = 3 (LONG VIEW)`.
- Setting minimum komunikasi: 9802 = STD MODBUS (set dulu), 5302 = ID, 5303 = baud, 5304 = 8 NONE 1, 5305 = ABB DRV LIM/FULL (5305 = 1 adalah DCU, bukan ABB), 3018 = NOT SEL.
- Default pabrik 5304 di ACS550 = 8N2 (bukan 8N1). Pilih berdasarkan nama di panel.
- Polaritas ACS310: terminal 24 = B(+), 25 = A(−), 26 = GND_A; jumper J701 = terminasi. ACS550: X1:29 = B(+), 30 = A(−), 31 = AGND, DIP J2 = terminasi.
- Pada ACS310 tes, parameter (5303, 1611) kembali ke default setelah daya dimatikan; penyebabnya belum ditemukan (1602/1607 tidak sempat dicek).
- 1104 REF1 MIN dan 1105 REF1 MAX ber-resolusi 0,1 Hz (500 = 50,0 Hz). Pernah 1105 tertulis 250 lewat Modbus (address 1104 = par 1105).
- Modbus Poll (Windows) alamat zero-based; jangan centang "PLC Addresses (Base 1)".

## Status (ubah tiap sesi)
- [x] Firmware ditulis untuk board KhursLabs, ditambah tegangan DC/output.
- [x] Komunikasi Modbus RTU ACS310 ↔ Modbus Poll terbukti jalan (Status Word terbaca).
- [x] **Firmware KOMPILASI BERSIH** (31 Okt 2026, PC Windows): espressif32@55.3.312 / arduino-esp32 3.3.12,
      RAM 9.7% (31908 B), Flash 56.7% (742970 B), tanpa warning. `ETH.begin(ETH_PHY_W5500, ..., SPI3_HOST, ...)`
      ternyata cocok dengan API 3.x — hanya terbukti meng-compile, belum pernah jalan di board.
- [x] Baca par 0103..0111 dalam satu FC03 + fallback otomatis; jalur tulis REFERENCE 1 ditulis (default MATI).
- [x] Proyek FUXA dibuat dan diuji import ke FUXA 1.3.5.
- [ ] Tes tulis setpoint via 40002 (1103 = 8, 1104 = 0, 1105 = 250 saat tes terakhir) — kode siap,
      aktifkan `ALLOW_SETPOINT_WRITE 1` saat mau dites.
- [ ] Belum diuji di hardware sama sekali: W5500, RS485 TX15/RX16, MQTT, dan blok baca 102..110.
- [ ] Program PLC M221 belum dibuat (ladder contoh SET/RESET ada di README.md).
- [ ] FUXA: tombol momentary baru terverifikasi sampai sisi server (`setValue` 1 lalu 0);
      frame di kabel belum dicek dengan alat yang bisa dipercaya.
- Manual vendor (tidak di Git): ACS550 `EN_ACS550_01_UM_H_A4.pdf`, ACS310 `EN_ACS310_UM_D_A4.pdf` (ada di D:\DOWNLOAD di PC kantor). Salin ke `docs/manual/` (di-ignore Git).
