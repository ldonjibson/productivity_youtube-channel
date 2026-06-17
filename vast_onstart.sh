#!/bin/bash
# =============================================================================
# Vast.ai Onstart Script for ldonjibson/musetalk:latest
# =============================================================================
# Copy this into your Vast.ai Template onstart field
# =============================================================================

set -e

export FFMPEG_PATH="/workspace/ffmpeg-static"
export PATH="/workspace/ffmpeg-static:$PATH"
export API_KEY="${MUSETALK_API_KEY:-musetalk-secret}"

cd /workspace

# Quick sanity checks
echo "=== MuseTalk Onstart ==="
echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'not found')"
echo "CUDA: $(python3 -c 'import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else "")' 2>/dev/null || echo 'check failed')"
echo "Server script: $(ls -la /workspace/musetalk_server.py 2>/dev/null || echo 'MISSING')"
echo "Models dir: $(ls /workspace/MuseTalk/models/ 2>/dev/null || echo 'MISSING')"
echo "ffmpeg: $(which ffmpeg 2>/dev/null || echo 'not on PATH')"

# Start the server
echo "Starting MuseTalk API server on port 8000..."
python3 -m uvicorn musetalk_server:app \
    --host 0.0.0.0 \
    --port 8000 \
    --log-level info
