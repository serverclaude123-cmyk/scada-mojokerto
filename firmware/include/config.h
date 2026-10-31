#pragma once
// ============================================================
//  KONFIGURASI -- sesuaikan dengan hardware & jaringan
// ============================================================

// ---------- Ethernet: W5500 (SPI) -- pinout dari silkscreen board KhursLabs ----------
#define W5500_CS_PIN       5
#define W5500_MOSI_PIN     11
#define W5500_SCK_PIN      12
#define W5500_MISO_PIN     13
#define W5500_RST_PIN      21
// INT 47 dibaca dari silkscreen tapi BELUM terbukti. Kalau pin IRQ salah,
// link tetap terdeteksi (itu register SPI) tapi paket masuk tidak pernah
// diproses -> DHCP diam dan ARP tidak dibalas. Isi -1 untuk mode polling,
// yang tidak bergantung pada pin IRQ sama sekali.
#define W5500_INT_PIN      -1
// Kecepatan SPI ke W5500. Default core arduino-esp32 adalah 20 MHz dan itu
// terlalu cepat untuk modul ini: PHY tetap melaporkan link=yes tapi paket rusak,
// sehingga DHCP tidak pernah dapat jawaban dan ARP tidak dibalas.
#define W5500_SPI_MHZ      8

// IP: 1 = static, 0 = DHCP
#define USE_STATIC_IP      0
#define STATIC_IP          192, 168, 1, 50
#define STATIC_GW          192, 168, 1, 1
#define STATIC_MASK        255, 255, 255, 0
#define STATIC_DNS         8, 8, 8, 8

// ---------- RS485 / Modbus RTU ----------
// Pin diambil dari contoh resmi KhursLabs (Test_sht20_RS485.ino):
//   const byte rxPin = 16; // RX2
//   const byte txPin = 15; // TX2
//   HardwareSerial modul(1);  ->  UART1, sama dengan Serial1 di sini
// CATATAN: komentar header di file contoh itu SALAH (menulis RX 18 / TX 19 / RTS 14);
// yang benar adalah angka di kodenya. Terminal sekrup berlabel "SERIAL 1" (17/18) di
// casing adalah breakout UART TTL yang TERPISAH, bukan jalur ke transceiver RS485 --
// itulah sebabnya konfigurasi 17/18 yang lama tidak pernah dapat balasan.
// Kalau tetap tidak ada balasan, coba TX 17 (pernah disebut 16/17 saat tes di toko).
#define RS485_TX_PIN       15
#define RS485_RX_PIN       16
// Contoh vendor tidak pernah menggerakkan pin DE/RE -> transceiver auto-direction.
#define RS485_DE_PIN       -1
#define MB_BAUD            19200       // par 5303 drive = 19.2 kbps (dikonfirmasi di lapangan, bukan default pabrik 9.6k)
#define MB_FORMAT          SERIAL_8N1  // samakan dengan par 5304 = 0 (8 NONE 1); default pabrik ACS550 = 8N2
#define MB_TIMEOUT_MS      300
#define MB_FRAME_GAP_MS    5

// ---------- VSD ----------
#define VSD_COUNT          2
static const uint8_t VSD_SLAVE_ID[VSD_COUNT]   = {1, 2};
static const char*   VSD_NAME[VSD_COUNT]       = {"vsd1", "vsd2"};

#define REG_VDC            106         // par 0107 DC BUS VOLTAGE, 1 V
#define REG_VOUT           108         // par 0109 OUTPUT VOLTAGE, 1 V
// ABB ACS550/ACS310 (EFB on-board). Alamat PDU 0-based = nomor register 4xxxx - 40001.
// Parameter drive NNNN dibaca di register 4NNNN -> alamat PDU = NNNN - 1.
// Kalau nilai terbaca bergeser 1 parameter, tambah/kurangi 1 (beda master 0-based vs 1-based).
// Isi 0 untuk menonaktifkan pembacaan.
#define REG_ETA            3           // 40004 Status Word (profil ABB Drives: par 5305 = 0 ABB DRV LIM)
#define REG_RFR            102         // par 0103 OUTPUT FREQ, 0.1 Hz
#define REG_LCR            103         // par 0104 CURRENT, 0.1 A
#define REG_SETPOINT       110         // par 0111 EXT REF 1 (Hz), 0.1 Hz

