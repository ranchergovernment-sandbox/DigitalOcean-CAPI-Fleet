#!/usr/bin/env bash
# Publishes ready Elemental SeedImages to DigitalOcean (Spaces + custom image).
# Inventory-first: gathers SeedImages, Spaces objects and DO custom images up
# front, then only does the work (download/convert/upload/create) that's missing.
set -euo pipefail

SEEDIMAGE_NS="${SEEDIMAGE_NAMESPACE:-fleet-default}"
STATE_CM="${STATE_CONFIGMAP:-do-seedimage-publisher-state}"
SPACES_BUCKET="${SPACES_BUCKET:?}"
SPACES_REGION="${SPACES_REGION:?}"        # e.g. atl1
DO_REGION="${DO_REGION:?}"                # e.g. atl1
SIGNED_URL_HOURS="${SIGNED_URL_HOURS:-4}"
WORKDIR="${WORKDIR:-/work}"

export DIGITALOCEAN_ACCESS_TOKEN="${DIGITALOCEAN_ACCESS_TOKEN:?}"
SPACES_KEY="${SPACES_KEY:?}"
SPACES_SECRET="${SPACES_SECRET:?}"

# --- s3cmd config (in $WORKDIR: writable by the non-root user via fsGroup) ---
S3CFG="$WORKDIR/.s3cfg"
mkdir -p "$WORKDIR"; cd "$WORKDIR"
cat > "$S3CFG" <<EOF
[default]
access_key = ${SPACES_KEY}
secret_key = ${SPACES_SECRET}
host_base = ${SPACES_REGION}.digitaloceanspaces.com
host_bucket = %(bucket)s.${SPACES_REGION}.digitaloceanspaces.com
use_https = True
EOF
S3CMD=(s3cmd --config="$S3CFG")

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# --- helpers: state configmap -------------------------------------------------
state_get() { kubectl -n "$SEEDIMAGE_NS" get configmap "$STATE_CM" \
  -o jsonpath="{.data.$1}" 2>/dev/null || true; }
state_set() { # state_set <key> <value>
  kubectl -n "$SEEDIMAGE_NS" get configmap "$STATE_CM" >/dev/null 2>&1 || \
    kubectl -n "$SEEDIMAGE_NS" create configmap "$STATE_CM" >/dev/null
  kubectl -n "$SEEDIMAGE_NS" patch configmap "$STATE_CM" \
    --type merge -p "{\"data\":{\"$1\":\"$2\"}}" >/dev/null
}

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' - | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//'; }

# === INVENTORY (gather everything before doing any work) ======================

# 1) opted-in SeedImages
# Opt in with:  labels: do-export.cattle.io/enabled: "true"
# Optional annotations:
#   do-export.cattle.io/name:          sl-micro-62-base     (default: seedimage name)
#   do-export.cattle.io/version:       v1.0.0               (default: build timestamp)
#   do-export.cattle.io/distribution:  opensuse             (default: opensuse)
SEEDIMAGES=$(kubectl -n "$SEEDIMAGE_NS" get seedimages.elemental.cattle.io \
  -l do-export.cattle.io/enabled=true -o json)
# count the items ARRAY — `jq 'length'` on the List object counts its keys
count=$(echo "$SEEDIMAGES" | jq '.items | length')
log "Inventory: $count opted-in SeedImage(s) in $SEEDIMAGE_NS"
[ "$count" -gt 0 ] || { log "Nothing to do"; exit 0; }

# 2) existing DO custom images (droplet images)
log "Inventory: listing DO custom images"
DO_IMAGES=$(doctl compute image list-user -o json)
do_image_exists() { echo "$DO_IMAGES" | jq -e --arg n "$1" \
  'map(select(.name == $n)) | length > 0' >/dev/null; }

# 3) existing objects in the Spaces bucket
log "Inventory: listing s3://$SPACES_BUCKET/"
S3_OBJECTS=$("${S3CMD[@]}" ls "s3://$SPACES_BUCKET/" 2>/dev/null || true)
s3_object_exists() { echo "$S3_OBJECTS" | grep -qF "$1"; }
log "Inventory: $(echo "$DO_IMAGES" | jq 'length') custom image(s), $(echo "$S3_OBJECTS" | grep -c . || true) object(s) in Spaces"

