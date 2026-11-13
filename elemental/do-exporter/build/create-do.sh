#!/usr/bin/env bash
# create-do.sh — processes the [create-do] queue: registers a DO custom
# image from the Spaces qcow2 via a signed URL. Sourced by
# export-seedimages.sh; skips items whose upload failed this run.

process_create_queue() {
  for SI in ${Q_CREATE[@]+"${Q_CREATE[@]}"}; do
    # skip items whose upload failed this run — don't register a stale object
    case "$FAILED" in *" $SI "*) log "SKIP [$SI]: upload failed earlier this run"; continue;; esac

    DO_IMAGE="${R_DOIMG[$SI]}"; DISTRIB="${R_DISTRIB[$SI]}"; SI_UID="${R_UID[$SI]}"
    S3_KEY="$DO_IMAGE.qcow2"

    EXPIRES=$(( $(date +%s) + SIGNED_URL_HOURS * 3600 ))
    SIGNED_URL=$("${S3CMD[@]}" signurl "s3://$SPACES_BUCKET/$S3_KEY" "$EXPIRES")

    log "[$SI] creating DO custom image $DO_IMAGE in $DO_REGION"
    doctl compute image create "$DO_IMAGE" \
      --image-url "$SIGNED_URL" \
      --image-distribution "$DISTRIB" \
      --region "$DO_REGION" \
      --output json | jq 'if type=="array" then .[0] else . end | {id, name, status}'

    state_set "last-published-$SI_UID" "$DO_IMAGE"
    log "[$SI] done: $DO_IMAGE"
  done
}