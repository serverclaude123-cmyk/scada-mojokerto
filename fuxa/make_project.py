#!/usr/bin/env python3
"""Bangun file proyek FUXA (.fuxap) untuk SCADA Mojokerto.

Jalankan:  python fuxa/make_project.py
Keluaran:  fuxa/scada-mojokerto.fuxap

Struktur mengikuti model data FUXA (client/src/app/_models/*.ts) dan driver
server/runtime/devices/{mqtt,modbus}/index.js:
  - Tag MQTT  : `address` = topik penuh, `type` = 'raw' (payload angka/teks biasa).
  - Tag Modbus: `memaddress` = area (0 coil, 400000 holding), `address` = 1-based
                (FUXA mengurangi 1 sebelum mengirim ke bus -> %M0 = address "1").
  - Gauge      : `property.variableId` HARUS sama dengan id tag.
"""
import json
import os

BASE = "scada/mojokerto"
VSDS = ["vsd1", "vsd2"]

MQTT_DEV = "MQTT Broker"
PLC_DEV = "PLC M221"

# Isi sebelum / sesudah import -- jangan commit kredensial asli.
# Broker ada di PC yang sama dengan FUXA, jadi dari sisi FUXA cukup localhost.
# (ESP32 TIDAK boleh pakai localhost -- di secrets.h isi IP LAN PC ini.)
MQTT_URL = "mqtt://localhost:1883"
MQTT_USER = "GANTI-USER"
MQTT_PASS = "GANTI-PASSWORD"

PLC_ADDR = "192.168.1.113:502"
PLC_SLAVE = "1"  # M221: 1, sebagian firmware menjawab 255


def daq(interval=60, changed=True, enabled=True):
    return {"enabled": enabled, "changed": changed, "interval": interval, "restored": False}


def mqtt_tag(tag_id, topic, fmt=1, retain_cmd=None):
    """Tag MQTT read-only (subscribe). retain_cmd != None -> tag publish."""
    tag = {
        "id": tag_id,
        "name": tag_id,
        "label": tag_id,
        "type": "raw",
        "address": f"{BASE}/{topic}",
        "memaddress": "",
        "divisor": 1,
        "format": fmt,
        "daq": daq(),
        "init": "",
        "options": {},
    }
    if retain_cmd is not None:
        # Tag yang dipublish FUXA: payload = nilai mentah, tanpa retained.
        tag["options"] = {"pubs": [{"type": "value", "key": "", "value": ""}],
                          "retain": retain_cmd}
        tag["daq"] = daq(enabled=False, changed=False)
    return tag


def modbus_tag(tag_id, memarea, address, mtype, fmt=0):
    return {
        "id": tag_id,
        "name": tag_id,
        "label": tag_id,
        "type": mtype,
        "memaddress": memarea,
        "address": str(address),
        "divisor": 1,
        "format": fmt,
        "daq": daq(enabled=False, changed=False),
        "init": "",
        "options": {},
    }


# ----------------------------------------------------------------- tags MQTT
mqtt_tags = {}


def add(tag):
    mqtt_tags[tag["id"]] = tag


add(mqtt_tag("gw_status", "gw/status", fmt=0))
add(mqtt_tag("gw_ip", "gw/ip", fmt=0))
add(mqtt_tag("gw_uptime", "gw/uptime", fmt=0))

# format: jumlah digit setelah koma
ANALOG = [("freq_out", 1), ("freq_set", 1), ("current", 1),
          ("volt_dc", 0), ("volt_out", 0), ("freq_cmd", 1)]
DIGITAL = ["running", "fault", "ready", "comm_ok", "cmd_ok"]
DIAG = ["status_word", "err_count"]

for v in VSDS:
    for name, fmt in ANALOG:
        add(mqtt_tag(f"{v}_{name}", f"{v}/{name}", fmt=fmt))
    for name in DIGITAL:
        add(mqtt_tag(f"{v}_{name}", f"{v}/{name}", fmt=0))
    for name in DIAG:
        add(mqtt_tag(f"{v}_{name}", f"{v}/{name}", fmt=0))
    # perintah setpoint: hanya berguna bila ALLOW_SETPOINT_WRITE = 1 di firmware
    add(mqtt_tag(f"{v}_cmd_freq_set", f"{v}/cmd/freq_set", fmt=1, retain_cmd=False))