# === EXPORT LOOP (only fills the gaps) ========================================

for i in $(seq 0 $((count - 1))); do
  SI=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.name")
  SI_UID=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.uid")   # NOT 'UID' — readonly in bash
  ANNOT=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.annotations // {}")
  URL=$(echo "$SEEDIMAGES" | jq -r ".items[$i].status.downloadURL // empty")
  CHECKSUM=$(echo "$SEEDIMAGES" | jq -r ".items[$i].status.checksum // empty")

  [ -n "$URL" ] || { log "SKIP $SI: no downloadURL yet"; continue; }

  NAME=$(slug "$(echo "$ANNOT" | jq -r '."do-export.cattle.io/name" // empty' || true)")
  [ -n "$NAME" ] || NAME=$(slug "$SI")
  VERSION=$(echo "$ANNOT" | jq -r '."do-export.cattle.io/version" // empty' | tr -d ' ')
  [ -n "$VERSION" ] || VERSION=$(date -u +%Y%m%d-%H%M%S)
  DISTRIB=$(echo "$ANNOT" | jq -r '."do-export.cattle.io/distribution" // "opensuse"')
  DO_IMAGE="${NAME}-$(slug "$VERSION")"
  S3_KEY="$DO_IMAGE.qcow2"

  # already registered as a DO custom image? nothing to do
  if do_image_exists "$DO_IMAGE"; then
    log "SKIP $SI: DO image '$DO_IMAGE' already exists"
    state_set "last-published-$SI_UID" "$DO_IMAGE"
    continue
  fi

  # upload only if the object is missing or was uploaded from a different build
  if s3_object_exists "$S3_KEY" && [ "$(state_get "object-$DO_IMAGE")" = "$URL" ]; then
    log "Reuse s3://$SPACES_BUCKET/$S3_KEY (same build)"
  else
    log "Export $SI -> $DO_IMAGE (checksum: ${CHECKSUM:-unknown})"
    RAW="$SI.raw"

    # --- download (Rancher endpoint may use self-signed certs -> -k) --------
    log "Downloading $URL"
    curl -sfk --retry 3 -o "$RAW" "$URL"

    # --- verify checksum (if the operator provides one) ---------------------
    if [ -n "$CHECKSUM" ]; then
      ACTUAL=$(sha256sum "$RAW" | cut -d' ' -f1)
      [ "$ACTUAL" = "$CHECKSUM" ] || { log "ERROR $SI: checksum mismatch ($ACTUAL != $CHECKSUM)"; rm -f "$RAW"; continue; }
      log "Checksum OK"
    else
      log "WARN $SI: no status.checksum, skipping verification"
    fi

    # --- convert ---------------------------------------------------------------
    log "Converting to qcow2"
    qemu-img convert -f raw -O qcow2 -c "$RAW" "$S3_KEY"
    rm -f "$RAW"

    # --- upload -----------------------------------------------------------------
    log "Uploading s3://$SPACES_BUCKET/$S3_KEY"
    "${S3CMD[@]}" put "$S3_KEY" "s3://$SPACES_BUCKET/$S3_KEY" \
      --acl-private --guess-mime-type
    rm -f "$S3_KEY"
    state_set "object-$DO_IMAGE" "$URL"
  fi

  # --- register as DO custom image ----------------------------------------------
  EXPIRES=$(( $(date +%s) + SIGNED_URL_HOURS * 3600 ))
  SIGNED_URL=$("${S3CMD[@]}" signurl "s3://$SPACES_BUCKET/$S3_KEY" "$EXPIRES")

  log "Creating DO custom image $DO_IMAGE in $DO_REGION"
  doctl compute image create "$DO_IMAGE" \
    --image-url "$SIGNED_URL" \
    --image-distribution "$DISTRIB" \
    --region "$DO_REGION" \
    --output json | jq 'if type=="array" then .[0] else . end | {id, name, status}'

  state_set "last-published-$SI_UID" "$DO_IMAGE"
  log "Done: $DO_IMAGE"
done

log "Run complete"