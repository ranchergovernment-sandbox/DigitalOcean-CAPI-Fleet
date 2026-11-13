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
#   [new-elemental] : seed images with a build we haven't seen before
#   [upload-s3]     : Spaces object missing or stale, needs download+convert+upload
#   [create-do]     : DO custom image missing, needs image create
# Before qcow2 conversion every image gets a legacy-BIOS boot path added
# (DO droplets boot SeaBIOS; UEFI-only images never boot there).
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/scripts" && pwd)"
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

log "Run complete"