#!/bin/bash
# =============================================================================
# Build a Vast.ai Template on an EXISTING Instance
# =============================================================================
# This script SSHes into a running vast.ai instance you already created,
# installs all MuseTalk deps + downloads model weights, then saves
# the instance as a reusable template.
#
# Usage:
#   export VAST_API_KEY="your-key"
#   bash build_template_existing.sh <INSTANCE_ID>
#
# Steps BEFORE running this:
#   1. Create an instance on vast.ai dashboard (use the Ubuntu 22 LTS template)
#   2. Wait for it to reach "running" state
#   3. Run this script with the instance ID
#
# The template hash it prints at the end goes into your .env as VAST_TEMPLATE_ID
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ── Args ──────────────────────────────────────────────────────────────────────
[ -z "$VAST_API_KEY" ] && err "Set VAST_API_KEY env var first"
INSTANCE_ID="${1:?Usage: bash build_template_existing.sh <INSTANCE_ID>}"

VAST_BASE="https://console.vast.ai/api/v0"
AUTH="Authorization: Bearer $VAST_API_KEY"
GITHUB_RAW="https://raw.githubusercontent.com/ldonjibson/productivity_youtube-channel/main"

# ── Helper: execute a command on the remote instance via vast.ai API ──────────
run_cmd() {
    local cmd="$1"
    local resp
    resp=$(curl -s -X PUT "$VAST_BASE/instances/command/$INSTANCE_ID/" \
        -H "$AUTH" -H "Content-Type: application/json" \
        -d "{\"command\": $(python3 -c "import json; print(json.dumps('$cmd'))")}")

    # Check for result_url and fetch it
    local result_url
    result_url=$(echo "$resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('result_url', ''))
except:
    print('')
" 2>/dev/null)

    if [ -n "$result_url" ]; then
        # Poll for result (async command)
        sleep 2
        local attempts=0
        while [ $attempts -lt 30 ]; do
            local result
            result=$(curl -s "$result_url" 2>/dev/null)
            if echo "$result" | grep -q '"status":"ok"' 2>/dev/null; then
                echo "$result" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('output', {}).get('stdout', '') if isinstance(data.get('output'), dict) else data.get('output', ''))
except:
    print('')
" 2>/dev/null
                return 0
            fi
            sleep 2
            attempts=$((attempts + 1))
        done
        echo ""
    else
        echo "$resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('output', {}).get('stdout', '') if isinstance(data.get('output'), dict) else '')
except:
    print('')
" 2>/dev/null
    fi
}

