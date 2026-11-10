#!/usr/bin/env bash
# Publishes ready Elemental SeedImages to DigitalOcean (Spaces + custom image).
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

# --- s3cmd config -----------------------------------------------------------
S3CFG="$WORKDIR/.s3cfg"
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

# --- helper: read state -------------------------------------------------------
state_get() { kubectl -n "$SEEDIMAGE_NS" get configmap "$STATE_CM" \
  -o jsonpath="{.data.$1}" 2>/dev/null || true; }
state_set() { # state_set <key> <value>
  kubectl -n "$SEEDIMAGE_NS" get configmap "$STATE_CM" >/dev/null 2>&1 || \
    kubectl -n "$SEEDIMAGE_NS" create configmap "$STATE_CM" >/dev/null
  kubectl -n "$SEEDIMAGE_NS" patch configmap "$STATE_CM" \
    --type merge -p "{\"data\":{\"$1\":\"$2\"}}" >/dev/null
}

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' - | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//'; }

mkdir -p "$WORKDIR"; cd "$WORKDIR"

# --- enumerate opt-in SeedImages ---------------------------------------------
# Opt in with:  labels: do-export.cattle.io/enabled: "true"
# Optional annotations:
#   do-export.cattle.io/name:          sl-micro-62-base     (default: seedimage name)
#   do-export.cattle.io/version:       v1.0.0               (default: build timestamp)
#   do-export.cattle.io/distribution:  opensuse             (default: opensuse)
SEEDIMAGES=$(kubectl -n "$SEEDIMAGE_NS" get seedimages.elemental.cattle.io \
  -l do-export.cattle.io/enabled=true -o json)

count=$(echo "$SEEDIMAGES" | jq 'length')
log "Found $count opted-in SeedImage(s) in $SEEDIMAGE_NS"

for i in $(seq 0 $((count - 1))); do
  SI=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.name")
  UID=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.uid")
  ANNOT=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.annotations // {}")
  URL=$(echo "$SEEDIMAGES" | jq -r ".items[$i].status.downloadURL // empty")
  CHECKSUM=$(echo "$SEEDIMAGES" | jq -r ".items[$i].status.checksum // empty")
  READY=$(echo "$SEEDIMAGES" | jq -r \
    '.items[0].status.conditions[]? | select(.type=="SeedImageReady") | .status' 2>/dev/null || true)

  [ -n "$URL" ] || { log "SKIP $SI: no downloadURL yet"; continue; }

  NAME=$(slug "$(echo "$ANNOT" | jq -r '."do-export.cattle.io/name" // empty' || true)")
  [ -n "$NAME" ] || NAME=$(slug "$SI")
  VERSION=$(echo "$ANNOT" | jq -r '."do-export.cattle.io/version" // empty' | tr -d ' ')
  [ -n "$VERSION" ] || VERSION=$(date -u +%Y%m%d-%H%M%S)
  DISTRIB=$(echo "$ANNOT" | jq -r '."do-export.cattle.io/distribution" // "opensuse"')
  DO_IMAGE="${NAME}-$(slug "$VERSION")"
  STATE_KEY="published-$UID"

  if [ -n "$CHECKSUM" ] && [ "$(state_get "$STATE_KEY")" = "$CHECKSUM" ]; then
    log "SKIP $SI: checksum $CHECKSUM already published as $DO_IMAGE"
    continue
  fi

  log "Export $SI -> $DO_IMAGE (checksum: ${CHECKSUM:-unknown})"
  RAW="$SI.raw"
  QCOW="$DO_IMAGE.qcow2"

  # --- 1. download (Rancher endpoint may use self-signed certs -> -k) --------
  log "Downloading $URL"
  curl -sfk --retry 3 -o "$RAW" "$URL"

  # --- 2. verify checksum ----------------------------------------------------
  if [ -n "$CHECKSUM" ]; then
    if command -v sha256sum >/dev/null; then
      ACTUAL=$(sha256sum "$RAW" | cut -d' ' -f1)
    else
      ACTUAL=$(sha256 -q "$RAW")
    fi
    [ "$ACTUAL" = "$CHECKSUM" ] || { log "ERROR $SI: checksum mismatch ($ACTUAL != $CHECKSUM)"; rm -f "$RAW"; continue; }
    log "Checksum OK"
  else
    log "WARN $SI: no status.checksum, skipping verification"
  fi

  # --- 3. convert -------------------------------------------------------------
  log "Converting to qcow2"
  qemu-img convert -f raw -O qcow2 -c "$RAW" "$QCOW"
  rm -f "$RAW"

  # --- 4. upload to Spaces ----------------------------------------------------
  S3_KEY="$DO_IMAGE.qcow2"
  log "Uploading s3://$SPACES_BUCKET/$S3_KEY"
  "${S3CMD[@]}" put "$QCOW" "s3://$SPACES_BUCKET/$S3_KEY" \
    --acl-private --guess-mime-type
  rm -f "$QCOW"

  # --- 5. create DO custom image ----------------------------------------------
  EXPIRES=$(( $(date +%s) + SIGNED_URL_HOURS * 3600 ))
  SIGNED_URL=$("${S3CMD[@]}" signurl "s3://$SPACES_BUCKET/$S3_KEY" "$EXPIRES")

  if doctl compute image list-user -o json | jq -e --arg n "$DO_IMAGE" \
      '.[] | select(.name == $n)' >/dev/null; then
    log "SKIP create: DO image '$DO_IMAGE' already exists"
  else
    log "Creating DO custom image $DO_IMAGE in $DO_REGION"
    doctl compute image create "$DO_IMAGE" \
      --image-url "$SIGNED_URL" \
      --image-distribution "$DISTRIB" \
      --region "$DO_REGION" \