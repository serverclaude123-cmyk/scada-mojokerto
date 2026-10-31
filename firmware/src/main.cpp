// ESP32 gateway: 2x VSD ABB ACS550/ACS310 (Modbus RTU) -> MQTT
// Default read-only. Tulis REFERENCE 1 hanya aktif bila ALLOW_SETPOINT_WRITE = 1 di config.h.
#include <Arduino.h>
#include <ETH.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include "config.h"
#include "secrets.h"

// ---------------------------------------------------------------- Modbus RTU
static HardwareSerial& RS485 = Serial1;

static uint16_t crc16(const uint8_t* d, size_t n) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < n; i++) {
    crc ^= d[i];
    for (int b = 0; b < 8; b++) crc = (crc & 1) ? (crc >> 1) ^ 0xA001 : crc >> 1;
  }
  return crc;
}

static void mbSend(uint8_t* req, size_t n) {
  while (RS485.available()) RS485.read();
#if RS485_DE_PIN >= 0
  digitalWrite(RS485_DE_PIN, HIGH);
#endif
  RS485.write(req, n);
  RS485.flush();
#if RS485_DE_PIN >= 0
  digitalWrite(RS485_DE_PIN, LOW);
#endif
}

// Kumpulkan `need` byte balasan. Return jumlah byte yang masuk.
// `need` dipendekkan ke 5 kalau drive membalas frame exception.
static size_t mbRecv(uint8_t* buf, size_t cap, size_t need) {
  size_t n = 0;
  uint32_t t0 = millis();
  while (millis() - t0 < MB_TIMEOUT_MS && n < need) {
    while (RS485.available() && n < cap) {
      buf[n++] = RS485.read();
      if (n == 2 && (buf[1] & 0x80)) need = 5;  // frame exception
    }
    delay(1);
  }
  delay(MB_FRAME_GAP_MS);
  return n;
}

// Baca `count` holding register (FC03). Return true kalau sukses.
static bool mbReadRegs(uint8_t slave, uint16_t addr, uint8_t count, uint16_t* out) {
  uint8_t req[8] = {slave, 0x03, (uint8_t)(addr >> 8), (uint8_t)addr,
                    (uint8_t)(count >> 8), count, 0, 0};
  uint16_t c = crc16(req, 6);
  req[6] = c & 0xFF;
  req[7] = c >> 8;
  mbSend(req, sizeof(req));

  uint8_t buf[5 + 2 * REG_BLOCK_COUNT];
  size_t need = 5 + 2 * (size_t)count;       // id + fc + len + data + crc2
  if (need > sizeof(buf)) return false;
  size_t n = mbRecv(buf, sizeof(buf), need);
  if (n < 5) return false;
  if (buf[1] & 0x80) return false;           // exception -> biar pemanggil yang fallback
  if (n < need) return false;
  uint16_t rc = crc16(buf, need - 2);
  if (buf[need - 2] != (rc & 0xFF) || buf[need - 1] != (rc >> 8)) return false;
  if (buf[0] != slave || buf[1] != 0x03 || buf[2] != 2 * count) return false;
  for (uint8_t i = 0; i < count; i++) out[i] = ((uint16_t)buf[3 + 2 * i] << 8) | buf[4 + 2 * i];
  return true;
}

static bool mbReadReg(uint8_t slave, uint16_t addr, uint16_t& value) {
  return mbReadRegs(slave, addr, 1, &value);
}

#if ALLOW_SETPOINT_WRITE
// Tulis 1 holding register (FC06). Balasan drive menggemakan request (8 byte).
static bool mbWriteReg(uint8_t slave, uint16_t addr, uint16_t value) {
  uint8_t req[8] = {slave, 0x06, (uint8_t)(addr >> 8), (uint8_t)addr,
                    (uint8_t)(value >> 8), (uint8_t)value, 0, 0};
  uint16_t c = crc16(req, 6);
  req[6] = c & 0xFF;
  req[7] = c >> 8;
  mbSend(req, sizeof(req));

  uint8_t buf[8];
  size_t n = mbRecv(buf, sizeof(buf), 8);
  if (n < 5 || (buf[1] & 0x80)) return false;
  if (n < 8) return false;
  uint16_t rc = crc16(buf, 6);
  if (buf[6] != (rc & 0xFF) || buf[7] != (rc >> 8)) return false;
  return buf[0] == slave && buf[1] == 0x06 &&
         buf[2] == req[2] && buf[3] == req[3] && buf[4] == req[4] && buf[5] == req[5];
}
#endif

