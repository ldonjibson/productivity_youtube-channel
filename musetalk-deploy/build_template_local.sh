#!/bin/bash
# =============================================================================
# Install MuseTalk Directly on This Vast.ai Instance
# =============================================================================
# Run this ON the instance (via SSH or Vast.ai console). It:
#   1. Installs all system dependencies
#   2. Installs Python deps (PyTorch, mmcv, etc.)
#   3. Downloads all model weights (~8GB)
#   4. Starts the API server on port 8000
#
# Usage (SSH into the instance):
#   bash build_template_local.sh [--api-key YOUR_SECRET]
#
# This does NOT create a Docker template — it installs directly.
# For a reusable template, use the Dockerfile approach instead.
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ── Parse args ───────────────────────────────────────────────────────────────
API_KEY=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --api-key) API_KEY="$2"; shift ;;
        *) warn "Unknown arg: $1" ;;
    esac
    shift
done
API_KEY="${API_KEY:-musetalk-secret}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     INSTALLING MUSETALK ON THIS INSTANCE                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Paths ────────────────────────────────────────────────────────────────────
WORKSPACE="/workspace"
MUSETALK_DIR="$WORKSPACE/MuseTalk"
MODELS_DIR="$MUSETALK_DIR/models"
FFMPEG_STATIC="$WORKSPACE/ffmpeg-static"
SERVER_SCRIPT="$WORKSPACE/musetalk_server.py"

# ── Step 1: System deps ─────────────────────────────────────────────────────
log "Step 1/5: Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq wget git curl ffmpeg libgl1-mesa-glx libglib2.0-0 \
    libsm6 libxext6 libxrender-dev > /dev/null 2>&1

# ── Step 2: ffmpeg static ───────────────────────────────────────────────────
if [ ! -f "$FFMPEG_STATIC/ffmpeg" ]; then
    log "Step 2/5: Downloading ffmpeg..."
    mkdir -p "$FFMPEG_STATIC"
    wget -q "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" \
        -O /tmp/ffmpeg.tar.xz
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp/
    FFMPEG_DIR=$(find /tmp -maxdepth 1 -name "ffmpeg-*-amd64-static" -type d | head -1)
    cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$FFMPEG_STATIC/"
    chmod +x "$FFMPEG_STATIC/ffmpeg" "$FFMPEG_STATIC/ffprobe"
    rm -rf /tmp/ffmpeg.tar.xz "$FFMPEG_DIR"
else
    log "Step 2/5: ffmpeg already installed"
fi
export FFMPEG_PATH="$FFMPEG_STATIC"
export PATH="$FFMPEG_STATIC:$PATH"

# ── Step 3: Clone MuseTalk ──────────────────────────────────────────────────
if [ ! -d "$MUSETALK_DIR" ]; then
    log "Step 3/5: Cloning MuseTalk..."
    git clone https://github.com/TMElyralab/MuseTalk.git "$MUSETALK_DIR" -q
else
    log "Step 3/5: MuseTalk already cloned"
fi

# ── Step 4: Python deps ─────────────────────────────────────────────────────
log "Step 4/5: Installing Python dependencies..."
pip install -q --no-cache-dir torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 \
    --index-url https://download.pytorch.org/whl/cu118

pip install -q --no-cache-dir -U openmim
mim install -q mmengine
mim install -q "mmcv==2.0.1"
mim install -q "mmdet==3.1.0"
mim install -q "mmpose==1.1.0"

pip install -q --no-cache-dir -r "$MUSETALK_DIR/requirements.txt"
pip install -q --no-cache-dir fastapi uvicorn[standard] python-multipart pyyaml

log "Python deps installed"

# ── Step 5: Download model weights ──────────────────────────────────────────
log "Step 5/5: Downloading model weights (~8GB)..."
mkdir -p \
    "$MODELS_DIR/musetalk" \
    "$MODELS_DIR/musetalkV15" \
    "$MODELS_DIR/syncnet" \
    "$MODELS_DIR/dwpose" \
    "$MODELS_DIR/face-parse-bisent" \
    "$MODELS_DIR/sd-vae" \
    "$MODELS_DIR/whisper"

dl() {
    local url="$1" dest="$2"
    if [ -f "$dest" ] && [ $(stat -c%s "$dest" 2>/dev/null || echo 0) -gt 1000 ]; then
        warn "Exists: $(basename $dest)"
        return
    fi
    wget -q --show-progress "$url" -O "$dest"
}

HF="https://huggingface.co"

# MuseTalk V1.5
dl "$HF/TMElyralab/MuseTalk/resolve/main/musetalkV15/unet.pth"          "$MODELS_DIR/musetalkV15/unet.pth"
dl "$HF/TMElyralab/MuseTalk/resolve/main/musetalkV15/musetalk.json"     "$MODELS_DIR/musetalkV15/musetalk.json"