// ---------- Blok baca (hemat transaksi RS485) ----------
// Satu FC03 mengambil par 0103..0111 sekaligus (alamat 102..110) = 1 transaksi,
// bukan 5. Status Word (alamat 3) tetap dibaca terpisah.
// Kalau drive menolak rentang ini (exception 02 ILLEGAL DATA ADDRESS), firmware
// otomatis jatuh kembali ke pembacaan satu-satu; set 0 untuk mematikannya.
#define MB_BLOCK_READ      1
#define REG_BLOCK_START    102
#define REG_BLOCK_COUNT    9           // 102..110

// ---------- Tulis setpoint frekuensi (OPSIONAL, default MATI) ----------
// AKTIF: sesuai arsitektur, setpoint frekuensi memang dikirim ESP32 lewat Modbus.
// Yang ditulis hanya REFERENCE 1 -- BUKAN Control Word (40001) -- jadi ESP32 tetap
// tidak bisa start/stop motor. ON/OFF tetap sepenuhnya lewat PLC M221.
// Prasyarat di drive: par 1103 REF1 SELECT = 8 (COMM) dan panel pada mode REM.
// Isi 0 kalau mau sementara mengembalikan firmware ke murni read-only.
#define ALLOW_SETPOINT_WRITE 1
#define REG_REF1            1          // 40002 REFERENCE 1 (jangan pernah 0 = Control Word)
#define REF1_SCALE_MAX      20000      // 20000 = par 1105 REF1 MAX
#define REF1_MAX_HZ         50.0f      // isi sesuai par 1105 di drive (resolusi 0,1 Hz: 500 = 50,0 Hz)
#define REF_CLAMP_MIN_HZ    0.0f       // batas bawah yang diterima dari MQTT
#define REF_CLAMP_MAX_HZ    50.0f      // batas atas yang diterima dari MQTT

// Bit Status Word ABB Drives profile
#define SW_RDY_ON          0x0001
#define SW_RDY_RUN         0x0002
#define SW_RDY_REF         0x0004      // running / operation enabled
#define SW_TRIPPED         0x0008
#define FREQ_SCALE         10.0f
#define CURRENT_SCALE      10.0f

#define POLL_INTERVAL_MS   500         // siklus polling semua VSD
#define OFFLINE_AFTER_FAILS 3
#define OFFLINE_RETRY_MS   5000

// ---------- MQTT ----------
// Broker ada di PC lokal (PC FUXA, 192.168.1.10), bukan lagi cloud free tier.
// Jadi default-nya plain 1883 tanpa TLS -- lalu lintasnya tidak keluar LAN.
// Kalau broker nanti dipasang dengan TLS, set MQTT_USE_TLS 1 dan port 8883.
#define MQTT_PORT_CFG      1883
#define MQTT_USE_TLS       0
#define MQTT_TLS_INSECURE  1           // hanya dipakai kalau MQTT_USE_TLS = 1
#define MQTT_BASE_TOPIC    "scada/mojokerto"
#define MQTT_PUBLISH_MS    2000
#define MQTT_RETAIN        1
// Topik perintah setpoint: <base>/<vsd>/cmd/freq_set, mis. scada/mojokerto/vsd1/cmd/freq_set.
// Publish TANPA retained -- perintah retained akan dipakai ulang tiap ESP32 reconnect.
#define MQTT_CMD_SUFFIX    "cmd/freq_set"

// ---------- Pagar keamanan waktu kompilasi ----------
#if ALLOW_SETPOINT_WRITE && REG_REF1 == 0
#error "REG_REF1 = 0 adalah Control Word (40001). Menulis ke sana bisa menjalankan motor."
#endif