# --------------------------------------------------------------- tags Modbus
# M221: %M0 -> coil 0 -> FUXA address "1";  %MW10 -> holding 10 -> address "11".
# Perintah pulse: START dan STOP bit terpisah per VSD.
#   %M0 START1  %M1 STOP1  %M2 START2  %M3 STOP2
#
# memaddress HARUS 6 digit. Driver membangun kunci area lewat getMemoryAddress()
# yang mengembalikan '000000' untuk coil; memakai '0' bikin kunci tidak cocok dan
# tag gagal dimuat ("load error! Cannot read properties of undefined (reading 'Items')").
COIL = "000000"
HOLDING = "400000"
plc_tags = {
    "plc_start_vsd1": modbus_tag("plc_start_vsd1", COIL, 1, "Bool"),
    "plc_stop_vsd1": modbus_tag("plc_stop_vsd1", COIL, 2, "Bool"),
    "plc_start_vsd2": modbus_tag("plc_start_vsd2", COIL, 3, "Bool"),
    "plc_stop_vsd2": modbus_tag("plc_stop_vsd2", COIL, 4, "Bool"),
    "plc_heartbeat": modbus_tag("plc_heartbeat", HOLDING, 11, "UInt16"),
}

devices = {
    MQTT_DEV: {
        "id": "mqtt-mojokerto",
        "name": MQTT_DEV,
        "enabled": True,
        "type": "MQTTclient",
        "polling": 1000,
        "property": {"address": MQTT_URL, "username": MQTT_USER, "password": MQTT_PASS},
        "tags": mqtt_tags,
    },
    PLC_DEV: {
        "id": "plc-m221",
        "name": PLC_DEV,
        "enabled": True,
        "type": "ModbusTCP",
        "polling": 1000,
        "property": {
            "address": PLC_ADDR,
            "slaveid": PLC_SLAVE,
            "connectionOption": "TcpPort",
            "options": "",
            "delay": 20,
        },
        "tags": plc_tags,
    },
}

# ------------------------------------------------------------------- alarms
def alarm(name, variable_id, text, level="high", lo=1, hi=1, color="#ffffff", bk="#d32f2f"):
    empty = {"enabled": False, "text": "", "group": "", "ackmode": "alarm.ack-float",
             "bkcolor": "", "color": "", "checkdelay": 0, "min": 0, "max": 0, "timedelay": 0}
    a = {
        "name": name,
        "property": {"variableId": variable_id, "permission": 0},
        "highhigh": dict(empty),
        "high": dict(empty),
        "low": dict(empty),
        "info": dict(empty),
        "actions": {"enabled": False, "values": []},
        "value": "",
    }
    a[level] = {
        "enabled": True,
        "text": text,
        "group": "VSD",
        "ackmode": "alarm.ack-active",
        "bkcolor": bk,
        "color": color,
        "checkdelay": 1,
        "min": lo,
        "max": hi,
        "timedelay": 0,
    }
    return a


alarms = []
for i, v in enumerate(VSDS, start=1):
    alarms.append(alarm(f"AL_{v.upper()}_FAULT", f"{v}_fault",
                        f"VSD{i} TRIPPED (fault)", level="highhigh"))
    alarms.append(alarm(f"AL_{v.upper()}_COMM", f"{v}_comm_ok",
                        f"VSD{i} tidak terbaca ESP32 (comm lost)", level="high",
                        lo=0, hi=0, bk="#f57c00"))

# ------------------------------------------------------------------- view
W, H = 1200, 800
items = {}
svg = [f'<svg width="{W}" height="{H}" xmlns="http://www.w3.org/2000/svg">']
svg.append(f'<rect x="0" y="0" width="{W}" height="{H}" fill="#f4f6f8" stroke-width="0" id="bg"/>')


