#!/usr/bin/env node
/*
 * Bangun proyek FUXA untuk arsitektur BARU (23 Nov 2026): semua data lewat PLC M221.
 * ESP32 + MQTT tidak dipakai lagi. PLC membaca 5 VSD + flow meter lewat RS485 (IOScanner)
 * dan menyajikan semuanya di %MW / %M (Modbus TCP 192.168.1.113).
 *
 * Jalankan (Node bawaan FUXA di PC#2):
 *   C:\Tools\node-v22.23.4-win-x64\node.exe fuxa\make_project_plc.js
 * Keluaran: fuxa/scada-mojokerto-plc.fuxap
 *
 * Peta alamat = docs/plc-program-m221.md §3 (dibuat oleh plc/build_mojokerto_rev1.ps1).
 * Aturan FUXA 1.3.5 yang sudah terbukti di make_project.py dipakai ulang di sini:
 *  - Tag Modbus: memaddress 6 digit ('000000' coil, '400000' holding), address 1-based (%M10 -> "11").
 *  - divisor: baca = raw / divisor, tulis = nilai * divisor (runtime/devices/modbus/index.js).
 *  - Tipe 32-bit: 'Float32'/'UInt32' = word tinggi dulu, '...MLE' = word rendah dulu
 *    (runtime/devices/modbus/datatypes.js). Urutan word M221 diuji saat commissioning -> WORD_ORDER.
 *  - Tombol: <foreignObject><BUTTON id="B-<id>">, event 'mousedown'/'mouseup' + 'onSetValue'.
 *  - Isian: <foreignObject><INPUT id="I-<id>">.
 *  - Lampu koneksi PLC dari tag sistem "Fuxa Server" (sysType 1: 0 OFF, 3 WARNING, 5 ON).
 */
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ---------------------------------------------------------------- parameter
const PLC_DEV = 'PLC M221';
const PLC_ID = 'plc-m221';           // sama dengan proyek lama -> riwayat DAQ device tetap nyambung
const PLC_ADDR = '192.168.1.113:502';
const PLC_SLAVE = '1';
// Urutan word 32-bit di M221 BELUM diuji. 'MLE' = word rendah di %MW yang lebih kecil
// (perkiraan untuk M221). Kalau flow di FUXA ngawur tapi %MF1100 di PLC benar, ganti ke ''.
const WORD_ORDER = 'MLE';
// Totalizer MV145 = bilangan bulat; jumlah desimal ada di LSB %MW1112. Isi pembagi yang cocok
// (mis. 1000 untuk 3 desimal) setelah dibaca di lapangan.
const TOT_DIVISOR = 1;

// ---------------------------------------------------------------- tag
const COIL = '000000', HOLDING = '400000';
const plcTags = {};
function daq(enabled = false) { return { enabled, changed: enabled, interval: 60, restored: false }; }
function tag(id, area, plcIndex, type, divisor = 1, fmt = 0, logged = false) {
  plcTags[id] = {
    id, name: id, label: id, type, memaddress: area, address: String(plcIndex + 1),
    divisor, format: fmt, daq: daq(logged), init: '', options: {},
  };
}
const coil = (id, m, logged = false) => tag(id, COIL, m, 'Bool', 1, 0, logged);
const word = (id, mw, type = 'Int16', div = 1, fmt = 0, logged = false) => tag(id, HOLDING, mw, type, div, fmt, logged);

