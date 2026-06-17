"""
MuseTalk API Server
===================
A FastAPI endpoint that wraps MuseTalk for lip-sync video generation.

Endpoints:
  POST /generate          — submit a job (image + audio file upload)
  GET  /status/{job_id}   — poll job status
  GET  /download/{job_id} — download the finished .mp4
  GET  /health            — liveness check
  GET  /jobs              — list all jobs

Usage:
  uvicorn musetalk_server:app --host 0.0.0.0 --port 8000
"""

import os
import uuid
import time
import shutil
import subprocess
import threading
import queue
from pathlib import Path
from enum import Enum
from typing import Optional

import yaml
from fastapi import FastAPI, File, UploadFile, HTTPException, BackgroundTasks
from fastapi.responses import FileResponse, JSONResponse
import uvicorn

# ── Config ────────────────────────────────────────────────────────────────────
MUSETALK_DIR  = Path("/workspace/MuseTalk")
JOBS_DIR      = Path("/workspace/jobs")
MODELS_DIR    = MUSETALK_DIR / "models"
FFMPEG_PATH   = "/workspace/ffmpeg-static"
API_KEY       = os.environ.get("API_KEY", "")   # optional: set API_KEY env var to protect endpoint
MAX_WORKERS   = 1                                 # 1 GPU = 1 job at a time

JOBS_DIR.mkdir(parents=True, exist_ok=True)

# ── Job tracking ──────────────────────────────────────────────────────────────
class JobStatus(str, Enum):
    QUEUED     = "queued"
    PROCESSING = "processing"
    DONE       = "done"
    FAILED     = "failed"

jobs: dict[str, dict] = {}   # in-memory; fine for single-instance use
job_queue: queue.Queue = queue.Queue()

# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="MuseTalk API",
    description="Self-hosted lip-sync video generation endpoint",
    version="1.0.0"
)

# ── Auth helper ───────────────────────────────────────────────────────────────
def check_auth(x_api_key: Optional[str] = None):
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")

# ── Health ────────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    import torch
    # Check key model files
    models_ok = all(
        (MUSETALK_DIR / f).exists()
        for f in [
            "models/musetalkV15/unet.pth",
            "models/musetalkV15/musetalk.json",
            "models/sd-vae/config.json",
            "models/dwpose/dw-ll_ucoco_384.pth",
        ]
    )
    return {
        "status": "ok",
        "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none",
        "vram_gb": round(torch.cuda.get_device_properties(0).total_memory / 1e9, 1)
                   if torch.cuda.is_available() else 0,
        "queue_depth": job_queue.qsize(),
        "jobs_total": len(jobs),
        "models_loaded": models_ok,
    }

# ── Submit job ────────────────────────────────────────────────────────────────
@app.post("/generate")
async def generate(
    audio: UploadFile = File(..., description="Audio file (.wav or .mp3)"),
    image: UploadFile = File(..., description="Avatar image (.jpg or .png)"),
    x_api_key: Optional[str] = None,
    fps: int = 25,
    use_float16: bool = True,
):
    check_auth(x_api_key)

    job_id  = str(uuid.uuid4())
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True)

    # Save uploads
    audio_ext = Path(audio.filename).suffix or ".wav"
    image_ext = Path(image.filename).suffix or ".jpg"
    audio_path = job_dir / f"audio{audio_ext}"
    image_path = job_dir / f"avatar{image_ext}"

    with open(audio_path, "wb") as f:
        shutil.copyfileobj(audio.file, f)
    with open(image_path, "wb") as f:
        shutil.copyfileobj(image.file, f)

    jobs[job_id] = {
        "id":         job_id,
        "status":     JobStatus.QUEUED,
        "created_at": time.time(),
        "started_at": None,
        "done_at":    None,
        "audio":      str(audio_path),
        "image":      str(image_path),
        "output":     str(job_dir / "output.mp4"),
        "fps":        fps,
        "use_float16": use_float16,
        "error":      None,
        "queue_pos":  job_queue.qsize() + 1,
    }

    job_queue.put(job_id)

    return JSONResponse(status_code=202, content={
        "job_id":    job_id,
        "status":    JobStatus.QUEUED,
        "queue_pos": jobs[job_id]["queue_pos"],
        "poll_url":  f"/status/{job_id}",
    })

