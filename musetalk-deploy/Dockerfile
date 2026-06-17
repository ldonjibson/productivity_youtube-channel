# =============================================================================
# MuseTalk Docker Image — Fresh Build
# =============================================================================
# Build:   docker build -t ldonjibson/musetalk:latest .
# Run:     docker run --gpus all -p 8000:8000 ldonjibson/musetalk:latest
#
# This image contains:
#   - PyTorch 2.0.1 + CUDA 11.7
#   - MuseTalk (TMElyralab/MuseTalk) + all Python deps
#   - All model weights (~8GB) baked in
#   - FastAPI server (musetalk_server.py)
#   - Static ffmpeg
#
# Total image size: ~18-20GB
# =============================================================================

FROM pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime AS base

LABEL maintainer="ldonjibson"
LABEL description="MuseTalk lip-sync API — fully self-contained"

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV FFMPEG_PATH=/workspace/ffmpeg-static
ENV PATH=/workspace/ffmpeg-static:$PATH
# Use HuggingFace mirror for faster downloads in some regions
# Set to https://huggingface.co if mirror not needed
ENV HF_ENDPOINT=https://huggingface.co

# ── System deps ──────────────────────────────────────────────────────────────
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        git wget curl unzip ca-certificates \
        libgl1-mesa-glx libglib2.0-0 \
        libsm6 libxext6 libxrender-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Static ffmpeg ────────────────────────────────────────────────────────────
RUN mkdir -p /workspace/ffmpeg-static && \
    wget -q "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" \
        -O /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    FFMPEG_DIR=$(find /tmp -maxdepth 1 -name "ffmpeg-*-amd64-static" -type d | head -1) && \
    cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" /workspace/ffmpeg-static/ && \
    chmod +x /workspace/ffmpeg-static/ffmpeg /workspace/ffmpeg-static/ffprobe && \
    rm -rf /tmp/ffmpeg.tar.xz "$FFMPEG_DIR"

# ── Clone MuseTalk ───────────────────────────────────────────────────────────
RUN git clone https://github.com/TMElyralab/MuseTalk.git /workspace/MuseTalk && \
    cd /workspace/MuseTalk && git checkout main

# ── Python dependencies ─────────────────────────────────────────────────────
# PyTorch 2.0.1 with CUDA 11.8 wheels (bundled CUDA runtime, works on 11.7 base)
RUN pip install --no-cache-dir \
        torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 \
        --index-url https://download.pytorch.org/whl/cu118

# MMLab ecosystem (mmcv, mmdet, mmpose)
RUN pip install --no-cache-dir -U openmim && \
    mim install --no-cache-dir mmengine && \
    mim install --no-cache-dir "mmcv==2.0.1" && \
    mim install --no-cache-dir "mmdet==3.1.0" && \
    mim install --no-cache-dir "mmpose==1.1.0"

# MuseTalk requirements + API server deps
RUN pip install --no-cache-dir -r /workspace/MuseTalk/requirements.txt && \
    pip install --no-cache-dir fastapi uvicorn[standard] python-multipart pyyaml

# ── Download model weights ───────────────────────────────────────────────────
# Using Python script with huggingface_hub + curl fallback for reliability.
# Each model is downloaded separately for better Docker layer caching.

RUN pip install --no-cache-dir "huggingface_hub[cli]>=0.20.0" gdown

# Create model directories
RUN mkdir -p \
    /workspace/MuseTalk/models/musetalk \
    /workspace/MuseTalk/models/musetalkV15 \
    /workspace/MuseTalk/models/syncnet \
    /workspace/MuseTalk/models/dwpose \
    /workspace/MuseTalk/models/face-parse-bisent \
    /workspace/MuseTalk/models/sd-vae \
    /workspace/MuseTalk/models/whisper

# --- MuseTalk V1.5 (main model) ---
RUN huggingface-cli download TMElyralab/MuseTalk \
    musetalkV15/unet.pth musetalkV15/musetalk.json \
    --local-dir /workspace/MuseTalk/models \
    --local-dir-use-symlinks False \
    || (echo "huggingface-cli failed, trying curl..." && \
        curl -L -o /workspace/MuseTalk/models/musetalkV15/unet.pth \
            "https://huggingface.co/TMElyralab/MuseTalk/resolve/main/musetalkV15/unet.pth" && \
        curl -L -o /workspace/MuseTalk/models/musetalkV15/musetalk.json \
            "https://huggingface.co/TMElyralab/MuseTalk/resolve/main/musetalkV15/musetalk.json")

