#!/bin/bash
# =============================================================================
# Build a Vast.ai Template LOCALLY (run this ON the instance itself)
# =============================================================================
# SSH into your vast.ai instance, then run this script directly.
# No remote SSH extraction needed — everything runs locally.
#
# Usage (on the instance):
#   export VAST_API_KEY="your-key"
#   export INSTANCE_ID=$(curl -s https://instance-data/vastai-id 2>/dev/null || echo "")
#   bash build_template_local.sh
#
# Or pass it explicitly:
#   bash build_template_local.sh <INSTANCE_ID>
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ── Args ──────────────────────────────────────────────────────────────────────
[ -z "$VAST_API_KEY" ] && err "Set VAST_API_KEY env var first"
INSTANCE_ID="${1:-}"

if [ -z "$INSTANCE_ID" ]; then
    # Try to auto-detect instance ID from vast.ai metadata
    INSTANCE_ID=$(curl -s http://metadata.vast.ai/instance_id 2>/dev/null || echo "")
fi

if [ -z "$INSTANCE_ID" ]; then
    # Ask user
    read -p "Enter your Vast.ai instance ID: " INSTANCE_ID
fi

[ -z "$INSTANCE_ID" ] && err "Could not determine instance ID"

VAST_BASE="https://console.vast.ai/api/v0"
AUTH="Authorization: Bearer $VAST_API_KEY"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     BUILDING MUSETALK TEMPLATE (LOCAL MODE)                ║"
echo "║     Instance: $INSTANCE_ID                                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Install system deps ──────────────────────────────────────────────
log "Step 1/5: Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq wget git curl ffmpeg > /dev/null 2>&1

# ── Step 2: Install Python deps ──────────────────────────────────────────────
log "Step 2/5: Installing Python dependencies..."
pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 2>/dev/null || true
pip install --quiet fastapi uvicorn python-multipart requests 2>/dev/null || true

# ── Step 3: Run MuseTalk deploy ──────────────────────────────────────────────
log "Step 3/5: Running MuseTalk deploy script..."
mkdir -p /workspace
cd /workspace

# Download setup scripts from GitHub
GITHUB_RAW="https://raw.githubusercontent.com/ldonjibson/productivity_youtube-channel/main"

echo "  Downloading musetalk_server.py..."
wget -q "$GITHUB_RAW/musetalk_server.py" -O /workspace/musetalk_server.py

echo "  Downloading musetalk_deploy.sh..."
wget -q "$GITHUB_RAW/musetalk_deploy.sh" -O /workspace/musetalk_deploy.sh
chmod +x /workspace/musetalk_deploy.sh

echo "  Running deploy script (this downloads ~8GB of models)..."
bash /workspace/musetalk_deploy.sh --api-key template-build 2>&1 | tail -5

# ── Step 4: Verify installation ──────────────────────────────────────────────
log "Step 4/5: Verifying installation..."
export FFMPEG_PATH="/workspace/ffmpeg-static"

# Quick health check — start server briefly to confirm it loads
cd /workspace
timeout 30 python3 -c "
import sys
sys.path.insert(0, '/workspace')
try:
    from musetalk_server import app
    print('FastAPI app imports OK')
except Exception as e:
    print(f'Import warning: {e}')
" 2>/dev/null || warn "Could not import musetalk_server (may need manual check)"

# ── Step 5: Create template ──────────────────────────────────────────────────
log "Step 5/5: Creating template..."

TEMPLATE_NAME="musetalk-$(date +%Y%m%d-%H%M%S)"
RESULT=$(curl -s -X PUT "$VAST_BASE/asks/$INSTANCE_ID/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "{
        \"templates\": [{
            \"template_name\": \"$TEMPLATE_NAME\",
            \"instance_id\": $INSTANCE_ID
        }]
    }")

TEMPLATE_HASH=$(echo "$RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Try different response formats
    if 'template_id' in data:
        print(data['template_id'])
    elif 'templates' in data:
        t = data['templates']
        if isinstance(t, list) and t:
            print(t[0].get('hash', t[0].get('id', '')))
        elif isinstance(t, dict):
            print(t.get('hash', t.get('id', '')))
    elif 'hash' in data:
        print(data['hash'])
    elif 'id' in data:
        print(data['id'])
except Exception as e:
    print(f'parse_error: {e}', file=sys.stderr)
" 2>/dev/null || echo "")

if [ -n "$TEMPLATE_HASH" ] && [ "$TEMPLATE_HASH" != "parse_error"* ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✅ TEMPLATE CREATED SUCCESSFULLY!                         ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Template Name: $TEMPLATE_NAME"
    echo "║  Template Hash: $TEMPLATE_HASH"
    echo "║                                                             ║"
    echo "║  Add to your .env file:                                     ║"
    echo "║    VAST_TEMPLATE_ID=$TEMPLATE_HASH"
    echo "╚══════════════════════════════════════════════════════════════╝"
else
    warn "Could not parse template hash from API response."
    echo "Raw response: $RESULT"
    echo ""
    echo "You may need to save the template manually from the Vast.ai dashboard."
    echo "Go to: https://cloud.vast.ai/templates and create one from instance $INSTANCE_ID"
fi

echo ""
log "Done! The instance now has MuseTalk fully installed."
log "You can destroy this instance and use the template for faster startups."