// ---------------------------------------------------------------- State VSD
struct Vsd {
  bool online = false;
  uint8_t fails = 0;
  uint32_t lastTry = 0;
  uint16_t eta = 0;
  float freqOut = 0, freqSet = 0, current = 0, voltDc = 0, voltOut = 0;
  bool running = false, fault = false, ready = false;
  uint32_t okCount = 0, errCount = 0;
  bool useBlock = MB_BLOCK_READ;  // dimatikan sendiri kalau drive menolak rentangnya
  uint8_t blockFails = 0;
#if ALLOW_SETPOINT_WRITE
  volatile bool cmdPending = false;
  volatile float cmdHz = 0;
  float cmdApplied = 0;
  bool cmdOk = false;
#endif
};
static Vsd vsd[VSD_COUNT];
static bool dirty = true;  // ada perubahan state penting -> publish segera

// Ambil 1 register dari hasil baca blok; false kalau alamatnya di luar blok.
static bool blkGet(const uint16_t* blk, int reg, uint16_t& out) {
  if (!reg) return false;
  int i = reg - REG_BLOCK_START;
  if (i < 0 || i >= REG_BLOCK_COUNT) return false;
  out = blk[i];
  return true;
}

static void applyMeas(Vsd& v, int reg, uint16_t r) {
  if (reg == REG_RFR)           v.freqOut = (int16_t)r / FREQ_SCALE;
  else if (reg == REG_SETPOINT) v.freqSet = (int16_t)r / FREQ_SCALE;
  else if (reg == REG_LCR)      v.current = r / CURRENT_SCALE;
  else if (reg == REG_VDC)      v.voltDc  = r;
  else if (reg == REG_VOUT)     v.voltOut = r;
}

static void readMeas(Vsd& v, uint8_t id) {
  static const int regs[] = {REG_RFR, REG_SETPOINT, REG_LCR, REG_VDC, REG_VOUT};

  if (v.useBlock) {
    uint16_t blk[REG_BLOCK_COUNT];
    if (mbReadRegs(id, REG_BLOCK_START, REG_BLOCK_COUNT, blk)) {
      v.blockFails = 0;
      bool any = false;
      for (int reg : regs) {
        uint16_t r;
        if (blkGet(blk, reg, r)) { applyMeas(v, reg, r); any = true; }
      }
      if (any) return;      // semua alamat ada di dalam blok -> selesai
      v.useBlock = false;   // blok tidak memuat satu pun REG_* -> tidak ada gunanya
      Serial.println("[MB] blok tidak memuat register yang dipakai, pakai baca satu-satu");
    } else if (++v.blockFails >= 2) {
      v.useBlock = false;
      Serial.printf("[MB] id=%u blok %u+%u ditolak, pakai baca satu-satu\n",
                    id, (unsigned)REG_BLOCK_START, (unsigned)REG_BLOCK_COUNT);
    }
  }

  for (int reg : regs) {
    uint16_t r;
    if (reg && mbReadReg(id, reg, r)) applyMeas(v, reg, r);
  }
}

static void pollVsd(int i) {
  Vsd& v = vsd[i];
  uint8_t id = VSD_SLAVE_ID[i];
  uint16_t r;

  if (!mbReadReg(id, REG_ETA, r)) {
    v.errCount++;
    if (++v.fails >= OFFLINE_AFTER_FAILS && v.online) {
      v.online = false;
      v.running = v.fault = v.ready = false;
      v.freqOut = v.freqSet = v.current = v.voltDc = v.voltOut = 0;
      dirty = true;
    }
    return;
  }
  v.okCount++;
  v.fails = 0;
  if (!v.online) { v.online = true; dirty = true; }

  v.eta = r;
  bool running = (r & SW_RDY_REF) != 0;
  bool fault   = (r & SW_TRIPPED) != 0;
  bool ready   = (r & (SW_RDY_ON | SW_RDY_RUN)) == (SW_RDY_ON | SW_RDY_RUN);
  if (running != v.running || fault != v.fault || ready != v.ready) dirty = true;
  v.running = running; v.fault = fault; v.ready = ready;

  readMeas(v, id);
}

