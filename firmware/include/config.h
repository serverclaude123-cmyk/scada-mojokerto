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
#define W5500_INT_PIN      47

// IP: 1 = static, 0 = DHCP
#define USE_STATIC_IP      1
#define STATIC_IP          192, 168, 1, 50
#define STATIC_GW          192, 168, 1, 1
#define STATIC_MASK        255, 255, 255, 0
#define STATIC_DNS         8, 8, 8, 8

// ---------- RS485 / Modbus RTU ----------
// Silkscreen "SERIAL 1": 17 dan 18. Urutan TX/RX belum terkonfirmasi; kalau tidak ada balasan, tukar.
// Tidak ada label DE/RE di board -> dianggap auto-direction (-1).
#define RS485_TX_PIN       17
#define RS485_RX_PIN       18
#define RS485_DE_PIN       -1
#define MB_BAUD            9600        // samakan dengan par 5303 drive (default 9.6 kbit/s)
#define MB_FORMAT          SERIAL_8N1  // samakan dengan par 5303 (baud) & 5304 (parity) ACS550
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
#define REG_ETA            3           // 40004 Status Word (profil ABB Drives, par 5305=0)
#define REG_RFR            102         // par 0103 OUTPUT FREQ, 0.1 Hz
#define REG_LCR            103         // par 0104 CURRENT, 0.1 A
#define REG_SETPOINT       110         // par 0111 EXT REF 1 (Hz), 0.1 Hz

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
#define MQTT_PORT_CFG      8883
#define MQTT_USE_TLS       1
#define MQTT_TLS_INSECURE  1           // 1 = terenkripsi tapi sertifikat server tidak diverifikasi
#define MQTT_BASE_TOPIC    "scada/mojokerto"
#define MQTT_PUBLISH_MS    2000
#define MQTT_RETAIN        1