const VSD = [
  { n: 1, type: 'ACS550', id: 1 }, { n: 2, type: 'ACS580', id: 2 }, { n: 3, type: 'ACS580', id: 3, future: true },
  { n: 4, type: 'ACS580', id: 5 }, { n: 5, type: 'ACS580', id: 6 },
];
for (const v of VSD) {
  const n = v.n, b = 1000 + 20 * (n - 1), p = `vsd${n}_`;
  coil(p + 'start', 8 + 2 * n);  coil(p + 'stop', 9 + 2 * n);
  coil(p + 'run_cmd', 19 + n, true); coil(p + 'running', 24 + n, true);
  coil(p + 'fault', 39 + n, true); coil(p + 'warning', 44 + n); coil(p + 'remote', 49 + n);
  coil(p + 'comm_ok', 59 + n); coil(p + 'comm_lost', 69 + n);
  word(p + 'status_word', b, 'UInt16');
  word(p + 'freq', b + 1, 'Int16', 10, 1, true);
  word(p + 'current', b + 2, 'Int16', 10, 1, true);
  word(p + 'dc_bus', b + 3, 'Int16', 1, 0);
  word(p + 'vout', b + 4, 'Int16', 1, 0);
  word(p + 'ref_rb', b + 5, 'Int16', 10, 1);
  word(p + 'setpoint', b + 6, 'Int16', 10, 1, true);   // ditulis FUXA (Hz), PLC menerima Hz x10
  word(p + 'ios_stat', 1600 + [0, 0, 1, 2, 4, 5][n], 'Int16');
}
coil('mode_remote', 30); coil('mode_estop_ok', 31);
coil('flow_comm_ok', 65); coil('flow_comm_lost', 75);
coil('flow_pipe_empty', 80); coil('flow_coil_err', 81); coil('flow_min', 82); coil('flow_max', 83);
coil('vsd3_installed', 90);
word('sp_min', 990, 'Int16', 10, 1); word('sp_max', 991, 'Int16', 10, 1);
word('flow', 1100, 'Float32' + WORD_ORDER, 1, 2, true);
word('flow_lps', 1102, 'Float32' + WORD_ORDER, 1, 2, true);
word('flow_pct', 1104, 'Float32' + WORD_ORDER, 1, 1);
word('flow_vel', 1106, 'Float32' + WORD_ORDER, 1, 2);
word('flow_tot_pos', 1108, 'UInt32' + WORD_ORDER, TOT_DIVISOR, 0, true);
word('flow_tot_neg', 1110, 'UInt32' + WORD_ORDER, TOT_DIVISOR, 0);
word('flow_tp_info', 1112, 'UInt16'); word('flow_flags12', 1114, 'UInt16');
word('flow_alarms', 1115, 'UInt16'); word('flow_batt', 1116, 'UInt16');
word('flow_ios_stat', 1603, 'Int16');

const devices = {
  [PLC_DEV]: {
    id: PLC_ID, name: PLC_DEV, enabled: true, type: 'ModbusTCP', polling: 1000,
    property: { address: PLC_ADDR, slaveid: PLC_SLAVE, connectionOption: 'TcpPort', options: '', delay: 20 },
    tags: plcTags,
  },
};

// ---------------------------------------------------------------- Fuxa Server (status koneksi)
const SERVER_ID = '0';
const connTagId = 't_conn_' + PLC_ID;
const serverDevice = {
  name: 'Fuxa Server', id: SERVER_ID, type: 'FuxaServer', property: {}, polling: 1000, enabled: true,
  tags: { [connTagId]: {
    id: connTagId, name: `${PLC_DEV} Connection Status`, label: `${PLC_DEV} Connection Status`, value: '',
    type: 'number', memaddress: PLC_ID, daq: { enabled: false, interval: 60, changed: false, restored: false },
    init: '', sysType: 1,
  } },
};

// ---------------------------------------------------------------- alarm
function alarm(name, variableId, text, level, lo, hi, group, bk) {
  const empty = { enabled: false, text: '', group: '', ackmode: 'alarm.ack-float', bkcolor: '', color: '', checkdelay: 0, min: 0, max: 0, timedelay: 0 };
  const a = { name, property: { variableId, permission: 0 }, highhigh: { ...empty }, high: { ...empty }, low: { ...empty }, info: { ...empty }, actions: { enabled: false, values: [] }, value: '' };
  a[level] = { enabled: true, text, group, ackmode: 'alarm.ack-active', bkcolor: bk, color: '#ffffff', checkdelay: 1, min: lo, max: hi, timedelay: 0 };
  return a;
}
const alarms = [];
for (const v of VSD) {
  alarms.push(alarm(`AL_VSD${v.n}_FAULT`, `vsd${v.n}_fault`, `VSD${v.n} TRIPPED (fault)`, 'highhigh', 1, 1, 'VSD', '#d32f2f'));
  alarms.push(alarm(`AL_VSD${v.n}_COMM`, `vsd${v.n}_comm_lost`, `VSD${v.n} komunikasi RS485 putus (drive Last speed)`, 'high', 1, 1, 'VSD', '#f57c00'));
}
alarms.push(alarm('AL_FLOW_COMM', 'flow_comm_lost', 'Flow meter komunikasi RS485 putus', 'high', 1, 1, 'FLOW', '#f57c00'));
alarms.push(alarm('AL_FLOW_EMPTY', 'flow_pipe_empty', 'Flow meter: pipa kosong', 'high', 1, 1, 'FLOW', '#f57c00'));
alarms.push(alarm('AL_FLOW_COIL', 'flow_coil_err', 'Flow meter: coil excitation error', 'highhigh', 1, 1, 'FLOW', '#d32f2f'));
alarms.push(alarm('AL_ESTOP', 'mode_estop_ok', 'E-STOP panel aktif', 'highhigh', 0, 0, 'PANEL', '#d32f2f'));

