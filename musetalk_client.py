"""
MuseTalk Batch Client
=====================
Submits 30 audio files against one avatar image to the MuseTalk API,
polls for completion, and downloads all videos.

Usage:
    python musetalk_client.py \
        --host http://<vast-ip>:<port> \
        --avatar avatar.jpg \
        --audio-dir ./audio_files \
        --output-dir ./videos \
        --api-key YOUR_SECRET_KEY   # omit if no key set

Audio files should be named: audio_01.wav, audio_02.wav ... audio_30.wav
"""

import os
import sys
import time
import argparse
import requests
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

def submit_job(host: str, avatar: Path, audio: Path, api_key: str) -> dict:
    headers = {"x-api-key": api_key} if api_key else {}
    with open(avatar, "rb") as img_f, open(audio, "rb") as aud_f:
        resp = requests.post(
            f"{host}/generate",
            headers=headers,
            files={
                "image": (avatar.name, img_f, "image/jpeg"),
                "audio": (audio.name, aud_f, "audio/wav"),
            },
            timeout=30,
        )
    resp.raise_for_status()
    return resp.json()

def poll_job(host: str, job_id: str, api_key: str, interval: int = 5) -> dict:
    headers = {"x-api-key": api_key} if api_key else {}
    while True:
        resp = requests.get(f"{host}/status/{job_id}", headers=headers, timeout=10)
        resp.raise_for_status()
        data = resp.json()
        status = data["status"]
        if status in ("done", "failed"):
            return data
        time.sleep(interval)

def download_video(host: str, job_id: str, output_path: Path, api_key: str):
    headers = {"x-api-key": api_key} if api_key else {}
    resp = requests.get(f"{host}/download/{job_id}", headers=headers, stream=True, timeout=120)
    resp.raise_for_status()
    with open(output_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=8192):
            f.write(chunk)

def process_one(host, avatar, audio_file, output_dir, api_key, label):
    output_path = output_dir / audio_file.name.replace("audio_", "video_").replace(".wav", ".mp4").replace(".mp3", ".mp4")

    if output_path.exists():
        print(f"[skip] {label} — already downloaded")
        return label, "skipped"

    # Submit
    print(f"[→]    {label} — submitting...")
    job = submit_job(host, avatar, audio_file, api_key)
    job_id = job["job_id"]
    print(f"[✔]    {label} — queued as {job_id[:8]}  (queue pos: {job.get('queue_pos', '?')})")

    # Poll
    result = poll_job(host, job_id, api_key)
    if result["status"] == "failed":
        print(f"[✘]    {label} — FAILED: {result.get('error', 'unknown')}")
        return label, "failed"

    elapsed = round(result["done_at"] - result["started_at"], 1)
    print(f"[✔]    {label} — done in {elapsed}s, downloading...")

    # Download
    download_video(host, job_id, output_path, api_key)
    print(f"[💾]   {label} — saved to {output_path}")
    return label, "done"

def main():
    parser = argparse.ArgumentParser(description="MuseTalk batch client")
    parser.add_argument("--host",       required=True,  help="API base URL e.g. http://12.34.56.78:8000")
    parser.add_argument("--avatar",     required=True,  help="Avatar image file")
    parser.add_argument("--audio-dir",  required=True,  help="Directory of audio files (audio_01.wav ...)")
    parser.add_argument("--output-dir", default="./videos", help="Where to save videos")
    parser.add_argument("--api-key",    default="",     help="API key if set on server")
    parser.add_argument("--workers",    type=int, default=5,
                        help="Concurrent submissions (jobs still run 1-at-a-time on GPU)")
    args = parser.parse_args()

    host       = args.host.rstrip("/")
    avatar     = Path(args.avatar)
    audio_dir  = Path(args.audio_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if not avatar.exists():
        sys.exit(f"Avatar not found: {avatar}")

    audio_files = sorted(audio_dir.glob("audio_*.wav")) + \
                  sorted(audio_dir.glob("audio_*.mp3"))
    if not audio_files:
        sys.exit(f"No audio files found in {audio_dir}")

    print(f"\n🎬 MuseTalk Batch Client")
    print(f"   Server:      {host}")
    print(f"   Avatar:      {avatar}")
    print(f"   Audio files: {len(audio_files)}")
    print(f"   Output dir:  {output_dir}")
    print(f"   Workers:     {args.workers} concurrent submissions\n")

    # Health check
    try:
        r = requests.get(f"{host}/health", timeout=5)
        h = r.json()
        print(f"   GPU: {h.get('gpu')} | VRAM: {h.get('vram_gb')}GB\n")
    except Exception as e:
        sys.exit(f"Cannot reach server: {e}")

    start = time.time()
    results = {"done": 0, "failed": 0, "skipped": 0}

    # Submit all jobs concurrently (they queue server-side, GPU processes 1-at-a-time)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(process_one, host, avatar, af, output_dir, args.api_key,
                        af.stem): af
            for af in audio_files
        }
        for future in as_completed(futures):
            label, outcome = future.result()
            results[outcome] = results.get(outcome, 0) + 1

    elapsed = round(time.time() - start)
    print(f"\n{'='*50}")
    print(f"✅  Batch complete in {elapsed}s")
    print(f"    Done: {results['done']}  |  Failed: {results['failed']}  |  Skipped: {results['skipped']}")
    print(f"    Videos saved to: {output_dir.resolve()}")
    print(f"{'='*50}\n")

if __name__ == "__main__":
    main()
