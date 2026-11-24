# build_mojokerto_rev1.ps1
# Membaca mojokerto.smbp (konfigurasi Ethernet + SL1 IOScanner 6 device buatan user),
# mengisi channel IOScanner + program, lalu menyimpan ke file BARU. File sumber tidak diubah.
# Rancangan lengkap: scada-mojokerto/docs/plc-program-m221.md
#
# Urutan slave (sesuai file user, dikonfirmasi 23 Nov 2026):
#   dev0 ID1 VSD1 ACS550 | dev1 ID2 VSD2 ACS580 | dev2 ID3 VSD3 ACS580 (belum terpasang)
#   dev3 ID4 FLOW ISOIL MV145 | dev4 ID5 VSD4 ACS580 | dev5 ID6 VSD5 ACS580
param(
  [string]$Src = "C:\Users\Admin\claude\mojokerto.smbp",
  [string]$Out = "C:\Users\Admin\claude\mojokerto-rev1.smbp",
  [int]$Cycle = 50,         # cycle time channel IOScanner, satuan 10 ms -> 50 = 500 ms
  [int]$DevTimeout = 3,     # response timeout per device, satuan 100 ms -> 3 = 300 ms (rev4: 10 = 1 s)
  [int]$RetrySec = 15       # tiap berapa detik IOScanner di-reset kalau ada device yang gagal
)
$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding($true)
$fs = [IO.File]::Open($Src, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs, $enc); $txt = $sr.ReadToEnd(); $sr.Close()
$x = New-Object xml; $x.PreserveWhitespace = $false; $x.LoadXml($txt)
$pd = $x.ProjectDescriptor; $sc = $pd.SoftwareConfiguration

function El($parent, $name, $text) {
  $e = $x.CreateElement($name); if ($null -ne $text) { $e.InnerText = [string]$text }
  [void]$parent.AppendChild($e); return $e
}
function Clear-Node($node) { while ($node.HasChildNodes) { [void]$node.RemoveChild($node.FirstChild) } }

# ====================================================================================
# 1. IOScanner channel
# ====================================================================================
$RD3 = 'IoScannerChannelAccessReadHoldingRegisters'    # FC03
$RD4 = 'IoScannerChannelAccessReadInputRegisters'      # FC04
$WR16 = 'IoScannerChannelAccessWriteMultipleRegisters' # FC16

$acs580 = @(
  @{ n='SW_REF_ACT';  a=$RD3; ro=1;     rl=4; c='400002 ref1, 400003 ref2, 400004 status word, 400005 act1 (20000 = 46.02)' },
  @{ n='CURRENT_32';  a=$RD3; ro=20213; rl=2; c='420214-15 = par 01.07 arus 32-bit (100 = 1 A), word order 58.34' },
  @{ n='DC_BUS';      a=$RD3; ro=110;   rl=1; c='400111 = par 01.11 DC bus (10 = 1 V)' },
  @{ n='VOUT';        a=$RD3; ro=112;   rl=1; c='400113 = par 01.13 tegangan output (1 = 1 V). 01.12 tidak ada -> dibaca terpisah' },
  @{ n='REF1_WRITE';  a=$WR16; wo=1;    wl=1; c='Tulis 400002 ref1 berkala (58.15 = Cw/Ref1/Ref2). 20000 = 46.02 = 50 Hz' }
)
$plan = @(
  @{ dev=0; ch=@(
      @{ n='SW_REF_ACT'; a=$RD3; ro=1;   rl=4; c='40002 ref1, 40003 ref2, 40004 status word, 40005 act1' },
      @{ n='PAR_0103_0111'; a=$RD3; ro=102; rl=9; c='par 0103 freq (0.1 Hz) .. 0104 arus (0.1 A) .. 0107 DC .. 0109 Vout .. 0111 ext ref1' },
      @{ n='REF1_WRITE'; a=$WR16; wo=1; wl=1; c='Tulis 40002 ref1 berkala. 20000 = par 1105 = 50 Hz' }) },
  @{ dev=1; ch=$acs580 },
  @{ dev=2; ch=$acs580 },
  @{ dev=3; ch=@(
      @{ n='FLOW_TOT_FLAGS'; a=$RD4; ro=2;  rl=19; c='MV145 reg 0002-0020: flow%, flow, velocity, T+, P+, T-, P-, flag 1/2 (FC04)' },
      @{ n='BATT_ALM_LPS';   a=$RD4; ro=27; rl=10; c='MV145 reg 0027-0036: baterai %, suhu, sensor test, jumlah alarm, flow l/s' },
      @{ n='FLAGS_3_4';      a=$RD4; ro=51; rl=1;  c='MV145 reg 0051: flag 3/4 (baterai low, mains ada, ...)' }) },
  @{ dev=4; ch=$acs580 },
  @{ dev=5; ch=$acs580 }
)

