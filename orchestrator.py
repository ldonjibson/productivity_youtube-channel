"""
MuseTalk Orchestrator
=====================
A lightweight FastAPI service you run LOCALLY (or on any cheap always-on server
like a $5 VPS / Railway / Render free tier).

n8n calls this service. The service handles:
  1. Finding the cheapest valid GPU offer on vast.ai
  2. Provisioning an instance with /root/onstart.sh pre-baked
  3. Polling until the instance is running and the MuseTalk server is live
  4. Submitting the video generation job
  5. Polling until the video is ready
  6. Downloading the video locally
  7. Uploading to YouTube via the YouTube Data API v3
  8. Destroying the vast.ai instance
  9. Returning the YouTube URL to n8n

ENV VARS REQUIRED (put in .env or set in your shell):
  VAST_API_KEY          — from https://cloud.vast.ai/manage-keys/
  YOUTUBE_CLIENT_ID     — from Google Cloud Console
  YOUTUBE_CLIENT_SECRET
  YOUTUBE_REFRESH_TOKEN — run get_youtube_token.py once to get this
  MUSETALK_API_KEY      — any secret string you choose; baked into the instance
  ORCHESTRATOR_API_KEY  — protects this orchestrator's own endpoint

Run:
  pip install fastapi uvicorn python-dotenv requests google-auth google-auth-oauthlib google-api-python-client
  uvicorn orchestrator:app --host 0.0.0.0 --port 7000
"""

import os
import time
import uuid
import shutil
import tempfile
import threading
import traceback
from pathlib import Path
from typing import Optional

import requests
from fastapi import FastAPI, UploadFile, File, Header, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse
from dotenv import load_dotenv

load_dotenv()

# ── Config ────────────────────────────────────────────────────────────────────
VAST_API_KEY         = os.environ["VAST_API_KEY"]
MUSETALK_API_KEY     = os.environ.get("MUSETALK_API_KEY", "musetalk-secret")
ORCHESTRATOR_API_KEY = os.environ.get("ORCHESTRATOR_API_KEY", "orchestrator-secret")
VAST_TEMPLATE_ID     = os.environ.get("VAST_TEMPLATE_ID", "")   # optional: reuse pre-built template for faster startup
YOUTUBE_CLIENT_ID    = os.environ.get("YOUTUBE_CLIENT_ID", "")
YOUTUBE_CLIENT_SECRET= os.environ.get("YOUTUBE_CLIENT_SECRET", "")
YOUTUBE_REFRESH_TOKEN= os.environ.get("YOUTUBE_REFRESH_TOKEN", "")

VAST_BASE   = "https://console.vast.ai/api/v0"
VAST_SEARCH = "https://console.vast.ai/api/v0/bundles/"
WORK_DIR    = Path(tempfile.gettempdir()) / "musetalk_jobs"
WORK_DIR.mkdir(exist_ok=True)

# ── GitHub raw URL for your setup scripts (update to your fork/repo) ──────────
# The instance pulls these on startup via /root/onstart.sh
GITHUB_RAW = "https://raw.githubusercontent.com/ldonjibson/productivity_youtube-channel/main"
GITHUB_REPO = "https://github.com/ldonjibson/productivity_youtube-channel.git"

# ── Job store ─────────────────────────────────────────────────────────────────
jobs: dict[str, dict] = {}

app = FastAPI(title="MuseTalk Orchestrator", version="1.0.0")


# =============================================================================
# Auth
# =============================================================================
def auth(x_api_key: Optional[str] = None):
    if x_api_key != ORCHESTRATOR_API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorised")


# =============================================================================
# Endpoints
# =============================================================================
@app.get("/health")
def health():
    return {"status": "ok", "jobs": len(jobs)}


@app.post("/generate")
async def generate(
    background_tasks: BackgroundTasks,
    audio: UploadFile = File(...),
    image: UploadFile = File(...),
    title: str = "AI Productivity Video",
    description: str = "Generated with MuseTalk",
    tags: str = "productivity,AI",
    x_api_key: Optional[str] = Header(default=None),
):
    auth(x_api_key)

    job_id  = str(uuid.uuid4())
    job_dir = WORK_DIR / job_id
    job_dir.mkdir()

    audio_path = job_dir / f"audio{Path(audio.filename).suffix}"
    image_path = job_dir / f"avatar{Path(image.filename).suffix}"

    with open(audio_path, "wb") as f:
        shutil.copyfileobj(audio.file, f)
    with open(image_path, "wb") as f:
        shutil.copyfileobj(image.file, f)

    jobs[job_id] = {
        "id":           job_id,
        "status":       "queued",
        "step":         "waiting",
        "instance_id":  None,
        "youtube_url":  None,
        "error":        None,
        "created_at":   time.time(),
        "audio":        str(audio_path),
        "image":        str(image_path),
        "yt_title":     title,
        "yt_desc":      description,
        "yt_tags":      tags,
    }

    background_tasks.add_task(run_pipeline, job_id)

    return JSONResponse(status_code=202, content={
        "job_id":    job_id,
        "status":    "queued",
        "poll_url":  f"/status/{job_id}",
    })


