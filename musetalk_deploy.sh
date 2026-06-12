#!/bin/bash
# =============================================================================
# MuseTalk API Server — Setup & Launch for vast.ai
# =============================================================================
# Run this once on a fresh instance. It:
#   1. Installs all dependencies
#   2. Downloads model weights
#   3. Starts the API server on port 8000
#
# Usage:
#   bash musetalk_deploy.sh [--api-key YOUR_SECRET_KEY]
#
# The vast.ai instance must expose port 8000.
# In vast.ai UI: Template > Extra ports > add 8000
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ── Parse args ────────────────────────────────────────────────────────────────
API_KEY=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --api-key) API_KEY="$2"; shift ;;
        *) warn "Unknown arg: $1" ;;
    esac
    shift
done

# ── Paths ─────────────────────────────────────────────────────────────────────
WORKSPACE="/workspace"
MUSETALK_DIR="$WORKSPACE/MuseTalk"
MODELS_DIR="$MUSETALK_DIR/models"
FFMPEG_STATIC="$WORKSPACE/ffmpeg-static"
SERVER_SCRIPT="$WORKSPACE/musetalk_server.py"

# =============================================================================
# 1 — System deps
# =============================================================================
log "Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq \
    git wget curl unzip \
    libgl1-mesa-glx libglib2.0-0 \
    libsm6 libxext6 libxrender-dev \
    > /dev/null 2>&1

# =============================================================================
# 2 — ffmpeg static
# =============================================================================
if [ ! -f "$FFMPEG_STATIC/ffmpeg" ]; then
    log "Downloading ffmpeg..."
    wget -q "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" \
        -O /tmp/ffmpeg.tar.xz
    mkdir -p "$FFMPEG_STATIC"
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp/
    FFMPEG_DIR=$(find /tmp -maxdepth 1 -name "ffmpeg-*-amd64-static" -type d | head -1)
    cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$FFMPEG_STATIC/"
    chmod +x "$FFMPEG_STATIC/ffmpeg" "$FFMPEG_STATIC/ffprobe"
    rm -rf /tmp/ffmpeg.tar.xz "$FFMPEG_DIR"
fi
export PATH="$FFMPEG_STATIC:$PATH"
log "ffmpeg ready."

# =============================================================================
# 3 — Clone MuseTalk
# =============================================================================
if [ ! -d "$MUSETALK_DIR" ]; then
    log "Cloning MuseTalk..."
    git clone https://github.com/TMElyralab/MuseTalk.git "$MUSETALK_DIR" -q
fi

# =============================================================================
# 4 — Python deps
# =============================================================================
log "Installing Python dependencies..."
pip install -q torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 \
    --index-url https://download.pytorch.org/whl/cu118
pip install -q --no-cache-dir -U openmim
mim install -q mmengine
mim install -q "mmcv==2.0.1"
mim install -q "mmdet==3.1.0"
mim install -q "mmpose==1.1.0"
pip install -q -r "$MUSETALK_DIR/requirements.txt"
pip install -q fastapi uvicorn[standard] python-multipart
log "Python deps installed."

# =============================================================================
# 5 — Download model weights
# =============================================================================
log "Downloading model weights..."
mkdir -p \
    "$MODELS_DIR/musetalkV15" \
    "$MODELS_DIR/dwpose" \
    "$MODELS_DIR/face-parse-bisent" \
    "$MODELS_DIR/sd-vae" \
    "$MODELS_DIR/whisper"

dl() {
    [ -f "$2" ] && { warn "Exists: $(basename $2)"; return; }
    wget -q --show-progress "$1" -O "$2"
}

HF="https://huggingface.co/TMElyralab/MuseTalk/resolve/main"
dl "$HF/musetalkV15/unet.pth"                                    "$MODELS_DIR/musetalkV15/unet.pth"
dl "$HF/musetalkV15/musetalk.json"                               "$MODELS_DIR/musetalkV15/musetalk.json"
dl "$HF/dwpose/dw-ll_ucoco_384.pth"                              "$MODELS_DIR/dwpose/dw-ll_ucoco_384.pth"
dl "$HF/dwpose/yolox_l.pth"                                      "$MODELS_DIR/dwpose/yolox_l.pth"
dl "$HF/face-parse-bisent/79999_iter.pth"                        "$MODELS_DIR/face-parse-bisent/79999_iter.pth"
dl "$HF/face-parse-bisent/resnet18-5c106cde.pth"                 "$MODELS_DIR/face-parse-bisent/resnet18-5c106cde.pth"
dl "https://openaipublic.azureedge.net/main/whisper/models/65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9/tiny.pt" \
                                                                  "$MODELS_DIR/whisper/tiny.pt"
dl "https://huggingface.co/stabilityai/sd-vae-ft-mse/resolve/main/diffusion_pytorch_model.bin" \
                                                                  "$MODELS_DIR/sd-vae/diffusion_pytorch_model.bin"
dl "https://huggingface.co/stabilityai/sd-vae-ft-mse/resolve/main/config.json" \
                                                                  "$MODELS_DIR/sd-vae/config.json"
log "Models ready."

# =============================================================================
# 6 — Copy server script
# =============================================================================
# Download the server script if not already present
if [ ! -f "$SERVER_SCRIPT" ]; then
    warn "musetalk_server.py not found at $SERVER_SCRIPT"
    warn "Upload it manually:  scp musetalk_server.py root@<ip>:/workspace/"
    err "Aborted — server script missing."
fi

# =============================================================================
# 7 — Launch server
# =============================================================================
log "Starting MuseTalk API server on port 8000..."

if [ -n "$API_KEY" ]; then
    log "API key protection: enabled"
    export API_KEY="$API_KEY"
else
    warn "No API key set — endpoint is open. Pass --api-key YOUR_SECRET to protect it."
fi

export FFMPEG_PATH="$FFMPEG_STATIC"
export PATH="$FFMPEG_STATIC:$PATH"

cd "$WORKSPACE"

# Run with nohup so it survives terminal disconnect
nohup python -m uvicorn musetalk_server:app \
    --host 0.0.0.0 \
    --port 8000 \
    --workers 1 \
    > "$WORKSPACE/server.log" 2>&1 &

SERVER_PID=$!
echo $SERVER_PID > "$WORKSPACE/server.pid"

sleep 3

if kill -0 $SERVER_PID 2>/dev/null; then
    echo ""
    log "============================================"
    log "MuseTalk API server is LIVE!"
    log "============================================"
    echo ""
    echo "  Find your instance IP & port in the vast.ai dashboard"
    echo "  (Instances > your instance > Connection > port 8000)"
    echo ""
    echo "  Health check:"
    echo "    curl http://<ip>:<port>/health"
    echo ""
    echo "  Generate a video:"
    echo "    curl -X POST http://<ip>:<port>/generate \\"
    if [ -n "$API_KEY" ]; then
    echo "         -H 'x-api-key: $API_KEY' \\"
    fi
    echo "         -F 'image=@avatar.jpg' \\"
    echo "         -F 'audio=@script.wav'"
    echo ""
    echo "  Poll status:"
    echo "    curl http://<ip>:<port>/status/<job_id>"
    echo ""
    echo "  Download result:"
    echo "    curl http://<ip>:<port>/download/<job_id> -o output.mp4"
    echo ""
    echo "  Logs:  tail -f $WORKSPACE/server.log"
    echo "  Stop:  kill \$(cat $WORKSPACE/server.pid)"
    echo ""
    warn "Remember to DESTROY the instance when you're done to stop billing!"
else
    err "Server failed to start. Check logs: cat $WORKSPACE/server.log"
fi