$io = $pd.HardwareConfiguration.Plc.SerialLineIoScannerConfiguration
$rin = $io.SelectSingleNode('RegisterInputsIoScanner');  Clear-Node $rin
$rout = $io.SelectSingleNode('RegisterOutputsIoScanner'); Clear-Node $rout
$cst = $io.SelectSingleNode('RegisterInputsStatusIoScanner'); Clear-Node $cst
$inIdx = 0; $outIdx = 0; $stIdx = 0
foreach ($p in $plan) {
  $de = $io.Devices.SerialLineIoScannerDeviceEntity | Where-Object { $_.DeviceId -eq [string]$p.dev }
  if (-not $de) { throw "Device $($p.dev) tidak ada di file sumber" }
  $d = 100 + $p.dev
  $de.SelectSingleNode('ResponseTime').InnerText = [string]$DevTimeout   # device yang tidak ada tidak menahan bus 1 s per channel
  $chs = $de.SelectSingleNode('Channels'); Clear-Node $chs
  for ($c = 0; $c -lt $p.ch.Count; $c++) {
    $k = $p.ch[$c]; $isW = ($k.a -eq $WR16)
    $ce = El $chs 'SerialLineIoScannerChannelEntity' $null
    [void](El $ce 'ChannelId' $c); [void](El $ce 'AccessType' $k.a)
    [void](El $ce 'Trigger' 'IoScannerChannelTriggerCyclic'); [void](El $ce 'CyclingTime' $Cycle)
    [void](El $ce 'MemoryBit' $null)
    if ($isW) { [void](El $ce 'ReadOffset' 0); [void](El $ce 'ReadLength' 1); [void](El $ce 'WriteOffset' $k.wo); [void](El $ce 'WriteLength' $k.wl) }
    else      { [void](El $ce 'ReadOffset' $k.ro); [void](El $ce 'ReadLength' $k.rl); [void](El $ce 'WriteOffset' 0); [void](El $ce 'WriteLength' 1) }
    [void](El $ce 'CanEditChannel' 'true'); [void](El $ce 'ErrorHandling' 'IoScannerChannelSetToZero')
    [void](El $ce 'Name' $k.n); [void](El $ce 'Comment' $k.c)
    if ($isW) {
      for ($i = 0; $i -lt $k.wl; $i++) { $r = El $rout 'RegisterIoScanner' $null; [void](El $r 'Address' "%QWN$d.$c.$i"); [void](El $r 'Index' $outIdx); [void](El $r 'Channel' $k.n); $outIdx++ }
    } else {
      for ($i = 0; $i -lt $k.rl; $i++) { $r = El $rin 'RegisterIoScanner' $null; [void](El $r 'Address' "%IWN$d.$c.$i"); [void](El $r 'Index' $inIdx); [void](El $r 'Channel' $k.n); $inIdx++ }
    }
    $s = El $cst 'RegisterIoScannerStatus' $null; [void](El $s 'Address' "%IWNS$d.$c"); [void](El $s 'Index' $stIdx); $stIdx++
  }
}

# ====================================================================================
# 2. Program
# ====================================================================================
$rungs = New-Object System.Collections.ArrayList
function AddRung($name, $comment, [object[]]$lines) { [void]$rungs.Add(@{ name=$name; comment=$comment; lines=$lines }) }
function Ln($il, $cm = '') { ,@($il, $cm) }

# --- daftar drive: n = nomor VSD, dev = device IOScanner, base %MW untuk FUXA, raw %MW salinan IOScanner
$vsd = @(
  @{ n=1; dev=0; type='ACS550'; base=1000; raw=1300; wch=2; q='%Q0.0' },
  @{ n=2; dev=1; type='ACS580'; base=1020; raw=1340; wch=4; q='%Q0.1'; md=1210; mf=1220 },
  @{ n=3; dev=2; type='ACS580'; base=1040; raw=1380; wch=4; q='%Q0.2'; md=1212; mf=1222 },
  @{ n=4; dev=4; type='ACS580'; base=1060; raw=1460; wch=4; q='%Q0.3'; md=1214; mf=1224 },
  @{ n=5; dev=5; type='ACS580'; base=1080; raw=1500; wch=4; q='%Q0.4'; md=1216; mf=1226 }
)
$FLOWRAW = 1420; $FLOW = 1100

AddRung 'INIT' 'Cold start: batas setpoint default 0..50,0 Hz (x10)' @(
  (Ln 'LD    %S13' 'Siklus pertama setelah start'),
  (Ln '[ %MW990 := 0 ]' 'SP_MIN Hz x10'),
  (Ln '[ %MW991 := 500 ]' 'SP_MAX Hz x10'))