@app.get("/status/{job_id}")
def status(job_id: str, x_api_key: Optional[str] = Header(default=None)):
    auth(x_api_key)
    if job_id not in jobs:
        raise HTTPException(404, "Job not found")
    return jobs[job_id]


@app.get("/jobs")
def list_jobs(x_api_key: Optional[str] = Header(default=None)):
    auth(x_api_key)
    return [{"id": j["id"], "status": j["status"], "step": j["step"],
             "youtube_url": j["youtube_url"]} for j in jobs.values()]


# =============================================================================
# Pipeline
# =============================================================================
def run_pipeline(job_id: str):
    job = jobs[job_id]
    instance_id = None
    try:
        job["status"] = "running"

        # ── Step 1: Find cheapest GPU offer ───────────────────────────────────
        job["step"] = "searching_gpu"
        offer_id, host_ip = find_best_offer()
        print(f"[{job_id[:8]}] Found offer {offer_id}")
        if VAST_TEMPLATE_ID:
            print(f"[{job_id[:8]}] Using template {VAST_TEMPLATE_ID} (fast startup)")

        # ── Step 2: Provision instance ────────────────────────────────────────
        job["step"] = "provisioning"
        instance_id = create_instance(offer_id, job_id)
        job["instance_id"] = instance_id
        print(f"[{job_id[:8]}] Instance {instance_id} created")

        # ── Step 3: Wait for instance + MuseTalk server to be ready ───────────
        job["step"] = "waiting_for_server"
        api_url = wait_for_musetalk(instance_id)
        print(f"[{job_id[:8]}] MuseTalk server live at {api_url}")

        # ── Step 4: Submit generation job ─────────────────────────────────────
        job["step"] = "generating_video"
        musetalk_job_id = submit_musetalk_job(api_url, job["image"], job["audio"])
        print(f"[{job_id[:8]}] MuseTalk job {musetalk_job_id[:8]} submitted")

        # ── Step 5: Poll until done ───────────────────────────────────────────
        video_path = poll_and_download(api_url, musetalk_job_id, job_id)
        print(f"[{job_id[:8]}] Video downloaded to {video_path}")

        # ── Step 6: Upload to YouTube ─────────────────────────────────────────
        job["step"] = "uploading_youtube"
        youtube_url = upload_to_youtube(
            video_path,
            title=job["yt_title"],
            description=job["yt_desc"],
            tags=job["yt_tags"].split(","),
        )
        job["youtube_url"] = youtube_url
        print(f"[{job_id[:8]}] YouTube: {youtube_url}")

        job["status"] = "done"
        job["step"]   = "complete"

    except Exception as e:
        job["status"] = "failed"
        job["error"]  = f"{type(e).__name__}: {e}\n{traceback.format_exc()}"
        print(f"[{job_id[:8]}] FAILED: {e}")

    finally:
        # ── Always destroy the instance ───────────────────────────────────────
        if instance_id:
            try:
                destroy_instance(instance_id)
                print(f"[{job_id[:8]}] Instance {instance_id} destroyed")
            except Exception as e:
                print(f"[{job_id[:8]}] WARNING: Could not destroy instance: {e}")

        # Clean up local files
        job_dir = WORK_DIR / job_id
        if job_dir.exists():
            shutil.rmtree(job_dir, ignore_errors=True)


# =============================================================================
# vast.ai helpers
# =============================================================================
def vast_headers():
    return {"Authorization": f"Bearer {VAST_API_KEY}"}

