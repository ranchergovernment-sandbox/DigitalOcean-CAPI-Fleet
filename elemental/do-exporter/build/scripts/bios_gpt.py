#!/usr/bin/env python3
"""GPT surgery on a raw disk image without mounting it.

Modes:
  bios_gpt.py <image> <min_gap_sectors>
      Add a BIOS Boot partition into the free LBA 34..2047 gap.
  bios_gpt.py <image> --esp
      Read-only: locate the EFI System Partition, print JSON.
  bios_gpt.py <image> --add-elemental-parts <state_gib> <persistent_gib>
      Grow the image and append the Elemental `state` and `persistent`
      partitions the seed image is missing (elemental-rootfs.service mounts
      /dev/disk/by-partlabel/persistent unconditionally -> emergency mode on
      a fresh disk). GPT partition NAMES are literally `state` and
      `persistent` so udev's /dev/disk/by-partlabel/ lookups resolve;
      filesystems (ext4) are created by the caller via `mke2fs -E offset`
      using the returned byte offsets.
"""
import json
import struct
import sys
import zlib

BIOS_BOOT_GUID = "21686148-6449-6E6F-744E-656564424949"
ESP_GUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
LINUX_FS_GUID = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
SS = 512  # only handles 512-byte sectors
GIB_SECTORS = (1 << 30) // SS  # 2097152 sectors per GiB


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


def gpt_name(raw):
    return raw.decode("utf-16-le", "ignore").rstrip("\x00")


def read_gpt(f):
    """Parse + validate the protective MBR, primary GPT header and entries."""
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
    entry_lba, num_entries, entry_size, pe_crc = struct.unpack("<QIII", hdr[72:92])
    if entry_size < 128 or entry_size % 128 != 0:
        die(1, "unexpected GPT entry size %d" % entry_size)
    f.seek(entry_lba * SS)
    entries = f.read(num_entries * entry_size)
    if zlib.crc32(entries) & 0xFFFFFFFF != pe_crc:
        die(1, "GPT entry array CRC mismatch (corrupt image?)")
    return hdr, entry_lba, num_entries, entry_size, entries


def fix_header(h, entries_crc):
    # GPT spec: header CRC is computed over bytes 0..91 ONLY (with the
    # CRC field itself zeroed). CRC-ing the full 512 bytes yields a value
    # the Linux kernel rejects -> it falls back to the protective MBR and
    # the disk appears to have NO partitions (GRUB ignores CRCs, so GRUB
    # still boots while dracut emergency-modes).
    h = bytearray(h)
    h[88:92] = struct.pack("<I", entries_crc)
    h[16:20] = b"\x00" * 4
    crc = zlib.crc32(bytes(h[:92])) & 0xFFFFFFFF
    h[16:20] = struct.pack("<I", crc)
    return bytes(h)


def hdr_crc_ok(h):
    hb = bytearray(h[:92])
    hb[16:20] = b"\x00" * 4
    return struct.unpack("<I", h[16:20])[0] == (zlib.crc32(bytes(hb)) & 0xFFFFFFFF)


def self_check(f, entry_lba, num_entries, entry_size, backup_entries_lba, backup_hdr_lba):
    """Kernel-grade validation: exactly the checks Linux does on boot."""
    ents_bytes = num_entries * entry_size
    f.seek(SS)
    ph = f.read(SS)
    if not hdr_crc_ok(ph):
        die(1, "self-check failed: primary GPT header CRC invalid")
    f.seek(entry_lba * SS)
    if zlib.crc32(f.read(ents_bytes)) & 0xFFFFFFFF != struct.unpack("<I", ph[88:92])[0]:
        die(1, "self-check failed: primary GPT entries CRC invalid")
    f.seek(backup_hdr_lba * SS)
    bhh = f.read(SS)
    if not hdr_crc_ok(bhh):
        die(1, "self-check failed: backup GPT header CRC invalid")
    f.seek(backup_entries_lba * SS)
    if zlib.crc32(f.read(ents_bytes)) & 0xFFFFFFFF != struct.unpack("<I", bhh[88:92])[0]:
        die(1, "self-check failed: backup GPT entries CRC invalid")


def make_entry(entry_size, type_guid, start, end, name):
    e = bytearray(entry_size)
    e[0:16] = guid_raw(type_guid)
    e[32:48] = struct.pack("<QQ", start, end)
    e[48:56] = b"\x00" * 8  # attributes
    nb = name.encode("utf-16-le")
    e[56:56 + len(nb)] = nb
    return bytes(e)


