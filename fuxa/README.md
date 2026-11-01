# Proyek FUXA – SCADA Mojokerto

`scada-mojokerto.fuxap` = file proyek FUXA siap import. Dibuat oleh `make_project.py`
(jalankan `python fuxa/make_project.py` kalau daftar tag berubah; jangan edit `.fuxap` manual).

## Isi

| Bagian | Jumlah | Keterangan |
|---|---|---|
| Device `MQTT Broker` | 31 tag | monitoring, subscribe ke `scada/mojokerto/#` |
| Device `PLC M221` | 5 tag | Modbus TCP, 4 bit perintah pulse + heartbeat |
| View `Overview` | 28 gauge | 2 panel VSD: lampu RUN/FAULT/COMM, 5 nilai, tombol START/STOP |
| Alarm | 4 | fault & comm-lost per VSD |

## Menjalankan FUXA
Tidak ada installer Windows di halaman rilis FUXA — distribusinya lewat npm atau Docker.
Butuh Node.js (diuji dengan **Node 22 LTS**; Node 26 dihindari karena modul native FUXA
belum tentu punya prebuild).

```bash
npm install -g @frangoteam/fuxa
fuxa
```

Lalu buka **http://localhost:1881**.

> Jalankan `fuxa` dari shell yang PATH-nya memuat `npm`. FUXA memanggil `npm` saat memasang
> plugin; kalau tidak ketemu, pemasangan plugin gagal dengan `'npm.cmd' is not recognized`.

## Plugin Modbus harus dipasang dulu
Paket npm FUXA **tidak** menyertakan driver Modbus. Tanpa itu, log hanya menulis
`try to create PLC M221 but plugin is missing!` dan device PLC diam saja.

Pasang lewat **Settings → Plugins → `modbus-serial`** (versi yang dipakai di sini: 8.0.19).
Driver MQTT sudah bawaan, tidak perlu plugin.

## Cara import
1. Buka FUXA → menu **☰ → Open/Save project** → **Load project** → pilih `scada-mojokerto.fuxap`.
2. **Edit kredensial broker** (tidak disimpan di Git): Connections → `MQTT Broker` →
   isi `GANTI-USER` / `GANTI-PASSWORD` sesuai user yang dibuat di Mosquitto.
   URL-nya sudah `mqtt://localhost:1883` karena broker ada di PC yang sama dengan FUXA.
   (ESP32 tidak boleh pakai `localhost` — di `secrets.h` isi IP LAN PC ini.)
3. Cek `PLC M221`: alamat `192.168.1.113:502`, Slave ID `1`. Kalau M221 tidak menjawab,
   coba Slave ID `255`.

## Pemetaan alamat Modbus ke PLC — PERHATIAN
FUXA memakai alamat **1-based** lalu mengurangi 1 sebelum mengirim ke bus
(`server/runtime/devices/modbus/index.js`: `parseInt(address) - 1`). Jadi:

| PLC M221 | Tag FUXA | Area Modbus | `memaddress` | `address` di FUXA |
|---|---|---|---|---|
| `%M0` START VSD1 | `plc_start_vsd1` | coil | `0` | **1** |
| `%M1` STOP VSD1 | `plc_stop_vsd1` | coil | `0` | **2** |
| `%M2` START VSD2 | `plc_start_vsd2` | coil | `0` | **3** |
| `%M3` STOP VSD2 | `plc_stop_vsd2` | coil | `0` | **4** |
| `%MW10` heartbeat | `plc_heartbeat` | holding register | `400000` | **11** |

Kalau tombol tampak menulis ke bit yang salah (geser satu), inilah tempat memeriksanya.

**`memaddress` harus 6 digit.** Driver Modbus FUXA membangun kunci area lewat `getMemoryAddress()`
yang mengembalikan `'000000'` untuk coil. Kalau tag diisi `'0'`, kunci tidak cocok dan tag gagal
dimuat dengan `'PLC M221' load error! TypeError: Cannot read properties of undefined (reading 'Items')`
— device tetap "created" jadi kesalahannya mudah terlewat. Pakai `000000` / `100000` / `300000` / `400000`.

## Tombol momentary (pulse 1 → 0)
Tiap tombol punya **dua** event: `mousedown` menulis `1`, `mouseup` menulis `0`.
Jadi bit perintah naik selama tombol ditahan lalu turun sendiri saat dilepas.

```json
"events": [
 {"type": "mousedown", "action": "onSetValue", "actparam": "1", "actoptions": {"variablesMapping": []}},
 {"type": "mouseup",   "action": "onSetValue", "actparam": "0", "actoptions": {"variablesMapping": []}}
]
```

**Nama event harus persis seperti itu.** FUXA 1.3.5 memakai nama pendek (`mousedown`, `onSetValue`).
Bentuk `shapes.event-mousedown` / `shapes.event-onsetvalue` yang ada di `hmi.ts` branch master
adalah format versi yang **belum dirilis** — dipakai di 1.3.5, dropdown Type/Action di editor
tampil kosong dan event-nya tidak jalan sama sekali. Acuan yang benar: konfigurasi satu tombol
lewat editor FUXA lalu baca `GET /api/project`.