// ---------------------------------------------------------------- view
const W = 1400, H = 820;
const items = {};
const svg = [`<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">`,
  `<rect x="0" y="0" width="${W}" height="${H}" fill="#f4f6f8" stroke-width="0" id="bg"/>`];
const prop = (variableId, src, extra = {}) => ({ events: [], variable: variableId, variableId, variableSrc: src, alarmId: '', alarmSrc: '', alarm: '', alarmColor: '', ...extra });

function text(x, y, s, size = 16, color = '#263238', anchor = 'start', weight = 'normal') {
  svg.push(`<text x="${x}" y="${y}" font-family="sans-serif" font-size="${size}" fill="${color}" text-anchor="${anchor}" font-weight="${weight}" stroke-width="0">${s}</text>`);
}
function value(id, x, y, variableId, unit, placeholder = '##.#', size = 22) {
  items[id] = { id, type: 'svg-ext-value', name: variableId, label: 'Value',
    property: prop(variableId, PLC_ID, { ranges: [{ type: 'unit', min: 0, max: 100, text: unit }] }) };
  svg.push(`<g id="${id}" type="svg-ext-value" text-anchor="end" font-family="sans-serif" font-size="${size}" fill="none" stroke-width="0">` +
    `<text id="${id}_t" x="${x}" y="${y}" text-anchor="end" font-family="sans-serif" font-size="${size}" fill="#0d47a1" stroke-width="0" xml:space="preserve">${placeholder}</text></g>`);
}
function lamp(id, cx, cy, variableId, ranges, defColor, src = PLC_ID, r = 11) {
  items[id] = { id, type: 'svg-ext-gauge_semaphore', name: variableId, label: 'HtmlSemaphore', property: prop(variableId, src, { ranges }) };
  svg.push(`<g id="${id}" type="svg-ext-gauge_semaphore" font-family="sans-serif" font-size="14">` +
    `<ellipse cx="${cx}" cy="${cy}" rx="${r}" ry="${r}" fill="${defColor}" stroke="#607d8b" stroke-width="1" id="${id}_e"/></g>`);
}
const onOff = (on, off = '#bdbdbd') => [{ type: 'range', min: '0', max: '0', color: off }, { type: 'range', min: '1', max: '1', color: on }];
function input(id, x, y, w, h, variableId) {
  items[id] = { id, type: 'svg-ext-html_input', name: variableId, label: 'HtmlInput', property: prop(variableId, PLC_ID) };
  svg.push(`<g id="${id}" stroke="#000000" text-anchor="right" font-family="sans-serif" font-size="14" fill="#f1f1f1ff" type="svg-ext-html_input">` +
    `<rect id="svg_${id}" stroke="null" fill="#ffffff" height="${h}" width="${w}" y="${y}" x="${x}" stroke-width="0"/>` +
    `<foreignObject id="H-${id}" width="${w}" height="${h}" y="${y}" x="${x}">` +
    `<INPUT id="I-${id}" style="width: calc(100% - 7px); height: calc(100% - 7px); text-align: right; border: unset; background-color: rgb(255, 255, 255); color: rgb(0, 0, 0); vector-effect: non-scaling-stroke;" type="text"/>` +
    `</foreignObject></g>`);
}
function button(id, x, y, w, h, variableId, label, fill) {
  const ev = (type, v) => ({ type, action: 'onSetValue', actparam: v, actoptions: { variablesMapping: [] } });
  items[id] = { id, type: 'svg-ext-html_button', name: label, label: 'HtmlButton',
    property: prop(variableId, PLC_ID, { events: [ev('mousedown', '1'), ev('mouseup', '0')], text: label }) };
  svg.push(`<g id="${id}" type="svg-ext-html_button" fill="#FFFFFF" font-size="15" font-family="sans-serif" text-anchor="right" stroke="#000000">` +
    `<rect stroke-width="0" x="${x}" y="${y}" width="${w}" height="${h}" fill="${fill}" id="svg_${id}" stroke="#ffffff"/>` +
    `<foreignObject x="${x}" y="${y}" height="${h}" width="${w}" id="H-${id}">` +
    `<BUTTON style="width: 100%; height: 100%; vector-effect: non-scaling-stroke; background-color: ${fill}; color: rgb(255, 255, 255);" class="md-btn  md-btn-raised" id="B-${id}">${label}</BUTTON>` +
    `</foreignObject></g>`);
}