# --- salin IOScanner -> %MW raw (assignment saja; semua hitungan dari %MW)
foreach ($v in $vsd) {
  $d = 100 + $v.dev; $lines = @(Ln 'LD    1' 'Selalu')
  for ($i = 0; $i -lt 4; $i++) { $lines += ,@("[ %MW$($v.raw + $i) := %IWN$d.0.$i ]", @('ref1','ref2','status word','act1')[$i]) }
  if ($v.type -eq 'ACS550') {
    for ($i = 0; $i -lt 9; $i++) { $lines += ,@("[ %MW$($v.raw + 4 + $i) := %IWN$d.1.$i ]", "par 01$('{0:D2}' -f (3 + $i))") }
  } else {
    $lines += ,@("[ %MW$($v.raw + 4) := %IWN$d.1.0 ]", '01.07 arus word 1')
    $lines += ,@("[ %MW$($v.raw + 5) := %IWN$d.1.1 ]", '01.07 arus word 2')
    $lines += ,@("[ %MW$($v.raw + 6) := %IWN$d.2.0 ]", '01.11 DC bus')
    $lines += ,@("[ %MW$($v.raw + 7) := %IWN$d.3.0 ]", '01.13 Vout')
  }
  $lines += ,@("[ %MW$(1600 + $v.dev) := %IWNS$d ]", 'status device IOScanner (2 = OK)')
  AddRung "RAW_VSD$($v.n)" "Salin data IOScanner VSD$($v.n) ($($v.type), slave ID $($v.dev + 1)) ke %MW$($v.raw)" $lines
}
$lines = @(Ln 'LD    1' 'Selalu')
for ($i = 0; $i -lt 19; $i++) { $lines += ,@("[ %MW$($FLOWRAW + $i) := %IWN103.0.$i ]", "MV145 reg 00$('{0:D2}' -f (2 + $i))") }
for ($i = 0; $i -lt 10; $i++) { $lines += ,@("[ %MW$($FLOWRAW + 20 + $i) := %IWN103.1.$i ]", "MV145 reg 00$('{0:D2}' -f (27 + $i))") }
$lines += ,@("[ %MW$($FLOWRAW + 30) := %IWN103.2.0 ]", 'MV145 reg 0051')
$lines += ,@('[ %MW1603 := %IWNS103 ]', 'status device IOScanner flow (2 = OK)')
AddRung 'RAW_FLOW' 'Salin data IOScanner flow meter MV145 (slave ID 4) ke %MW1420' $lines

# --- COMM_OK (%IWNS = 2: device ada dan ter-scan) + alarm comm lost
$comm = @(@{b='%M60';w=1600;t='VSD1'},@{b='%M61';w=1601;t='VSD2'},@{b='%M62';w=1602;t='VSD3'},@{b='%M65';w=1603;t='FLOW'},@{b='%M63';w=1604;t='VSD4'},@{b='%M64';w=1605;t='VSD5'})
# rev5: status 1 (sedang inisialisasi sesudah reset IOScanner) juga dianggap OK supaya alarm tidak berkedip
# rev7: rev5/6 menganggap status 1 = OK -> device yang TIDAK terpasang ikut hijau tiap reset (terlihat di FUXA
# 24 Nov 2026). Sekarang: SET hanya di status 2, RESET hanya di status error (bukan 2 dan bukan 1),
# status 1 (init sesudah reset) tidak mengubah apa-apa -> VSD1 tidak berkedip, device absen tetap merah.
foreach ($c in $comm) {
  AddRung "COMM_OK_SET_$($c.t)" "$($c.t): komunikasi OK saat status device IOScanner = 2" @((Ln "LD    [ %MW$($c.w) = 2 ]"), (Ln "S     $($c.b)"))
  AddRung "COMM_OK_RST_$($c.t)" "$($c.t): komunikasi putus saat status bukan 2 dan bukan 1 (1 = init sesudah reset, abaikan)" @(
    (Ln "LD    [ %MW$($c.w) <> 2 ]"), (Ln "AND   [ %MW$($c.w) <> 1 ]"), (Ln "R     $($c.b)"))
}

# rev5: AUTO-RETRY IOScanner. Help M221: "If a communication interruption occurs, the IOScanner stops"
# -> device yang sekali gagal tidak di-scan lagi (terbukti di lapangan 24 Nov 2026: LED SL1 berkedip 4x
# lalu mati, semua device status 3). Tiap $RetrySec detik, kalau %SW210 <> 2 (tidak semua device
# ter-scan), set %S110 = reset Modbus Serial IOScanner SL1 supaya device yang gagal dicoba lagi.
AddRung 'IOS_STATE' 'Salin %SW210 (status IOScanner SL1: 0 stop, 1 init, 2 operasional, 3 sebagian, 4 suspend) untuk FUXA/diagnosa' @(
  (Ln 'LD    1'), (Ln '[ %MW1606 := %SW210 ]'))
# rev6: 'LDR %S6' ditolak compiler (sisi naik tidak boleh pada bit sistem) -> deteksi sisi naik manual
AddRung 'RETRY_SEC' 'Hitung detik: %S6 (basis waktu 1 s) = 1 dan scan sebelumnya 0 (%M112)' @(
  (Ln 'LD    %S6'), (Ln 'ANDN  %M112' '%S6 scan sebelumnya'), (Ln '[ %MW1610 := %MW1610 + 1 ]'))
