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
#   1b. Elemental state/persistent partitions: the seed image ships only
#       ESP/OEM/RECOVERY, but elemental-rootfs.service unconditionally
#       mounts /dev/disk/by-partlabel/persistent -> emergency mode on a
#       fresh disk. bios_gpt.py --add-elemental-parts grows the image and
#       appends GPT partitions NAMED `state`/`persistent` (that is what
#       /dev/disk/by-partlabel matches), then mke2fs -E offset creates the
#       ext4 filesystems with labels COS_STATE/COS_PERSISTENT. Sizes via
#       STATE_SIZE_GIB (default 8) and PERSISTENT_SIZE_GIB (default 1);
#       empty ext4 compresses to ~nothing in the qcow2 upload.
#   2. grub2-mkimage builds an i386-pc core.img whose embedded early config
#      locates the guest's own /boot/grub2/grub.cfg (elemental's grub.cfg
#      is platform-aware, so under BIOS it uses the plain `linux` command).
#   3. bios_grub.py installs GRUB into the image file the way
#      grub2-bios-setup would: it writes core.img into the BIOS Boot
#      partition and — critically — PATCHES the LBA of core.img into the
#      MBR's boot.img (the kernel_sector field) and the sector blocklist
#      into core.img's first (diskboot) sector. Those are build-time
#      placeholders in the packaged files: a plain `dd` of
#      boot.img/core.img ships them unpatched, so boot.img jumps to a wrong
#      sector and the machine silently dies right after SeaBIOS'
#      "Booting from hard drive". bios_grub.py does the byte patching
#      itself because grub2-bios-setup enumerates the host's block
#      devices via /sys/block and fails in containers that cannot see the
#      node's device nodes (e.g. "failed to get canonical path of
#      /dev/nvme0n1p4").
#   4. Elemental's ESP grub.cfg loads /grub_oem_env, which ships ALL menu
#      variables (labels, kernel, initramfs, kernelcmd) pre-expanded at BUILD
#      time with EMPTY values: recovery entry does `search --label --set=root
#      ${recovery_label}` with an empty label and `linux (${root})${kernel}`
#      with no kernel -> "you need to load the kernel first" (confirmed on a
#      droplet: full GRUB menu appears but entries fail to boot). The env
#      load happens INSIDE Elemental's own grub.cfg, so the only override
#      point left is the /grubcustom/custom.cfg hook it sources after all
#      env loads and before the menu entries. We inject that file into the
#      ESP with mtools (FAT, no mounting) redefining ALL variables:
#      labels, kernel=/boot/vmlinuz, initramfs=/boot/initrd (symlinks on the
#      recovery partition; GRUB follows symlinks) and the proven recovery
#      kernelcmd.
# Container needs: python3, grub2-mkimage, the grub2 i386-pc modules and
# mtools for the ESP custom.cfg injection (Containerfile installs
# grub2 + grub2-i386-pc + mtools on amd64).
# Disable with BIOS_SUPPORT=false.
BIOS_SUPPORT="${BIOS_SUPPORT:-true}"
BIOS_PY="${SCRIPTS_DIR}/bios_gpt.py"
BIOS_GRUB_PY="${SCRIPTS_DIR}/bios_grub.py"

bios_partition() { # bios_partition <raw-image> -> echoes "start end sectors"
  python3 "$BIOS_PY" "$1" 512 | jq -r '"\(.start) \(.end) \(.size_sectors)"'
}