# MuseTalk V1.0
dl "$HF/TMElyralab/MuseTalk/resolve/main/musetalk/musetalk.json"        "$MODELS_DIR/musetalk/musetalk.json"
dl "$HF/TMElyralab/MuseTalk/resolve/main/musetalk/pytorch_model.bin"    "$MODELS_DIR/musetalk/pytorch_model.bin"

# SD VAE
dl "$HF/stabilityai/sd-vae-ft-mse/resolve/main/diffusion_pytorch_model.bin" "$MODELS_DIR/sd-vae/diffusion_pytorch_model.bin"
dl "$HF/stabilityai/sd-vae-ft-mse/resolve/main/config.json"                  "$MODELS_DIR/sd-vae/config.json"

# Whisper (use OpenAI's direct URL — more reliable than HuggingFace)
dl "https://openaipublic.azureedge.net/main/whisper/models/65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9/tiny.pt" \
   "$MODELS_DIR/whisper/tiny.pt"
dl "$HF/openai/whisper-tiny/resolve/main/config.json"               "$MODELS_DIR/whisper/config.json"
dl "$HF/openai/whisper-tiny/resolve/main/pytorch_model.bin"         "$MODELS_DIR/whisper/pytorch_model.bin"
dl "$HF/openai/whisper-tiny/resolve/main/preprocessor_config.json"  "$MODELS_DIR/whisper/preprocessor_config.json"

# DWPose
dl "$HF/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth"  "$MODELS_DIR/dwpose/dw-ll_ucoco_384.pth"

# SyncNet
dl "$HF/ByteDance/LatentSync/resolve/main/latentsync_syncnet.pt"  "$MODELS_DIR/syncnet/latentsync_syncnet.pt"

# Face Parse Bisent (Google Drive)
pip install -q gdown
gdown --id 154JgKpzCPW82qINcVieuPH3fZ2e0P812 -O "$MODELS_DIR/face-parse-bisent/79999_iter.pth"

# ResNet18
dl "https://download.pytorch.org/models/resnet18-5c106cde.pth" \
   "$MODELS_DIR/face-parse-bisent/resnet18-5c106cde.pth"

log "All model weights downloaded"

# ── Verify model files ──────────────────────────────────────────────────────
echo ""
log "Verifying model files..."
MISSING=0
for f in \
    "$MODELS_DIR/musetalkV15/unet.pth" \
    "$MODELS_DIR/musetalkV15/musetalk.json" \
    "$MODELS_DIR/sd-vae/config.json" \
    "$MODELS_DIR/sd-vae/diffusion_pytorch_model.bin" \
    "$MODELS_DIR/whisper/config.json" \
    "$MODELS_DIR/whisper/pytorch_model.bin" \
    "$MODELS_DIR/whisper/preprocessor_config.json" \
    "$MODELS_DIR/dwpose/dw-ll_ucoco_384.pth" \
    "$MODELS_DIR/syncnet/latentsync_syncnet.pt" \
    "$MODELS_DIR/face-parse-bisent/79999_iter.pth" \
    "$MODELS_DIR/face-parse-bisent/resnet18-5c106cde.pth"; do
    if [ -f "$f" ] && [ $(stat -c%s "$f" 2>/dev/null || echo 0) -gt 1000 ]; then
        SIZE=$(du -h "$f" | cut -f1)
        log "  ✔ $(basename $f) ($SIZE)"
    else
        err "  ✘ MISSING or corrupt: $f"
        MISSING=1
    fi
done

# ── Copy server script if not present ────────────────────────────────────────
if [ ! -f "$SERVER_SCRIPT" ]; then
    warn "musetalk_server.py not found at $SERVER_SCRIPT"
    warn "Downloading from GitHub..."
    wget -q "https://raw.githubusercontent.com/ldonjibson/productivity_youtube-channel/main/musetalk-deploy/musetalk_server.py" \
        -O "$SERVER_SCRIPT" 2>/dev/null || true
    [ -f "$SERVER_SCRIPT" ] || err "Could not download musetalk_server.py — upload it manually"
fi

# ── Start the server ────────────────────────────────────────────────────────
log "Starting MuseTalk API server on port 8000..."
export FFMPEG_PATH="$FFMPEG_STATIC"
export PATH="$FFMPEG_STATIC:$PATH"
export API_KEY="$API_KEY"

cd "$WORKSPACE"

# Run in foreground — will keep the container alive
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  ✅ MUSETALK READY — Starting server...${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Health:     curl http://localhost:8000/health"
echo "  Generate:   curl -X POST http://localhost:8000/generate -F 'image=@avatar.jpg' -F 'audio=@speech.wav'"
echo ""

exec python -m uvicorn musetalk_server:app \
    --host 0.0.0.0 \
    --port 8000 \
    --workers 1 \
    --log-level info