// header
text(40, 44, 'SCADA Mojokerto - 5 VSD + Flow', 26, '#263238', 'start', 'bold');
text(40, 72, 'PLC M221', 14, '#546e7a');
lamp('LMP_plc_conn', 120, 67, connTagId, [
  { type: 'range', min: '0', max: '0', color: '#c62828' }, { type: 'range', min: '3', max: '3', color: '#f9a825' },
  { type: 'range', min: '5', max: '5', color: '#2e7d32' }], '#c62828', SERVER_ID, 9);
text(150, 72, 'Mode panel', 14, '#546e7a');
lamp('LMP_mode', 245, 67, 'mode_remote', [{ type: 'range', min: '0', max: '0', color: '#f9a825' }, { type: 'range', min: '1', max: '1', color: '#2e7d32' }], '#bdbdbd', PLC_ID, 9);
text(265, 72, 'hijau = REMOTE (SCADA), kuning = LOCAL (tombol panel; START/STOP di sini diabaikan PLC)', 12, '#90a4ae');
text(900, 72, 'E-stop', 14, '#546e7a');
lamp('LMP_estop', 960, 67, 'mode_estop_ok', onOff('#2e7d32', '#c62828'), '#c62828', PLC_ID, 9);

// panel VSD: 3 di baris atas, 2 di bawah, flow di kanan bawah
const PW = 440, PH = 350, GX = 450, Y1 = 95, Y2 = 460;
const pos = [[40, Y1], [40 + GX, Y1], [40 + 2 * GX, Y1], [40, Y2], [40 + GX, Y2]];
const ROWS = [['freq', 'Frekuensi', ' Hz', '##.#'], ['ref_rb', 'Setpoint di drive', ' Hz', '##.#'], ['current', 'Arus', ' A', '##.#'],
  ['dc_bus', 'DC bus', ' V', '###'], ['vout', 'Tegangan output', ' V', '###']];
VSD.forEach((v, i) => {
  const [x0, y0] = pos[i], p = `vsd${v.n}_`;
  svg.push(`<rect x="${x0}" y="${y0}" width="${PW}" height="${PH}" rx="8" fill="#ffffff" stroke="#cfd8dc" stroke-width="1" id="panel_vsd${v.n}"/>`);
  text(x0 + 18, y0 + 32, `VSD${v.n}`, 22, '#263238', 'start', 'bold');
  text(x0 + 100, y0 + 32, `${v.type} - ID ${v.id}${v.future ? ' (belum terpasang)' : ''}`, 13, '#78909c');
  const L = [['running', 'RUN', '#2e7d32'], ['fault', 'FAULT', '#c62828'], ['warning', 'WARN', '#f9a825'], ['comm_ok', 'COMM', '#2e7d32'], ['remote', 'REM', '#1565c0'], ['run_cmd', 'PLC Q', '#2e7d32']];
  L.forEach(([t, lbl, col], j) => {
    const cx = x0 + 40 + j * 70;
    lamp(`GSE_${p}${t}`, cx, y0 + 62, p + t, t === 'comm_ok' ? onOff(col, '#c62828') : onOff(col), t === 'comm_ok' ? '#c62828' : '#bdbdbd');
    text(cx, y0 + 88, lbl, 11, '#546e7a', 'middle');
  });
  ROWS.forEach(([t, lbl, unit, ph], k) => {
    const y = y0 + 122 + k * 32;
    text(x0 + 18, y, lbl, 14, '#37474f');
    value(`VAL_${p}${t}`, x0 + 330, y + 3, p + t, unit, ph, 20);
  });
  text(x0 + 18, y0 + 292, 'Set frekuensi (Hz)', 14, '#37474f');
  input(`HXI_${p}sp`, x0 + 252, y0 + 274, 78, 26, p + 'setpoint');
  text(x0 + 338, y0 + 292, 'Enter', 11, '#90a4ae');
  button(`HXB_${p}start`, x0 + 18, y0 + 306, 110, 34, p + 'start', 'START', '#2e7d32');
  button(`HXB_${p}stop`, x0 + 140, y0 + 306, 110, 34, p + 'stop', 'STOP', '#c62828');
  text(x0 + 262, y0 + 328, 'hanya di mode REMOTE', 11, '#90a4ae');
});