def static_text(x, y, s, size=16, color="#263238", anchor="start", weight="normal"):
    svg.append(
        f'<text x="{x}" y="{y}" font-family="sans-serif" font-size="{size}" fill="{color}" '
        f'text-anchor="{anchor}" font-weight="{weight}" stroke-width="0">{s}</text>')


def value_item(item_id, x, y, variable_id, unit, fmt_text="##.#", size=26):
    items[item_id] = {
        "id": item_id,
        "type": "svg-ext-value",
        "name": variable_id,
        "property": {
            "events": [],
            "variable": variable_id,
            "variableId": variable_id,
            "variableSrc": devices[MQTT_DEV]["id"],
            "alarmId": "", "alarmSrc": "", "alarm": "", "alarmColor": "",
            "ranges": [{"type": "unit", "min": 0, "max": 100, "text": unit}],
        },
        "label": "Value",
    }
    svg.append(
        f'<g id="{item_id}" type="svg-ext-value" text-anchor="end" font-family="sans-serif" '
        f'font-size="{size}" fill="none" stroke-width="0">'
        f'<text id="{item_id}_t" x="{x}" y="{y}" text-anchor="end" font-family="sans-serif" '
        f'font-size="{size}" fill="#0d47a1" stroke-width="0" xml:space="preserve">{fmt_text}</text>'
        f'</g>')


def lamp_item(item_id, cx, cy, variable_id, on_color, off_color="#bdbdbd", r=13):
    items[item_id] = {
        "id": item_id,
        "type": "svg-ext-gauge_semaphore",
        "name": variable_id,
        "property": {
            "events": [],
            "variable": variable_id,
            "variableId": variable_id,
            "variableSrc": devices[MQTT_DEV]["id"],
            "alarmId": "", "alarmSrc": "", "alarm": "", "alarmColor": "",
            "ranges": [
                {"type": "range", "min": "0", "max": "0", "color": off_color},
                {"type": "range", "min": "1", "max": "1", "color": on_color},
            ],
        },
        "label": "HtmlSemaphore",
    }
    svg.append(
        f'<g id="{item_id}" type="svg-ext-gauge_semaphore" font-family="sans-serif" font-size="14">'
        f'<ellipse cx="{cx}" cy="{cy}" rx="{r}" ry="{r}" fill="{off_color}" stroke="#607d8b" '
        f'stroke-width="1" id="{item_id}_e"/></g>')


# Nama event/aksi diambil dari proyek yang DISIMPAN editor FUXA 1.3.5 (acuan pasti).
# Jangan pakai bentuk "shapes.event-*" dari hmi.ts di branch master: itu format versi
# yang belum dirilis, dan di 1.3.5 dropdown Type/Action tampil kosong = event mati.
EV_MOUSEDOWN = "mousedown"
EV_MOUSEUP = "mouseup"
ACT_SETVALUE = "onSetValue"
ACT_OPTIONS = {"variablesMapping": []}


def input_item(item_id, x, y, w, h, variable_id):
    """Kotak isian setpoint. Strukturnya mengikuti proyek demo FUXA:
    <g> berisi <rect> + <foreignObject> dengan <INPUT id="I-<gid>">.
    Tanpa INPUT ber-prefiks 'I-' itu, FUXA hanya menggambar kotak mati."""
    items[item_id] = {
        "id": item_id,
        "type": "svg-ext-html_input",
        "name": variable_id,
        "property": {
            "events": [],
            "variable": variable_id,
            "variableId": variable_id,
            "variableSrc": devices[MQTT_DEV]["id"],
            "alarmId": "", "alarmSrc": "", "alarm": "", "alarmColor": "",
        },
        "label": "HtmlInput",
    }
    svg.append(
        f'<g id="{item_id}" stroke="#000000" text-anchor="right" font-family="sans-serif" '
        f'font-size="14" fill="#f1f1f1ff" type="svg-ext-html_input">'
        f'<rect id="svg_{item_id}" stroke="null" fill="#ffffff" height="{h}" width="{w}" '
        f'y="{y}" x="{x}" stroke-width="0"/>'
        f'<foreignObject id="H-{item_id}" width="{w}" height="{h}" y="{y}" x="{x}">'
        f'<INPUT id="I-{item_id}" style="width: calc(100% - 7px); height: calc(100% - 7px); '
        f'text-align: right; border: unset; background-color: rgb(255, 255, 255); '
        f'color: rgb(0, 0, 0); vector-effect: non-scaling-stroke;" type="text"/>'
        f'</foreignObject></g>')


