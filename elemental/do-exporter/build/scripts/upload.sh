#!/usr/bin/env bash
# upload.sh — processes the [upload-s3] queue: download the raw SeedImage,
# verify the checksum, add BIOS boot support, convert to qcow2, upload to
# Spaces. Sourced by export-seedimages.sh; appends failed SeedImage names
# to the global FAILED tracker (space-delimited, " " padded).

process_upload_queue() {
  FAILED=" "
  for SI in ${Q_UPLOAD[@]+"${Q_UPLOAD[@]}"}; do
    DO_IMAGE="${R_DOIMG[$SI]}"; URL="${R_URL[$SI]}"; CHECKSUM="${R_CKSUM[$SI]}"
    RAW="$SI.raw"; S3_KEY="$DO_IMAGE.qcow2"

    run_step "[$SI] downloading (missing or stale object)" \
      curl -sfk --retry 3 -o "$RAW" "$URL"

    if [ -n "$CHECKSUM" ]; then
      ACTUAL=$(sha256sum "$RAW" | cut -d' ' -f1)
      [ "$ACTUAL" = "$CHECKSUM" ] || { log "ERROR [$SI] checksum mismatch ($ACTUAL != $CHECKSUM)"; rm -f "$RAW"; FAILED+="$SI "; continue; }
      log "[$SI] checksum OK"
    else
      log "WARN [$SI] no status.checksum, skipping verification"
    fi

    # legacy-BIOS boot support (DO droplets are SeaBIOS, not UEFI)
    if ! add_bios_boot "$RAW"; then
      rm -f "$RAW"; FAILED+="$SI "; continue
    fi

    run_step "[$SI] converting to qcow2" \
      qemu-img convert -f raw -O qcow2 -c "$RAW" "$S3_KEY"
    rm -f "$RAW"

    run_step "[$SI] uploading s3://$SPACES_BUCKET/$S3_KEY" \
      "${S3CMD[@]}" put "$S3_KEY" "s3://$SPACES_BUCKET/$S3_KEY" \
      --acl-private --guess-mime-type
    rm -f "$S3_KEY"

    state_set "object-$DO_IMAGE" "$URL"
    log "[$SI] uploaded: $S3_KEY"
  done
}