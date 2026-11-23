# Rencana bus RS485 — PLC M221 sebagai master (revisi 23 Nov 2026)

Status: **RANCANGAN**, belum ada yang dipasang/diuji. Menggantikan ESP32 sebagai gateway Modbus
(ESP32 sempat putus dari broker ±9 menit tanpa sebab yang bisa dilacak, firmware di board tidak
sama dengan repo).

Keputusan user (23 Nov 2026):
- **Master Modbus RTU = PLC M221** (port serial RS485). FUXA tetap bicara ke PLC lewat Modbus TCP.
- **Start/stop semua drive tetap HARDWIRED** dari output PLC ke DI drive. Modbus hanya untuk
  baca nilai + tulis setpoint frekuensi.

```
PC#2 FUXA ──Modbus TCP── PLC M221 ──RS485 (Modbus RTU master)───────────────────────────────┐
                           │ [120Ω+bias]                                                    │
                           ├─ ID 1 VSD1 ACS550                                              │
                           ├─ ID 2 VSD2 ACS580                                              │
                           ├─ ID 3 VSD3 ACS580 (belum terpasang)                            │
                           ├─ ID 4 Flow meter ISOIL MV145                                   │
                           ├─ ID 5 VSD4 ACS580                                              │
                           └─ ID 6 VSD5 ACS580 [120Ω di perangkat paling ujung kabel]       │
                           output %Q0.0–Q0.4 → DI start VSD1–VSD5 (hardwired) ──────────────┘
```

> **Urutan slave ID direvisi 23 Nov 2026** mengikuti proyek PLC user (`mojokerto.smbp`):
> ID1 = ACS550, ID3 = VSD3 (belum terpasang), ID4 = flow meter. Rencana awal (ACS550 = ID6,
> flow = ID3) tidak berlaku lagi. Alamat `%MW`/`%M` yang berlaku: **`docs/plc-program-m221.md`**.

## Aturan fisik bus
- Daisy chain, tanpa cabang/star. Kabel twisted pair berselubung, AGND/0V tersambung ke semua.
- **Bias (polarisasi):** SL1 bawaan M221 hanya punya bias internal tetap **4,7 kΩ** (impedansi tinggi,
  tidak bisa diubah di software). Help Schneider: jangan pasang terminasi tanpa bias impedansi rendah
  tambahan. Karena itu bias diambil dari **satu ACS580: switch S5 BIAS = ON** (sebaiknya ACS580 di
  ujung kabel). Semua perangkat lain BIAS OFF.
- **Terminasi 120 Ω hanya di dua ujung kabel:** perangkat paling jauh (kalau ACS580: S4 TERM = ON;
  ACS550: J2; MV145: lihat manual) dan sisi PLC (resistor 120 Ω di terminal A–B dekat PLC, boleh
  karena bias kuat sudah ada dari ACS580). Perangkat di tengah: TERM OFF. Bus 50 m @ 19200 bps:
  kalau terminasi sisi PLC dihilangkan pun biasanya tetap jalan, tapi ujung jauh wajib.
- Satu setelan serial untuk semua: usul **19200, 8N1**. MV145 mendukung 4800–57600 (menu 8.2),
  parity di menu 8.3. Pastikan semua 6 perangkat diset sama.
- Slave ID = nomor posisi (1–6).

## Flow meter ISOIL MV145 (#3) — dari manual `145_IT_EN_IS_R1_1.00.0X`
Setelan di menu 8: 8.1 Device address = **4**, 8.2 speed, 8.3 parity, 8.4 reply delay, 8.5 char timeout.
Terminal RS485 di blok terminal konverter: **A, B, 0V, SH**.

**Perhatian catu daya:** MV145 ada versi baterai (lithium/alkaline) dan versi mains (HV 100–240 V AC,
LLV 12–48 V). Manual: konsumsi baterai bergantung pada "jumlah koneksi ke logger eksternal (4-20 mA
atau MODBUS)". Untuk bus yang di-poll terus, **wajib versi mains/LLV**. Catatan manual: alat tidak
bisa jalan dengan baterai dilepas/habis walau dicatu mains, dan start dengan mains perlu kabel USB.

Semua data **FC04 (input register)**, big endian (word tinggi dulu). Nilai flow = rata-rata sampel
sejak pembacaan Modbus terakhir.