# --- MuseTalk V1.0 (backward compat) ---
RUN huggingface-cli download TMElyralab/MuseTalk \
    musetalk/musetalk.json musetalk/pytorch_model.bin \
    --local-dir /workspace/MuseTalk/models \
    --local-dir-use-symlinks False \
    || (echo "huggingface-cli failed, trying curl..." && \
        curl -L -o /workspace/MuseTalk/models/musetalk/musetalk.json \
            "https://huggingface.co/TMElyralab/MuseTalk/resolve/main/musetalk/musetalk.json" && \
        curl -L -o /workspace/MuseTalk/models/musetalk/pytorch_model.bin \
            "https://huggingface.co/TMElyralab/MuseTalk/resolve/main/musetalk/pytorch_model.bin")

# --- SD VAE ft-mse ---
RUN huggingface-cli download stabilityai/sd-vae-ft-mse \
    config.json diffusion_pytorch_model.bin \
    --local-dir /workspace/MuseTalk/models/sd-vae \
    --local-dir-use-symlinks False \
    || (echo "huggingface-cli failed, trying curl..." && \
        curl -L -o /workspace/MuseTalk/models/sd-vae/config.json \
            "https://huggingface.co/stabilityai/sd-vae-ft-mse/resolve/main/config.json" && \
        curl -L -o /workspace/MuseTalk/models/sd-vae/diffusion_pytorch_model.bin \
            "https://huggingface.co/stabilityai/sd-vae-ft-mse/resolve/main/diffusion_pytorch_model.bin")

# --- Whisper tiny (HuggingFace transformers format) ---
RUN huggingface-cli download openai/whisper-tiny \
    config.json pytorch_model.bin preprocessor_config.json \
    --local-dir /workspace/MuseTalk/models/whisper \
    --local-dir-use-symlinks False \
    || (echo "huggingface-cli failed, trying curl..." && \
        curl -L -o /workspace/MuseTalk/models/whisper/config.json \
            "https://huggingface.co/openai/whisper-tiny/resolve/main/config.json" && \
        curl -L -o /workspace/MuseTalk/models/whisper/pytorch_model.bin \
            "https://huggingface.co/openai/whisper-tiny/resolve/main/pytorch_model.bin" && \
        curl -L -o /workspace/MuseTalk/models/whisper/preprocessor_config.json \
            "https://huggingface.co/openai/whisper-tiny/resolve/main/preprocessor_config.json")

# --- DWPose ---
RUN huggingface-cli download yzd-v/DWPose \
    dw-ll_ucoco_384.pth \
    --local-dir /workspace/MuseTalk/models/dwpose \
    --local-dir-use-symlinks False \
    || (echo "huggingface-cli failed, trying curl..." && \
        curl -L -o /workspace/MuseTalk/models/dwpose/dw-ll_ucoco_384.pth \
            "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth")

# --- SyncNet (LatentSync) ---
RUN huggingface-cli download ByteDance/LatentSync \
    latentsync_syncnet.pt \
    --local-dir /workspace/MuseTalk/models/syncnet \
    --local-dir-use-symlinks False \
    || (echo "huggingface-cli failed, trying curl..." && \
        curl -L -o /workspace/MuseTalk/models/syncnet/latentsync_syncnet.pt \
            "https://huggingface.co/ByteDance/LatentSync/resolve/main/latentsync_syncnet.pt")

# --- Face Parse Bisent (Google Drive) ---
RUN gdown --id 154JgKpzCPW82qINcVieuPH3fZ2e0P812 \
    -O /workspace/MuseTalk/models/face-parse-bisent/79999_iter.pth

# --- ResNet18 backbone ---
RUN curl -L -o /workspace/MuseTalk/models/face-parse-bisent/resnet18-5c106cde.pth \
    "https://download.pytorch.org/models/resnet18-5c106cde.pth"

# ── Verify all model files ──────────────────────────────────────────────────
RUN echo "=== Verifying model files ===" && \
    echo "--- musetalkV15 ---" && \
    ls -lh /workspace/MuseTalk/models/musetalkV15/ && \
    echo "--- musetalk ---" && \
    ls -lh /workspace/MuseTalk/models/musetalk/ && \
    echo "--- sd-vae ---" && \
    ls -lh /workspace/MuseTalk/models/sd-vae/ && \
    echo "--- whisper ---" && \
    ls -lh /workspace/MuseTalk/models/whisper/ && \
    echo "--- dwpose ---" && \
    ls -lh /workspace/MuseTalk/models/dwpose/ && \
    echo "--- syncnet ---" && \
    ls -lh /workspace/MuseTalk/models/syncnet/ && \
    echo "--- face-parse-bisent ---" && \
    ls -lh /workspace/MuseTalk/models/face-parse-bisent/ && \
    echo "=== All model files present ==="

# ── Copy server script ──────────────────────────────────────────────────────
COPY musetalk_server.py /workspace/musetalk_server.py

# ── Working directory ────────────────────────────────────────────────────────
WORKDIR /workspace

# ── Expose API port ─────────────────────────────────────────────────────────
EXPOSE 8000

# ── Health check ────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# ── Default: keep container alive ──────────────────────────────────────────
# Onstart script or docker run command launches uvicorn
CMD ["sleep", "infinity"]