def align_up(x, a):
    return ((x + a - 1) // a) * a


def find_esp(img):
    """Read-only: locate the EFI System Partition. Prints its JSON location."""
    f = open(img, "rb")
    _hdr, _el, _ne, _es, entries = read_gpt(f)
    num_entries, entry_size = _ne, _es
    for i in range(num_entries):
        e = entries[i * entry_size:(i + 1) * entry_size]
        if e[0:16] != b"\x00" * 16 and guid_str(e[0:16]) == ESP_GUID:
            s, en = struct.unpack("<QQ", e[32:48])
            print(json.dumps({"esp_start": s, "esp_end": en,
                              "esp_sectors": en - s + 1}))
            return
    die(1, "no EFI System Partition found")


def add_elemental_parts(img, state_gib, persistent_gib):
    """Grow the image and append Elemental state + persistent partitions.

    The standard Elemental disk layout carries state (holds the active and
    passive system images after the first install) and persistent (user
    data) partitions besides EFI/OEM/RECOVERY. Seed images built without
    them emergency-mode: elemental-rootfs.service unconditionally mounts
    /dev/disk/by-partlabel/persistent. Partition NAMES are `state` /
    `persistent` (that is what /dev/disk/by-partlabel matches); the ext4
    labels COS_STATE / COS_PERSISTENT are applied by the caller.
    """
    f = open(img, "r+b")
    hdr, entry_lba, num_entries, entry_size, entries = read_gpt(f)

    have = set()
    used = set()
    for i in range(num_entries):
        e = entries[i * entry_size:(i + 1) * entry_size]
        if e[0:16] != b"\x00" * 16:
            used.add(i)
            name = gpt_name(e[56:128])
            if name in ("state", "persistent"):
                have.add(name)
    if have:
        print(json.dumps({"already": True, "present": sorted(have)}))
        return
    if len(used) >= num_entries:
        die(2, "no free GPT entry slots")

    old_total = f.seek(0, 2)
    if old_total % SS:
        die(1, "image size not a multiple of %d" % SS)
    old_sectors = old_total // SS
    if struct.unpack("<Q", hdr[32:40])[0] != old_sectors - 1:
        die(1, "backup GPT header not at last LBA (unexpected layout)")

    ents_sectors = align_up(num_entries * entry_size, SS) // SS
    state_s = state_gib * GIB_SECTORS
    persistent_s = persistent_gib * GIB_SECTORS
    # 1 MiB alignment for the new partitions (mkfs and DO import friendly)
    state_start = align_up(old_sectors, 2048)
    state_end = state_start + state_s - 1
    per_start = state_end + 1
    per_end = per_start + persistent_s - 1
    new_sectors = align_up(per_end + 1 + ents_sectors + 2, 2048)
    backup_hdr_lba = new_sectors - 1
    backup_entries_lba = backup_hdr_lba - ents_sectors
    last_usable = backup_entries_lba - 1
    if per_end >= last_usable:
        die(1, "size math error: partitions overlap backup GPT area")

    slots = [i for i in range(num_entries) if i not in used]
    slot_state, slot_persistent = slots[0], slots[1]

    def splice(entries_raw, slot, entry):
        return (entries_raw[:slot * entry_size] + entry +
                entries_raw[(slot + 1) * entry_size:])

    entries_new = entries
    entries_new = splice(entries_new, slot_state,
                         make_entry(entry_size, LINUX_FS_GUID, state_start, state_end, "state"))
    entries_new = splice(entries_new, slot_persistent,
                         make_entry(entry_size, LINUX_FS_GUID, per_start, per_end, "persistent"))
    pe_crc = zlib.crc32(entries_new) & 0xFFFFFFFF

    # Grow the image; the old backup GPT header/entries end up inside the
    # new state partition region and get overwritten by the mkfs that follows.
    f.truncate(new_sectors * SS)

    # Primary header: point at the new backup header, extend last-usable LBA.
    ph = bytearray(hdr)
    ph[32:40] = struct.pack("<Q", backup_hdr_lba)
    ph[48:56] = struct.pack("<Q", last_usable)
    # Backup header: mirrored copy with its own location + entries array.
    bh = bytearray(hdr)
    bh[24:32] = struct.pack("<Q", 1)              # primary header LBA
    bh[32:40] = struct.pack("<Q", backup_hdr_lba)  # own location
    bh[40:48] = struct.pack("<Q", last_usable)     # first usable (mirrored)
    bh[48:56] = struct.pack("<Q", last_usable)
    bh[72:80] = struct.pack("<Q", backup_entries_lba)

    f.seek(entry_lba * SS)
    f.write(entries_new)
    f.seek(backup_entries_lba * SS)
    f.write(entries_new)
    f.seek(SS)
    f.write(fix_header(bytes(ph), pe_crc))
    f.seek(backup_hdr_lba * SS)
    f.write(fix_header(bytes(bh), pe_crc))
    f.flush()

    self_check(f, entry_lba, num_entries, entry_size, backup_entries_lba, backup_hdr_lba)
    f.close()

    print(json.dumps({
        "state": {
            "partition": slot_state + 1, "start": state_start, "end": state_end,
            "sectors": state_s, "offset_bytes": state_start * SS,
            "label": "COS_STATE",
        },
        "persistent": {
            "partition": slot_persistent + 1, "start": per_start, "end": per_end,
            "sectors": persistent_s, "offset_bytes": per_start * SS,
            "label": "COS_PERSISTENT",
        },
        "new_size_sectors": new_sectors,
    }))


def add_bios_partition(img, min_gap):
    f = open(img, "r+b")
    hdr, entry_lba, num_entries, entry_size, entries = read_gpt(f)

    used = []
    first_part_start = None
    for i in range(num_entries):
        e = entries[i * entry_size:(i + 1) * entry_size]
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
    entries_new = entries[:slot * entry_size] + bytes(e) + \
        entries[(slot + 1) * entry_size:]
    pe_crc = zlib.crc32(entries_new) & 0xFFFFFFFF

    total = f.seek(0, 2)
    if total % SS:
        die(1, "image size not a multiple of %d" % SS)
    backup_hdr_lba = total // SS - 1
    if struct.unpack("<Q", hdr[32:40])[0] != backup_hdr_lba:
        die(1, "backup GPT header not at last LBA (unexpected layout)")

    # backup entries array: num_entries * entry_size BYTES = 32 sectors for
    # the usual 128x128 layout -- NOT num_entries sectors (that mis-placement
    # used to overwrite the tail of the last data partition).
    ents_bytes = num_entries * entry_size
    backup_entries_lba = backup_hdr_lba - ((ents_bytes + SS - 1) // SS)

    f.seek(entry_lba * SS)
    f.write(entries_new)
    f.seek(backup_entries_lba * SS)
    f.write(entries_new)
    f.seek(SS)
    f.write(fix_header(hdr, pe_crc))
    f.seek(backup_hdr_lba * SS)
    bh = bytearray(f.read(SS))
    if bytes(bh[0:8]) != b"EFI PART":
        die(1, "no backup GPT header (unexpected layout)")
    bh[72:80] = struct.pack("<Q", backup_entries_lba)
    f.seek(backup_hdr_lba * SS)
    f.write(fix_header(bytes(bh), pe_crc))

    self_check(f, entry_lba, num_entries, entry_size, backup_entries_lba, backup_hdr_lba)
    f.flush()
    f.close()

    print(json.dumps({
        "partition": slot + 1, "start": gap_start, "end": gap_end,
        "size_sectors": gap, "first_part_start": first_part_start,
    }))


def main():
    if len(sys.argv) == 3 and sys.argv[2] == "--esp":
        find_esp(sys.argv[1])
        return
    if len(sys.argv) >= 3 and sys.argv[2] == "--add-elemental-parts":
        if len(sys.argv) != 5:
            die(1, "usage: bios_gpt.py <image> --add-elemental-parts <state_gib> <persistent_gib>")
        add_elemental_parts(sys.argv[1], int(sys.argv[3]), int(sys.argv[4]))
        return
    if len(sys.argv) != 3:
        die(1, "usage: bios_gpt.py <image> <min_gap_sectors> | "
               "bios_gpt.py <image> --esp | "
               "bios_gpt.py <image> --add-elemental-parts <state_gib> <persistent_gib>")
    add_bios_partition(sys.argv[1], int(sys.argv[2]))


if __name__ == "__main__":
    main()
