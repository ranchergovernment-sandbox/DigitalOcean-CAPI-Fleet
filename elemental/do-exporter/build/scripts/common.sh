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

# --- progress heartbeat ---------------------------------------------------------
# Long steps (download, convert, upload) are silent for their whole duration,
# which is indistinguishable from a hang for anyone watching `kubectl logs`.
# progress_start() spawns a heartbeat that logs "<step> (still running)" every
# PROGRESS_INTERVAL seconds (default 30) until progress_stop() kills it.
# run_step() wraps a command with all of that plus a duration on completion.
#
# Lifecycle safety (a leftover heartbeat holds the container's stdout pipe
# open, which can keep the pod stuck in Running after "Run complete"):
#   - the heartbeat runs via setsid in its own process group, so progress_stop
#     kills the whole group (the running `sleep` included) — no orphans
#   - the heartbeat also polls its parent and exits on its own if the main
#     script is gone, even if every kill path failed
#   - progress_stop never returns non-zero (its `wait` would otherwise see
#     143 and trip set -e inside the EXIT trap)
#   - the EXIT trap plus a final sweep in export-seedimages.sh guarantee
#     cleanup on every exit path
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-30}"
_progress_pid=""

progress_start() { # progress_start <message>
  progress_stop
  _progress_t0=$(date +%s)
  _progress_msg="$1"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c '
      trap "exit 0" TERM INT
      while sleep "$1"; do
        kill -0 "$PPID" 2>/dev/null || exit 0   # main script gone -> stop
        echo "[$(date -u +%FT%TZ)] ... $2 (still running)"
      done
    ' _ "$PROGRESS_INTERVAL" "$_progress_msg" &
    _progress_pid=$!
  else # fallback: plain subshell (sleep child may need an extra beat to die)
    ( while sleep "$PROGRESS_INTERVAL"; do
        kill -0 "$PPID" 2>/dev/null || exit 0
        echo "[$(date -u +%FT%TZ)] ... $_progress_msg (still running)"
      done ) &
    _progress_pid=$!
  fi
}

progress_stop() {
  [ -n "$_progress_pid" ] || return 0
  kill -TERM -- "-$_progress_pid" 2>/dev/null \
    || kill -TERM "$_progress_pid" 2>/dev/null \
    || true
  wait "$_progress_pid" 2>/dev/null || true
  _progress_pid=""
  return 0
}

run_step() { # run_step <label> <command...> — start/end logs + heartbeat while running
  local label="$1"; shift
  log "$label ..."
  progress_start "$label"
  local rc=0
  "$@" || rc=$?
  progress_stop
  if [ "$rc" -eq 0 ]; then
    log "$label - done in $(( $(date +%s) - _progress_t0 ))s"
  else
    log "ERROR: $label - failed (exit $rc)"
  fi
  return "$rc"
}

progress_cleanup() { # last-resort sweep: never leave a job holding stdout
  progress_stop
  local -a pids
  pids=$(jobs -p)
  [ -n "$pids" ] && kill $pids 2>/dev/null || true
  wait 2>/dev/null || true
  return 0
}

# never leave a heartbeat process behind, even on unexpected exit
trap 'progress_cleanup' EXIT

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