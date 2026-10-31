// ESP32 gateway: 2x VSD Schneider (Modbus RTU, read-only) -> MQTT
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

// Baca 1 holding register (FC03). Return true kalau sukses.
static bool mbReadReg(uint8_t slave, uint16_t addr, uint16_t& value) {
  uint8_t req[8] = {slave, 0x03, (uint8_t)(addr >> 8), (uint8_t)addr, 0x00, 0x01, 0, 0};
  uint16_t c = crc16(req, 6);
  req[6] = c & 0xFF;
  req[7] = c >> 8;

  while (RS485.available()) RS485.read();
#if RS485_DE_PIN >= 0
  digitalWrite(RS485_DE_PIN, HIGH);
#endif
  RS485.write(req, sizeof(req));
  RS485.flush();
#if RS485_DE_PIN >= 0
  digitalWrite(RS485_DE_PIN, LOW);
#endif

  uint8_t buf[7];
  size_t n = 0, need = 7;
  uint32_t t0 = millis();
  while (millis() - t0 < MB_TIMEOUT_MS && n < need) {
    while (RS485.available() && n < sizeof(buf)) {
      buf[n++] = RS485.read();
      if (n == 2 && (buf[1] & 0x80)) need = 5;  // frame exception
    }
    delay(1);
  }
  delay(MB_FRAME_GAP_MS);
  if (n < need) return false;
  uint16_t rc = crc16(buf, need - 2);
  if (buf[need - 2] != (rc & 0xFF) || buf[need - 1] != (rc >> 8)) return false;
  if (buf[0] != slave || buf[1] != 0x03 || buf[2] != 2) return false;
  value = ((uint16_t)buf[3] << 8) | buf[4];
  return true;
}

// ---------------------------------------------------------------- State VSD
struct Vsd {
  bool online = false;
  uint8_t fails = 0;
  uint32_t lastTry = 0;
  uint16_t eta = 0;
  float freqOut = 0, freqSet = 0, current = 0, voltDc = 0, voltOut = 0;
  bool running = false, fault = false, ready = false;
  uint32_t okCount = 0, errCount = 0;
};
static Vsd vsd[VSD_COUNT];
static bool dirty = true;  // ada perubahan state penting -> publish segera

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

  if (REG_RFR      && mbReadReg(id, REG_RFR, r))      v.freqOut = (int16_t)r / FREQ_SCALE;
  if (REG_SETPOINT && mbReadReg(id, REG_SETPOINT, r)) v.freqSet = (int16_t)r / FREQ_SCALE;
  if (REG_LCR      && mbReadReg(id, REG_LCR, r))      v.current = r / CURRENT_SCALE;
  if (REG_VDC      && mbReadReg(id, REG_VDC, r))      v.voltDc = r;
  if (REG_VOUT     && mbReadReg(id, REG_VOUT, r))     v.voltOut = r;
}

static void pollAll() {
  static uint32_t last = 0;
  if (millis() - last < POLL_INTERVAL_MS) return;
  last = millis();
  for (int i = 0; i < VSD_COUNT; i++) {
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
