#!/bin/bash
# =============================================================================
# Build a Vast.ai Template for MuseTalk
# =============================================================================
# Run this ONCE. It:
#   1. Spins up a cheap GPU instance
#   2. Installs all MuseTalk deps + downloads model weights (~8GB)
#   3. Saves a reusable template so future instances start in seconds
#
# Usage:
#   export VAST_API_KEY="your-key"
#   bash build_template.sh
#
# The template ID it prints at the end goes into your .env as VAST_TEMPLATE_ID
# =============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

[ -z "$VAST_API_KEY" ] && err "Set VAST_API_KEY env var first"

VAST_BASE="https://console.vast.ai/api/v0"
AUTH="Authorization: Bearer $VAST_API_KEY"

# ── Step 1: Find a cheap on-demand GPU with 16GB+ VRAM ────────────────────────
log "Searching for a cheap GPU instance..."
SEARCH_RESP=$(curl -s -X POST "$VAST_BASE/bundles/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d '{
        "limit": 5,
        "type": "ondemand",
        "order": [["dph_total", "asc"]],
        "rentable": {"eq": true},
        "rented": {"eq": false},
        "direct_port_count": {"gte": 1},
        "disk_space": {"gte": 50},
        "gpu_ram": {"gte": 16000}
    }')

OFFER_ID=$(echo "$SEARCH_RESP" | python3 -c "
import sys, json
offers = json.load(sys.stdin).get('offers', [])
if not offers: sys.exit('No offers found')
# Pick cheapest
best = sorted(offers, key=lambda o: o.get('dph_total', 99))[0]
print(f\"{best['id']}|{best.get('gpu_name','?')}|{best['dph_total']:.4f}\")
")

IFS='|' read -r OFFER_ID GPU_NAME GPU_PRICE <<< "$OFFER_ID"
log "Selected: $GPU_NAME @ \$${GPU_PRICE}/hr (offer $OFFER_ID)"

# ── Step 2: Create the instance ───────────────────────────────────────────────
GITHUB_RAW="https://raw.githubusercontent.com/ldonjibson/productivity_youtube-channel/main"

ONSTART=$(cat <<'SCRIPT'
#!/bin/bash
set -e
apt-get update -qq
apt-get install -y -qq wget git curl > /dev/null 2>&1

wget -q "GITHUB_RAW_PLACEHOLDER/musetalk_server.py"   -O /workspace/musetalk_server.py
wget -q "GITHUB_RAW_PLACEHOLDER/musetalk_deploy.sh"  -O /workspace/musetalk_deploy.sh
chmod +x /workspace/musetalk_deploy.sh
bash /workspace/musetalk_deploy.sh --api-key "template-build"
SCRIPT
)
ONSTART="${ONSTART//GITHUB_RAW_PLACEHOLDER/$GITHUB_RAW}"

log "Creating instance..."
CREATE_RESP=$(curl -s -X PUT "$VAST_BASE/asks/$OFFER_ID/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "$(python3 -c "
import json
payload = {
    'client_id': 'me',
    'image': 'pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime',
    'disk': 60,
    'onstart': '''$ONSTART''',
    'env': {'API_KEY': 'template-build'},
    'label': 'musetalk-template-builder',
    'runtype': 'ssh'
}
print(json.dumps(payload))
")")

CONTRACT_ID=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('new_contract',''))")
[ -z "$CONTRACT_ID" ] && err "Failed to create instance: $CREATE_RESP"
INSTANCE_ID="$CONTRACT_ID"
log "Instance $INSTANCE_ID created"

# ── Step 3: Wait for it to be running + server ready ──────────────────────────
log "Waiting for instance to start (this takes ~1-2 min)..."
for i in $(seq 1 60); do
    INFO=$(curl -s "$VAST_BASE/instances/$INSTANCE_ID/" -H "$AUTH")
    STATE=$(echo "$INFO" | python3 -c "
import sys, json
instances = json.load(sys.stdin).get('instances', [])
print(instances[0].get('actual_status','') if instances else '')
" 2>/dev/null || echo "")

    if [ "$STATE" = "running" ]; then
        log "Instance running!"
        break
    fi
    echo -n "."
    sleep 10
done
[ "$STATE" != "running" ] && err "Instance did not reach running state (got: $STATE)"

# ── Step 4: Wait for the MuseTalk server to be healthy ────────────────────────
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
log "Server should be at $API_URL — waiting for /health..."

for i in $(seq 1 90); do
    if curl -s -o /dev/null -w "%{http_code}" "$API_URL/health" 2>/dev/null | grep -q "200"; then
        log "MuseTalk server is healthy!"
        break
    fi
    echo -n "."
    sleep 10
done

# ── Step 5: Save as template ──────────────────────────────────────────────────
log "Saving template..."
TEMPLATE_RESP=$(curl -s -X PUT "$VAST_BASE/template/" \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d "{
        \"instance_id\": $INSTANCE_ID,
        \"label\": \"musetalk-server\",
        \"image\": \"pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime\",
        \"disk\": 60,
        \"onstart\": $(python3 -c "import json; print(json.dumps('''$ONSTART'''))"),
        \"extra_ports\": \"8000\"
    }")

TEMPLATE_ID=$(echo "$TEMPLATE_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('template', {}).get('hash_id', '') or data.get('hash_id', ''))
" 2>/dev/null)

if [ -n "$TEMPLATE_ID" ]; then
    echo ""
    log "============================================"
    log "TEMPLATE CREATED SUCCESSFULLY"
    log "============================================"
    echo ""
    log "Template hash: $TEMPLATE_ID"
    echo ""
    echo "  Add this to your .env file:"
    echo "  VAST_TEMPLATE_ID=$TEMPLATE_ID"
    echo ""
else
    warn "Template save response: $TEMPLATE_RESP"
    warn "You may need to save the template manually from the Vast.ai dashboard"
fi

# ── Step 6: Destroy the builder instance ──────────────────────────────────────
log "Destroying builder instance $INSTANCE_ID..."
curl -s -X DELETE "$VAST_BASE/instances/$INSTANCE_ID/" -H "$AUTH" > /dev/null
log "Instance destroyed"

echo ""
log "Done! Future instances will use this template for instant startup."
