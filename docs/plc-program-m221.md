# Program PLC TM221CE24R — master RS485 untuk 5 VSD + flow meter

Status (23 Nov 2026): rev4 = rev3 + simbol input/output fisik (SEL_REMOTE, ESTOP_OK, VSDn_PB_ON/OFF, VSDn_RUN); rev3 = rev2 + selector LOCAL/REMOTE dan PB panel. **rev4 COMPILE TANPA ERROR** di Machine Expert Basic (23 Nov 2026, dicek user). Belum di-download ke PLC, belum diuji di lapangan. Riwayat: rev1 dibuka di Machine Expert Basic — hanya rung `CLR_CMD_*` error (dua `LD`
dalam satu rung IL tidak boleh); diperbaiki di rev2 (dipecah jadi `CLR_START_*` / `CLR_STOP_*`). **rev2 belum di-compile,
BELUM di-download, BELUM diuji.**

- Proyek: `C:\Users\Admin\claude\mojokerto-rev7.smbp` (PC#2), dibuat oleh
  `C:\Users\Admin\claude\build_mojokerto_rev1.ps1` dari `mojokerto.smbp` buatan user
  (konfigurasi Ethernet + SL1 IOScanner 6 device). File sumber tidak diubah.
- **Sumber kebenaran = skrip generator.** Kalau program diubah di Machine Expert Basic, skrip
  tidak lagi mencerminkan proyek — catat perubahan di sini.
- Rancangan bus: `docs/rs485-bus-plc-master.md`.

Dicek ke help Machine Expert Basic yang terpasang di PC#2 (`Help\en-GB\*.chm`):
`%IWN(100+dev).ch.i` / `%QWN…` / `%IWNS(100+dev)`; status device **2 = ada dan ter-scan**;
cycle time channel satuan **10 ms**; maks 16 device, **10 channel per device**;
`LD 1` untuk rung tanpa syarat; `DINT_TO_REAL`/`REAL_TO_INT` ada; **tidak ada MIN/MAX** (pakai
perbandingan). Nama enum channel diambil dari `SchneiderElectric.SoMachineBasic.Entities.dll`.

### rev5/rev6 (24 Nov 2026): IOScanner auto-retry (rev6: `LDR %S6` ditolak compiler, diganti deteksi sisi naik manual dengan `%M112`)
Temuan lapangan: setelah download rev4 semua device status **3**, LED SL1 hanya berkedip 4x saat
start lalu mati, counter ACS550 5306/5307/5308 tidak bergerak. Help M221: *"If a communication
interruption occurs, the IOScanner stops"* — device yang sekali gagal tidak di-scan lagi.
- Rung `RETRY_*`: tiap 15 s, kalau `%SW210` ≠ 2, program men-set **`%S110`** (reset Modbus Serial
  IOScanner SL1). `%MW1606` = salinan `%SW210`, `%MW1611` = jumlah reset.
- rev7: `COMM_OK` di-SET saat status 2, di-RESET saat status error (bukan 2 dan bukan 1); status 1 (init sesudah reset) tidak mengubahnya. rev5/6 menganggap 1 = OK sehingga device yang tidak terpasang ikut hijau (terlihat di FUXA 24 Nov).
- Response timeout per device 10 → **3 (300 ms)** supaya device yang belum terpasang tidak menahan bus.
- **TERBUKTI 24 Nov 2026 (rev6 di PLC):** `%MW1600` VSD1 = **2**, `%IWNS100.0/.1/.2` = 0 (ketiga channel ACS550 OK), `%SW210` = 3 (karena VSD2–5 + flow belum terpasang), `%MW1611` naik. Kabel PLC SL1 ↔ ACS550 dan setting 19200 8N1 ID1 benar.

## 1. Device (urutan sesuai file user)

| Dev | Nama di proyek | Slave ID | Tipe | Output RUN | Base `%MW` FUXA | Raw `%MW` |
|---|---|---|---|---|---|---|
| 0 | vsd1acs550 | 1 | **ACS550** | `%Q0.0` | 1000 | 1300 |
| 1 | vsd2 | 2 | ACS580 | `%Q0.1` | 1020 | 1340 |
| 2 | vsd3future | 3 | ACS580 **(belum terpasang)** | `%Q0.2` | 1040 | 1380 |
| 3 | flowmeter | 4 | ISOIL MV145 | — | 1100 | 1420 |
| 4 | vsd4 | 5 | ACS580 | `%Q0.3` | 1060 | 1460 |
| 5 | vsd5 | 6 | ACS580 | `%Q0.4` | 1080 | 1500 |

### Input panel (rev3, keputusan user 23 Nov 2026)
| Input | Fungsi | Kontak |
|---|---|---|
| `%I0.0` | Selector **REMOTE** (1) / LOCAL (0) — satu untuk semua drive | |
| `%I0.1` | E-stop OK | NC |
| `%I0.2` / `%I0.3` | VSD1 PB ON / PB OFF | NO / **NC** |
| `%I0.4` / `%I0.5` | VSD2 PB ON / PB OFF | NO / NC |
| `%I0.6` / `%I0.7` | VSD3 PB ON / PB OFF | NO / NC |
| `%I0.8` / `%I0.9` | VSD4 PB ON / PB OFF | NO / NC |
| `%I0.10` / `%I0.11` | VSD5 PB ON / PB OFF | NO / NC |
| `%I0.12`–`%I0.13` | cadangan | |

- **REMOTE:** start/stop dari SCADA (`%M10–19`). PB ON panel diabaikan.
- **LOCAL:** start dari PB ON panel; START/STOP SCADA diabaikan (bit tetap dibersihkan).
- **PB OFF panel aktif di kedua mode** (pengaman orang di dekat pompa). NC → kabel putus = stop.
  Akibatnya: **selama PB OFF belum terpasang/dijumper, drive itu tidak bisa jalan sama sekali.**
- Pindah selector tidak menghentikan pompa. Setpoint Hz selalu dari SCADA.
- E-stop (`%I0.1` = 0) mematikan semua RUN. Fault drive mematikan RUN drive itu.
- FUXA: `%M30` MODE_REMOTE, `%M31` ESTOP_OK → tombol START/STOP di FUXA dinonaktifkan saat LOCAL.

## 2. Channel IOScanner (semua cyclic 50 × 10 ms = 500 ms, error → set to zero)

ACS580 (dev 1, 2, 4, 5) — 5 channel:
| Ch | Nama | Fungsi | Offset/Len | Isi | Objek |
|---|---|---|---|---|---|
| 0 | SW_REF_ACT | FC03 | 1 / 4 | 400002 ref1, 400003 ref2, **400004 SW**, 400005 act1 | `%IWNd.0.0–3` |
| 1 | CURRENT_32 | FC03 | 20213 / 2 | 01.07 arus 32-bit (100 = 1 A) | `%IWNd.1.0–1` |
| 2 | DC_BUS | FC03 | 110 / 1 | 01.11 (10 = 1 V) | `%IWNd.2.0` |
| 3 | VOUT | FC03 | 112 / 1 | 01.13 (1 = 1 V); 01.12 tidak ada → terpisah | `%IWNd.3.0` |
| 4 | REF1_WRITE | FC16 | 1 / 1 | tulis 400002 ref1 | `%QWNd.4.0` |

ACS550 (dev 0) — 3 channel: ch0 FC03 1/4 (40002–40005) → `%IWN100.0.0–3`;
ch1 FC03 102/9 (par 0103–0111) → `%IWN100.1.0–8`; ch2 FC16 1/1 → `%QWN100.2.0`.

Flow MV145 (dev 3) — 3 channel FC04: ch0 2/19 (reg 0002–0020) → `%IWN103.0.0–18`;
ch1 27/10 (reg 0027–0036) → `%IWN103.1.0–9`; ch2 51/1 → `%IWN103.2.0`.

Total 75 `%IWN`, 5 `%QWN`, 26 channel.

## 3. Peta memori untuk FUXA (Modbus TCP 192.168.1.113, alamat FUXA = nomor + 1)

### Bit `%M` (simbol sudah ada di proyek)
| | VSD1 | VSD2 | VSD3 | VSD4 | VSD5 | Flow |
|---|---|---|---|---|---|---|
| START (FUXA, pulse) | `%M10` | `%M12` | `%M14` | `%M16` | `%M18` | |
| STOP (FUXA, pulse) | `%M11` | `%M13` | `%M15` | `%M17` | `%M19` | |
| RUN output | `%M20` | `%M21` | `%M22` | `%M23` | `%M24` | |
| Running (SW b2) | `%M25` | `%M26` | `%M27` | `%M28` | `%M29` | |
| Fault (SW b3 & comm OK) | `%M40` | `%M41` | `%M42` | `%M43` | `%M44` | |
| Warning (SW b7) | `%M45` | `%M46` | `%M47` | `%M48` | `%M49` | |
| Remote (SW b9) | `%M50` | `%M51` | `%M52` | `%M53` | `%M54` | |
| COMM_OK (`%IWNS` = 2) | `%M60` | `%M61` | `%M62` | `%M63` | `%M64` | `%M65` |
| Comm lost (alarm) | `%M70` | `%M71` | `%M72`* | `%M73` | `%M74` | `%M75` |

\* `%M72` hanya aktif kalau **`%M90` VSD3_INSTALLED = 1**. Flow: `%M80` pipa kosong, `%M81` coil
error, `%M82` di bawah MIN, `%M83` di atas MAX. **`%M99` WORD_SWAP** (lihat §5).

### Word drive (base: VSD1 1000, VSD2 1020, VSD3 1040, VSD4 1060, VSD5 1080)
| Offset | Isi | Satuan |
|---|---|---|
| +0 | status word | bit |
| +1 | frekuensi aktual | Hz × 10 |
| +2 | arus | A × 10 |
| +3 | DC bus | V |
| +4 | tegangan output | V |
| +5 | ref1 terbaca dari drive | Hz × 10 |
| +6 | **setpoint dari FUXA** | Hz × 10 |

### Word flow (base 1100)
`%MF1100` flow (unit alat), `%MF1102` flow l/s, `%MF1104` flow %, `%MF1106` kecepatan,
`%MD1108` T+ raw, `%MD1110` T− raw, `%MW1112` T+ info (MSB overflow, LSB desimal), `%MW1113` T− info,
`%MW1114` flag 1/2, `%MW1115` jumlah alarm, `%MW1116` baterai %, `%MW1117` flag 3/4.

### Lain-lain
`%MW990` SP_MIN / `%MW991` SP_MAX (Hz × 10, default 0 / 500 saat cold start).
`%MW1600–1605` status device IOScanner dev 0–5. `%MD1210–1216` / `%MF1220–1226` / `%MW1251–1255`
sementara. Batas proyek: `%MW` 0–1999, `%M` 0–511 (Memory allocation manual di file user).

## 4. Isi program (109 rung, urutan penting)
1. `INIT` — `%S13`: SP_MIN 0, SP_MAX 500.
2. `RAW_*` — salin semua `%IWN` dan `%IWNS` ke `%MW13xx–16xx` (hanya assignment).
3. `COMM_OK_*` — `[%MW160x = 2]` → `%M6x`; `COMM_LOST_*` → `%M7x`.
4. `WORD32_SWAP` (`%M99` = 0) / `WORD32_STRAIGHT` (`%M99` = 1) — rakit float/32-bit flow dan arus ACS580.
5. `FLOW_WORDS`, `FLOW_ALM_*`.
6. `SCALE_VSD*` — ACS580: act1 ÷ 40, arus via REAL ÷ 10, DC ÷ 10; ACS550: langsung (0,1 Hz / 0,1 A).
7. `STAT_*` — bit dari status word; fault hanya kalau COMM_OK.
8. `SP_MAX_*`, `SP_MIN_*`, `SP_REF_*` — clamp lalu `× 40` ke `%QWN`.
9. Per drive: `START_REM_*` (REMOTE + bit FUXA), `START_LOC_*` (LOCAL + PB ON), `STOP_REM_*`, `STOP_PB_*` (PB OFF NC, semua mode), `STOP_FLT_*` (fault), `CLR_START_*`, `CLR_STOP_*`. START ditolak bila fault atau PB OFF ditekan.
10. `INTERLOCK` — hanya e-stop `%I0.1`; reset semua `%Q0.0–0.4`. `MODE_REMOTE`/`MODE_ESTOP` → `%M30`/`%M31` untuk FUXA.
11. `RUN_FB_*` — paling bawah.

Comm lost **tidak** mematikan RUN (keputusan: drive Last speed). Skala `/40` dan `×40` hanya benar
bila **46.02 (ACS580) dan 1105 (ACS550) = 50,0 Hz**.

## 5. Langkah di Machine Expert Basic sebelum download
1. Tutup `mojokerto.smbp`, buka **`mojokerto-rev7.smbp`**.
2. SL1 Polarization **tidak bisa diubah** (abu-abu, "4.7 kΩ"): SL1 bawaan M221 punya bias internal tetap 4,7 kΩ (impedansi tinggi). Bias kuat diambil dari drive — lihat `docs/rs485-bus-plc-master.md` §Aturan fisik bus.
3. Cek IOScanner → tiap device: channel dan offset sesuai §2.
4. **Compile.** Kalau ada rung merah, catat nama rung + pesan errornya.
5. Simpan. Animation table **Commissioning** sudah berisi alamat-alamat uji.

## 6. Commissioning
1. `%MW1600–1605` = 2 untuk tiap device yang terpasang (VSD3 boleh ≠ 2).
2. **Alamat**: `%MW1020` (SW VSD2) = par 58.19 di panel ACS580; `%MW1000` = SW ACS550.
3. **Word order**: `%MF1100` = flow di layar MV145. Kalau angkanya ngawur → `%M99 = 1`.
   Cek juga `%MW1022` (arus VSD2 × 10) = arus di panel.
4. **Skala**: `%MW1026 = 250` → panel drive 25,0 Hz (bukan 12,5).
5. **Fault**: buat fault uji → `%M41` = 1 dan `%Q0.1` = 0.
6. **Comm lost**: cabut bus ke drive yang jalan tanpa beban → drive tetap jalan (A7CE / Last speed),
   `%M71` = 1, STOP dari FUXA tetap mematikan.
7. **Interlock**: e-stop → semua `%Q0.0–0.4` = 0. Selector LOCAL: PB ON start, START SCADA diabaikan; REMOTE: sebaliknya. PB OFF menghentikan di kedua mode. Pindah selector saat jalan: pompa tetap jalan.
8. Setelah reset fault di panel, drive (20.02 = Edge) tidak start sendiri.
9. Saat VSD3 dipasang: set `%M90 = 1`.

## 7. FUXA (setelah PLC terbukti)
Device MQTT untuk drive tidak dipakai lagi. Device PLC (Modbus TCP 192.168.1.113) mendapat tag
sesuai §3. Tag lama `%M0–%M5` dihapus.