AddRung 'RETRY_SEC_MEM' 'Simpan %S6 untuk deteksi sisi naik di scan berikutnya' @((Ln 'LD    %S6'), (Ln 'ST    %M112'))
AddRung 'RETRY_PULSE' "Pulse satu scan tiap $RetrySec detik" @((Ln "LD    [ %MW1610 >= $RetrySec ]"), (Ln 'ST    %M111'))
AddRung 'RETRY_CNT_CLR' 'Nol-kan hitungan detik setelah pulse' @((Ln 'LD    %M111'), (Ln '[ %MW1610 := 0 ]'))
AddRung 'RETRY_RESET' 'IOScanner tidak operasional penuh -> reset IOScanner SL1 (%S110) + hitung jumlah reset' @(
  (Ln 'LD    %M111'), (Ln 'AND   [ %SW210 <> 2 ]'), (Ln 'S     %S110' 'reset Modbus Serial IOScanner SL1'), (Ln '[ %MW1611 := %MW1611 + 1 ]' 'jumlah reset (diagnosa)'))
AddRung 'RETRY_RESET_CLR' 'Pengaman: kalau sistem belum menurunkan %S110 setelah 3 s, turunkan' @(
  (Ln 'LD    %S110'), (Ln 'AND   [ %MW1610 >= 3 ]'), (Ln 'R     %S110'))
AddRung 'COMM_LOST' 'Alarm komunikasi putus (FUXA). VSD3 hanya bila %M90 = 1 (drive sudah terpasang)' @(
  (Ln 'LDN   %M60'), (Ln 'ST    %M70' 'VSD1 comm lost'))
AddRung 'COMM_LOST_VSD2' '' @((Ln 'LDN   %M61'), (Ln 'ST    %M71'))
AddRung 'COMM_LOST_VSD3' 'VSD3 belum terpasang: alarm hanya aktif kalau %M90 = 1' @((Ln 'LD    %M90' 'VSD3 terpasang'), (Ln 'ANDN  %M62'), (Ln 'ST    %M72'))
AddRung 'COMM_LOST_VSD4' '' @((Ln 'LDN   %M63'), (Ln 'ST    %M73'))
AddRung 'COMM_LOST_VSD5' '' @((Ln 'LDN   %M64'), (Ln 'ST    %M74'))
AddRung 'COMM_LOST_FLOW' '' @((Ln 'LDN   %M65'), (Ln 'ST    %M75'))

# --- perakitan 32-bit. %M99 = 0: tukar word (perangkat kirim word tinggi dulu), %M99 = 1: lurus
$pairs = @(
  @(1100, ($FLOWRAW + 2)),  # flow (unit alat)  reg 4-5
  @(1102, ($FLOWRAW + 28)), # flow l/s          reg 35-36
  @(1104, ($FLOWRAW + 0)),  # flow %            reg 2-3
  @(1106, ($FLOWRAW + 4)),  # kecepatan         reg 6-7
  @(1108, ($FLOWRAW + 6)),  # T+ raw            reg 8-9
  @(1110, ($FLOWRAW + 12))  # T- raw            reg 14-15
)
foreach ($v in $vsd | Where-Object { $_.type -eq 'ACS580' }) { $pairs += ,@($v.md, ($v.raw + 4)) }
$sw = @(Ln 'LDN   %M99' 'WORD_SWAP = 0 -> tukar word'); $st = @(Ln 'LD    %M99' 'WORD_SWAP = 1 -> tanpa tukar')
foreach ($p in $pairs) {
  $sw += ,@("[ %MW$($p[0]) := %MW$($p[1] + 1) ]", ''); $sw += ,@("[ %MW$($p[0] + 1) := %MW$($p[1]) ]", '')
  $st += ,@("[ %MW$($p[0]) := %MW$($p[1]) ]", ''); $st += ,@("[ %MW$($p[0] + 1) := %MW$($p[1] + 1) ]", '')
}
AddRung 'WORD32_SWAP' 'Rakit float/32-bit flow meter + arus ACS580, word ditukar. Uji saat commissioning: %MF1100 harus = flow di layar MV145' $sw
AddRung 'WORD32_STRAIGHT' 'Sama, tanpa tukar word (pakai kalau %M99 = 1)' $st

# --- flow meter: word tunggal + alarm
AddRung 'FLOW_WORDS' 'Flow meter: info totalizer, flag, alarm, baterai' @(
  (Ln 'LD    1'),
  (Ln "[ %MW1112 := %MW$($FLOWRAW + 8) ]" 'T+ info: MSB overflow, LSB jumlah desimal'),
  (Ln "[ %MW1113 := %MW$($FLOWRAW + 14) ]" 'T- info'),
  (Ln "[ %MW1114 := %MW$($FLOWRAW + 18) ]" 'flag 1 (MSB) / flag 2 (LSB), reg 0020'),
  (Ln "[ %MW1115 := %MW$($FLOWRAW + 27) ]" 'jumlah alarm aktif, reg 0034'),
  (Ln "[ %MW1116 := %MW$($FLOWRAW + 20) ]" 'baterai %, reg 0027'),
  (Ln "[ %MW1117 := %MW$($FLOWRAW + 30) ]" 'flag 3/4, reg 0051'))
