# MuseTalk → YouTube Full Setup Guide

## Architecture Overview

```
n8n webhook
    │
    ▼
orchestrator.py  (always-on, cheap VPS or localhost)
    │
    ├─► vast.ai API  →  spin up GPU instance
    │                    └─► onstart.sh installs MuseTalk + starts server
    │
    ├─► MuseTalk API  →  generate video
    │
    ├─► YouTube API   →  upload video
    │
    └─► vast.ai API  →  destroy instance
```

Total cost per video: ~$0.05–0.20 (GPU time only, ~5–15 min)

---

## Step 1 — Get your API keys

### vast.ai
1. Go to https://cloud.vast.ai/manage-keys/
2. Create a new API key → copy it

### YouTube (OAuth2 refresh token)
1. Go to https://console.cloud.google.com
2. Create a project → enable **YouTube Data API v3**
3. Create OAuth 2.0 credentials (Desktop App type)
4. Download the `client_secret.json`
5. Run `python get_youtube_token.py` (see below) to get your refresh token

### get_youtube_token.py  (run once locally)
```python
from google_auth_oauthlib.flow import InstalledAppFlow

flow = InstalledAppFlow.from_client_secrets_file(
    "client_secret.json",
    scopes=["https://www.googleapis.com/auth/youtube.upload"]
)
creds = flow.run_local_server(port=0)
print("REFRESH TOKEN:", creds.refresh_token)
print("CLIENT ID:",     creds.client_id)
print("CLIENT SECRET:", creds.client_secret)
```

---

## Step 2 — Host your scripts on GitHub

1. Fork or create a repo
2. Push `musetalk_server.py` and `musetalk_deploy.sh` to it
3. Update `GITHUB_RAW` in `orchestrator.py` to point to your raw repo URL:
   ```python
   GITHUB_RAW = "https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main"
   ```

---

## Step 3 — Run the orchestrator

### Option A: Local machine (simplest)
```bash
pip install fastapi uvicorn python-dotenv requests google-auth google-auth-oauthlib google-api-python-client
```

Create `.env`:
```
VAST_API_KEY=your_vast_key
MUSETALK_API_KEY=any_secret_string
ORCHESTRATOR_API_KEY=another_secret_string
YOUTUBE_CLIENT_ID=your_client_id
YOUTUBE_CLIENT_SECRET=your_client_secret
YOUTUBE_REFRESH_TOKEN=your_refresh_token
```

Run:
```bash
uvicorn orchestrator:app --host 0.0.0.0 --port 7000
```

Use ngrok to expose it if running locally:
```bash
ngrok http 7000
# → https://abc123.ngrok.io  ← use this as ORCHESTRATOR_URL in n8n
```

### Option B: Always-on VPS (Railway / Render / $5 DigitalOcean)
Deploy orchestrator.py as a web service. Set env vars in the platform dashboard.

---

## Step 4 — Import n8n workflow

1. Open n8n → Workflows → Import from file
2. Select `n8n_musetalk_workflow.json`
3. Set these n8n environment variables (Settings → Variables):
   - `ORCHESTRATOR_URL` = `https://your-orchestrator-url`
   - `ORCHESTRATOR_API_KEY` = same value as in .env
4. Activate the workflow

---

## Step 5 — Trigger it

### Via curl (test):
```bash
curl -X POST https://your-n8n.com/webhook/generate-video \
  -F "image=@avatar.jpg" \
  -F "audio=@script_01.wav" \
  -F "title=5 Productivity Hacks That Changed My Life" \
  -F "description=In this video..." \
  -F "tags=productivity,focus,AI"
```

### For 30 videos (batch trigger script):
```bash
#!/bin/bash
WEBHOOK="https://your-n8n.com/webhook/generate-video"

for i in $(seq -w 1 30); do
  echo "Submitting video $i..."
  curl -s -X POST "$WEBHOOK" \
    -F "image=@avatar.jpg" \
    -F "audio=@audio_${i}.wav" \
    -F "title=Productivity Video ${i}" \
    -F "description=AI generated productivity content" \
    -F "tags=productivity,AI" \
    &   # ← runs in background, all 30 submit simultaneously
done
wait
echo "All 30 submitted!"
```

---

## Timeline per video

| Phase | Time |
|---|---|
| Find GPU offer | ~5 sec |
| Provision instance | ~2 min |
| Install MuseTalk + models | ~8-12 min |
| Generate video (3 min clip) | ~3-5 min |
| Upload to YouTube | ~1-2 min |
| Destroy instance | ~5 sec |
| **Total** | **~15-20 min** |

For 30 videos running in parallel, wall-clock time ≈ same as 1 video (~20 min),
each on its own instance. Total cost: ~$1.50–$3.

---

## Reducing setup time (optional optimisation)

The 8-12 min install phase can be eliminated by building a **custom Docker image**
with MuseTalk pre-installed and pushing it to Docker Hub:

```dockerfile
FROM pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
RUN git clone https://github.com/TMElyralab/MuseTalk /workspace/MuseTalk
# ... install deps and download models ...
```

Then in orchestrator.py change:
```python
"image": "your_dockerhub_user/musetalk:latest"
```

This cuts per-video time to ~5-8 min total.
