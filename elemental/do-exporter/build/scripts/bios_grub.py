#!/usr/bin/env python3
"""bios_grub.py - embed a grub2 i386-pc core.img into a raw disk image.

Replaces `grub2-bios-setup` for this pipeline: bios-setup enumerates the
host's block devices via /sys/block and dies in containers that cannot see
the node's device nodes ("failed to get canonical path of /dev/nvme0n1p4").
Everything it does to the image (the no-Reed-Solomon path, i.e.
`grub2-bios-setup --no-rs-codes`) is deterministic byte patching, derived
from grub-core/boot/i386/pc/boot.S, diskboot.S, include/grub/i386/pc/boot.h
and util/setup.c of SUSE's grub2:

  boot.img -> MBR (LBA 0), 512 bytes total:
    [0x5c:0x64]  kernel_sector: u64 LE = LBA of core.img's first sector
    [0x64]       boot_drive: 0xFF (use the BIOS boot drive)
    [0x1b8:0x1fe] NT magic + partition table: preserved from the MBR
    (boot.img's own 0x55AA at 0x1fe is kept)

  core.img -> BIOS Boot partition (LBA <start>), N = ceil(size/512) sectors,
  zero-padded. Its first (diskboot) sector gets a blocklist of 12-byte
  entries {start u64, len u16, segment u16} written downward from offset
  500: the core sectors AFTER the first are read by diskboot into segment
  0x820; a zeroed terminator entry sits below the last real entry. (Our
  layout is one contiguous run, so: entry at 500, terminator at 488.)

The diskboot sector loads at 0x8200; the run segment is
GRUB_BOOT_I386_PC_KERNEL_SEG (0x800) + 0x20 = 0x820, per diskboot.S.

Usage: bios_grub.py <raw-image> <start-lba> <boot.img> <core.img>
Prints JSON: {"core_sectors": N, "core_bytes": n, "kernel_sector": lba}
Exits 2 on bad inputs.
"""
import json
import struct
import sys

SS = 512
OFF_KERNEL_SECTOR = 0x5C
OFF_BOOT_DRIVE = 0x64
OFF_NT_MAGIC = 0x1B8
OFF_PART_END = 0x1FE
FIRST_BLOCK_OFF = SS - 12  # 500: first blocklist entry in diskboot sector
SEG_CORE = 0x820


def die(code, msg):
    print(json.dumps({"error": msg}))
    sys.exit(code)


def main():
    if len(sys.argv) != 5:
        die(2, f"usage: {sys.argv[0]} <raw-image> <start-lba> <boot.img> <core.img>")
    raw_path, start_s, boot_path, core_path = sys.argv[1:5]
    try:
        start = int(start_s)
    except ValueError:
        die(2, f"bad start LBA: {start_s!r}")
    if start < 34:
        die(2, f"implausible BIOS Boot partition start {start}")

    with open(boot_path, "rb") as f:
        boot = bytearray(f.read())
    if len(boot) != SS:
        die(2, f"boot.img must be {SS} bytes, got {len(boot)} (wrong package/arch?)")
    with open(core_path, "rb") as f:
        core = f.read()
    if len(core) < SS:
        die(2, f"core.img too small ({len(core)} B)")
    if (len(core) % SS) != 0:
        core = core + b"\x00" * (SS - (len(core) % SS))  # pad to whole sectors

    nsec = len(core) // SS

    # --- patch boot.img (the future MBR) -------------------------------
    boot[OFF_KERNEL_SECTOR:OFF_KERNEL_SECTOR + 8] = struct.pack("<Q", start)
    boot[OFF_BOOT_DRIVE] = 0xFF

    # --- patch core's first (diskboot) sector --------------------------
    dboot = bytearray(core[:SS])
    # Clean the blocklist area (mkimage placeholder entries) before writing
    # ours. Clear ONLY offsets (FIRST_BLOCK_OFF - 12*4)..511: a negative range
    # start would wrap and wipe the whole diskboot sector (code included).
    for i in range(FIRST_BLOCK_OFF - 12 * 4, SS):
        dboot[i] = 0
    if nsec > 1:
        e = FIRST_BLOCK_OFF
        struct.pack_into("<QHH", dboot, e, start + 1, nsec - 1, SEG_CORE)
        # terminator one entry below
        struct.pack_into("<QHH", dboot, e - 12, 0, 0, 0)
    else:
        # single-sector core: no entries, just the terminator
        struct.pack_into("<QHH", dboot, FIRST_BLOCK_OFF - 12, 0, 0, 0)
    core = bytes(dboot) + core[SS:]

    # --- write ----------------------------------------------------------
    with open(raw_path, "r+b") as f:
        # preserve the partition table area of the existing MBR
        f.seek(0)
        mbr = bytearray(f.read(SS))
        if len(mbr) != SS:
            die(2, "raw image shorter than one sector")
        boot[OFF_NT_MAGIC:OFF_PART_END] = mbr[OFF_NT_MAGIC:OFF_PART_END]
        boot[SS - 2:SS] = b"\x55\xaa"  # keep the boot signature
        f.seek(0)
        f.write(boot)

        f.seek(start * SS)
        f.write(core)

        # verify read-back
        f.seek(0)
        rb_mbr = f.read(SS)
        f.seek(start * SS)
        rb_core = f.read(len(core))
    if rb_mbr != bytes(boot) or rb_core != core:
        die(1, "verification failed: image content does not match what was written")

    print(json.dumps({
        "core_sectors": nsec,
        "core_bytes": len(core),
        "kernel_sector": start,
        "blocklist": {"start": start + 1, "len": max(nsec - 1, 0), "segment": SEG_CORE},
    }))


if __name__ == "__main__":
    main()