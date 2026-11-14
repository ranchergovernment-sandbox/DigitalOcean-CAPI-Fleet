#!/usr/bin/env bash
# bios-diagnose.sh — read-only forensics for BIOS-patched Elemental/SLE Micro images.
# Usage: ./bios-diagnose.sh <image>   (raw or qcow2; qcow2 requires qemu-img)
#
# Instantly distinguishes the two failure classes:
#   1. Artifact NOT patched (MBR is the untouched GPT protective MBR = zeros)
#      -> SeaBIOS silently hangs after "Booting from hard drive".
#   2. Artifact patched but GRUB chain broken -> MBR shows "GRUB " code,
#      kernel_sector@92 set, blocklist at LBA34+500 readable.
set -u
IMG="${1:-}"
[ -n "$IMG" ] || { echo "usage: $0 <image.raw|image.qcow2>"; exit 1; }
[ -r "$IMG" ] || { echo "cannot read $IMG"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RAW="$TMP/disk.raw"
case "$IMG" in
  *.qcow2)
    command -v qemu-img >/dev/null || { echo "qcow2 input but qemu-img not found"; exit 1; }
    echo "== converting qcow2 -> raw (temp)"
    qemu-img convert -f qcow2 -O raw "$IMG" "$RAW" || exit 1
    ;;
  *) cp --reflink=auto "$IMG" "$RAW" 2>/dev/null || cp "$IMG" "$RAW" ;;
esac

python3 - "$RAW" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb')
def sec(lba):
    f.seek(lba*512); return f.read(512)

print("== LBA 0 (MBR / protective MBR)")
mbr = sec(0)
print("  first 32 bytes :", mbr[:32].hex())
grub_sig = b'GRUB ' in mbr
noncode  = mbr[:440] == b'\x00'*440
pentry   = mbr[446:510]
sig55aa  = mbr[510:512] == b'\x55\xaa'
ptype    = pentry[4]
kernel_sector = struct.unpack('<Q', mbr[92:100])[0]
boot_drive = mbr[0x64]
print(f"  boot code present       : {not noncode}   (all-zero => protective MBR, NOT patched)")
print(f"  'GRUB ' string in MBR   : {grub_sig}")
print(f"  kernel_sector (off 92)  : {kernel_sector}   (patched => 34, unpatched => 0)")
print(f"  boot_drive   (off 0x64) : 0x{boot_drive:02x}   (patched => 0xff)")
print(f"  MBR partition entry type: 0x{ptype:02x}   (0xee == GPT protective)")
print(f"  0x55AA signature        : {sig55aa}")

print("== LBA 1 (GPT header)")
hdr = sec(1)
if hdr[:8] == b'EFI PART':
    nent, esz = struct.unpack('<II', hdr[80:88])
    print(f"  entries: {nent}, entry size: {esz}")
else:
    print("  NO valid GPT header!")

print("== partition table")
elba = struct.unpack('<Q', hdr[72:80])[0] if hdr[:8]==b'EFI PART' else 2
f.seek(elba*512); ents = f.read(nent*esz) if hdr[:8]==b'EFI PART' else b''
BIOS_BOOT_GUID = bytes.fromhex('4868612169 64496e6f744e65656442 4949'.replace(' ',''))
for i in range(nent):
    e = ents[i*esz:(i+1)*esz]
    if e[:16] == b'\x00'*16: continue
    tg = e[:16]
    start, end = struct.unpack('<QQ', e[32:48])
    name = e[56:128].decode('utf-16-le', 'ignore').rstrip('\x00')
    kind = 'BIOS Boot' if tg.hex()=='4861682149646f6e744e656564424949' else ('EFI System' if tg.hex()=='28732ac11ff8d211ba4b00a0c93ec93b' else 'other')
    print(f"  p{i+1}: LBA {start}..{end}  type={kind:10s}  name={name!r}")

print("== LBA 34 (first core.img sector = diskboot)")
db = sec(34)
print("  first 32 bytes :", db[:32].hex())
term_start, term_len = struct.unpack('<QH', db[488:498])
bl_start, bl_len, bl_seg = struct.unpack('<QHH', db[500:512]) if len(db)>=512 else (0,0,0)
print(f"  blocklist @500  : start={bl_start} len={bl_len} seg=0x{bl_seg:04x}")
print(f"  terminator @488 : start={term_start} len={term_len} (len must be 0)")

print("== verdict")
if noncode and not grub_sig:
    print("  UNPATCHED: MBR boot code area is all zeros (protective MBR only).")
    print("  This artifact never went through the BIOS patch — testing a stale or")
    print("  upstream file. SeaBIOS will hang silently exactly as observed.")
elif grub_sig and kernel_sector:
    print(f"  PATCHED: GRUB MBR present, kernel_sector={kernel_sector}.")
    if kernel_sector == 34 and bl_start > 0 and bl_len > 0 and term_len == 0:
        print("  diskboot blocklist looks sane; chain is ours. If still silent, run:")
        print("    qemu-system-x86_64 -m 2048 -drive file=<raw>,format=raw -nographic")
        print("  (with the serial-enabled core.img) to see GRUB stage markers.")
    else:
        print("  PATCHED but blocklist/header inconsistent — inspect offsets above.")
else:
    print("  INDETERMINATE: inspect raw hex above.")
PY