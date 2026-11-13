#!/usr/bin/env bash
# Publishes ready Elemental SeedImages to DigitalOcean (Spaces + custom image).
# Queue-based pipeline: inventory -> classify into queues -> process queues.
#   [new-elemental] : seed images with a build we haven't seen before
#   [upload-s3]     : Spaces object missing or stale, needs download+convert+upload
#   [create-do]      : DO custom image missing, needs image create
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

# === INVENTORY =================================================================

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

log "Inventory: listing DO custom images"
DO_IMAGES=$(doctl compute image list-user -o json)
do_image_exists() { echo "$DO_IMAGES" | jq -e --arg n "$1" \
  'map(select(.name == $n)) | length > 0' >/dev/null; }

log "Inventory: listing s3://$SPACES_BUCKET/"
S3_OBJECTS=$("${S3CMD[@]}" ls "s3://$SPACES_BUCKET/" 2>/dev/null || true)
s3_object_exists() { echo "$S3_OBJECTS" | grep -qF "$1"; }

# === CLASSIFY (build the three queues) ==========================================

declare -a Q_NEW=() Q_UPLOAD=() Q_CREATE=()
declare -A R_URL=() R_UID=() R_DOIMG=() R_CKSUM=() R_DISTRIB=()

for i in $(seq 0 $((count - 1))); do
  SI=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.name")
  URL=$(echo "$SEEDIMAGES" | jq -r ".items[$i].status.downloadURL // empty")
  [ -n "$URL" ] || { log "SKIP $SI: no downloadURL yet"; continue; }

  SI_UID=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.uid")   # NOT 'UID' — readonly in bash
  ANNOT=$(echo "$SEEDIMAGES" | jq -r ".items[$i].metadata.annotations // {}")
  CHECKSUM=$(echo "$SEEDIMAGES" | jq -r ".items[$i].status.checksum // empty")

  NAME=$(slug "$(echo "$ANNOT" | jq -r '."do-export.cattle.io/name" // empty' || true)")
  [ -n "$NAME" ] || NAME=$(slug "$SI")
  VERSION=$(echo "$ANNOT" | jq -r '."do-export.cattle.io/version" // empty' | tr -d ' ')
  [ -n "$VERSION" ] || VERSION=$(date -u +%Y%m%d-%H%M%S)
  DISTRIB=$(echo "$ANNOT" | jq -r '."do-export.cattle.io/distribution" // "opensuse"')

  R_URL["$SI"]="$URL"; R_UID["$SI"]="$SI_UID"
  R_DOIMG["$SI"]="${NAME}-$(slug "$VERSION")"
  R_CKSUM["$SI"]="$CHECKSUM"; R_DISTRIB["$SI"]="$DISTRIB"

  BUILD_SEEN=$(state_get "build-$SI_UID")

  # queue 1: new elemental build (downloadURL differs from the last one we saw)
  [ "$BUILD_SEEN" = "$URL" ] || Q_NEW+=("$SI")

  # queue 2+3 only matter if the DO image doesn't exist yet (images are immutable)
  if ! do_image_exists "${R_DOIMG[$SI]}"; then
    Q_CREATE+=("$SI")
    if ! s3_object_exists "${R_DOIMG[$SI]}.qcow2" || [ "$BUILD_SEEN" != "$URL" ]; then
      Q_UPLOAD+=("$SI")
    fi
  fi

  # remember this build so Q_NEW only reports genuinely new builds
  state_set "build-$SI_UID" "$URL"
done

qprint() { # qprint <label> <items...>
  local label="$1"; shift
  if [ "$#" -gt 0 ]; then log "Queue [$label]: $# item(s) -> $*"
  else log "Queue [$label]: empty"; fi
}
qprint new-elemental "${Q_NEW[@]}"
qprint upload-s3 "${Q_UPLOAD[@]}"
qprint create-do "${Q_CREATE[@]}"

[ ${#Q_UPLOAD[@]} -eq 0 ] && [ ${#Q_CREATE[@]} -eq 0 ] && { log "Nothing to do"; exit 0; }

# === PROCESS [upload-s3] ========================================================

FAILED=" "
for SI in ${Q_UPLOAD[@]+"${Q_UPLOAD[@]}"}; do