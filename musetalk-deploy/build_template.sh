#!/bin/bash
# =============================================================================
# Build a Vast.ai Template for MuseTalk (fully automated)
# =============================================================================
# This script:
#   1. Finds the cheapest GPU instance on Vast.ai (16GB+ VRAM)
#   2. Spins it up with the MuseTalk Docker image
#   3. Downloads all model weights (~8GB)
#   4. Saves the instance as a reusable template
#
# Usage:
#   export VAST_API_KEY="your-key-here"
#   bash build_template.sh
#
# Prerequisites:
#   - Vast.ai account with API key (https://cloud.vast.ai/manage-keys/)
#   - Docker image pushed to Docker Hub (or use musetalk_deploy.sh approach)
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

[ -z "$VAST_API_KEY" ] && err "Set VAST_API_KEY env var first.\n  export VAST_API_KEY='your-key-here'"

VAST_BASE="https://console.vast.ai/api/v0"
AUTH="Authorization: Bearer $VAST_API_KEY"
GITHUB_RAW="https://raw.githubusercontent.com/ldonjibson/productivity_youtube-channel/main/musetalk-deploy"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     BUILDING MUSETALK VAST.AI TEMPLATE                      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Find cheapest GPU with 16GB+ VRAM ───────────────────────────────
log "Searching for cheapest GPU instance (16GB+ VRAM)..."

SEARCH_RESP=$(curl -s -X POST "$VAST_BASE/bundles/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d '{
        "limit": 10,
        "type": "ondemand",
        "order": [["dph_total", "asc"]],
        "rentable": {"eq": true},
        "rented": {"eq": false},
        "direct_port_count": {"gte": 1},
        "disk_space": {"gte": 60},
        "gpu_ram": {"gte": 16000}
    }')

OFFER_INFO=$(echo "$SEARCH_RESP" | python3 -c "
import sys, json
try:
    offers = json.load(sys.stdin).get('offers', [])
    if not offers:
        print('NO_OFFERS')
        sys.exit(0)
    best = sorted(offers, key=lambda o: o.get('dph_total', 99))[0]
    print(f\"{best['id']}|{best.get('gpu_name','?')}|{best['dph_total']:.4f}|{best.get('num_gpus',1)}\")
except Exception as e:
    print(f'ERROR: {e}')
")

[ "$OFFER_INFO" = "NO_OFFERS" ] && err "No GPU offers found. Try again later or increase budget."
echo "$OFFER_INFO" | grep -q "ERROR:" && err "Search failed: $OFFER_INFO"

IFS='|' read -r OFFER_ID GPU_NAME GPU_PRICE NUM_GPUS <<< "$OFFER_INFO"
log "Selected: $GPU_NAME ($NUM_GPUS GPU) @ \$$GPU_PRICE/hr (offer #$OFFER_ID)"

# ── Step 2: Create instance ─────────────────────────────────────────────────
log "Creating instance..."

ONSTART=$(cat <<SCRIPT
#!/bin/bash
set -e
apt-get update -qq && apt-get install -y -qq wget git curl > /dev/null 2>&1

# Download scripts
wget -q "$GITHUB_RAW/musetalk_server.py" -O /workspace/musetalk_server.py 2>/dev/null || true
wget -q "$GITHUB_RAW/musetalk_deploy.sh" -O /workspace/musetalk_deploy.sh 2>/dev/null || true
chmod +x /workspace/musetalk_deploy.sh 2>/dev/null || true

# Run the deploy script (installs deps + downloads models + starts server)
bash /workspace/musetalk_deploy.sh --api-key "template-build" 2>&1 | tee /workspace/setup.log
SCRIPT
)

CREATE_RESP=$(curl -s -X PUT "$VAST_BASE/asks/$OFFER_ID/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
payload = {
    'client_id': 'me',
    'image': 'pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime',
    'disk': 80,
    'onstart': '''$ONSTART''',
    'env': {'API_KEY': 'template-build'},
    'label': 'musetalk-template-builder',
    'runtype': 'ssh'
}
print(json.dumps(payload))
")")

CONTRACT_ID=$(echo "$CREATE_RESP" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('new_contract', ''))
except:
    print('')
" 2>/dev/null)

[ -z "$CONTRACT_ID" ] && err "Failed to create instance: $CREATE_RESP"
INSTANCE_ID="$CONTRACT_ID"
log "Instance #$INSTANCE_ID created"

# ── Step 3: Wait for running state ──────────────────────────────────────────
log "Waiting for instance to reach 'running' state (may take 1-2 min)..."
STATE=""
for i in $(seq 1 60); do
    INFO=$(curl -s "$VAST_BASE/instances/$INSTANCE_ID/" -H "$AUTH")
    STATE=$(echo "$INFO" | python3 -c "
import sys, json
try:
    instances = json.load(sys.stdin).get('instances', [])
    print(instances[0].get('actual_status', '') if instances else '')
except:
    print('')
" 2>/dev/null || echo "")

    if [ "$STATE" = "running" ]; then
        log "Instance is running!"
        break
    fi
    echo -n "."
    sleep 10
done

[ "$STATE" != "running" ] && err "Instance did not reach running state (got: $STATE). Check dashboard."

# ── Step 4: Wait for server health ──────────────────────────────────────────
# Extract IP and port from instance info
IP=$(echo "$INFO" | python3 -c "
import sys, json
instances = json.load(sys.stdin).get('instances', [])
inst = instances[0] if instances else {}
print(inst.get('public_ipaddr') or inst.get('ssh_host', ''))
" 2>/dev/null)

PORT=$(echo "$INFO" | python3 -c "
import sys, json
instances = json.load(sys.stdin).get('instances', [])
inst = instances[0] if instances else {}
ports = inst.get('ports', {})
for cp, mappings in ports.items():
    if '8000' in str(cp) and mappings:
        print(mappings[0].get('HostPort', ''))
        break
" 2>/dev/null)

API_URL="http://$IP:$PORT"
log "Server URL: $API_URL — waiting for /health..."

for i in $(seq 1 120); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        log "MuseTalk server is healthy!"
        break
    fi
    echo -n "."
    sleep 15
done

# ── Step 5: Save as template ────────────────────────────────────────────────
log "Saving instance as template..."

TEMPLATE_RESP=$(curl -s -X PUT "$VAST_BASE/template/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "{
        \"instance_id\": $INSTANCE_ID,
        \"label\": \"musetalk-ready\"
    }")

TEMPLATE_ID=$(echo "$TEMPLATE_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('template', {}).get('id', data.get('id', '')))
except:
    print('')
" 2>/dev/null)

if [ -n "$TEMPLATE_ID" ]; then
    log "Template saved! ID: $TEMPLATE_ID"
else
    warn "Could not auto-save template. Save manually from dashboard."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     ✅ TEMPLATE BUILD COMPLETE                              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Instance ID:  $INSTANCE_ID"
echo "  Template ID:  ${TEMPLATE_ID:-'(save manually from dashboard)'}"
echo "  Server URL:   $API_URL"
echo "  GPU:          $GPU_NAME"
echo ""
echo "  Add to .env:  VAST_TEMPLATE_ID=$TEMPLATE_ID"
echo ""
echo "  Test it:      curl $API_URL/health"
echo "  Dashboard:    https://cloud.vast.ai/instances/$INSTANCE_ID"
echo ""