#if ALLOW_SETPOINT_WRITE
// Kirim perintah setpoint yang menunggu. Hanya REFERENCE 1 -- tidak bisa start/stop motor.
static void applyCmd(int i) {
  Vsd& v = vsd[i];
  if (!v.cmdPending) return;
  v.cmdPending = false;

  float hz = v.cmdHz;
  if (hz < REF_CLAMP_MIN_HZ) hz = REF_CLAMP_MIN_HZ;
  if (hz > REF_CLAMP_MAX_HZ) hz = REF_CLAMP_MAX_HZ;
  uint16_t raw = (uint16_t)lroundf(hz / REF1_MAX_HZ * REF1_SCALE_MAX);

  v.cmdOk = mbWriteReg(VSD_SLAVE_ID[i], REG_REF1, raw);
  v.cmdApplied = hz;
  dirty = true;
  Serial.printf("[CMD] %s ref1 <- %.1f Hz (raw %u) %s\n",
                VSD_NAME[i], hz, raw, v.cmdOk ? "OK" : "GAGAL");
}
#endif

static void pollAll() {
  static uint32_t last = 0;
  if (millis() - last < POLL_INTERVAL_MS) return;
  last = millis();
  for (int i = 0; i < VSD_COUNT; i++) {
#if ALLOW_SETPOINT_WRITE
    applyCmd(i);
#endif
    if (!vsd[i].online && vsd[i].fails >= OFFLINE_AFTER_FAILS &&
        millis() - vsd[i].lastTry < OFFLINE_RETRY_MS) continue;  // jangan blok 300 ms tiap siklus
    vsd[i].lastTry = millis();
    pollVsd(i);
  }
}

// ---------------------------------------------------------------- Network / MQTT
static bool ethUp = false;

static void onNetEvent(arduino_event_id_t ev) {
  switch (ev) {
    case ARDUINO_EVENT_ETH_START:
      ETH.setHostname("esp32-vsd");
#if USE_STATIC_IP
      ETH.config(IPAddress(STATIC_IP), IPAddress(STATIC_GW), IPAddress(STATIC_MASK), IPAddress(STATIC_DNS));
#endif
      break;
    case ARDUINO_EVENT_ETH_GOT_IP:
      ethUp = true;
      Serial.printf("[ETH] IP %s\n", ETH.localIP().toString().c_str());
      break;
    case ARDUINO_EVENT_ETH_DISCONNECTED:
    case ARDUINO_EVENT_ETH_STOP:
      ethUp = false;
      Serial.println("[ETH] link down");
      break;
    default: break;
  }
}

#if MQTT_USE_TLS
static WiFiClientSecure netClient;
#else
static WiFiClient netClient;
#endif
static PubSubClient mqtt(netClient);

static char topicBuf[96];
static const char* T(const char* sub) {
  snprintf(topicBuf, sizeof(topicBuf), "%s/%s", MQTT_BASE_TOPIC, sub);
  return topicBuf;
}

static void pubStr(const char* sub, const char* val) { mqtt.publish(T(sub), val, MQTT_RETAIN); }
static void pubVsd(int i, const char* name, const char* val) {
  char sub[40];
  snprintf(sub, sizeof(sub), "%s/%s", VSD_NAME[i], name);
  pubStr(sub, val);
}

#if ALLOW_SETPOINT_WRITE
static char cmdTopic[VSD_COUNT][96];

static void onMqttMsg(char* topic, byte* payload, unsigned int len) {
  char val[16];
  if (len >= sizeof(val)) len = sizeof(val) - 1;
  memcpy(val, payload, len);
  val[len] = 0;

  for (int i = 0; i < VSD_COUNT; i++) {
    if (strcmp(topic, cmdTopic[i]) != 0) continue;
    vsd[i].cmdHz = atof(val);
    vsd[i].cmdPending = true;   // ditulis di pollAll(), bukan di dalam callback
    return;
  }
}
#endif

static void publishAll() {
  char b[16];
  for (int i = 0; i < VSD_COUNT; i++) {
    const Vsd& v = vsd[i];
    pubVsd(i, "comm_ok", v.online ? "1" : "0");
    pubVsd(i, "running", v.running ? "1" : "0");
    pubVsd(i, "fault",   v.fault ? "1" : "0");
    pubVsd(i, "ready",   v.ready ? "1" : "0");
    snprintf(b, sizeof(b), "%.1f", v.freqOut);  pubVsd(i, "freq_out", b);
    snprintf(b, sizeof(b), "%.1f", v.freqSet);  pubVsd(i, "freq_set", b);
    snprintf(b, sizeof(b), "%.1f", v.current);  pubVsd(i, "current", b);
    snprintf(b, sizeof(b), "%.0f", v.voltDc);   pubVsd(i, "volt_dc", b);
    snprintf(b, sizeof(b), "%.0f", v.voltOut);  pubVsd(i, "volt_out", b);
    snprintf(b, sizeof(b), "%u", v.eta);        pubVsd(i, "status_word", b);
    snprintf(b, sizeof(b), "%lu", (unsigned long)v.errCount); pubVsd(i, "err_count", b);
#if ALLOW_SETPOINT_WRITE
    snprintf(b, sizeof(b), "%.1f", v.cmdApplied); pubVsd(i, "freq_cmd", b);
    pubVsd(i, "cmd_ok", v.cmdOk ? "1" : "0");
#endif
  }
  snprintf(b, sizeof(b), "%lu", (unsigned long)(millis() / 1000));
  pubStr("gw/uptime", b);
}