# ── Poll status ───────────────────────────────────────────────────────────────
@app.get("/status/{job_id}")
def status(job_id: str, x_api_key: Optional[str] = None):
    check_auth(x_api_key)
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")

    job = jobs[job_id]
    response = {
        "job_id":     job_id,
        "status":     job["status"],
        "created_at": job["created_at"],
        "started_at": job["started_at"],
        "done_at":    job["done_at"],
    }

    if job["status"] == JobStatus.DONE:
        response["download_url"] = f"/download/{job_id}"
    if job["status"] == JobStatus.FAILED:
        response["error"] = job["error"]
    if job["status"] == JobStatus.QUEUED:
        response["queue_pos"] = job["queue_pos"]

    return response

# ── Download result ───────────────────────────────────────────────────────────
@app.get("/download/{job_id}")
def download(job_id: str, x_api_key: Optional[str] = None):
    check_auth(x_api_key)
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")

    job = jobs[job_id]
    if job["status"] != JobStatus.DONE:
        raise HTTPException(status_code=400, detail=f"Job is {job['status']}, not done yet")

    output_path = Path(job["output"])
    if not output_path.exists():
        raise HTTPException(status_code=404, detail="Output file missing")

    return FileResponse(
        path=str(output_path),
        media_type="video/mp4",
        filename=f"musetalk_{job_id[:8]}.mp4"
    )

# ── List all jobs ─────────────────────────────────────────────────────────────
@app.get("/jobs")
def list_jobs(x_api_key: Optional[str] = None):
    check_auth(x_api_key)
    return [
        {
            "id":         j["id"],
            "status":     j["status"],
            "created_at": j["created_at"],
            "done_at":    j["done_at"],
        }
        for j in jobs.values()
    ]

# ── Worker thread — processes one job at a time ───────────────────────────────
def worker():
    """Background thread that pulls jobs off the queue and runs MuseTalk."""
    while True:
        job_id = job_queue.get()
        if job_id is None:
            break

        job = jobs[job_id]
        job["status"]     = JobStatus.PROCESSING
        job["started_at"] = time.time()

        try:
            _run_musetalk(job)
            job["status"]  = JobStatus.DONE
            job["done_at"] = time.time()
            elapsed = round(job["done_at"] - job["started_at"], 1)
            print(f"[✔] Job {job_id[:8]} done in {elapsed}s → {job['output']}")
        except Exception as e:
            job["status"] = JobStatus.FAILED
            job["error"]  = str(e)
            job["done_at"] = time.time()
            print(f"[✘] Job {job_id[:8]} failed: {e}")
        finally:
            job_queue.task_done()


def _run_musetalk(job: dict):
    """Run MuseTalk inference for a single job."""
    job_dir    = Path(job["output"]).parent
    result_dir = job_dir / "result"
    result_dir.mkdir(exist_ok=True)

    env = os.environ.copy()
    env["FFMPEG_PATH"] = FFMPEG_PATH
    env["PATH"]        = f"{FFMPEG_PATH}:{env['PATH']}"

    # The MuseTalk inference script reads video_path and audio_path from a YAML config.
    # We write a per-job config file so the script knows what to process.
    config = {
        "task_0": {
            "video_path": job["image"],
            "audio_path": job["audio"],
        }
    }
    config_path = job_dir / "inference_config.yaml"
    with open(config_path, "w") as f:
        yaml.dump(config, f)

    # Use the official inference script from MuseTalk
    cmd = [
        "python", "-m", "scripts.inference",
        "--inference_config", str(config_path),
        "--unet_config",     str(MODELS_DIR / "musetalkV15/musetalk.json"),
        "--unet_model_path", str(MODELS_DIR / "musetalkV15/unet.pth"),
        "--result_dir",      str(result_dir),
        "--fps",             str(job["fps"]),
        "--version",         "v15",
    ]
    if job.get("use_float16"):
        cmd.append("--use_float16")

    result = subprocess.run(
        cmd,
        cwd=str(MUSETALK_DIR),
        env=env,
        capture_output=True,
        text=True,
        timeout=600,   # 10-minute max per video
    )

    if result.returncode != 0:
        raise RuntimeError(f"MuseTalk failed:\n{result.stderr[-2000:]}")

    # Find the output file MuseTalk produced and move it to our job output path
    mp4_files = sorted(result_dir.glob("**/*.mp4"), key=lambda f: f.stat().st_mtime)
    if not mp4_files:
        raise RuntimeError("MuseTalk produced no .mp4 output")

    shutil.move(str(mp4_files[-1]), job["output"])


# ── Start worker threads on startup ──────────────────────────────────────────
@app.on_event("startup")
def startup():
    for _ in range(MAX_WORKERS):
        t = threading.Thread(target=worker, daemon=True)
        t.start()
    print(f"[✔] MuseTalk API server ready — {MAX_WORKERS} worker(s)")


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    uvicorn.run("musetalk_server:app", host="0.0.0.0", port=8000, reload=False)