AddRung 'FLOW_ALM_EMPTY' 'Flow: pipa kosong (flag 2 bit 0)' @((Ln 'LD    %MW1114:X0'), (Ln 'ST    %M80'))
AddRung 'FLOW_ALM_COIL'  'Flow: coils excitation error (flag 2 bit 1)' @((Ln 'LD    %MW1114:X1'), (Ln 'ST    %M81'))
AddRung 'FLOW_ALM_MIN'   'Flow: di bawah ambang MIN (flag 1 bit 7)' @((Ln 'LD    %MW1114:X15'), (Ln 'ST    %M82'))
AddRung 'FLOW_ALM_MAX'   'Flow: di atas ambang MAX (flag 1 bit 6)' @((Ln 'LD    %MW1114:X14'), (Ln 'ST    %M83'))

# --- skala drive ke %MW untuk FUXA
foreach ($v in $vsd) {
  $b = $v.base; $r = $v.raw
  if ($v.type -eq 'ACS550') {
    AddRung "SCALE_VSD$($v.n)" "VSD$($v.n) ACS550 -> FUXA (sudah 0,1 Hz / 0,1 A dari drive)" @(
      (Ln 'LD    1'),
      (Ln "[ %MW$b := %MW$($r + 2) ]" 'status word'),
      (Ln "[ %MW$($b+1) := %MW$($r + 4) ]" 'par 0103 freq Hz x10'),
      (Ln "[ %MW$($b+2) := %MW$($r + 5) ]" 'par 0104 arus A x10'),
      (Ln "[ %MW$($b+3) := %MW$($r + 8) ]" 'par 0107 DC bus V'),
      (Ln "[ %MW$($b+4) := %MW$($r + 10) ]" 'par 0109 Vout V'),
      (Ln "[ %MW$($b+5) := %MW$($r + 12) ]" 'par 0111 ext ref1 Hz x10'))
  } else {
    AddRung "SCALE_VSD$($v.n)" "VSD$($v.n) ACS580 -> FUXA. /40: 20000 = 46.02 = 50,00 Hz -> Hz x10" @(
      (Ln 'LD    1'),
      (Ln "[ %MW$b := %MW$($r + 2) ]" 'status word'),
      (Ln "[ %MW$($b+1) := %MW$($r + 3) / 40 ]" 'act1 -> Hz x10'),
      (Ln "[ %MF$($v.mf) := DINT_TO_REAL( %MD$($v.md) ) ]" '01.07 arus, 100 = 1 A'),
      (Ln "[ %MF$($v.mf) := %MF$($v.mf) / 10.0 ]" ''),
      (Ln "[ %MW$($b+2) := REAL_TO_INT( %MF$($v.mf) ) ]" 'arus A x10'),
      (Ln "[ %MW$($b+3) := %MW$($r + 6) / 10 ]" '01.11 DC bus V'),
      (Ln "[ %MW$($b+4) := %MW$($r + 7) ]" '01.13 Vout V'),
      (Ln "[ %MW$($b+5) := %MW$($r + 0) / 40 ]" 'ref1 terbaca balik Hz x10'))
  }
}

# --- bit status dari status word (profil ABB Drives)
foreach ($v in $vsd) {
  $b = $v.base; $n = $v.n
  AddRung "STAT_RUN_VSD$n" "VSD$n berjalan (status word bit 2 RDY_REF)" @((Ln "LD    %MW${b}:X2"), (Ln "ST    %M$(24 + $n)"))
  AddRung "STAT_FLT_VSD$n" "VSD$n FAULT (bit 3 TRIPPED), hanya dipercaya bila komunikasi OK" @((Ln "LD    %M$(59 + $n)" 'COMM_OK'), (Ln "AND   %MW${b}:X3"), (Ln "ST    %M$(39 + $n)"))
  AddRung "STAT_WRN_VSD$n" "VSD$n warning (bit 7 ALARM)" @((Ln "LD    %MW${b}:X7"), (Ln "ST    %M$(44 + $n)"))
  AddRung "STAT_REM_VSD$n" "VSD$n di REMOTE (bit 9)" @((Ln "LD    %MW${b}:X9"), (Ln "ST    %M$(49 + $n)"))
}

