#!/bin/bash
# =============================================================================
# Build a Reusable MuseTalk Docker Image for Vast.ai
# =============================================================================
# Run this ON a vast.ai instance where you want to snapshot the state.
#
# This commits the container as a Docker image, pushes to Docker Hub,
# then gives you instructions to create a template.
#
# Why Docker commit? Because Vast.ai templates are just configs (image + onstart).
# They can NOT "save instance state" — you need a Docker image with everything pre-installed.
#
# Usage:
#   export DOCKERHUB_USERNAME="your-dockerhub-user"
#   export DOCKERHUB_TOKEN="your-dockerhub-access-token"
#   bash build_template_local.sh
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ── Config ───────────────────────────────────────────────────────────────────
IMAGE_NAME="${DOCKERHUB_USERNAME:-musetalk}/musetalk"
IMAGE_TAG="latest"
FULL_IMAGE="$IMAGE_NAME:$IMAGE_TAG"
GITHUB_RAW="https://raw.githubusercontent.com/ldonjibson/productivity_youtube-channel/main"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     BUILDING MUSETALK REUSABLE DOCKER IMAGE                ║"
echo "║     Image: $FULL_IMAGE                                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Install system deps ──────────────────────────────────────────────
log "Step 1/5: Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq wget git curl ffmpeg > /dev/null 2>&1

# ── Step 2: Run MuseTalk deploy (installs everything + downloads models) ─────
log "Step 2/5: Running MuseTalk deploy (this downloads ~8GB of models)..."
mkdir -p /workspace
cd /workspace

echo "  Downloading scripts from GitHub..."
wget -q "$GITHUB_RAW/musetalk_server.py" -O /workspace/musetalk_server.py
wget -q "$GITHUB_RAW/musetalk_deploy.sh" -O /workspace/musetalk_deploy.sh
chmod +x /workspace/musetalk_deploy.sh

echo "  Running deploy script..."
bash /workspace/musetalk_deploy.sh --api-key template-build 2>&1 | tail -10

# ── Step 3: Verify installation ──────────────────────────────────────────────
log "Step 3/5: Verifying installation..."
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

# ── Step 4: Docker commit ────────────────────────────────────────────────────
log "Step 4/5: Committing container state as Docker image..."

# Find our container ID
CONTAINER_ID=$(cat /proc/1/cpuset 2>/dev/null | cut -d'/' -f3 || hostname)
log "  Container ID: $CONTAINER_ID"

# Get the base image we're running on
BASE_IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_ID" 2>/dev/null || echo "pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime")
log "  Base image: $BASE_IMAGE"

# Commit the container
docker commit "$CONTAINER_ID" "$FULL_IMAGE" 2>&1 || {
    warn "docker commit failed. Trying with sudo..."
    sudo docker commit "$CONTAINER_ID" "$FULL_IMAGE" 2>&1 || err "docker commit failed"
}

log "Docker image created: $FULL_IMAGE"
log "Image size: $(docker images --format '{{.Size}}' "$FULL_IMAGE" 2>/dev/null || echo 'unknown')"

# ── Step 5: Push to Docker Hub ───────────────────────────────────────────────
if [ -n "$DOCKERHUB_USERNAME" ] && [ -n "$DOCKERHUB_TOKEN" ]; then
    log "Step 5/5: Pushing to Docker Hub..."
    
    # Login
    echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin 2>&1 || {
        warn "docker login failed. Trying with sudo..."
        echo "$DOCKERHUB_TOKEN" | sudo docker login -u "$DOCKERHUB_USERNAME" --password-stdin 2>&1 || err "Docker Hub login failed"
    }
    
    # Push (this may take a while — it's a big image)
    docker push "$FULL_IMAGE" 2>&1 || {
        warn "docker push failed. Trying with sudo..."
        sudo docker push "$FULL_IMAGE" 2>&1 || err "Docker Hub push failed"
    }
    
    log "Image pushed: $FULL_IMAGE"
else
    warn "DOCKERHUB_USERNAME / DOCKERHUB_TOKEN not set."
    warn "Skipping push. To push manually:"
    warn "  docker login && docker push $FULL_IMAGE"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  ✅ DOCKER IMAGE READY: $FULL_IMAGE"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  To create a Vast.ai template:"
echo "  1. Go to https://cloud.vast.ai/templates"
echo "  2. Click '+ New'"
echo "  3. Set Docker Image: $FULL_IMAGE"
echo "  4. Set Disk Space: 80 GB"
echo "  5. Set Launch Mode: SSH"
echo "  6. Add On-Start Script:"
echo '     #!/bin/bash'
echo '     export FFMPEG_PATH="/workspace/ffmpeg-static"'
echo '     cd /workspace'
echo '     nohup python3 -m uvicorn musetalk_server:app --host 0.0.0.0 --port 8000 > /workspace/server.log 2>&1 &'
echo "  7. Save → get template hash → add to .env as VAST_TEMPLATE_ID"
echo ""
echo "  With this image, new instances boot in ~30-60 seconds"
echo "  (models already baked in, no download needed)"
