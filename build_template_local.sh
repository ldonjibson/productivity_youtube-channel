#!/bin/bash
# =============================================================================
# Install MuseTalk on this Vast.ai instance (runtime only)
# =============================================================================
# This installs MuseTalk + deps on the current instance so you can use it NOW.
# It does NOT create a template (docker commit is not available inside
# vast.ai containers — they don't mount /var/run/docker.sock).
#
# To build a reusable Docker image, use the Dockerfile instead:
#   docker build -t ldonjibson/musetalk:latest .
#   docker push ldonjibson/musetalk:latest
#   Then create a template at https://cloud.vast.ai/templates
#
# Usage (on the instance):
#   bash build_template_local.sh
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

GITHUB_RAW="https://raw.githubusercontent.com/ldonjibson/productivity_youtube-channel/main"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     INSTALLING MUSETALK ON THIS INSTANCE                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Install system deps ──────────────────────────────────────────────
log "Step 1/4: Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq wget git curl ffmpeg > /dev/null 2>&1

# ── Step 2: Run MuseTalk deploy (installs everything + downloads models) ─────
log "Step 2/4: Running MuseTalk deploy (this downloads ~8GB of models)..."
mkdir -p /workspace
cd /workspace

echo "  Downloading scripts from GitHub..."
wget -q "$GITHUB_RAW/musetalk_server.py" -O /workspace/musetalk_server.py
wget -q "$GITHUB_RAW/musetalk_deploy.sh" -O /workspace/musetalk_deploy.sh
chmod +x /workspace/musetalk_deploy.sh

echo "  Running deploy script..."
bash /workspace/musetalk_deploy.sh --api-key "${MUSETALK_API_KEY:-musetalk-secret}" 2>&1 | tail -10

# ── Step 3: Verify installation ──────────────────────────────────────────────
log "Step 3/4: Verifying installation..."
export FFMPEG_PATH="/workspace/ffmpeg-static"
cd /workspace

timeout 30 python3 -c "
import sys
sys.path.insert(0, '/workspace')
try:
    from musetalk_server import app
    print('  FastAPI app imports OK')
except Exception as e:
    print(f'  Import warning: {e}')
" 2>/dev/null || warn "Could not verify musetalk_server"

# ── Step 4: Start server ────────────────────────────────────────────────────
log "Step 4/4: Starting MuseTalk server on port 8000..."

export FFMPEG_PATH="/workspace/ffmpeg-static"
cd /workspace
nohup python3 -m uvicorn musetalk_server:app --host 0.0.0.0 --port 8000 --log-level info > /workspace/server.log 2>&1 &
echo $! > /workspace/musetalk.pid

log "Server started! PID: $(cat /workspace/musetalk.pid)"
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  ✅ MUSETALK RUNNING"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Health:  curl http://localhost:8000/health"
echo "  Logs:    tail -f /workspace/server.log"
echo "  Stop:    kill \$(cat /workspace/musetalk.pid)"
echo ""
echo "  To build a reusable Docker image for faster future startups:"
echo "  1. Clone this repo on your LOCAL machine"
echo "  2. Run: docker build -t ldonjibson/musetalk:latest ."
echo "  3. Run: docker push ldonjibson/musetalk:latest"
echo "  4. Create template at https://cloud.vast.ai/templates"
echo "     with image: ldonjibson/musetalk:latest"