# --- setpoint: clamp lalu tulis ref1 (x40: Hz x10 -> 20000 = 50 Hz)
foreach ($v in $vsd) {
  $sp = $v.base + 6; $tmp = 1250 + $v.n; $n = $v.n
  AddRung "SP_MAX_VSD$n" "VSD$n setpoint dari FUXA (%MW$sp, Hz x10) dibatasi SP_MAX" @((Ln "LD    [ %MW$sp > %MW991 ]"), (Ln "[ %MW$sp := %MW991 ]"))
  AddRung "SP_MIN_VSD$n" "VSD$n setpoint dibatasi SP_MIN" @((Ln "LD    [ %MW$sp < %MW990 ]"), (Ln "[ %MW$sp := %MW990 ]"))
  AddRung "SP_REF_VSD$n" "VSD$n ref1 ke drive: Hz x10 * 40 (20000 = 50 Hz). Ditulis IOScanner tiap 500 ms" @(
    (Ln 'LD    1'), (Ln "[ %MW$tmp := %MW$sp * 40 ]"), (Ln "[ %QWN$(100 + $v.dev).$($v.wch).0 := %MW$tmp ]"))
}

# --- start / stop hardwired (revisi rev3: selector LOCAL/REMOTE, keputusan user 23 Nov 2026)
#   %I0.0 SEL_REMOTE: 1 = REMOTE (start/stop dari SCADA), 0 = LOCAL (PB ON/OFF di panel). Satu selector semua drive.
#   PB ON  VSDn = %I0.(2n)   kontak NO  (VSD1 %I0.2 ... VSD5 %I0.10)
#   PB OFF VSDn = %I0.(2n+1) kontak NC  (VSD1 %I0.3 ... VSD5 %I0.11) -> 0 = ditekan ATAU kabel putus
#   PB OFF panel aktif di LOCAL MAUPUN REMOTE (pengaman orang di dekat pompa).
#   Pindah LOCAL <-> REMOTE tidak menghentikan pompa (bumpless). Setpoint tetap dari SCADA.
#   Satu rung IL hanya boleh satu LD (rev1 error compile) -> tiap kondisi rung sendiri.
foreach ($v in $vsd) {
  $n = $v.n; $s = 8 + 2*$n; $t = 9 + 2*$n; $f = 39 + $n; $on = "%I0.$(2*$n)"; $off = "%I0.$(2*$n + 1)"
  AddRung "START_REM_VSD$n" "VSD$n START dari SCADA (%M$s): hanya di REMOTE, ditolak bila fault / PB OFF ditekan" @(
    (Ln 'LD    %I0.0' 'REMOTE'), (Ln "AND   %M$s" 'START FUXA'), (Ln "AND   $off" 'PB OFF tidak ditekan (NC)'), (Ln "ANDN  %M$f" 'tidak fault'), (Ln "S     $($v.q)"))
  AddRung "START_LOC_VSD$n" "VSD$n START dari PB ON panel ($on): hanya di LOCAL, ditolak bila fault / PB OFF ditekan" @(
    (Ln 'LDN   %I0.0' 'LOCAL'), (Ln "AND   $on" 'PB ON (NO)'), (Ln "AND   $off" 'PB OFF tidak ditekan (NC)'), (Ln "ANDN  %M$f" 'tidak fault'), (Ln "S     $($v.q)"))
  AddRung "STOP_REM_VSD$n" "VSD$n STOP dari SCADA (%M$t): hanya di REMOTE" @(
    (Ln 'LD    %I0.0' 'REMOTE'), (Ln "AND   %M$t" 'STOP FUXA'), (Ln "R     $($v.q)"))
  AddRung "STOP_PB_VSD$n" "VSD$n STOP dari PB OFF panel ($off, NC): aktif di LOCAL dan REMOTE; kabel putus = stop" @(
    (Ln "LDN   $off" 'PB OFF ditekan / kabel putus'), (Ln "R     $($v.q)"))
  AddRung "STOP_FLT_VSD$n" "VSD$n fault (status word, comm OK) -> RUN mati" @((Ln "LD    %M$f"), (Ln "R     $($v.q)"))
  AddRung "CLR_START_VSD$n" "VSD$n bersihkan bit START dari FUXA (pulse; juga di LOCAL supaya tidak tertahan)" @((Ln "LD    %M$s"), (Ln "R     %M$s"))
  AddRung "CLR_STOP_VSD$n" "VSD$n bersihkan bit STOP dari FUXA (pulse)" @((Ln "LD    %M$t"), (Ln "R     %M$t"))
}
AddRung 'INTERLOCK' 'E-stop tidak sehat (%I0.1 = 0) -> semua RUN mati. Selector TIDAK lagi menghentikan pompa (bumpless). HARUS di bawah rung START' @(
  (Ln 'LDN   %I0.1' 'ESTOP_OK (NC)'),
  (Ln 'R     %Q0.0'), (Ln 'R     %Q0.1'), (Ln 'R     %Q0.2'), (Ln 'R     %Q0.3'), (Ln 'R     %Q0.4'))