| Alamat (doc, 0-based) | Tipe | Isi | Dipakai |
|---|---|---|---|
| 0000-0001 | FLOAT | full scale (unit di alat) | referensi |
| 0002-0003 | FLOAT | flow % | bar |
| **0004-0005** | FLOAT | **flow rate** (unit di alat) | utama |
| 0006-0007 | FLOAT | kecepatan aliran m/s | diagnosa |
| **0008-0009 + 0010** | UINT32 + 2 byte | **totalizer T+** ; 0010 MSB = jumlah overflow, LSB = jumlah desimal | utama |
| 0011-0012 + 0013 | UINT32 + 2 byte | totalizer parsial P+ | opsional |
| 0014-0015 + 0016 | UINT32 + 2 byte | totalizer T− | net = T+ − T− |
| 0017-0018 + 0019 | UINT32 + 2 byte | totalizer parsial P− | opsional |
| **0020** | 2 byte | flag status/alarm 1 (MSB) dan 2 (LSB) | alarm |
| 0027 | UINT16 | sisa kapasitas baterai % | alarm baterai |
| 0032-0033 | UINT32 | hasil sensor test (bit) | diagnosa |
| 0034 | UINT16 | jumlah alarm aktif | alarm |
| **0035-0036** | FLOAT | **flow l/s (tetap, tidak ikut unit di alat)** | lebih aman |
| 0037/0039 | FLOAT | tekanan P1/P2 bar (kalau ada sensor) | opsional |
| 0051 | 2 byte | flag 3 (MSB: baterai low, mains ada, …) dan 4 | diagnosa |

Totalizer: `nilai = (overflow × nilai_overflow + raw) / 10^desimal`. Nilai overflow diset lewat MCP
(VTPOS dst., "MCP ONLY") — **belum diketahui**, baca dari alat/MCP.

Flag 1 (0020 MSB): b7 alarm MIN, b6 alarm MAX, b5 tanda negatif, b4 di bawah cut-off, b3 range 2,
b2 measure di-reset, b1 counter terkunci. Flag 2 (0020 LSB): b7 flow overflow, b6/b5 overflow pulsa,
b4/b3 sinyal di luar range, b2 input error, b1 **coils excitation error**, b0 **pipe empty**.
Flag 3 (0051 MSB): b7–b5 baterai 1–3 low, b4 mains ada, b3 USB ada, b2 banjir, b1 tamper.

Reset totalizer = **FC05** (write single coil) alamat 0000. M221 `WRITE_VAR` menulis coil dengan
FC15 — belum tentu diterima alat ini. Reset sebaiknya dari panel alat, bukan dari SCADA.

Poll flow meter **pelan**: flow tiap ±5 s, totalizer/diagnosa tiap 30–60 s.

## ACS580 #1, #2, #4, #5 — terverifikasi ke ACS580 Firmware Manual (23 Nov 2026)
Sumber: `ACS580 Firmware Manual.pdf` (462 hal.), grup 58 hal. 308–319, data tambahan hal. 371–372.

### Parameter yang diset di tiap ACS580
| Par | Nilai | Catatan dari manual |
|---|---|---|
| 58.01 Protocol | **Modbus RTU** | |
| 58.03 Node address | **2 / 3 / 5 / 6** | VSD2 / VSD3 / VSD4 / VSD5 |
| 58.04 Baud rate | **19.2 kbps** (default) | |
| 58.05 Parity | **8 NONE 1** | default pabrik **8 EVEN 1** — wajib diubah supaya sama dengan ACS550 & MV145 |
| 58.14 Comm loss action | **Last speed** | keputusan user 23 Nov 2026. Default *Fault*. Saat Modbus putus: warning A7CE, frekuensi dibekukan di nilai terakhir, motor TETAP jalan. Berhenti tetap bisa lewat STOP hardwired PLC |
| 58.15 Comm loss mode | **Cw / Ref1 / Ref2** (default) | HANYA tulisan CW/ref yang mereset timer → **PLC wajib menulis Ref1 berkala** (tiap siklus), bukan hanya saat berubah |
| 58.16 Comm loss time | 3.0 s (default) | siklus PLC harus jauh di bawah ini; usul naikkan ke 10 s |
| 58.25 Control profile | **ABB Drives** (default) | |
| 58.26 EFB ref1 type | Speed or frequency (default) → otomatis *Frequency* di mode frekuensi | |
| 58.33 Addressing mode | **Mode 0** (default) | |
| 58.34 Word order | **HI-LO** | default **LO-HI**; HI-LO = word tinggi dulu, sama dengan MV145 → satu rutin tukar word di PLC |
| 58.06 Communication control | **Refresh settings** | setelah semua di atas, supaya berlaku |
| 20.01 Ext1 commands | **In1 Start** (DI1 dari output PLC) | start/stop hardwired |
| 99.04 Motor control mode | **Scalar** (default) | keputusan user 23 Nov 2026: kecepatan diatur dalam **Hz** → kontrol frekuensi, tanpa ID run |
| 20.02 Ext1 start trigger type | **Edge** | default Level; Edge mencegah start sendiri setelah reset fault (lihat bagian fault) |
| 28.11 Ext1 frequency ref1 | **EFB ref1** | sumber setpoint Hz dari Modbus (Ref1, 400002) |
| 46.02 Frequency scaling | **50.00 Hz** (default 50/60) | **20000 di Modbus = nilai 46.02.** Skala di PLC WAJIB sama — jebakan yang sama dengan 1105 di ACS550 |

