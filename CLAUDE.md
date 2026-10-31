# SCADA Mojokerto – 2 VSD ABB via ESP32, MQTT, FUXA

Bahasa kerja: Indonesia. Proyek dikerjakan bergantian di PC Windows (hari kerja) dan Mac mini (Sabtu–Minggu).
Percakapan Claude tidak ikut pindah komputer; file ini adalah catatan serah-terima. Perbarui bagian "Status" setiap selesai sesi.

## Arsitektur
- VSD ×2 (target ABB ACS550; untuk tes dipakai ACS310) –Modbus RTU RS485– ESP32 (hanya MEMBACA) –LAN– router/gateway –Internet– broker MQTT free tier (HiveMQ Cloud/EMQX Serverless, TLS 8883).
- PLC M221 (LAN, Modbus TCP server) mengirim ON/OFF ke VSD lewat output hardwired. FUXA (PC lokal) subscribe MQTT untuk monitoring dan menulis coil ke PLC untuk perintah remote.
- Detail wiring, parameter drive, topik MQTT, program PLC, setup FUXA: lihat `README.md`. PDF seting drive: `docs/Setting_VSD_ACS550_Modbus.pdf`, `docs/Setting_VSD_ACS310_Modbus_TEST.pdf`.

## Hardware ESP32
KhursLabs "ESP32-S3 IoT Acquisition RS485 Modbus-Ethernet" (ESP32-S3-WROOM-1 + modul W5500 Lite).
Pin dari silkscreen board (belum dikonfirmasi ke dokumentasi vendor, tidak ada dokumentasi online):
- W5500: CS 5, MOSI 11, SCK 12, MISO 13, RST 21, INT 47 (SPI sama dengan slot TF card).
- RS485 "SERIAL 1": pin 17 dan 18 -> dipakai TX 17 / RX 18 (urutan belum terbukti; tukar di `config.h` bila tak ada balasan). Tanpa label DE/RE -> dianggap auto-direction (`RS485_DE_PIN = -1`).
- Terminal lain: I2C SDA/SCL, ADC A0–A3, digital 14/38.

## Firmware (`firmware/`, PlatformIO, platform pioarduino = arduino-esp32 3.x)
- `include/config.h`: pin, IP statis (192.168.1.50), baud (`MB_BAUD`, harus sama dengan par 5303 drive), alamat register, topik MQTT.
- `include/secrets.h`: tidak ada di Git. Salin dari `secrets.example.h` dan isi data broker.
- Alamat register (PDU, 0-based = nomor 4xxxx − 40001), terverifikasi di manual ACS550/ACS310 dan sebagian dengan Modbus Poll di ACS310:
  Status Word 40004→3, par 0103 freq out→102, 0104 arus→103, 0107 DC bus→106, 0109 volt out→108, 0111 EXT REF1 (0,1 Hz)→110.
- Bit Status Word (profil ABB, 5305 = ABB DRV LIM): bit0 RDY_ON, bit1 RDY_RUN, bit2 RDY_REF (run), bit3 TRIPPED.
- Referensi frekuensi via Modbus: tulis register 40002 (alamat 1, FC06); 20000 = par 1105 REF1 MAX; butuh par 1103 = 8 (COMM) dan panel REM.
- Build: `cd firmware && pio run` (Mac: `brew install platformio`; Windows: Python + `pip install platformio`).
  Di Windows PC kantor unduhan lambat/DNS bermasalah; set `PLATFORMIO_DEFAULT_REQUESTS_TIMEOUT=300`.

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
- [ ] Tes tulis setpoint via 40002 (1103 = 8, 1104 = 0, 1105 = 250 saat tes terakhir).
- [ ] Firmware BELUM berhasil dikompilasi (unduhan core Arduino gagal: DNS `github.com` di PC kantor). Pemanggilan `ETH.begin(ETH_PHY_W5500, ...)` belum teruji.
- [ ] Belum diuji di hardware: W5500, RS485 pin 17/18, MQTT.
- [ ] Program PLC M221 dan proyek FUXA belum dibuat (panduan ada di README.md).
- Manual vendor (tidak di Git): ACS550 `EN_ACS550_01_UM_H_A4.pdf`, ACS310 `EN_ACS310_UM_D_A4.pdf` (ada di D:\DOWNLOAD di PC kantor). Salin ke `docs/manual/` (di-ignore Git).