def button_item(item_id, x, y, w, h, variable_id, text, fill):
    # Momentary: tekan -> tulis 1, lepas -> tulis 0.
    # FUXA 1.3.5 belum punya buttonAction (mode press/release) -- itu baru ada di master --
    # jadi momentary dibuat dari pasangan event mousedown/mouseup.
    # Lebar pulse = selama tombol ditahan. PLC tetap HARUS mereset bit perintah sendiri
    # sebagai pengaman kalau browser/jaringan mati di antara mousedown dan mouseup.
    items[item_id] = {
        "id": item_id,
        "type": "svg-ext-html_button",
        "name": text,
        "property": {
            "events": [
                {"type": EV_MOUSEDOWN, "action": ACT_SETVALUE, "actparam": "1",
                 "actoptions": dict(ACT_OPTIONS)},
                {"type": EV_MOUSEUP, "action": ACT_SETVALUE, "actparam": "0",
                 "actoptions": dict(ACT_OPTIONS)},
            ],
            "variable": variable_id,
            "variableId": variable_id,
            "variableSrc": devices[PLC_DEV]["id"],
            "alarmId": "", "alarmSrc": "", "alarm": "", "alarmColor": "",
            "text": text,
        },
        "label": "HtmlButton",
    }
    # Struktur wajib FUXA: <g> berisi <rect> + <foreignObject> dengan <BUTTON id="B-<gid>">.
    # html-button.component.ts mencari anak ber-id awalan 'B-HXB_'; tanpa itu tombol tampil polos.
    svg.append(
        f'<g id="{item_id}" type="svg-ext-html_button" fill="#FFFFFF" font-size="15" '
        f'font-family="sans-serif" text-anchor="right" stroke="#000000">'
        f'<rect stroke-width="0" x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" '
        f'id="svg_{item_id}" stroke="#ffffff"/>'
        f'<foreignObject x="{x}" y="{y}" height="{h}" width="{w}" id="H-{item_id}">'
        f'<BUTTON style="width: 100%; height: 100%; vector-effect: non-scaling-stroke; '
        f'background-color: {fill}; color: rgb(255, 255, 255);" '
        f'class="md-btn  md-btn-raised" id="B-{item_id}">{text}</BUTTON>'
        f'</foreignObject></g>')


# header
static_text(40, 48, "SCADA Mojokerto - 2 VSD ABB", size=26, weight="bold")
static_text(40, 76, "Gateway ESP32", size=14, color="#546e7a")
value_item("VAL_gw_status", 420, 76, "gw_status", "", fmt_text="--", size=16)
static_text(440, 76, "IP", size=14, color="#546e7a")
value_item("VAL_gw_ip", 640, 76, "gw_ip", "", fmt_text="---.---.---.---", size=16)

ROWS = [("freq_out", "Frek. output", " Hz"), ("freq_set", "Setpoint", " Hz"),
        ("current", "Arus", " A"), ("volt_dc", "DC bus", " V"),
        ("volt_out", "Teg. output", " V")]