add_elemental_partitions() { # add_elemental_partitions <raw-image> (logs via $SI)
  local RAW="$1" RES ALREADY ST_OFF ST_SEC ST_LBA PER_OFF PER_SEC PER_LBA
  local state_gib="${STATE_SIZE_GIB:-8}" persistent_gib="${PERSISTENT_SIZE_GIB:-1}"
  command -v mke2fs >/dev/null 2>&1 || { log "ERROR [$SI] mke2fs not found (install e2fsprogs in the container image)"; return 1; }
  RES=$(python3 "$BIOS_PY" "$RAW" --add-elemental-parts "$state_gib" "$persistent_gib") \
    || { log "ERROR [$SI] elemental state/persistent partition carving failed"; return 1; }
  ALREADY=$(jq -r '.already // false' <<<"$RES")
  if [ "$ALREADY" = "true" ]; then
    log "[$SI] state/persistent partitions already present (skipping)"
    return 0
  fi
  ST_OFF=$(jq -r '.state.offset_bytes' <<<"$RES")
  ST_SEC=$(jq -r '.state.sectors' <<<"$RES")
  ST_LBA=$(jq -r '.state.start' <<<"$RES")
  PER_OFF=$(jq -r '.persistent.offset_bytes' <<<"$RES")
  PER_SEC=$(jq -r '.persistent.sectors' <<<"$RES")
  PER_LBA=$(jq -r '.persistent.start' <<<"$RES")
  # mke2fs -E offset formats a region INSIDE the raw image, no mounting;
  # explicit -b 4096 makes the size argument unambiguous (fs blocks).
  if ! mke2fs -q -t ext4 -b 4096 -F -L COS_STATE -E offset="$ST_OFF" "$RAW" $(( ST_SEC * 512 / 4096 )); then
    log "ERROR [$SI] mkfs COS_STATE failed"
    return 1
  fi
  if ! mke2fs -q -t ext4 -b 4096 -F -L COS_PERSISTENT -E offset="$PER_OFF" "$RAW" $(( PER_SEC * 512 / 4096 )); then
    log "ERROR [$SI] mkfs COS_PERSISTENT failed"
    return 1
  fi
  log "[$SI] Elemental partitions: state ${state_gib}GiB @LBA $ST_LBA (ext4 COS_STATE), persistent ${persistent_gib}GiB @LBA $PER_LBA (ext4 COS_PERSISTENT)"
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

  # 1b. Elemental state/persistent partitions (see header): required by
  #     elemental-rootfs.service, missing from the shipped seed image.
  if ! add_elemental_partitions "$RAW"; then
    log "ERROR [$SI] elemental partition step failed"
    return 1
  fi

  # 2. core.img with embedded early config
  cat > "$WORKDIR/bios-early.cfg" <<'EOG'
# Early GRUB config embedded into core.img (i386-pc / BIOS). Try the known
# Elemental/SUSE grub.cfg locations, then the COS_STATE label, then give up.
# Output goes to BOTH VGA console (DO droplet web console) and COM1 serial
# (local QEMU -serial / DO recovery console), so boot-stage failures are
# visible wherever you look. Each search prints a marker so a silent death
# tells you exactly which stage never ran.
serial --unit=0 --speed=115200
terminal_output console serial
echo "BIOS GRUB: stage2 reached, loading elemental environment ..."
# Elemental's menu entries are driven by variables from a grubenv file that
# lives on the OEM partition. GRUB's normal auto-load only checks
# ${prefix}/grubenv (which does not exist on the ESP), so WITHOUT this the
# boot comes up with every variable empty: root=LABEL=, elemental.mode=,
# elemental.oemlabel= ... and the kernel emergency-modes.
search --no-floppy --set=root --file /grubenv
if [ -n "${root}" ]; then
  load_env -f ($root)/grubenv
  echo "BIOS GRUB: loaded grubenv from ($root) (state=${state_label})"
fi
# Recovery cmdline as a FALLBACK: the ESP grub.cfg loads /grub_oem_env
# (which ships a kernelcmd pre-expanded at build time with EMPTY labels)
# when it takes over, overwriting this value again. The authoritative
# override is /grubcustom/custom.cfg injected into the ESP below (step 4),
# which Elemental's grub.cfg sources AFTER all env loads. This one only
# survives if the env does not define kernelcmd at all.
set kernelcmd="console=tty1 console=ttyS0 root=LABEL=COS_RECOVERY rw elemental.image=/boot/recovery.img elemental.mode=recovery elemental.oemlabel=COS_OEM security=selinux selinux=0 rd.neednet=1"
echo "BIOS GRUB: searching for guest grub.cfg ..."
# Elemental keeps its real grub.cfg on the EFI System Partition
search --no-floppy --set=root --file /EFI/elemental/grub.cfg
if [ -n "${root}" ]; then
  set prefix=($root)/EFI/elemental
  configfile ($root)/EFI/elemental/grub.cfg
fi
echo "BIOS GRUB: /EFI/elemental/grub.cfg not found, trying /boot/grub2 ..."
search --no-floppy --set=root --file /boot/grub2/grub.cfg
if [ -n "${root}" ]; then
  set prefix=($root)/boot/grub2
  configfile ($root)/boot/grub2/grub.cfg
fi
echo "BIOS GRUB: /boot/grub2/grub.cfg not found, trying /grub2 ..."
search --no-floppy --set=root --file /grub2/grub.cfg
if [ -n "${root}" ]; then
  set prefix=($root)/grub2
  configfile ($root)/grub2/grub.cfg
fi
echo "BIOS GRUB: /grub2/grub.cfg not found, trying COS_STATE label ..."
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
    serial configfile echo test sleep ls loopback boot linux \
    normal gzio loadenv halt reboot help \
    all_video gfxterm font bitmap bitmap_scale png jpeg tga video video_fb
  if ! CORE_SIZE=$(stat -c%s "$WORKDIR/bios-core.img" 2>/dev/null) || [ -z "$CORE_SIZE" ]; then
    log "ERROR [$SI] grub2-mkimage failed (no core.img produced)"
    return 1
  fi
  if [ "$CORE_SIZE" -gt $((SECTORS * 512)) ]; then
    log "ERROR [$SI] core.img ($CORE_SIZE B) exceeds BIOS Boot partition ($((SECTORS * 512)) B)"
    return 1
  fi

  # 3. Install: bios_grub.py embeds core.img at the start of the BIOS Boot
  #    partition, patches MBR boot.img (kernel_sector -> START, boot_drive
  #    0xFF, partition table preserved) and core's diskboot blocklist —
  #    pure byte patching, no device enumeration, no root needed.
  local grub_out
  if ! grub_out=$(python3 "$BIOS_GRUB_PY" "$RAW" "$START" \
        "$grub_pc_dir/boot.img" "$WORKDIR/bios-core.img" 2>&1); then
    log "ERROR [$SI] GRUB install failed:"
    sed 's/^/ERROR [$SI]   /' <<<"$grub_out" >&2
    return 1
  fi

  # Verify the MBR really got the patched boot code: kernel_sector (offset
  # 92) must point at the BIOS Boot partition, not a placeholder 0/1.
  local mbr_lba
  mbr_lba=$(dd if="$RAW" bs=1 skip=92 count=8 status=none | od -An -tu8 | tr -d ' ')
  if [ "$mbr_lba" != "$START" ]; then
    log "ERROR [$SI] BIOS GRUB install inconsistent (MBR kernel_sector=$mbr_lba, expected $START)"
    return 1
  fi
  log "[$SI] BIOS GRUB installed (core.img $CORE_SIZE B -> LBA $START, MBR kernel_sector patched)"

  # 4. Inject /grubcustom/custom.cfg into the ESP (FAT via mtools, no mount).
  #    Elemental's ESP grub.cfg sets custom_file=/grubcustom/custom.cfg and
  #    sources it AFTER loading /grub_oem_env and BEFORE the menu entries.
  #    The build-time /grub_oem_env ships EVERY variable pre-expanded with
  #    EMPTY values (recovery_label=, kernel=, kernelcmd="root=LABEL= ..."),
  #    so menuentries do `search --label --set=root ${recovery_label}` with an
  #    empty label and `linux (${root})${kernel}` with no kernel ("you need
  #    to load the kernel first"). custom.cfg redefines ALL of them.
  command -v mcopy >/dev/null 2>&1 || { log "ERROR [$SI] mtools not found (install mtools in the container image)"; return 1; }
  ESP_JSON=$(python3 "$BIOS_PY" "$RAW" --esp) || { log "ERROR [$SI] ESP partition lookup failed"; return 1; }
  ESP_START=$(jq -r '.esp_start' <<<"$ESP_JSON")
  ESP_OFF=$((ESP_START * 512))
  cat > "$WORKDIR/grubcustom.cfg" <<'EOC'
# Injected by do-exporter (bios-boot.sh): the build-time /grub_oem_env ships
# variables PRE-EXPANDED with EMPTY labels (root=LABEL=, ${recovery_label}=,
# ${kernel}= ...), so the menuentries search for a device with an empty label,
# resolve ${kernel} to nothing, and fail with "you need to load the kernel
# first". Elemental sources this file AFTER loading /grub_oem_env and BEFORE
# the menuentries run, so redefining the variables here fixes every entry.
# Paths are relative to the partition the entry's search --set=root selects
# (recovery partition gpt3, COS_RECOVERY): /boot/vmlinuz and /boot/initrd
# are symlinks there; GRUB follows symlinks (validated on a real droplet).
set state_label=COS_STATE
set recovery_label=COS_RECOVERY
set oem_label=COS_OEM
set persistent_label=COS_PERSISTENT
set kernel=/boot/vmlinuz
set initramfs=/boot/initrd
set kernelcmd="console=tty1 console=ttyS0 root=LABEL=COS_RECOVERY rw elemental.image=/boot/recovery.img elemental.mode=recovery elemental.oemlabel=COS_OEM security=selinux selinux=0 rd.neednet=1"
EOC
  local esp_img="$RAW@@$ESP_OFF"
  if ! mmd -i "$esp_img" ::/grubcustom >/dev/null 2>&1; then
    log "[$SI] /grubcustom already present in ESP (reusing)"
  fi
  if ! mcopy -i "$esp_img" "$WORKDIR/grubcustom.cfg" ::/grubcustom/custom.cfg 2>&1; then
    log "ERROR [$SI] failed to inject custom.cfg into the ESP"
    return 1
  fi
  if ! mtype -i "$esp_img" ::/grubcustom/custom.cfg 2>/dev/null | grep -q "recovery_label=COS_RECOVERY" \
     || ! mtype -i "$esp_img" ::/grubcustom/custom.cfg 2>/dev/null | grep -q "root=LABEL=COS_RECOVERY"; then
    log "ERROR [$SI] custom.cfg verification failed (ESP injection inconsistent)"
    return 1
  fi
  log "[$SI] ESP /grubcustom/custom.cfg injected (grub env var overrides: labels, kernel, initramfs, kernelcmd; ESP at LBA $ESP_START)"
}