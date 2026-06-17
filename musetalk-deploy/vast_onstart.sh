#!/bin/bash
# =============================================================================
# Vast.ai Onstart Script — MuseTalk API Server
# =============================================================================
# This runs automatically when a Vast.ai instance starts with the
# ldonjibson/musetalk:latest template.
#
# Key: uvicorn runs in the FOREGROUND (no nohup/&) so the container
#      doesn't exit. sleep infinity was PID 1, now uvicorn is.
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
WORKSPACE="/workspace"
MUSETALK_DIR="$WORKSPACE/MuseTalk"
SERVER_SCRIPT="$WORKSPACE/musetalk_server.py"
FFMPEG_STATIC="$WORKSPACE/ffmpeg-static"
LOG_FILE="$WORKSPACE/server.log"
PID_FILE="$WORKSPACE/server.pid"

API_KEY="${API_KEY:-musetalk-secret}"
PORT="${PORT:-8000}"

# ── Verify critical files exist ──────────────────────────────────────────────
log "Verifying installation..."

[ -f "$SERVER_SCRIPT" ] || err "musetalk_server.py not found at $SERVER_SCRIPT"
[ -f "$FFMPEG_STATIC/ffmpeg" ] || err "ffmpeg not found at $FFMPEG_STATIC/ffmpeg"
[ -d "$MUSETALK_DIR" ] || err "MuseTalk directory not found at $MUSETALK_DIR"

# Check that key model files exist
for f in \
    "$MUSETALK_DIR/models/musetalkV15/unet.pth" \
    "$MUSETALK_DIR/models/sd-vae/config.json" \
    "$MUSETALK_DIR/models/whisper/config.json" \
    "$MUSETALK_DIR/models/dwpose/dw-ll_ucoco_384.pth"; do
    [ -f "$f" ] || err "Missing model file: $f"
done

log "All critical files verified."

# ── Export paths ──────────────────────────────────────────────────────────────
export FFMPEG_PATH="$FFMPEG_STATIC"
export PATH="$FFMPEG_STATIC:$PATH"

# ── Launch server in FOREGROUND ──────────────────────────────────────────────
# CRITICAL: Must run in foreground. If we use `nohup ... &` and the script
# exits, the container's PID 1 (sleep infinity) continues but the server
# is orphaned. Running uvicorn directly as the main process keeps everything
# alive and makes docker logs work.

log "Starting MuseTalk API server on port $PORT..."
log "API key: ${API_KEY:0:4}****"
log "Logs: $LOG_FILE"

cd "$WORKSPACE"

# Run uvicorn in foreground — this IS the container's main process now.
# The CMD ["sleep", "infinity"] from Dockerfile is replaced by this.
exec python -m uvicorn musetalk_server:app \
    --host 0.0.0.0 \
    --port "$PORT" \
    --workers 1 \
    --log-level info