Diagnosa di panel drive: 58.07 (bit 4 = A/B terbalik, 5 = parity salah, 6 = baud salah,
7 = tidak ada aktivitas bus, 9 = noise/ID ganda), 58.08 paket diterima, 58.12 CRC error.

### Register yang dibaca/ditulis PLC (alamat PDU = register − 400001)
Baca 1 — FC03 PDU 0…5 (400001–400006), 6 register:
| Register | Isi (default 58.101–58.106) |
|---|---|
| 400001 | Control word — **jangan ditulis** (start/stop hardwired) |
| 400002 | **Ref1** — ditulis PLC (FC16), Hz × 20000 / 46.02 |
| 400003 | Ref2 |
| 400004 | **Status word** (profil ABB Drives) |
| 400005 | Act1 — frekuensi aktual, 20000 = 46.02 |
| 400006 | Act2 |

Baca lain (yang dipakai program, lihat `docs/plc-program-m221.md` §2):
| Register | PDU | Parameter | Skala |
|---|---|---|---|
| 420214–15 | 20213, 2 reg | 01.07 Motor current, **32-bit** (Mode 0: 420000 + 200×group + 2×index) | 100 = 1 A |
| 400111 | 110, 1 reg | 01.11 DC voltage, 16-bit | 10 = 1 V |
| 400113 | 112, 1 reg | 01.13 Output voltage, 16-bit | 1 = 1 V |

- Frekuensi aktual diambil dari Act1 (400005, 20000 = 46.02), tidak perlu baca 01.06 terpisah.
- Arus 32-bit karena versi 16-bit 01.07 hanya **1 = 1 A** (tanpa desimal). Word order 58.34 = HI-LO.
- **01.12 tidak ada** di ACS580 → 01.11 dan 01.13 dibaca terpisah, bukan satu blok (blok yang
  melewati parameter tak ada berisiko ditolak seluruhnya).

Per ACS580: 4 kanal baca + 1 kanal tulis Ref1.

## ACS550 (VSD1, slave ID 1)
Peta register lama tetap berlaku (lihat README §1): status 40004, ref 40002, blok par 0103–0111.

## PLC M221 sebagai master
Dipakai **Modbus Serial IOScanner** bawaan M221 (ada di konfigurasi proyek `m221 plc.smbp`), bukan
`READ_VAR`/`WRITE_VAR` yang diprogram: polling, pengulangan, dan tulis berkala dikerjakan firmware PLC.
Program lengkap, tabel channel, dan langkah commissioning: **`docs/plc-program-m221.md`**.
- **Float 32-bit:** urutan word di M221 belum pasti → program punya saklar `%M99` (tukar/tidak)
  yang diset saat commissioning, tanpa mengubah program.

## Data yang sudah dikonfirmasi user (23 Nov 2026)
- PLC: **TM221CE24R** — 14 DI (`%I0.0`–`%I0.13`), 10 DO relay (`%Q0.0`–`%Q0.9`), 2 AI, Ethernet,
  **1 port serial SL1** (RJ45, RS232/RS485 dipilih di software). Bus RS485 masuk ke SL1.
  Pinout RJ45 SL1 untuk RS485 (D1 = B/+, D0 = A/−, 0V) **cek ke hardware guide M221** sebelum
  membuat kabel. SL1 tidak punya terminasi internal → pasang 120 Ω di sisi PLC; polarisasi
  diaktifkan di konfigurasi SL1 SoMachine Basic (cek opsinya ada di versi yang dipakai).
- Flow meter MV145 dicatu **24 V** (versi LLV 12–48 V). Menurut manual, baterai tetap harus
  terpasang dan tidak habis walau dicatu eksternal.
- Panjang bus maksimum **50 m** — jauh di bawah batas RS485, 19200 bps aman.

