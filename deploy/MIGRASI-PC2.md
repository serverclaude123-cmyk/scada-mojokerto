# Migrasi server: PC#1 → PC#2 (ruang pompa)

## Sebelum vs sesudah

```
SEBELUM                                       SESUDAH (revisi 23 Nov 2026)
-------                                       ---------------------------
PC#1 desktop-3n6b83h (192.168.1.10)           PC#2 DESKTOP-3HEVBT2 — RUANG POMPA (192.168.1.10)
  - Mosquitto (broker)                          - Mosquitto (broker)      service, auto
  - FUXA (HMI, server)                          - FUXA (HMI, server)      task SYSTEM + watchdog
  - Tailscale 100.93.24.7                       - Tailscale <ip-baru>
        ▲                                             ▲
        │ browser lewat Tailscale                     │ browser lewat Tailscale
PC#2 (viewer)                                 PC#1 desktop-3n6b83h — HANYA BROWSER
                                                - Mosquitto & FUXA dimatikan (tidak dihapus)
                                                - Tailscale tetap login
```

ESP32 dan PLC M221 tidak berubah. Kunci supaya ESP32 **tidak perlu di-flash ulang**:
PC#2 mengambil alih IP **192.168.1.10** (`MQTT_HOST` di `secrets.h` tetap sama).

Alasan pindah sama dengan catatan di `README.md` folder ini: server harus satu LAN dengan
ESP32 dan PLC dan tidak ikut terganggu kalau PC lain dimatikan/pindah jaringan.

## Urutan kerja (±1 jam, motor sebaiknya STOP / mode LOCAL selama cut-over)

| # | Di | Langkah | Skrip |
|---|---|---|---|
| 1 | PC#2 | Pasang **Mosquitto** (installer Windows 64-bit, centang *Service*) dan **Tailscale** (login tailnet `scadapdammojokerto@` yang sama). Clone repo ini. | — |
| 2 | PC#1 | PowerShell **Administrator**: backup data server ke Desktop. FUXA berhenti ±5 detik lalu hidup lagi. | `deploy\backup-server-pc1.ps1` |
| 3 | — | Bawa `scada-server-backup-*.zip` ke PC#2 dengan **flashdisk** (isi kredensial — jangan lewat Git/email/chat). | — |
| 4 | PC#1 | **Cut-over mulai.** Klik kanan → *Run as administrator*. FUXA + broker mati, IP .10 dilepas. | `deploy\pc1-jadi-viewer.cmd` |
| 5 | PC#2 | PowerShell **Administrator**: pasang IP .10, broker, FUXA, data, task, firewall. | `deploy\setup-server-pc2.ps1 -Backup <zip> -StaticIp` |
| 6 | PC#2 | Verifikasi (tabel di bawah). | — |
| 7 | PC#1 | Buka `http://<ip-tailscale-pc2>:1881`, login FUXA seperti biasa. Bookmark. | — |
| 8 | HP / klien MQTT | Ganti host dari `100.93.24.7` ke **IP Tailscale PC#2**. | — |

Opsional tapi disarankan di PC#2: matikan *Fast Startup* (lihat README folder ini) dan set
**Power → Sleep = Never**. PC ruang pompa yang tertidur = SCADA buta.

## Verifikasi di PC#2

| Cek | Cara | Harus |
|---|---|---|
| IP | `ipconfig` | 192.168.1.10 |
| Broker | `netstat -ano \| findstr :1883` | `0.0.0.0:1883 LISTENING` |
| ESP32 masuk | `mosquitto_sub -h 192.168.1.10 -t scada/mojokerto/# -v -u fuxa -P <pw>` | `gw/status online`, `vsd2/volt_dc ~288` dalam 2 detik |
| FUXA | `http://localhost:1881` | view tampil, nilai VSD2 bergerak |
| PLC | FUXA → Connections | device M221 hijau (plugin `modbus-serial` ikut di backup `_pkg`) |
| Reboot | restart PC#2, jangan login | dari PC#1 lewat Tailscale FUXA tetap terbuka |
| Remote | dari PC#1 `http://<ip-tailscale-pc2>:1881` | sama dengan tampilan lokal |

## PC#1: FUXA terbuka otomatis

Klik dua kali `deploy\pc1-viewer\pasang-autostart.cmd` di PC#1 (tanpa admin). Setiap login Windows,
`buka-scada.ps1` menunggu sampai `100.122.186.109:1881` terjangkau (Tailscale baru siap setelah login),
lalu membuka `http://100.122.186.109:1881/_widgets/scada-viewer.html` (pembungkus FUXA, berkasnya
di PC#2 `C:\ProgramData\fuxa\_widgets\`, dipasang oleh `setup-server-pc2.ps1`) di jendela Edge mode app.
Versi awal membuka pembungkus sebagai file lokal di PC#1: di sana Edge selalu menampilkan OFFLINE
walau server hidup (di PC#2 tidak terjadi) — karena itu dipindah ke server, satu origin dengan FUXA. Buka lagi lewat
shortcut "SCADA Mojokerto" di Desktop. Log: `%LOCALAPPDATA%\scada-viewer\buka-scada.log`.

**Kenapa pembungkus:** FUXA di browser TIDAK menunjukkan apa pun saat server mati — "Gateway
online" dan angka terakhir tetap tampil (terbukti 23 Nov 2026 saat PC#2 di-restart). Pembungkus
mengecek `/api/version` tiap 3 detik; 2x gagal -> layar diabu-abukan + spanduk merah
"SERVER SCADA (PC#2) OFFLINE" dengan jam terakhir terhubung; server kembali -> FUXA dimuat ulang
sendiri. Diuji dengan server palsu (mati -> spanduk muncul ±6 detik, hidup -> pulih) dan dengan
FUXA asli PC#2. Supaya jalan tanpa ada yang login, PC#1 perlu auto-login Windows (`netplwiz`).

## Rollback (kalau PC#2 bermasalah)

1. PC#2: `Stop-ScheduledTask FUXA; Stop-Service mosquitto`, kembalikan Ethernet ke DHCP.
2. PC#1: jalankan perintah ROLLBACK yang ada di kepala `pc1-jadi-viewer.cmd`
   (enable task FUXA, mosquitto auto, IP statis .10). Data PC#1 tidak pernah dihapus.

## Jebakan

- **Jangan pernah dua server hidup bersamaan.** Dua broker = data terpecah (lihat
  `broker/README.md` "dua broker sekaligus"); dua PC dengan IP .10 = konflik IP, ESP32 putus-sambung.
  `setup-server-pc2.ps1` menolak jalan kalau .10 masih menjawab ping.
- **Versi FUXA harus sama** dengan PC#1. Skrip membaca versinya dari `manifest.json` di zip dan
  memasang `@frangoteam/fuxa@<versi>`. Proyek dari versi lebih baru belum tentu terbaca versi lama.
- Kalau IP .10 tidak bisa dipakai (mis. diatur router), set DHCP reservation di router untuk
  MAC PC#2, atau ubah `MQTT_HOST` di `secrets.h` dan flash ulang ESP32.
- Password FUXA dan MQTT ikut di backup (`users.fuxap.db`, `passwd`) — login sama seperti dulu.
