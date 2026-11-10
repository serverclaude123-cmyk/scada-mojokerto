"""Terapkan view dari scada-mojokerto.fuxap ke FUXA yang sedang jalan, plus tag PLC yang belum ada.
Device MQTT tidak disentuh (kredensial broker aman); device PLC hanya DITAMBAH tag yang kurang,
tag dan properti yang sudah ada dibiarkan. Butuh login FUXA: FUXA_USER dan FUXA_PASS di environment.
Pakai: python fuxa/patch_live_view.py"""
import json, os, sys, urllib.error, urllib.request

BASE = "http://127.0.0.1:1881"
H = {"Content-Type": "application/json"}

def call(path, body=None, token=None):
    h = dict(H)
    if token:
        h["x-access-token"] = token
    req = urllib.request.Request(BASE + path, json.dumps(body).encode() if body is not None else None, h)
    raw = urllib.request.urlopen(req).read()
    return json.loads(raw) if raw else None  # set-view / set-device membalas body kosong

token = None
if os.environ.get("FUXA_USER"):
    try:
        # FUXA 1.3.5: {"status": ..., "data": {..., "token": "<jwt>"}}
        token = call("/api/signin", {"username": os.environ["FUXA_USER"], "password": os.environ["FUXA_PASS"]})["data"]["token"]
    except urllib.error.HTTPError as e:
        sys.exit(f"login FUXA gagal ({e.code}): user/password salah?")
repo = json.load(open(os.path.join(os.path.dirname(__file__), "scada-mojokerto.fuxap"), encoding="utf-8"))
live = call("/api/project", token=token)

# device PLC: tambahkan tag yang ada di repo tapi belum ada di proyek yang jalan
repo_plc = repo["devices"]["PLC M221"]
live_plc = next((d for d in live["devices"].values() if d["id"] == repo_plc["id"]), None)
if live_plc is None:
    sys.exit("device PLC M221 tidak ditemukan di FUXA yang jalan")
def _addr(t):
    return (str(t.get("memaddress")), str(t.get("address")), t.get("type"))
# tambah tag yang belum ada, dan perbaiki tag repo yang alamatnya beda (mis. plc_run_vsd1 pindah ke %M4)
added = [t for t in repo_plc["tags"]
         if t not in live_plc["tags"] or _addr(live_plc["tags"][t]) != _addr(repo_plc["tags"][t])]
if added:
    for t in added:
        live_plc["tags"][t] = repo_plc["tags"][t]
    call("/api/projectData", {"cmd": "set-device", "data": live_plc}, token)
print("tag PLC ditambah/diperbaiki:", ", ".join(added) or "(tidak ada)")

# device "Fuxa Server": tag status koneksi (sysType 1) yang dipakai lampu di header.
# HARUS diganti, bukan ditambah. FUXA mengisi status lewat
#   connectionTags.find(tag => tag.memaddress === deviceId)
# yang hanya mengenai tag PERTAMA dengan memaddress itu. Kalau tag lama dibiarkan dan
# tag baru hanya ditambahkan, tag baru tidak pernah terisi dan lampunya merah selamanya.
repo_srv = repo.get("server") or {}
if repo_srv.get("tags"):
    live_srv = next((d for d in live["devices"].values() if d["id"] == repo_srv["id"]), None)
    if live_srv is None:
        live_srv = dict(repo_srv)
    else:
        lama = {k: v for k, v in (live_srv.get("tags") or {}).items() if v.get("sysType") != 1}
        lama.update(repo_srv["tags"])
        live_srv["tags"] = lama
    call("/api/projectData", {"cmd": "set-device", "data": live_srv}, token)
    print("tag status koneksi dipasang:", ", ".join(sorted(repo_srv["tags"])))

# set-view mencocokkan berdasarkan view.id (runtime/project/index.js, setView), jadi id
# yang dikirim menentukan view MANA yang ditimpa.
#
# JANGAN memakai live["hmi"]["views"][0]. Proyek bisa punya lebih dari satu view dan
# urutannya bukan urutan yang terlihat: di PC ini views[0] ternyata "MainView" bawaan
# FUXA, bukan "Overview". Versi lama baris ini menimpa id view repo dengan id views[0],
# sehingga isi baru masuk ke MainView, Overview asli tidak tersentuh, dan layarnya tetap
# menampilkan view lama -- tampak seperti "perubahan tidak masuk" padahal masuk ke
# tempat yang salah, dan menyisakan dua view bernama sama.
view = repo["hmi"]["views"][0]
live_views = live["hmi"]["views"]
cocok_id = next((v for v in live_views if v["id"] == view["id"]), None)
if cocok_id is None:
    cocok_nama = [v for v in live_views if v.get("name") == view.get("name")]
    if len(cocok_nama) == 1:
        view["id"] = cocok_nama[0]["id"]
        print("view dicocokkan lewat nama ->", view["id"])
    elif len(cocok_nama) > 1:
        sys.exit("ada %d view bernama %r di FUXA; rapikan dulu lewat editor supaya tidak salah timpa"
                 % (len(cocok_nama), view.get("name")))
    else:
        print("view belum ada di FUXA, akan dibuat baru:", view["id"])
call("/api/projectData", {"cmd": "set-view", "data": view}, token)
print("view diganti:", view["name"], "id:", view["id"])

# Peringatkan kalau tersisa view lain bernama sama (mis. korban bug di atas).
kembar = [v for v in live_views if v.get("name") == view.get("name") and v["id"] != view["id"]]
for v in kembar:
    print("  [!] masih ada view lain bernama %r dengan id %s (%d item)."
          % (v.get("name"), v["id"], len(v.get("items") or {})))
    print("      Hapus lewat editor FUXA supaya tidak membingungkan. Tidak saya hapus otomatis.")

mulai = (live["hmi"].get("layout") or {}).get("start")
if mulai and mulai != view["id"]:
    print("  [!] layout.start menunjuk ke view %s, bukan %s." % (mulai, view["id"]))
    print("      Layar awal FUXA akan menampilkan view itu, bukan yang baru saja dikirim.")
