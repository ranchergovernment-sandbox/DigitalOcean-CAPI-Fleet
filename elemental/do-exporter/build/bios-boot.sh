#!/usr/bin/env bash
# bios-boot.sh — adds a legacy-BIOS boot path to a raw disk image.
# Sourced by export-seedimages.sh; needs bios_gpt.py next to this file.
#
# DO droplets boot with legacy BIOS (SeaBIOS) and custom images cannot use
# UEFI, but Elemental raw images are GPT + GRUB2-EFI only: they will not
# boot. This adds a BIOS/GPT boot path without ever mounting the image
# (works as uid 1000 with a read-only rootfs):
#   1. bios_gpt.py carves a BIOS Boot partition into the free gap between
#      the GPT structures (end at LBA 33) and the first partition
#      (elemental images start their EFI partition at LBA 2048, leaving
#      LBA 34..2047 free) and fixes all GPT CRCs. Idempotent.
#   2. grub2-mkimage builds an i386-pc core.img whose embedded early config
#      locates the guest's own /boot/grub2/grub.cfg (elemental's grub.cfg
#      is platform-aware, so under BIOS it uses the plain `linux` command).
#   3. GRUB boot.img goes into the MBR (first 440 bytes, partition table is
#      preserved), core.img into the BIOS Boot partition.
# Container needs: python3, grub2-mkimage and grub2 i386-pc modules
# (Containerfile installs grub2 + grub2-i386-pc). Disable with
# BIOS_SUPPORT=false.
BIOS_SUPPORT="${BIOS_SUPPORT:-true}"
BIOS_PY="${SCRIPTS_DIR}/bios_gpt.py"

bios_partition() { # bios_partition <raw-image> -> echoes "start end sectors"
  python3 "$BIOS_PY" "$1" 512 | jq -r '"\(.start) \(.end) \(.size_sectors)"'
}

add_bios_boot() { # add_bios_boot <raw-image> (logs via $SI)
  local RAW="$1" RES START END SECTORS CORE_SIZE
  [ "$BIOS_SUPPORT" = "true" ] || { log "[$SI] BIOS patch disabled (BIOS_SUPPORT=false)"; return 0; }

  command -v python3 >/dev/null 2>&1 || { log "ERROR [$SI] python3 not found for BIOS patch"; return 1; }

  local grub_pc_dir
  grub_pc_dir="$(for d in /usr/share/grub2/i386-pc /usr/lib/grub2/i386-pc /usr/share/grub/i386-pc /usr/lib/grub/i386-pc; do
    [ -f "$d/boot.img" ] && echo "$d" && break; done)"
  if [ -z "$grub_pc_dir" ]; then
    log "ERROR [$SI] grub2 i386-pc boot.img not found (install grub2-i386-pc in the container image)"
    return 1
  fi
  local mkimage
  mkimage="$(command -v grub2-mkimage || command -v grub-mkimage || true)"
  [ -n "$mkimage" ] || { log "ERROR [$SI] grub2-mkimage not found"; return 1; }

  # 1. BIOS Boot partition (idempotent)
  RES=$(bios_partition "$RAW") || { log "ERROR [$SI] BIOS partition creation failed"; return 1; }
  read -r START END SECTORS <<<"$RES"
  log "[$SI] BIOS Boot partition: LBA $START..$END ($SECTORS sectors)"

  # 2. core.img with embedded early config
  cat > "$WORKDIR/bios-early.cfg" <<'EOG'
# Early GRUB config embedded into core.img (i386-pc / BIOS). Try the known
# Elemental/SUSE grub.cfg locations, then the COS_STATE label, then give up.
search --no-floppy --set=root --file /boot/grub2/grub.cfg
if [ -n "${root}" ]; then
  set prefix=($root)/boot/grub2
  configfile ($root)/boot/grub2/grub.cfg
fi
search --no-floppy --set=root --file /grub2/grub.cfg
if [ -n "${root}" ]; then
  set prefix=($root)/grub2
  configfile ($root)/grub2/grub.cfg
fi
search --no-floppy --set=root --label COS_STATE
if [ -n "${root}" ]; then
  set prefix=($root)/boot/grub2
  configfile ($root)/boot/grub2/grub.cfg
fi
echo "BIOS GRUB: no Elemental grub.cfg found; dropping to GRUB shell."
search --no-floppy --set=root --file /boot/vmlinuz
set prefix=($root)/boot/grub2
EOG
  "$mkimage" -d "$grub_pc_dir" -O i386-pc \
    -c "$WORKDIR/bios-early.cfg" -p '($root)/boot/grub2' \
    -o "$WORKDIR/bios-core.img" \
    part_gpt biosdisk disk fat ext2 btrfs xfs squash4 \
    search search_fs_file search_label search_fs_uuid \
    configfile echo test sleep ls loopback boot linux initrd \
    normal gzio loadenv halt reboot help
  CORE_SIZE=$(stat -c%s "$WORKDIR/bios-core.img")
  if [ "$CORE_SIZE" -gt $((SECTORS * 512)) ]; then
    log "ERROR [$SI] core.img ($CORE_SIZE B) exceeds BIOS Boot partition ($((SECTORS * 512)) B)"
    return 1
  fi

  # 3. MBR boot code + core.img into the BIOS Boot partition
  dd if="$grub_pc_dir/boot.img" of="$RAW" bs=440 count=1 conv=notrunc status=none
  dd if="$WORKDIR/bios-core.img" of="$RAW" bs=512 seek="$START" conv=notrunc status=none
  log "[$SI] BIOS GRUB installed (boot.img -> MBR, core.img $CORE_SIZE B -> LBA $START)"
}