AddRung 'MODE_REMOTE' 'Status selector untuk FUXA: %M30 = 1 REMOTE, 0 LOCAL (FUXA menonaktifkan tombol START/STOP saat LOCAL)' @((Ln 'LD    %I0.0'), (Ln 'ST    %M30'))
AddRung 'MODE_ESTOP'  'Status e-stop untuk FUXA: %M31 = 1 sehat' @((Ln 'LD    %I0.1'), (Ln 'ST    %M31'))
$fb = @()
foreach ($v in $vsd) { AddRung "RUN_FB_VSD$($v.n)" "Umpan balik output RUN VSD$($v.n) untuk FUXA" @((Ln "LD    $($v.q)"), (Ln "ST    %M$(19 + $v.n)")) }

# --- tulis rung ke POU
$pou = $sc.Pous.ProgramOrganizationUnits
$pou.Name = 'Mojokerto'
$rs = $pou.SelectSingleNode('Rungs'); Clear-Node $rs
foreach ($r in $rungs) {
  $re = El $rs 'RungEntity' $null
  [void](El $re 'LadderElements' $null)
  $il = El $re 'InstructionLines' $null
  foreach ($l in $r.lines) { $ie = El $il 'InstructionLineEntity' $null; [void](El $ie 'InstructionLine' $l[0]); [void](El $ie 'Comment' $l[1]) }
  [void](El $re 'Name' $r.name); [void](El $re 'MainComment' $r.comment); [void](El $re 'Label' $null); [void](El $re 'IsLadderSelected' 'false')
}

# ====================================================================================
# 3. Simbol + animation table
# ====================================================================================
$mb = $sc.SelectSingleNode('MemoryBits')
function Sym-Bit($i, $sym, $cm) { $e = El $mb 'MemoryBit' $null; [void](El $e 'Address' "%M$i"); [void](El $e 'Index' $i); [void](El $e 'Symbol' $sym); [void](El $e 'Comment' $cm) }
$bits = @{}
foreach ($v in $vsd) { $n = $v.n
  $bits[8+2*$n] = @("VSD${n}_START", "VSD$n START dari FUXA (pulse)"); $bits[9+2*$n] = @("VSD${n}_STOP", "VSD$n STOP dari FUXA (pulse)")
  $bits[19+$n] = @("VSD${n}_RUN_CMD", "VSD$n output RUN aktif"); $bits[24+$n] = @("VSD${n}_RUNNING", "VSD$n berjalan (SW b2)")
  $bits[39+$n] = @("VSD${n}_FAULT", "VSD$n fault (SW b3, comm OK)"); $bits[44+$n] = @("VSD${n}_WARN", "VSD$n warning (SW b7)")
  $bits[49+$n] = @("VSD${n}_REMOTE", "VSD$n di REMOTE (SW b9)"); $bits[59+$n] = @("VSD${n}_COMM_OK", "VSD$n IOScanner status = 2")
  $bits[69+$n] = @("VSD${n}_COMM_LOST", "VSD$n alarm komunikasi putus") }
$bits[65] = @('FLOW_COMM_OK','Flow meter IOScanner status = 2'); $bits[75] = @('FLOW_COMM_LOST','Flow meter alarm komunikasi putus')
$bits[80] = @('FLOW_PIPE_EMPTY','Flow: pipa kosong'); $bits[81] = @('FLOW_COIL_ERR','Flow: coils excitation error')
$bits[82] = @('FLOW_MIN','Flow: di bawah MIN'); $bits[83] = @('FLOW_MAX','Flow: di atas MAX')
$bits[30] = @('MODE_REMOTE','1 = selector REMOTE (SCADA), 0 = LOCAL (PB panel)'); $bits[31] = @('MODE_ESTOP_OK','Salinan %I0.1 untuk FUXA: 1 = e-stop sehat')
$bits[111] = @('RETRY_PULSE','Pulse auto-retry IOScanner (rev5)'); $bits[112] = @('S6_PREV','%S6 scan sebelumnya (deteksi sisi naik)')
$bits[90] = @('VSD3_INSTALLED','1 = VSD3 sudah terpasang, alarm comm lost VSD3 aktif')
$bits[99] = @('WORD_SWAP','0 = tukar word 32-bit (default), 1 = lurus')
foreach ($k in ($bits.Keys | Sort-Object)) { Sym-Bit $k $bits[$k][0] $bits[$k][1] }

$mw = $sc.SelectSingleNode('MemoryWords')
if (-not $mw) { $mw = El $sc 'MemoryWords' $null }
function Sym-Word($i, $sym, $cm) { $e = El $mw 'MemoryWord' $null; [void](El $e 'Address' "%MW$i"); [void](El $e 'Index' $i); [void](El $e 'Symbol' $sym); [void](El $e 'Comment' $cm) }
$words = @{ 990 = @('SP_MIN','Setpoint minimum Hz x10'); 991 = @('SP_MAX','Setpoint maksimum Hz x10') }
foreach ($v in $vsd) { $n = $v.n; $b = $v.base
  $words[$b] = @("VSD${n}_SW", "VSD$n status word"); $words[$b+1] = @("VSD${n}_FREQ", "VSD$n frekuensi Hz x10")
  $words[$b+2] = @("VSD${n}_CURRENT", "VSD$n arus A x10"); $words[$b+3] = @("VSD${n}_DCBUS", "VSD$n DC bus V")
  $words[$b+4] = @("VSD${n}_VOUT", "VSD$n Vout V"); $words[$b+5] = @("VSD${n}_REF_RB", "VSD$n ref1 terbaca Hz x10")
  $words[$b+6] = @("VSD${n}_SP", "VSD$n setpoint dari FUXA Hz x10"); $words[1600+$v.dev] = @("VSD${n}_IOS_STAT", "VSD$n status device IOScanner") }
