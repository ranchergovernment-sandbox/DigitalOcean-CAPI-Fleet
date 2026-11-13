#!/usr/bin/env bash
# common.sh — shared config & helpers. Sourced by export-seedimages.sh,
# never executed directly.
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

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# --- state configmap (publish/fail markers across runs) ------------------------
state_get() { kubectl -n "$SEEDIMAGE_NS" get configmap "$STATE_CM" \
  -o jsonpath="{.data.$1}" 2>/dev/null || true; }
state_set() { # state_set <key> <value>
  kubectl -n "$SEEDIMAGE_NS" get configmap "$STATE_CM" >/dev/null 2>&1 || \
    kubectl -n "$SEEDIMAGE_NS" create configmap "$STATE_CM" >/dev/null
  kubectl -n "$SEEDIMAGE_NS" patch configmap "$STATE_CM" \
    --type merge -p "{\"data\":{\"$1\":\"$2\"}}" >/dev/null
}

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' - | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//'; }

# --- s3cmd config (in $WORKDIR: writable by the non-root user via fsGroup) -----
S3CFG="$WORKDIR/.s3cfg"
mkdir -p "$WORKDIR"; cd "$WORKDIR"
cat > "$S3CFG" <<S3EOF
[default]
access_key = ${SPACES_KEY}
secret_key = ${SPACES_SECRET}
host_base = ${SPACES_REGION}.digitaloceanspaces.com
host_bucket = %(bucket)s.${SPACES_REGION}.digitaloceanspaces.com
use_https = True
S3EOF
S3CMD=(s3cmd --config="$S3CFG")