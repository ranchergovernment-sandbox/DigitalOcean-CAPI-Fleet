#!/usr/bin/env bash
# inventory.sh — gathers all three sources of truth (SeedImages, DO custom
# images, Spaces objects) and classifies each SeedImage into the three
# queues. Sourced by export-seedimages.sh; sets globals:
#   Q_NEW / Q_UPLOAD / Q_CREATE (arrays) and R_URL / R_UID / R_DOIMG /
#   R_CKSUM / R_DISTRIB (assoc arrays, keyed by SeedImage name).

# Opt in with:  labels: do-export.cattle.io/enabled: "true"
# Optional annotations:
#   do-export.cattle.io/name:          sl-micro-62-base     (default: seedimage name)
#   do-export.cattle.io/version:       v1.0.0               (default: build timestamp)
#   do-export.cattle.io/distribution:  opensuse             (default: opensuse)

inventory_and_classify() {
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

  declare -ga Q_NEW=() Q_UPLOAD=() Q_CREATE=()
  declare -gA R_URL=() R_UID=() R_DOIMG=() R_CKSUM=() R_DISTRIB=()

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
}

qprint() { # qprint <label> <items...>
  local label="$1"; shift
  if [ "$#" -gt 0 ]; then log "Queue [$label]: $# item(s) -> $*"
  else log "Queue [$label]: empty"; fi
}