# =============================================================================
# MuseTalk Ready-to-Run Docker Image
# =============================================================================
# Build: docker build -t ldonjibson/musetalk:latest .
# Push:  docker push ldonjibson/musetalk:latest
#
# This image has everything pre-installed:
#   - PyTorch + CUDA
#   - MuseTalk + all Python deps
#   - Model weights (~8GB)
#   - FastAPI server
#
# On vast.ai, instances boot in ~30-60s (no downloads needed)
# =============================================================================

FROM pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime

LABEL maintainer="ldonjibson"
LABEL description="MuseTalk lip-sync API server — ready to run"

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV FFMPEG_PATH=/workspace/ffmpeg-static
ENV PATH=/workspace/ffmpeg-static:$PATH

# ── System deps ──────────────────────────────────────────────────────────────
RUN apt-get update -qq && \
    apt-get install -y -qq \
        git wget curl unzip \
        libgl1-mesa-glx libglib2.0-0 \
        libsm6 libxext6 libxrender-dev \
    && rm -rf /var/lib/apt/lists/*

# ── ffmpeg static ────────────────────────────────────────────────────────────
RUN mkdir -p /workspace/ffmpeg-static && \
    wget -q "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" \
        -O /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    FFMPEG_DIR=$(find /tmp -maxdepth 1 -name "ffmpeg-*-amd64-static" -type d | head -1) && \
    cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" /workspace/ffmpeg-static/ && \
    chmod +x /workspace/ffmpeg-static/ffmpeg /workspace/ffmpeg-static/ffprobe && \
    rm -rf /tmp/ffmpeg.tar.xz "$FFMPEG_DIR"

# ── Clone MuseTalk ───────────────────────────────────────────────────────────
RUN git clone https://github.com/TMElyralab/MuseTalk.git /workspace/MuseTalk -q

# ── Python deps ──────────────────────────────────────────────────────────────
RUN pip install -q torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 \
        --index-url https://download.pytorch.org/whl/cu118 && \
    pip install -q --no-cache-dir -U openmim && \
    mim install -q mmengine && \
    mim install -q "mmcv==2.0.1" && \
    mim install -q "mmdet==3.1.0" && \
    mim install -q "mmpose==1.1.0" && \
    pip install -q -r /workspace/MuseTalk/requirements.txt && \
    pip install -q fastapi uvicorn[standard] python-multipart

# ── Download model weights ───────────────────────────────────────────────────
# These are ~8GB total — baked into the image so instances boot instantly
# HuggingFace blocks wget without a User-Agent, so we add one.
ENV HF_BASE="https://huggingface.co/TMElyralab/MuseTalk/resolve/main"
ENV WGET_OPTS="--no-check-certificate --show-progress"
ENV UA="Mozilla/5.0 (Docker; x86_64) wget/1.21"

RUN mkdir -p \
    /workspace/MuseTalk/models/musetalkV15 \
    /workspace/MuseTalk/models/dwpose \
    /workspace/MuseTalk/models/face-parse-bisent \
    /workspace/MuseTalk/models/sd-vae \
    /workspace/MuseTalk/models/whisper

# MuseTalk V1.5
RUN wget $WGET_OPTS --header="User-Agent: $UA" "$HF_BASE/musetalkV15/unet.pth" \
        -O /workspace/MuseTalk/models/musetalkV15/unet.pth
RUN wget $WGET_OPTS --header="User-Agent: $UA" "$HF_BASE/musetalkV15/musetalk.json" \
        -O /workspace/MuseTalk/models/musetalkV15/musetalk.json

# DWPose
RUN wget $WGET_OPTS --header="User-Agent: $UA" "$HF_BASE/dwpose/dw-ll_ucoco_384.pth" \
        -O /workspace/MuseTalk/models/dwpose/dw-ll_ucoco_384.pth
RUN wget $WGET_OPTS --header="User-Agent: $UA" "$HF_BASE/dwpose/yolox_l.pth" \
        -O /workspace/MuseTalk/models/dwpose/yolox_l.pth

# Face parse
RUN wget $WGET_OPTS --header="User-Agent: $UA" "$HF_BASE/face-parse-bisent/79999_iter.pth" \
        -O /workspace/MuseTalk/models/face-parse-bisent/79999_iter.pth
RUN wget $WGET_OPTS --header="User-Agent: $UA" "$HF_BASE/face-parse-bisent/resnet18-5c106cde.pth" \
        -O /workspace/MuseTalk/models/face-parse-bisent/resnet18-5c106cde.pth

# Whisper (from OpenAI CDN)
RUN wget $WGET_OPTS --header="User-Agent: $UA" \
        "https://openaipublic.azureedge.net/main/whisper/models/65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9/tiny.pt" \
        -O /workspace/MuseTalk/models/whisper/tiny.pt

# SD VAE
RUN wget $WGET_OPTS --header="User-Agent: $UA" \
        "https://huggingface.co/stabilityai/sd-vae-ft-mse/resolve/main/diffusion_pytorch_model.bin" \
        -O /workspace/MuseTalk/models/sd-vae/diffusion_pytorch_model.bin
RUN wget $WGET_OPTS --header="User-Agent: $UA" \
        "https://huggingface.co/stabilityai/sd-vae-ft-mse/resolve/main/config.json" \
        -O /workspace/MuseTalk/models/sd-vae/config.json

# ── Copy server script ──────────────────────────────────────────────────────
COPY musetalk_server.py /workspace/musetalk_server.py

# ── Working directory ────────────────────────────────────────────────────────
WORKDIR /workspace

# ── Expose API port ─────────────────────────────────────────────────────────
EXPOSE 8000

# ── Health check ────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# ── Default: start the API server ───────────────────────────────────────────
CMD ["python3", "-m", "uvicorn", "musetalk_server:app", "--host", "0.0.0.0", "--port", "8000", "--log-level", "info"]
