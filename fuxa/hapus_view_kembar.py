"""Hapus view kembar di FUXA yang sedang jalan.

Dipakai saat editor FUXA tidak bisa dipakai karena ada dua view bernama sama
(daftar view jadi tidak bisa diklik). Penyebab kembarannya: set-view pernah
salah sasaran, lihat README.md bagian "views[0] belum tentu view yang kamu lihat".

  python fuxa/hapus_view_kembar.py --dry-run   <- hanya melihat, tanpa login
  python fuxa/hapus_view_kembar.py             <- menghapus, butuh FUXA_USER/FUXA_PASS

Pagar pengaman, supaya tidak ada yang terhapus karena salah tebak:
  - view yang ditunjuk hmi.layout.start TIDAK PERNAH dihapus;
  - view yang dipakai menu navigasi TIDAK PERNAH dihapus;
  - hanya view yang namanya kembar dengan view lain yang jadi calon;
  - view terakhir yang tersisa tidak dihapus;
  - id-nya harus diketik ulang untuk konfirmasi.
"""
import json, os, sys, urllib.error, urllib.request

BASE = "http://127.0.0.1:1881"
H = {"Content-Type": "application/json"}
DRY = "--dry-run" in sys.argv


def call(path, body=None, token=None):
    h = dict(H)
    if token:
        h["x-access-token"] = token
    req = urllib.request.Request(
        BASE + path, json.dumps(body).encode() if body is not None else None, h)
    raw = urllib.request.urlopen(req).read()
    return json.loads(raw) if raw else None


def rev_dari(view):
    import re
    m = re.search(r"rev ([0-9a-f]{8})", view.get("svgcontent") or "")
    return m.group(1) if m else "-"


token = None
if not DRY:
    if not os.environ.get("FUXA_USER"):
        sys.exit("FUXA_USER/FUXA_PASS belum diisi. Jalankan lewat hapus-view-kembar.cmd, "
                 "atau pakai --dry-run untuk melihat saja.")
    try:
        token = call("/api/signin", {"username": os.environ["FUXA_USER"],
                                     "password": os.environ["FUXA_PASS"]})["data"]["token"]
    except urllib.error.HTTPError as e:
        sys.exit(f"login FUXA gagal ({e.code}): user/password salah?")

live = call("/api/project", token=token)
hmi = live.get("hmi") or {}
views = hmi.get("views") or []
layout = hmi.get("layout") or {}
start_id = layout.get("start")
nav_ids = {i.get("view") for i in (layout.get("navigation") or {}).get("items") or []}

print(f"{len(views)} view di FUXA:")
for v in views:
    tanda = []
    if v["id"] == start_id:
        tanda.append("layar awal")
    if v["id"] in nav_ids:
        tanda.append("dipakai menu")
    print("  id=%-26s nama=%-12s item=%-3d rev=%-9s %s"
          % (v["id"], v.get("name"), len(v.get("items") or {}), rev_dari(v),
             ("<- " + ", ".join(tanda)) if tanda else ""))

nama_count = {}
for v in views:
    nama_count[v.get("name")] = nama_count.get(v.get("name"), 0) + 1

calon = [v for v in views
         if nama_count.get(v.get("name"), 0) > 1
         and v["id"] != start_id
         and v["id"] not in nav_ids]

if not calon:
    print("\nTidak ada view kembar yang aman dihapus. Tidak ada yang dikerjakan.")
    sys.exit(0)
if len(views) - len(calon) < 1:
    sys.exit("\nMenolak: semua view akan terhapus.")

print("\nCalon untuk dihapus (kembar nama, bukan layar awal, tidak dipakai menu):")
for v in calon:
    print("  %s  nama=%r  item=%d  rev=%s"
          % (v["id"], v.get("name"), len(v.get("items") or {}), rev_dari(v)))

if DRY:
    print("\n--dry-run: tidak ada yang dihapus.")
    sys.exit(0)

for v in calon:
    print(f"\nHapus view {v['id']} ({len(v.get('items') or {})} item)? "
          f"Ketik ulang id-nya untuk mengonfirmasi, atau Enter untuk melewati.")
    jawab = input("  id: ").strip()
    if jawab != v["id"]:
        print("  dilewati.")
        continue
    call("/api/projectData", {"cmd": "del-view", "data": {"id": v["id"]}}, token)
    print("  dihapus.")

sisa = (call("/api/project", token=token).get("hmi") or {}).get("views") or []
print(f"\nSekarang tersisa {len(sisa)} view:")
for v in sisa:
    print("  id=%-26s nama=%-12s item=%-3d rev=%s"
          % (v["id"], v.get("name"), len(v.get("items") or {}), rev_dari(v)))
