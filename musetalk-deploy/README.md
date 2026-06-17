# MuseTalk Docker Deployment

A fully self-contained Docker image for running MuseTalk lip-sync API on **Vast.ai** GPU instances.

## What's Inside

| Component | Details |
|-----------|---------|
| **Base** | `pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime` |
| **MuseTalk** | TMElyralab/MuseTalk (V1.5 + V1.0) |
| **GPU** | CUDA 11.7+ (any NVIDIA GPU with 8GB+ VRAM) |
| **API** | FastAPI on port 8000 |
| **Models** | ~8GB baked into the image |
| **ffmpeg** | Static build |

## Model Weights Included

| Model | Source | Size |
|-------|--------|------|
| MuseTalk V1.5 (unet.pth) | HuggingFace TMElyralab | ~500MB |
| MuseTalk V1.0 | HuggingFace TMElyralab | ~500MB |
| SD VAE ft-mse | HuggingFace stabilityai | ~320MB |
| Whisper tiny | OpenAI / HuggingFace | ~73MB |
| DWPose | HuggingFace yzd-v | ~240MB |
| SyncNet | HuggingFace ByteDance | ~1.4GB |
| Face Parse Bisent | Google Drive | ~90MB |
| ResNet18 | PyTorch | ~40MB |

## Quick Start (Local Docker)

```bash
# Build the image
docker build -t ldonjibson/musetalk:latest .

# Run with GPU
docker run --gpus all -p 8000:8000 ldonjibson/musetalk:latest

# Test health
curl http://localhost:8000/health
```

## Vast.ai Deployment

### Option 1: Using Pre-built Template (Fastest)

1. Create a template at [cloud.vast.ai/templates](https://cloud.vast.ai/templates)
   - Image: `ldonjibson/musetalk:latest`
   - Disk: 80GB+
   - Onstart: use `vast_onstart.sh`

2. Launch an instance from the template

3. Test:
   ```bash
   curl http://<ip>:<port>/health
   ```

### Option 2: Build Template from Scratch

```bash
export VAST_API_KEY="your-key"
bash build_template.sh
```

### Option 3: Install on Running Instance

SSH into the instance and run:

```bash
bash build_template_local.sh --api-key YOUR_SECRET
```

## API Usage

### Generate a video

```bash
curl -X POST http://<ip>:<port>/generate \
    -F 'image=@avatar.jpg' \
    -F 'audio=@speech.wav'
```

Response:
```json
{
    "job_id": "abc123...",
    "status": "queued",
    "queue_pos": 1,
    "poll_url": "/status/abc123..."
}
```

### Poll status

```bash
curl http://<ip>:<port>/status/<job_id>
```

### Download result

```bash
curl http://<ip>:<port>/download/<job_id> -o output.mp4
```

### Batch processing

```bash
python musetalk_client.py \
    --host http://<ip>:<port> \
    --avatar avatar.jpg \
    --audio-dir ./audio_files \
    --output-dir ./videos \
    --api-key YOUR_SECRET
```

## File Structure

```
musetalk-deploy/
├── Dockerfile                    # Docker build file
├── README.md                     # This file
├── musetalk_server.py            # FastAPI server
├── musetalk_client.py            # Batch client
├── download_models.py            # Model download helper
├── vast_onstart.sh               # Vast.ai onstart script
├── build_template.sh             # Automated template builder
└── build_template_local.sh       # Manual instance installer
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | `""` (open) | Protect the API with a secret key |
| `PORT` | `8000` | Server port |
| `FFMPEG_PATH` | `/workspace/ffmpeg-static` | Path to ffmpeg binary |

## Troubleshooting

### Model download fails during Docker build

The Dockerfile uses `huggingface-cli` with `curl` fallback. If both fail:
1. Check network connectivity
2. Try setting `HF_ENDPOINT=https://hf-mirror.com` for mirror access
3. Build with `--no-cache` to retry failed layers

### Container exits immediately

Make sure you're running with:
```bash
docker run --gpus all ...
```

The `--gpus all` flag requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html).

### Server starts but /health returns 500

Check that model files exist:
```bash
docker exec -it <container> ls -la /workspace/MuseTalk/models/
```

### Video generation fails

Check server logs:
```bash
docker logs <container>
```

Common issues:
- Missing model files (rebuild with `--no-cache`)
- CUDA out of memory (use smaller batch size or `--use_float16`)
- ffmpeg not found (check `FFMPEG_PATH`)

## Architecture

```
┌─────────────────────────────────────┐
│           Docker Container          │
│                                     │
│  ┌──────────┐    ┌──────────────┐  │
│  │ FastAPI  │───▶│ MuseTalk     │  │
│  │ :8000    │    │ Inference    │  │
│  └──────────┘    └──────────────┘  │
│       │               │            │
│       ▼               ▼            │
│  ┌──────────┐    ┌──────────────┐  │
│  │ Jobs     │    │ Models (~8GB)│  │
│  │ Queue    │    │              │  │
│  └──────────┘    └──────────────┘  │
│                                     │
│  ┌──────────────────────────────┐  │
│  │      NVIDIA GPU (CUDA)       │  │
│  └──────────────────────────────┘  │
└─────────────────────────────────────┘
```

## Credits

- [MuseTalk](https://github.com/TMElyralab/MuseTalk) by TMElyralab (Tencent Music Entertainment)
- Model weights from various open-source projects
