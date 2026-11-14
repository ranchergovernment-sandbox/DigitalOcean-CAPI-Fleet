#!/usr/bin/env python3
"""Add a BIOS Boot partition to a GPT disk image without mounting it."""
import json
import struct
import sys
import zlib

BIOS_BOOT_GUID = "21686148-6449-6E6F-744E-656564424949"
SS = 512  # only handles 512-byte sectors


def die(code, msg):
    print(json.dumps({"error": msg}), file=sys.stderr)
    sys.exit(code)


def guid_str(raw):
    d1, d2, d3 = struct.unpack("<IHH", raw[0:8])
    d4 = raw[8:10].hex().upper()
    d5 = raw[10:16].hex().upper()
    return "%08X-%04X-%04X-%s-%s" % (d1, d2, d3, d4, d5)


def guid_raw(s):
    p = s.replace("-", "")
    packed = struct.pack("<IHH", int(p[0:8], 16), int(p[8:12], 16), int(p[12:16], 16))
    return packed + bytes.fromhex(p[16:])


def main():
    if len(sys.argv) != 3:
        die(1, "usage: bios_gpt.py <image> <min_gap_sectors>")
    img, min_gap = sys.argv[1], int(sys.argv[2])

    f = open(img, "r+b")
    f.seek(0)
    mbr = f.read(SS)
    if len(mbr) < SS or mbr[510:512] != b"\x55\xaa":
        die(1, "no MBR boot signature (not a disk image?)")
    if mbr[0x1c2:0x1c3] != b"\xee":
        die(1, "no protective MBR (image is not GPT-partitioned)")

    f.seek(SS)
    hdr = f.read(SS)
    if hdr[0:8] != b"EFI PART":
        die(1, "no GPT header at LBA 1")

    entry_lba, num_entries, entry_size, _pe_crc = struct.unpack("<QIII", hdr[72:92])
    if entry_size < 128 or entry_size % 128 != 0:
        die(1, "unexpected GPT entry size %d" % entry_size)

    f.seek(entry_lba * SS)
    entries_raw = f.read(num_entries * entry_size)
    if zlib.crc32(entries_raw) & 0xFFFFFFFF != _pe_crc:
        die(1, "GPT entry array CRC mismatch (corrupt image?)")

    used = []
    first_part_start = None
    for i in range(num_entries):
        e = entries_raw[i * entry_size:(i + 1) * entry_size]
        if e[0:16] != b"\x00" * 16:
            s, en = struct.unpack("<QQ", e[32:48])
            used.append(i)
            if guid_str(e[0:16]) == BIOS_BOOT_GUID:
                print(json.dumps({"partition": i + 1, "start": s, "end": en,
                                  "size_sectors": en - s + 1, "already": True}))
                sys.exit(0)
            if s and (first_part_start is None or s < first_part_start):
                first_part_start = s

    if first_part_start is None:
        die(1, "no partitions found")
    gap_start, gap_end = 34, first_part_start - 1
    gap = gap_end - gap_start + 1
    if gap < min_gap:
        die(2, "free gap is %d sectors; need >= %d" % (gap, min_gap))

    if len(used) >= num_entries:
        die(2, "no free GPT entry slots")

    slot = next(i for i in range(num_entries) if i not in used)

    e = bytearray(entry_size)
    e[0:16] = guid_raw(BIOS_BOOT_GUID)
    e[32:48] = struct.pack("<QQ", gap_start, gap_end)
    e[48:56] = b"\x00" * 8
    name = "BIOS Boot"
    e[56:56 + len(name) * 2] = name.encode("utf-16-le")
    entries_new = entries_raw[:slot * entry_size] + bytes(e) + \
        entries_raw[(slot + 1) * entry_size:]
    pe_crc = zlib.crc32(entries_new) & 0xFFFFFFFF

    total = f.seek(0, 2)
    if total % SS:
        die(1, "image size not a multiple of %d" % SS)
    backup_hdr_lba = total // SS - 1
    if struct.unpack("<Q", hdr[32:40])[0] != backup_hdr_lba:
        die(1, "backup GPT header not at last LBA (unexpected layout)")

    def fix_header(h, entries_crc):
        h = bytearray(h)
        h[88:92] = struct.pack("<I", entries_crc)
        h[16:20] = b"\x00" * 4
        crc = zlib.crc32(bytes(h)) & 0xFFFFFFFF
        h[16:20] = struct.pack("<I", crc)
        return bytes(h)

    f.seek(entry_lba * SS)
    f.write(entries_new)
    f.seek((backup_hdr_lba - num_entries) * SS)
    f.write(entries_new)
    f.seek(SS)
    f.write(fix_header(hdr, pe_crc))
    f.seek(backup_hdr_lba * SS)
    bh = bytearray(f.read(SS))
    if bytes(bh[0:8]) != b"EFI PART":
        die(1, "no backup GPT header (unexpected layout)")
    bh[72:80] = struct.pack("<Q", backup_hdr_lba - num_entries)
    f.seek(backup_hdr_lba * SS)
    f.write(fix_header(bytes(bh), pe_crc))
    f.flush()
    f.close()

    print(json.dumps({
        "partition": slot + 1, "start": gap_start, "end": gap_end,
        "size_sectors": gap, "first_part_start": first_part_start,
    }))


if __name__ == "__main__":
    main()