for idx, v in enumerate(VSDS):
    x0 = 40 + idx * 580
    y0 = 110
    svg.append(f'<rect x="{x0}" y="{y0}" width="540" height="430" rx="8" fill="#ffffff" '
               f'stroke="#cfd8dc" stroke-width="1" id="panel_{v}"/>')
    static_text(x0 + 24, y0 + 40, f"VSD{idx + 1}", size=22, weight="bold")

    # lampu
    for j, (tag, label, on_col) in enumerate([("running", "RUN", "#2e7d32"),
                                              ("fault", "FAULT", "#c62828"),
                                              ("comm_ok", "COMM", "#2e7d32")]):
        cx = x0 + 150 + j * 130
        lamp_item(f"GSE_{v}_{tag}", cx, y0 + 33, f"{v}_{tag}", on_col)
        static_text(cx, y0 + 60, label, size=12, color="#546e7a", anchor="middle")

    # nilai
    for k, (tag, label, unit) in enumerate(ROWS):
        y = y0 + 110 + k * 46
        static_text(x0 + 24, y, label, size=15, color="#37474f")
        value_item(f"VAL_{v}_{tag}", x0 + 430, y + 4, f"{v}_{tag}", unit)

    # kotak isian setpoint -> MQTT cmd/freq_set -> ESP32 tulis REFERENCE 1
    static_text(x0 + 24, y0 + 326, "Set frekuensi (Hz)", size=15, color="#37474f")
    input_item(f"HXI_{v}_cmd", x0 + 352, y0 + 308, 78, 26, f"{v}_cmd_freq_set")
    static_text(x0 + 440, y0 + 326, "Enter untuk kirim", size=11, color="#90a4ae")

    # tombol menulis 1; PLC yang mengembalikan bit ke 0 (lihat fuxa/README.md)
    by = y0 + 355
    button_item(f"HXB_{v}_start", x0 + 24, by, 120, 42,
                f"plc_start_vsd{idx + 1}", "START", "#2e7d32")
    button_item(f"HXB_{v}_stop", x0 + 160, by, 120, 42,
                f"plc_stop_vsd{idx + 1}", "STOP", "#c62828")
    static_text(x0 + 300, by + 28, "tulis 1 -> PLC SET/RESET + clear bit",
                size=12, color="#90a4ae")

static_text(40, 580, "Diagnosa", size=18, weight="bold")
for idx, v in enumerate(VSDS):
    x0 = 40 + idx * 580
    static_text(x0, 612, f"VSD{idx + 1} status word", size=14, color="#546e7a")
    value_item(f"VAL_{v}_status_word", x0 + 300, 612, f"{v}_status_word", "", fmt_text="0", size=18)
    static_text(x0, 644, f"VSD{idx + 1} error frames", size=14, color="#546e7a")
    value_item(f"VAL_{v}_err_count", x0 + 300, 644, f"{v}_err_count", "", fmt_text="0", size=18)
svg.append("</svg>")

view = {
    "id": "v_scada_mojokerto",
    "name": "Overview",
    "type": "svg",
    "profile": {"width": W, "height": H, "bkcolor": "#f4f6f8ff"},
    "items": items,
    "variables": {},
    "svgcontent": "".join(svg),
    "property": {"events": []},
}

project = {
    "version": "1.01",
    "name": "SCADA Mojokerto",
    "server": {"name": "Fuxa Server", "id": "0", "type": "FuxaServer", "property": {}},
    "hmi": {
        "layout": {
            "start": view["id"],
            "navigation": {"mode": "fix", "type": "inline",
                           "items": [{"icon": "dashboard", "view": view["id"],
                                      "link": "", "text": "Overview"}]},
            "header": {"title": "SCADA Mojokerto", "alarms": "modeNone", "infos": "modeNone"},
            "showdev": True,
            "inputdialog": "false",
            "hidenavigation": False,
            "theme": "",
        },
        "views": [view],
    },
    "devices": devices,
    "charts": [],
    "graphs": [],
    "alarms": alarms,
    "recipes": [],
    "notifications": [],
    "scripts": [],
    "reports": [],
    "texts": [],
    "mapsLocations": [],
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scada-mojokerto.fuxap")
with open(out, "w", encoding="utf-8") as f:
    json.dump(project, f, ensure_ascii=False, indent=1)

print(f"{out}")
print(f"  devices : {len(devices)}")
print(f"  tags    : MQTT {len(mqtt_tags)}, Modbus {len(plc_tags)}")
print(f"  alarms  : {len(alarms)}")
print(f"  gauges  : {len(items)}")