Mode `buttonAction` (press/release dengan `minHoldTime`) juga hanya ada di master — tidak ada
di 1.3.5, jangan dipakai sampai versinya naik.

### PLC tetap harus membersihkan bit perintah
Lebar pulse = selama operator menahan tombol. Kalau browser, PC, atau jaringan mati di antara
mousedown dan mouseup, bitnya tertinggal `1`. Dengan pola SET/RESET di PLC, `%M0` yang terus `1`
akan me-SET ulang `%Q0.0` tiap scan dan **STOP tidak akan pernah bisa mematikan motor**.
Karena itu program PLC wajib punya `RESET %M0..%M3` setelah memprosesnya — lihat `../README.md`.

## Heartbeat `%MW10` belum otomatis
Tag `plc_heartbeat` sudah ada, tapi **tidak ada script yang menaikkannya** di proyek ini.
Kalau watchdog di PLC diaktifkan tanpa script ini, motor tidak akan pernah bisa run.
Buat di FUXA: Scripts → script baru, jadwal tiap 1 detik:

```js
$setTag('plc_heartbeat', ($getTag('plc_heartbeat') + 1) % 32767);
```

Nama fungsi script bisa berbeda antar versi FUXA — cek daftar fungsi di editor script.

## Status verifikasi
Sudah di-import ke **FUXA 1.3.5** (Node 22.23.4) dan diperiksa:

- Kedua device dimuat tanpa error (`'MQTT Broker' created/start`, `'PLC M221' created/start`).
- View ter-render: 2 panel, lampu RUN/FAULT/COMM, 5 nilai per VSD dengan placeholder `##.#`,
  tombol START/STOP berlabel, blok diagnosa.
- Alarm dan semua tag masuk.
- Koneksi memang gagal di PC uji — broker masih `GANTI-HOST` (`Not authorized`) dan PLC tidak
  ada di jaringan (`ETIMEDOUT 192.168.1.20:502`). Itu yang diharapkan.

- Tombol momentary diuji dengan menekan 400 ms: FUXA memanggil `setValue` dua kali dan
  driver Modbus menghitung `val: 1` lalu `val: 0` untuk coil offset yang benar.

Yang **belum** diuji dan masih jadi tugas di lapangan:
- Nilai live dari broker sungguhan dan tulis coil ke M221 sungguhan (frame di kabel belum
  diverifikasi dengan alat yang bisa dipercaya — listener uji coba saya sendiri salah baca).
- **Dialog konfirmasi START/STOP belum ada.** Tombol ini menjalankan motor lewat PLC.
  Tambahkan konfirmasi di editor FUXA (property tombol) **sebelum dipakai di lapangan**.
- Posisi/ukuran elemen: koordinat tetap 1200×800, rapikan di editor kalau perlu.

### Kotak isian setpoint
Tiap panel punya kotak isian yang terhubung ke tag publish `vsdN_cmd_freq_set`.
Ketik angka lalu tekan **Enter** untuk mengirim.

Strukturnya sama polanya dengan tombol: `<g id="HXI_...">` berisi `<rect>` dan
`<foreignObject>` dengan `<INPUT id="I-HXI_...">`. Tanpa INPUT ber-prefiks `I-` itu,
FUXA hanya menggambar kotak putih yang tidak bisa diketik.

Terbukti ujung ke ujung: isian di FUXA -> `vsd2/cmd/freq_set` -> ESP32 -> Modbus FC06
ke 40002 -> drive ACK, terlihat dari `vsd2/cmd_ok` yang berubah 0 menjadi 1.

### Catatan bentuk tombol
Gauge `svg-ext-html_button` tidak cukup `<rect>`. FUXA mencari anak ber-id awalan `B-HXB_`
(`html-button.component.ts`, `prefixB`), jadi tiap tombol butuh `<foreignObject>` berisi
`<BUTTON id="B-<id gauge>">`. Tanpa itu tombol tampil sebagai kotak warna tanpa teks.
`make_project.py` sudah membuat struktur ini.

## Tag MQTT
Semua bertipe `raw` (payload angka/teks biasa, bukan JSON), `address` = topik penuh.

- `gw_status`, `gw_ip`, `gw_uptime`
- per VSD (`vsd1_`, `vsd2_`): `freq_out`, `freq_set`, `current`, `volt_dc`, `volt_out`,
  `freq_cmd`, `running`, `fault`, `ready`, `comm_ok`, `cmd_ok`, `status_word`, `err_count`
- `vsd1_cmd_freq_set`, `vsd2_cmd_freq_set` — **publish**, retained = false.
  Hanya berguna bila firmware dibangun dengan `ALLOW_SETPOINT_WRITE 1`.

## Alarm
| Nama | Tag | Level | Kondisi |
|---|---|---|---|
| `AL_VSD1_FAULT` / `AL_VSD2_FAULT` | `vsdN_fault` | highhigh | = 1 |
| `AL_VSD1_COMM` / `AL_VSD2_COMM` | `vsdN_comm_ok` | high | = 0 |

Alarm "gateway offline" belum dibuat: `gw_status` berisi teks (`online`/`offline`),
sedangkan alarm FUXA membandingkan angka. Praktisnya kedua alarm comm-lost sudah
menutupi kasus gateway mati.
