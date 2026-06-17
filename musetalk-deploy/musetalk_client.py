"""
MuseTalk Batch Client
====================
Submits audio files against an avatar image to the MuseTalk API,
polls for completion, and downloads all videos.

Usage:
    python musetalk_client.py \
        --host http://<vast-ip>:<port> \
        --avatar avatar.jpg \
        --audio-dir ./audio_files \
        --output-dir ./videos \
        --api-key YOUR_SECRET_KEY

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

def download_result(host: str, job_id: str, output_path: Path, api_key: str):
    headers = {"x-api-key": api_key} if api_key else {}
    resp = requests.get(f"{host}/download/{job_id}", headers=headers, timeout=120, stream=True)
    resp.raise_for_status()
    with open(output_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=8192):
            f.write(chunk)

def process_one(host: str, avatar: Path, audio: Path, output_dir: Path, api_key: str):
    """Submit one audio, wait, download result."""
    audio_name = audio.stem
    output_path = output_dir / f"{audio_name}.mp4"

    if output_path.exists():
        print(f"  ⏭  {audio_name} — already done, skipping")
        return output_path

    try:
        # Submit
        result = submit_job(host, avatar, audio, api_key)
        job_id = result["job_id"]
        print(f"  📤 {audio_name} — submitted (job {job_id[:8]})")

        # Poll
        final = poll_job(host, job_id, api_key)

        if final["status"] == "done":
            download_result(host, job_id, output_path, api_key)
            print(f"  ✅ {audio_name} — done → {output_path.name}")
            return output_path
        else:
            print(f"  ❌ {audio_name} — FAILED: {final.get('error', 'unknown')}")
            return None

    except Exception as e:
        print(f"  ❌ {audio_name} — ERROR: {e}")
        return None

def main():
    parser = argparse.ArgumentParser(description="MuseTalk batch client")
    parser.add_argument("--host",       required=True, help="MuseTalk server URL (e.g. http://1.2.3.4:8000)")
    parser.add_argument("--avatar",     required=True, type=Path, help="Avatar image path")
    parser.add_argument("--audio-dir",  required=True, type=Path, help="Directory with audio files")
    parser.add_argument("--output-dir", default=Path("./videos"), type=Path, help="Output directory")
    parser.add_argument("--api-key",    default="", help="API key (if set on server)")
    parser.add_argument("--concurrent", type=int, default=1, help="Number of concurrent jobs (default: 1)")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    # Find audio files
    audio_files = sorted([
        f for f in args.audio_dir.iterdir()
        if f.suffix.lower() in (".wav", ".mp3", ".flac", ".ogg")
    ])

    if not audio_files:
        print("No audio files found in", args.audio_dir)
        sys.exit(1)

    print(f"\n🎵 MuseTalk Batch Client")
    print(f"   Server:   {args.host}")
    print(f"   Avatar:   {args.avatar}")
    print(f"   Audio:    {len(audio_files)} files")
    print(f"   Output:   {args.output_dir}")
    print(f"   Workers:  {args.concurrent}\n")

    # Health check
    try:
        health = requests.get(f"{args.host}/health", timeout=5).json()
        print(f"   GPU: {health.get('gpu', '?')} ({health.get('vram_gb', '?')}GB)\n")
    except Exception as e:
        print(f"   ⚠️  Health check failed: {e}\n")

    # Process
    start = time.time()
    results = []

    if args.concurrent > 1:
        with ThreadPoolExecutor(max_workers=args.concurrent) as pool:
            futures = {
                pool.submit(process_one, args.host, args.avatar, audio, args.output_dir, args.api_key): audio
                for audio in audio_files
            }
            for future in as_completed(futures):
                results.append(future.result())
    else:
        for audio in audio_files:
            results.append(process_one(args.host, args.avatar, audio, args.output_dir, args.api_key))

    # Summary
    done = sum(1 for r in results if r is not None)
    elapsed = round(time.time() - start, 1)

    print(f"\n{'='*50}")
    print(f"  ✅ {done}/{len(audio_files)} videos generated in {elapsed}s")
    print(f"  📁 Output: {args.output_dir}")
    print(f"{'='*50}\n")

if __name__ == "__main__":
    main()