static void mqttService() {
  static uint32_t lastTry = 0, lastPub = 0, downSince = 0;
  if (!ethUp) return;

  if (!mqtt.connected()) {
    if (!downSince) downSince = millis();
    if (millis() - downSince > 10UL * 60UL * 1000UL) ESP.restart();  // 10 menit tanpa broker
    if (millis() - lastTry < 5000) return;
    lastTry = millis();
    Serial.println("[MQTT] connecting...");
    char will[80];
    snprintf(will, sizeof(will), "%s/gw/status", MQTT_BASE_TOPIC);
    if (mqtt.connect(MQTT_CLIENT_ID, MQTT_USER, MQTT_PASS, will, 1, true, "offline")) {
      Serial.println("[MQTT] connected");
      downSince = 0;
      pubStr("gw/status", "online");
      pubStr("gw/ip", ETH.localIP().toString().c_str());
#if ALLOW_SETPOINT_WRITE
      for (int i = 0; i < VSD_COUNT; i++) {
        snprintf(cmdTopic[i], sizeof(cmdTopic[i]), "%s/%s/%s",
                 MQTT_BASE_TOPIC, VSD_NAME[i], MQTT_CMD_SUFFIX);
        mqtt.subscribe(cmdTopic[i]);
        Serial.printf("[MQTT] subscribe %s\n", cmdTopic[i]);
      }
#endif
      dirty = true;
    } else {
      Serial.printf("[MQTT] failed rc=%d\n", mqtt.state());
    }
    return;
  }

  mqtt.loop();
  if (dirty || millis() - lastPub >= MQTT_PUBLISH_MS) {
    lastPub = millis();
    dirty = false;
    publishAll();
  }
}

// ---------------------------------------------------------------- Arduino
void setup() {
  Serial.begin(115200);
  Serial.println("\nESP32 VSD gateway start");
#if ALLOW_SETPOINT_WRITE
  Serial.println("[CFG] tulis REFERENCE 1 AKTIF (start/stop tetap lewat PLC)");
#else
  Serial.println("[CFG] mode read-only");
#endif

#if RS485_DE_PIN >= 0
  pinMode(RS485_DE_PIN, OUTPUT);
  digitalWrite(RS485_DE_PIN, LOW);
#endif
  RS485.begin(MB_BAUD, MB_FORMAT, RS485_RX_PIN, RS485_TX_PIN);

  WiFi.onEvent(onNetEvent);
  ETH.begin(ETH_PHY_W5500, 1, W5500_CS_PIN, W5500_INT_PIN, W5500_RST_PIN,
            SPI3_HOST, W5500_SCK_PIN, W5500_MISO_PIN, W5500_MOSI_PIN);

#if MQTT_USE_TLS && MQTT_TLS_INSECURE
  netClient.setInsecure();
#endif
  mqtt.setServer(MQTT_HOST, MQTT_PORT_CFG);
  mqtt.setBufferSize(256);
  mqtt.setKeepAlive(30);
#if ALLOW_SETPOINT_WRITE
  mqtt.setCallback(onMqttMsg);
#endif
}

void loop() {
  pollAll();
  mqttService();

  static uint32_t lastLog = 0;
  if (millis() - lastLog > 5000) {
    lastLog = millis();
    for (int i = 0; i < VSD_COUNT; i++) {
      const Vsd& v = vsd[i];
      Serial.printf("[%s] %s eta=0x%04X out=%.1fHz set=%.1fHz I=%.1fA Vdc=%.0f Vout=%.0f run=%d flt=%d err=%lu\n",
                    VSD_NAME[i], v.online ? "ON " : "OFF", v.eta, v.freqOut, v.freqSet,
                    v.current, v.voltDc, v.voltOut, v.running, v.fault, (unsigned long)v.errCount);
    }
  }
}