def find_best_offer() -> tuple[int, str]:
    """Find best available GPU for MuseTalk.
    IMPORTANT vast.ai REST API quirks:
      - type must be "ondemand" (not "on-demand")
      - gpu_ram is in MB not GB
      - order must be array of [field, direction] pairs
      - do NOT filter by gpu_name — use priority scoring instead
        since exact name strings vary (e.g. "Tesla V100" not "V100")
    """
    payload = {
        "limit":             20,
        "type":              "ondemand",
        "order":             [["dph_total", "asc"]],
        "rentable":          {"eq": True},
        "rented":            {"eq": False},
        "direct_port_count": {"gte": 1},
        "disk_space":        {"gte": 120},   # GB — headroom for models + outputs
        "gpu_ram":           {"gte": 25000}, # MB — 25GB+ rules out weak cards

    }
    resp = requests.post(
        VAST_SEARCH,
        headers={**vast_headers(), "Content-Type": "application/json"},
        json=payload,
        timeout=30,
    )
 
    if resp.status_code != 200:
        raise RuntimeError(f"vast.ai search failed {resp.status_code}: {resp.text}")
 
    offers = resp.json().get("offers", [])
 
    # Fallback: retry with 16GB minimum if nothing 25GB+ found
    if not offers:
        payload["gpu_ram"] = {"gte": 16000}
        payload["disk_space"] = {"gte": 50}
        resp = requests.post(
            VAST_SEARCH,
            headers={**vast_headers(), "Content-Type": "application/json"},
            json=payload,
            timeout=30,
        )
        offers = resp.json().get("offers", [])
 
    if not offers:
        raise RuntimeError("No suitable GPU offers found on vast.ai")

    # Filter out low-CPU machines (need 16+ cores for MuseTalk preprocessing)
    offers = [o for o in offers if o.get("cpu_cores", 0) >= 16]
    if not offers:
        raise RuntimeError("No suitable GPU offers with enough CPU found")
 
    # Score offers by performance tier first, then price within tier.
    # Tiers based on actual vast.ai GPU names observed:
    #   Tier 0 = best (A100, H100, RTX 5090, L40)
    #   Tier 1 = great (Q RTX 8000, RTX A6000, A40, RTX 5000Ada)
    #   Tier 2 = good  (Tesla V100 32GB — proven MuseTalk benchmark GPU)
    #   Tier 3 = ok    (RTX 4080S, RTX 3090, RTX PRO 4500)
    #   Tier 4 = fallback (anything else with enough VRAM)
    #
    # Within each tier, pick cheapest (dph_total).
    # This ensures we never pick a slow cheap GPU over a fast one at similar price.
 
    def tier(offer):
        gpu  = offer.get("gpu_name", "")
        vram = offer.get("gpu_ram", 0)   # MB
        price = offer.get("dph_total", 99)
 
        if any(x in gpu for x in ["A100", "H100", "RTX 5090", "L40 "]):
            return (0, price)
        if any(x in gpu for x in ["Q RTX 8000", "RTX A6000", "A40", "RTX 5000Ada", "L40S"]):
            return (1, price)
        if "Tesla V100" in gpu and vram >= 32000:
            return (2, price)
        if any(x in gpu for x in ["RTX 4080", "RTX 3090", "RTX PRO 4500", "RTX 4090"]):
            return (3, price)
        return (4, price)
 
    offers.sort(key=tier)
    best = offers[0]
    print(f"  Selected: {best['gpu_name']} | {best['gpu_ram']}MB VRAM "
          f"| ${best['dph_total']:.4f}/hr | id:{best['id']}")
    return best["id"], best.get("public_ipaddr", "")