$words[1603] = @('FLOW_IOS_STAT','Flow status device IOScanner')
$words[1606] = @('IOS_SL1_STATE','%SW210: 0 stop 1 init 2 OK 3 sebagian 4 suspend'); $words[1610] = @('RETRY_SEC_CNT','Hitungan detik auto-retry IOScanner'); $words[1611] = @('IOS_RESET_COUNT','Jumlah reset IOScanner SL1 oleh program')
$words[1112] = @('FLOW_TP_INFO','T+ MSB overflow LSB desimal'); $words[1113] = @('FLOW_TN_INFO','T- info')
$words[1114] = @('FLOW_FLAGS12','Flag 1/2 reg 0020'); $words[1115] = @('FLOW_ALARMS','Jumlah alarm'); $words[1116] = @('FLOW_BATT','Baterai %'); $words[1117] = @('FLOW_FLAGS34','Flag 3/4 reg 0051')
foreach ($k in ($words.Keys | Sort-Object)) { Sym-Word $k $words[$k][0] $words[$k][1] }

$wl = $sc.SelectSingleNode('WatchLists')
$we = El $wl 'WatchListEntity' $null; [void](El $we 'Name' 'Commissioning')
$wi = El $we 'WatchListItemEntities' $null
$watch = @('%MW1606','%MW1611','%IWNS100.0','%IWNS100.1','%IWNS100.2','%MW1600','%MW1601','%MW1602','%MW1603','%MW1604','%MW1605','%M99','%MW1000','%MW1020','%MW1001','%MW1021','%MW1022','%MW1006','%MW1026','%MF1100','%MF1102','%MD1108','%MW1112','%MW1114')
foreach ($a in $watch) { $e = El $wi 'WatchListItemEntity' $null; [void](El $e 'Address' $a); [void](El $e 'IsTraced' 'false'); [void](El $e 'ValueRepresentation' 'Decimal') }

# --- simbol input/output fisik (urutan elemen seperti contoh Schneider Compact_Hardwired_M221.smbe:
#     Address, Index, Symbol, Comment, lalu elemen lain)
$ioSym = @{
  '%I0.0' = @('SEL_REMOTE', 'Selector panel: 1 = REMOTE (start/stop SCADA), 0 = LOCAL (PB panel)')
  '%I0.1' = @('ESTOP_OK',   'E-stop, kontak NC: 1 = sehat')
  '%Q0.0' = @('VSD1_RUN',   'Ke DI start VSD1 ACS550 (hardwired)')
}
foreach ($v in $vsd) {
  $n = $v.n
  $ioSym["%I0.$(2*$n)"]     = @("VSD${n}_PB_ON",  "PB ON VSD$n di panel (NO), aktif di LOCAL")
  $ioSym["%I0.$(2*$n + 1)"] = @("VSD${n}_PB_OFF", "PB OFF VSD$n di panel (NC), aktif di LOCAL dan REMOTE, 0 = stop")
  $ioSym[$v.q] = @("VSD${n}_RUN", "Ke DI start VSD$n ($($v.type)), hardwired")
}
$cpu = $pd.HardwareConfiguration.Plc.Cpu
foreach ($node in @($cpu.DigitalInputs.DiscretInput) + @($cpu.DigitalOutputs.DiscretOutput)) {
  $sym = $ioSym[$node.Address]; if (-not $sym) { continue }
  foreach ($old in @($node.SelectNodes('Symbol')) + @($node.SelectNodes('Comment'))) { [void]$node.RemoveChild($old) }
  $idx = $node.SelectSingleNode('Index')
  $c = $x.CreateElement('Comment'); $c.InnerText = $sym[1]; [void]$node.InsertAfter($c, $idx)
  $s = $x.CreateElement('Symbol');  $s.InnerText = $sym[0]; [void]$node.InsertAfter($s, $idx)
}

# ====================================================================================
# 4. Simpan
# ====================================================================================
$name = [IO.Path]::GetFileNameWithoutExtension($Out)
$pd.Name = $name; $pd.FullName = $Out
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true; $settings.IndentChars = '  '; $settings.Encoding = $enc; $settings.NewLineChars = "`r`n"
$w = [System.Xml.XmlWriter]::Create($Out, $settings); $x.Save($w); $w.Close()
"Saved $Out : $($rungs.Count) rung, $inIdx %IWN, $outIdx %QWN, $stIdx channel"