# ── Step 1: Verify instance is running ────────────────────────────────────────
log "Checking instance $INSTANCE_ID status..."
INFO=$(curl -s "$VAST_BASE/instances/$INSTANCE_ID/" -H "$AUTH")
STATE=$(echo "$INFO" | python3 -c "
import sys, json
instances = json.load(sys.stdin).get('instances', [])
print(instances[0].get('actual_status','') if instances else '')
" 2>/dev/null || echo "")

if [ "$STATE" != "running" ]; then
    err "Instance is not running (state: $STATE). Start it from the Vast.ai dashboard first."
fi
log "Instance is running!"

# ── Step 2: Get SSH info ─────────────────────────────────────────────────────
SSH_HOST=$(echo "$INFO" | python3 -c "
import sys, json
instances = json.load(sys.stdin).get('instances', [])
inst = instances[0] if instances else {}
print(inst.get('ssh_host', inst.get('public_ipaddr', '')))
")
SSH_PORT=$(echo "$INFO" | python3 -c "
import sys, json
instances = json.load(sys.stdin).get('instances', [])
inst = instances[0] if instances else {}
ports = inst.get('ports', {})
for cp, mappings in ports.items():
    if '22' in str(cp) and mappings:
        print(mappings[0].get('HostPort', ''))
        break
" 2>/dev/null || echo "")

# ── Step 3: Upload setup scripts and install ──────────────────────────────────
log "Uploading scripts to instance..."
GITHUB_RAW_ESCAPED="${GITHUB_RAW//\//\\/}"

# Create the install command that will run on the instance
INSTALL_CMD='#!/bin/bash
set -e
apt-get update -qq
apt-get install -y -qq wget git curl > /dev/null 2>&1

echo "[1/4] Downloading setup scripts from GitHub..."
wget -q "'"$GITHUB_RAW"'/musetalk_server.py"   -O /workspace/musetalk_server.py
wget -q "'"$GITHUB_RAW"'/musetalk_deploy.sh"  -O /workspace/musetalk_deploy.sh
chmod +x /workspace/musetalk_deploy.sh

echo "[2/4] Running MuseTalk deploy script (this takes ~10-12 min)..."
bash /workspace/musetalk_deploy.sh --api-key "template-build" 2>&1

echo "[3/4] Verifying server can start..."
cd /workspace
export API_KEY="template-build"
export FFMPEG_PATH="/workspace/ffmpeg-static"
timeout 10 python -c "
import torch
print(\"CUDA available:\", torch.cuda.is_available())
print(\"GPU:\", torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"none\")
" 2>&1 || echo "GPU check skipped (will work on next boot)"

echo "[4/4] Done installing!"
'

log "Starting installation on instance $INSTANCE_ID..."
log "This will take ~10-12 minutes (installing deps + downloading ~8GB of models)..."

# Upload and execute via SSH if possible, otherwise use the vast.ai command API
if [ -n "$SSH_PORT" ] && [ -n "$SSH_HOST" ]; then
    log "Using SSH to install (host: $SSH_HOST, port: $SSH_PORT)"
    log "SSH into your instance if you want to watch progress:"
    log "  ssh -p $SSH_PORT root@$SSH_HOST"
    log ""
fi

# Use the vast.ai execute API
RESULT=$(curl -s -X PUT "$VAST_BASE/instances/command/$INSTANCE_ID/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
cmd = '''#!/bin/bash
set -e
apt-get update -qq
apt-get install -y -qq wget git curl > /dev/null 2>&1

echo \"[1/4] Downloading setup scripts from GitHub...\"
wget -q \"$GITHUB_RAW/musetalk_server.py\" -O /workspace/musetalk_server.py
wget -q \"$GITHUB_RAW/musetalk_deploy.sh\" -O /workspace/musetalk_deploy.sh
chmod +x /workspace/musetalk_deploy.sh

echo \"[2/4] Running MuseTalk deploy script...\"
bash /workspace/musetalk_deploy.sh --api-key template-build

echo \"[3/4] Verifying installation...\"
cd /workspace
export FFMPEG_PATH=\"/workspace/ffmpeg-static\"

echo \"[4/4] Installation complete!\"
'''
print(json.dumps({'command': cmd}))
")")

# Check if command was accepted
CMD_ACCEPTED=$(echo "$RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print('yes' if 'result_url' in data or 'success' in data else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

if [ "$CMD_ACCEPTED" = "no" ]; then
    err "Could not send command to instance. Response: $RESULT"
fi

log "Command sent to instance. Waiting for installation to complete..."
log "(Monitor progress by SSH-ing in: ssh -p $SSH_PORT root@$SSH_HOST)"
log ""

# Wait for the command to complete by polling health endpoint
# The deploy script starts uvicorn on port 8000 when done
IP=$(echo "$INFO" | python3 -c "
import sys, json
instances = json.load(sys.stdin).get('instances', [])
inst = instances[0] if instances else {}
print(inst.get('public_ipaddr') or inst.get('ssh_host', ''))
")
PORTS=$(echo "$INFO" | python3 -c "
import sys, json
instances = json.load(sys.stdin).get('instances', [])
inst = instances[0] if instances else {}
ports = inst.get('ports', {})
host_port = None
for cp, mappings in ports.items():
    if '8000' in str(cp) and mappings:
        host_port = mappings[0].get('HostPort')
        break
print(host_port or '')
")

API_URL="http://$IP:$PORTS"

if [ -n "$PORTS" ]; then
    log "Waiting for MuseTalk server at $API_URL/health ..."
    SECONDS=0
    while [ $SECONDS -lt 1200 ]; do
        if curl -s -o /dev/null -w "%{http_code}" "$API_URL/health" 2>/dev/null | grep -q "200"; then
            log "MuseTalk server is healthy! (${SECONDS}s elapsed)"
            break
        fi
        if [ $((SECONDS % 60)) -eq 0 ] && [ $SECONDS -gt 0 ]; then
            echo "  ... still installing (${SECONDS}s elapsed)"
        fi
        sleep 15
    done

    if ! curl -s -o /dev/null -w "%{http_code}" "$API_URL/health" 2>/dev/null | grep -q "200"; then
        warn "Server not responding yet after 20 min. Check the instance manually."
        warn "SSH: ssh -p $SSH_PORT root@$SSH_HOST"
        warn "Then: tail -f /workspace/server.log"
    fi
else
    warn "Could not determine port 8000 mapping. Check Vast.ai dashboard."
fi

# ── Step 4: Save as template ──────────────────────────────────────────────────
log "Saving instance as template..."

TEMPLATE_RESP=$(curl -s -X PUT "$VAST_BASE/template/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
payload = {
    'instance_id': $INSTANCE_ID,
    'label': 'musetalk-server',
    'image': 'pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime',
    'disk': 60,
    'extra_ports': '8000'
}
print(json.dumps(payload))
")")

TEMPLATE_HASH=$(echo "$TEMPLATE_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    t = data.get('template', data)
    print(t.get('hash_id', '') or t.get('id', ''))
except:
    print('')
" 2>/dev/null)

if [ -n "$TEMPLATE_HASH" ]; then
    echo ""
    log "============================================"
    log "TEMPLATE CREATED SUCCESSFULLY"
    log "============================================"
    echo ""
    log "Template hash: $TEMPLATE_HASH"
    echo ""
    echo "  Add this to your .env file:"
    echo "  VAST_TEMPLATE_ID=$TEMPLATE_HASH"
    echo ""
else
    warn "Template save response: $TEMPLATE_RESP"
    warn ""
    warn "Manual steps to save template:"
    warn "  1. Go to https://cloud.vast.ai/instances/"
    warn "  2. Click on instance $INSTANCE_ID"
    warn "  3. Click 'Save as Template'"
    warn "  4. Label it 'musetalk-server'"
    warn "  5. Copy the hash and add to .env as VAST_TEMPLATE_ID=<hash>"
fi

echo ""
log "Instance is still running. Destroy it from the dashboard when done,"
log "or use: curl -X DELETE $VAST_BASE/instances/$INSTANCE_ID/ -H '$AUTH'"