// panel flow
{
  const x0 = 40 + 2 * GX, y0 = Y2;
  svg.push(`<rect x="${x0}" y="${y0}" width="${PW}" height="${PH}" rx="8" fill="#ffffff" stroke="#cfd8dc" stroke-width="1" id="panel_flow"/>`);
  text(x0 + 18, y0 + 32, 'FLOW', 22, '#263238', 'start', 'bold');
  text(x0 + 100, y0 + 32, 'ISOIL MV145 - ID 4', 13, '#78909c');
  const L = [['flow_comm_ok', 'COMM', '#2e7d32', true], ['flow_pipe_empty', 'KOSONG', '#f9a825'], ['flow_coil_err', 'COIL ERR', '#c62828'], ['flow_min', 'MIN', '#f9a825'], ['flow_max', 'MAX', '#f9a825']];
  L.forEach(([t, lbl, col, red], j) => {
    const cx = x0 + 40 + j * 80;
    lamp(`GSE_${t}`, cx, y0 + 62, t, red ? onOff(col, '#c62828') : onOff(col), red ? '#c62828' : '#bdbdbd');
    text(cx, y0 + 88, lbl, 11, '#546e7a', 'middle');
  });
  const R = [['flow', 'Flow (unit di alat)', '', '##.##'], ['flow_lps', 'Flow', ' l/s', '##.##'], ['flow_pct', 'Flow % skala', ' %', '##.#'],
    ['flow_vel', 'Kecepatan', ' m/s', '#.##'], ['flow_tot_pos', 'Totalizer T+', '', '########'], ['flow_tot_neg', 'Totalizer T-', '', '########'], ['flow_batt', 'Baterai', ' %', '###']];
  R.forEach(([t, lbl, unit, ph], k) => {
    const y = y0 + 122 + k * 30;
    text(x0 + 18, y, lbl, 14, '#37474f');
    value(`VAL_${t}`, x0 + 400, y + 3, t, unit, ph, 18);
  });
}

// stempel revisi (hash isi sebelum stempel ditambahkan; stabil antar-generate)
const revSrc = JSON.stringify({ items, svg: svg.join(''), tags: Object.keys(plcTags).sort(), alarms: alarms.map(a => a.name) });
const REV = crypto.createHash('sha1').update(revSrc, 'utf8').digest('hex').slice(0, 8);
text(W - 16, 24, `rev ${REV} (PLC)`, 11, '#b0bec5', 'end');
svg.push('</svg>');

const view = { id: 'v_scada_mojokerto', name: 'Overview', type: 'svg', profile: { width: W, height: H, bkcolor: '#f4f6f8ff' },
  items, variables: {}, svgcontent: svg.join(''), property: { events: [] } };
const project = {
  version: '1.01', name: 'SCADA Mojokerto (PLC)', server: serverDevice,
  hmi: { layout: { start: view.id, navigation: { mode: 'fix', type: 'inline', items: [{ icon: 'dashboard', view: view.id, link: '', text: 'Overview' }] },
    header: { title: 'SCADA Mojokerto', alarms: 'modeNone', infos: 'modeNone' }, showdev: true, inputdialog: 'false', hidenavigation: false, theme: '' },
    views: [view] },
  devices, charts: [], graphs: [], alarms, recipes: [], notifications: [], scripts: [], reports: [], texts: [], mapsLocations: [],
};

const out = path.join(__dirname, 'scada-mojokerto-plc.fuxap');
fs.writeFileSync(out, JSON.stringify(project, null, 1), 'utf8');
console.log(out);
console.log(`  tags   : ${Object.keys(plcTags).length} (PLC M221), 1 status koneksi`);
console.log(`  alarms : ${alarms.length}`);
console.log(`  gauges : ${Object.keys(items).length}`);
console.log(`  rev    : ${REV}   <- harus sama dengan pojok kanan atas FUXA`);
