#!/usr/bin/env bash
# Publishes ready Elemental SeedImages to DigitalOcean (Spaces + custom image).
#
# Meta script: sources the pipeline pieces from scripts/ and orchestrates:
#   scripts/common.sh     config, logging, state configmap, s3cmd setup
#   scripts/inventory.sh  inventory + classification into the three queues
#   scripts/bios-boot.sh  legacy-BIOS boot patch for a raw disk image
#   scripts/upload.sh     [upload-s3] queue: download -> checksum -> BIOS ->
#                         qcow2 -> Spaces
#   scripts/create-do.sh  [create-do] queue: register the DO custom image
#
# Queue-based pipeline: inventory -> classify into queues -> process queues.
# Full flow of a run, per queued SeedImage:
#
#   inventory ──► queues ──► download ──► BIOS partition + GRUB install ──►
#   convert (qcow2) ──► Spaces upload ──► DO image create ──► "Run complete"
#
#   inventory            gather SeedImages + status, DO custom image list and
#                        Spaces bucket listing (scripts/inventory.sh)
#   queues               classify each SeedImage into new-elemental / upload-s3 /
#                        create-do; log the queues before any work happens
#   download             fetch the raw image from status.downloadURL, verify
#                        sha256 against status.checksum when present
#   BIOS partition +     DO droplets boot SeaBIOS (UEFI custom images don't
#   GRUB install         boot), so add a BIOS/GPT GRUB path: BIOS Boot partition
#                        carved into the free LBA 34-2047 gap, boot.img into
#                        the MBR, core.img into the new partition
#                        (scripts/bios-boot.sh + bios_gpt.py)
#   convert (qcow2)      qemu-img convert the patched raw image, compressed
#   Spaces upload        s3cmd put the qcow2 into the DO Spaces bucket
#   DO image create      sign a Spaces URL and register it as a DO custom
#                        image via doctl (scripts/create-do.sh)
#   "Run complete"       every queue item either published or was logged as
#                        failed/skipped; failures never block the rest
#   [new-elemental] : seed images with a build we haven't seen before
#   [upload-s3]     : Spaces object missing or stale, needs download+convert+upload
#   [create-do]     : DO custom image missing, needs image create
# Before qcow2 conversion every image gets a legacy-BIOS boot path added
# (DO droplets boot SeaBIOS; UEFI-only images never boot there).
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/" && pwd)"
source "$SCRIPTS_DIR/common.sh"
source "$SCRIPTS_DIR/inventory.sh"
source "$SCRIPTS_DIR/bios-boot.sh"
source "$SCRIPTS_DIR/upload.sh"
source "$SCRIPTS_DIR/create-do.sh"

# === 1. inventory + classify =====================================================
inventory_and_classify

qprint new-elemental "${Q_NEW[@]}"
qprint upload-s3 "${Q_UPLOAD[@]}"
qprint create-do "${Q_CREATE[@]}"

[ ${#Q_UPLOAD[@]} -eq 0 ] && [ ${#Q_CREATE[@]} -eq 0 ] && { log "Nothing to do"; exit 0; }

# === 2. process the queues ========================================================
process_upload_queue
process_create_queue

# final sweep: never leave a background job (heartbeat, orphaned tool) holding
# the container's stdout — a lingering writer can leave the pod stuck in
# Running after this script exits, even though "Run complete" already logged
progress_cleanup

log "Run complete"