def create_instance(offer_id: int, job_id: str) -> int:
    """Create a vast.ai instance.

    If VAST_TEMPLATE_ID is set, uses the pre-built template (instant startup).
    Otherwise, runs the full onstart.sh install (~10 min).
    """

    # ── Full install onstart (fallback when no template) ──────────────────────
    full_onstart = f"""#!/bin/bash
set -e
# Pull setup scripts from GitHub and run them
apt-get update -qq
apt-get install -y -qq wget git curl > /dev/null 2>&1

wget -q "{GITHUB_RAW}/musetalk_server.py"   -O /workspace/musetalk_server.py
wget -q "{GITHUB_RAW}/musetalk_deploy.sh"  -O /workspace/musetalk_deploy.sh
chmod +x /workspace/musetalk_deploy.sh

bash /workspace/musetalk_deploy.sh --api-key "{MUSETALK_API_KEY}"
"""

    # ── Minimal onstart (template has everything pre-installed) ────────────────
    template_onstart = f"""#!/bin/bash
export API_KEY="{MUSETALK_API_KEY}"
export FFMPEG_PATH="/workspace/ffmpeg-static"
export PYTHONPATH="/workspace/MuseTalk:$PYTHONPATH"
cd /workspace
echo "Starting MuseTalk server..."
nohup python3 -m uvicorn musetalk_server:app --host 0.0.0.0 --port 8000 --workers 1 > /workspace/server.log 2>&1 &
echo "Server PID: $!"
# Wait for server to be ready (up to 5 minutes)
for i in $(seq 1 30); do
  sleep 10
  if curl -s http://localhost:8000/health > /dev/null 2>&1; then
    echo "Server healthy after $((i*10))s"
    exit 0
  fi
  echo "Waiting for server... ($((i*10))s)"
done
echo "Server did not start in time. Check server.log"
exit 0
"""

    onstart = template_onstart if VAST_TEMPLATE_ID else full_onstart

    payload = {
        "client_id":    "me",
        "disk":           60,
        "onstart":        onstart,          # vast.ai runs this at container start
        "env":            {
                              "MUSETALK_API_KEY": MUSETALK_API_KEY,
                              "API_KEY":          MUSETALK_API_KEY,
                            },
        "label":          f"musetalk-{job_id[:8]}",
        "runtype":        "ssh",
    }
    if VAST_TEMPLATE_ID:
        payload["template_hash_id"] = VAST_TEMPLATE_ID
        # Template provides the Docker image — don't override it
    else:
        payload["image"] = "pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime"

    resp = requests.put(
        f"{VAST_BASE}/asks/{offer_id}/",
        headers=vast_headers(),
        json=payload,
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()

    if not data.get("success"):
        raise RuntimeError(f"vast.ai create instance failed: {data}")

    return data["new_contract"]


def get_instance_info(instance_id: int) -> dict:
    """Fetch instance details. Tries v1 endpoint first, falls back to v0."""
    # v1 endpoint (preferred — not deprecated)
    resp = requests.get(
        f"https://console.vast.ai/api/v1/instances/{instance_id}",
        headers=vast_headers(),
        timeout=15,
    )
    if resp.ok:
        data = resp.json()
        # v1 returns the instance dict directly or under "instance"
        if isinstance(data, dict) and "id" in data:
            return data
        if isinstance(data, dict) and "instance" in data:
            return data["instance"]
        if isinstance(data, list) and data:
            return data[0]

    # v0 fallback — note: v0 returns instances as a DICT, not a list
    resp2 = requests.get(
        f"{VAST_BASE}/instances/{instance_id}/",
        headers=vast_headers(),
        timeout=15,
    )
    resp2.raise_for_status()
    instances = resp2.json().get("instances", {})
    if isinstance(instances, list):
        return instances[0] if instances else {}
    if isinstance(instances, dict) and instances:
        return instances
    raise RuntimeError(f"Instance {instance_id} not found (empty response from v0 and v1)")


def destroy_instance(instance_id: int):
    requests.delete(
        f"{VAST_BASE}/instances/{instance_id}/",
        headers=vast_headers(),
        timeout=15,
    )


def wait_for_musetalk(instance_id: int, timeout: int = 900) -> str:
    """
    Poll vast.ai until the instance is running, then poll the MuseTalk
    /health endpoint until it responds. Returns the base API URL.
    """
    deadline = time.time() + timeout
    api_url  = None

    print(f"  Waiting for instance {instance_id} to start...")
    poll_count = 0
    while time.time() < deadline:
        try:
            info = get_instance_info(instance_id)
        except Exception as e:
            poll_count += 1
            if poll_count <= 3 or poll_count % 5 == 0:
                print(f"  [warn] Could not fetch instance info (attempt {poll_count}): {e}")
            time.sleep(15)
            continue
        # v0 API: actual_status is often null; cur_state is more reliable
        state = info.get("actual_status") or info.get("cur_state") or info.get("status", "")
        if poll_count % 4 == 0:
            print(f"  [poll] state={state}")
        poll_count += 1

        if state == "running":
            ip   = info.get("public_ipaddr") or info.get("ssh_host")
            # vast.ai maps container port 8000 to a random host port
            ports = info.get("ports", {})
            host_port = None
            if isinstance(ports, dict):
                for container_port, mappings in ports.items():
                    if "8000" in str(container_port):
                        host_port = mappings[0].get("HostPort") if isinstance(mappings, list) and mappings else None
                        break

            if ip and host_port:
                api_url = f"http://{ip}:{host_port}"
                break

            # State is "running" but port 8000 not mapped yet — image still pulling
            if poll_count % 4 == 0:
                print(f"  [poll] running but port 8000 not mapped yet (image pulling?)...")

        elif state in ("failed", "dead", "stopped"):
            raise RuntimeError(f"Instance entered state: {state}")

        time.sleep(15)

    if not api_url:
        raise RuntimeError("Timed out waiting for instance to start")

    # Now wait for the MuseTalk server itself (setup takes ~5-10 min)
    print(f"  Instance running. Waiting for MuseTalk server at {api_url}...")
    while time.time() < deadline:
        try:
            r = requests.get(f"{api_url}/health", timeout=5)
            if r.status_code == 200:
                print(f"  MuseTalk server ready!")
                return api_url
        except Exception:
            pass
        time.sleep(20)

    raise RuntimeError("Timed out waiting for MuseTalk server to be ready")


# =============================================================================
# MuseTalk helpers
# =============================================================================
def musetalk_headers():
    return {"x-api-key": MUSETALK_API_KEY}


def submit_musetalk_job(api_url: str, image_path: str, audio_path: str) -> str:
    with open(image_path, "rb") as img, open(audio_path, "rb") as aud:
        resp = requests.post(
            f"{api_url}/generate",
            headers=musetalk_headers(),
            files={
                "image": (Path(image_path).name, img),
                "audio": (Path(audio_path).name, aud),
            },
            timeout=60,
        )
    resp.raise_for_status()
    return resp.json()["job_id"]


def poll_and_download(api_url: str, musetalk_job_id: str, local_job_id: str,
                      timeout: int = 600) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = requests.get(
            f"{api_url}/status/{musetalk_job_id}",
            headers=musetalk_headers(),
            timeout=10,
        )
        r.raise_for_status()
        data = r.json()
        status = data["status"]

        if status == "done":
            # Download the video
            out_path = str(WORK_DIR / local_job_id / "output.mp4")
            vid = requests.get(
                f"{api_url}/download/{musetalk_job_id}",
                headers=musetalk_headers(),
                stream=True,
                timeout=120,
            )
            vid.raise_for_status()
            with open(out_path, "wb") as f:
                for chunk in vid.iter_content(8192):
                    f.write(chunk)
            return out_path

        elif status == "failed":
            raise RuntimeError(f"MuseTalk job failed: {data.get('error')}")

        time.sleep(10)

    raise RuntimeError("Timed out waiting for video generation")


# =============================================================================
# YouTube upload
# =============================================================================
def get_youtube_access_token() -> str:
    """Exchange refresh token for a short-lived access token."""
    resp = requests.post("https://oauth2.googleapis.com/token", data={
        "client_id":     YOUTUBE_CLIENT_ID,
        "client_secret": YOUTUBE_CLIENT_SECRET,
        "refresh_token": YOUTUBE_REFRESH_TOKEN,
        "grant_type":    "refresh_token",
    })
    resp.raise_for_status()
    return resp.json()["access_token"]


def upload_to_youtube(video_path: str, title: str, description: str,
                      tags: list[str]) -> str:
    access_token = get_youtube_access_token()

    metadata = {
        "snippet": {
            "title":       title,
            "description": description,
            "tags":        tags,
            "categoryId":  "27",   # 27 = Education
        },
        "status": {
            "privacyStatus": "public",   # or "private" / "unlisted"
        },
    }

    # Resumable upload
    init = requests.post(
        "https://www.googleapis.com/upload/youtube/v3/videos"
        "?uploadType=resumable&part=snippet,status",
        headers={
            "Authorization":  f"Bearer {access_token}",
            "Content-Type":   "application/json",
            "X-Upload-Content-Type": "video/mp4",
        },
        json=metadata,
        timeout=30,
    )
    init.raise_for_status()
    upload_url = init.headers["Location"]

    # Upload the file
    with open(video_path, "rb") as f:
        video_data = f.read()

    upload = requests.put(
        upload_url,
        headers={
            "Authorization":  f"Bearer {access_token}",
            "Content-Type":   "video/mp4",
            "Content-Length": str(len(video_data)),
        },
        data=video_data,
        timeout=300,
    )
    upload.raise_for_status()
    video_id = upload.json()["id"]
    return f"https://www.youtube.com/watch?v={video_id}"


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("orchestrator:app", host="0.0.0.0", port=7000, reload=False)