## Alokasi I/O TM221CE24R (usulan)
| I/O | Fungsi | Catatan |
|---|---|---|
| `%I0.0` | SEL_REMOTE (selector Local/Remote) | sama dengan program lama |
| `%I0.1` | ESTOP_OK (kontak NC) | sama dengan program lama |
| `%I0.2`–`%I0.11` | PB ON (NO) / PB OFF (NC) VSD1–VSD5 | selector LOCAL/REMOTE, lihat `docs/plc-program-m221.md` §1. Tanpa relay fault — fault lewat Modbus |
| `%I0.12`–`%I0.13` | cadangan (2) | |
| `%Q0.0`–`%Q0.4` | RUN VSD1 (ACS550) … VSD5 | ke DI start tiap drive |
| `%Q0.5`–`%Q0.9` | cadangan (5) | mis. lampu alarm / reset fault |

### Fault lewat Modbus (tanpa relay fault)
- Sumber: **status word bit 3 TRIPPED** (profil ABB Drives, sama di ACS580 reg 400004 dan ACS550
  reg 40004). Juga dipakai: bit 7 ALARM (warning), bit 9 REMOTE (drive di REM), bit 2 RDY_REF (running).
- Logika PLC: `comm_ok` = 1 **dan** TRIPPED = 1 → RESET output RUN drive itu + alarm di FUXA.
- Konsekuensi yang harus diterima: **kalau Modbus drive itu putus, PLC tidak tahu drive fault.**
  Drive tetap berhenti sendiri saat trip (proteksi ada di drive), tapi output RUN PLC bisa tetap 1.
  Bahayanya: operator me-reset fault di panel drive → drive langsung jalan lagi karena DI start
  masih aktif (20.02 default **Level**). Pencegahan:
  - ACS580: **20.02 Ext1 start trigger type = Edge** → setelah reset fault perlu sisi naik baru
    di DI1, jadi tidak start sendiri.
  - ACS550 (VSD1): cari parameter setara (start inhibit) di manual ACS550 — **belum dicek**.
  - PLC: kalau `comm_ok` = 0 lebih dari ±10 s saat RUN aktif → alarm "status drive tidak diketahui"
    di FUXA. RUN **tidak** dimatikan (58.14 = Last speed, keputusan user): motor jalan terus di
    frekuensi terakhir, operator tetap bisa STOP lewat FUXA → PLC → kontak hardwired.
Perintah START/STOP dari FUXA: pasangan bit `%M` per drive (pola SET/RESET + bit dibersihkan PLC,
sama seperti README §2), dengan interlock selector, e-stop, dan fault (kalau komunikasi OK).
Comm loss tidak memblokir START/STOP (start/stop hardwired; 58.14 = Last speed).

## Peta memori PLC → FUXA
Dipindah ke **`docs/plc-program-m221.md` §3** (satu sumber, sesuai proyek PLC yang dibuat).
Ringkas: drive VSD1–VSD5 di `%MW1000/1020/1040/1060/1080` (+0 SW, +1 Hz×10, +2 A×10, +3 DC V,
+4 Vout, +5 ref terbaca, +6 setpoint FUXA); flow meter di `%MW1100` (`%MF1100` flow, `%MF1102` l/s, …).

## Polling
IOScanner, semua channel repetition 500 ms (termasuk tulis Ref1 — wajib berkala untuk 58.15),
response timeout 500 ms. 26 channel × ±25–40 ms di 19200 bps → satu putaran ±1 s.

## Setelan serial bersama (dikunci)
**19200 bps, 8 data, NONE, 1 stop** di semua: M221 SL1, ACS580 (58.04/58.05), ACS550 (5303/5304 = 0,
sudah begitu di lapangan), MV145 (menu 8.2/8.3).

## Yang masih dibutuhkan
1. ~~Mode kontrol~~ → **Scalar, setpoint Hz, 28.11 = EFB ref1** (dijawab 23 Nov 2026).
2. ~~Reaksi saat Modbus putus~~ → **Last speed** (dijawab 23 Nov 2026). Akibatnya di PLC:
   `comm_ok` = 0 **tidak** mematikan RUN; hanya alarm "status drive tidak diketahui" di FUXA.
   ACS550 (VSD1) disamakan: **3018 COMM FAULT FUNC = LAST SPEED**, 3019 COMM FAULT TIME ±10 s
   (dulu 3018 = NOT SEL) — **cek nama/nilai pilihan di panel ACS550** sebelum diset.
3. Unit flow yang diset di MV145 (atau cukup pakai reg 0035 l/s).
4. START boleh walau Modbus drive itu putus? (usul: boleh, karena start/stop hardwired — tapi kalau
   58.14 = Fault, drive tetap trip saat referensi Modbus hilang.)
