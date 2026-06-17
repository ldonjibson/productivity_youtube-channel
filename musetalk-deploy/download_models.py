#!/usr/bin/env python3
"""
MuseTalk Model Downloader
=========================
Downloads ALL required model weights for MuseTalk using the official sources.

This script is used both during Docker build and on fresh Vast.ai instances.

Usage:
    python download_models.py [--models-dir /path/to/models]

Model Sources (from official TMElyralab/MuseTalk/download_weights.sh):
  - MuseTalk V1.5:  huggingface.co/TMElyralab/MuseTalk
  - SD VAE ft-mse:  huggingface.co/stabilityai/sd-vae-ft-mse
  - Whisper tiny:   huggingface.co/openai/whisper-tiny
  - DWPose:         huggingface.co/yzd-v/DWPose
  - SyncNet:        huggingface.co/ByteDance/LatentSync
  - Face Parse:     Google Drive (gdown)
  - ResNet18:       download.pytorch.org
"""

import os
import sys
import argparse
import hashlib
import time
import subprocess
from pathlib import Path

# ── Model definitions ────────────────────────────────────────────────────────
# Each entry: (repo_id, filename_in_repo, local_subpath, expected_min_size_mb)
# If repo_id is None, use url directly.

HF_MIRROR = os.environ.get("HF_ENDPOINT", "https://huggingface.co")

MODELS = [
    # ── MuseTalk V1.5 (main model) ──────────────────────────────────────
    {
        "name": "MuseTalk V1.5 UNet",
        "repo": "TMElyralab/MuseTalk",
        "hf_file": "musetalkV15/unet.pth",
        "local": "musetalkV15/unet.pth",
        "min_mb": 400,
    },
    {
        "name": "MuseTalk V1.5 Config",
        "repo": "TMElyralab/MuseTalk",
        "hf_file": "musetalkV15/musetalk.json",
        "local": "musetalkV15/musetalk.json",
        "min_mb": 0.001,
    },
    # ── MuseTalk V1.0 (optional, for backward compat) ───────────────────
    {
        "name": "MuseTalk V1.0 Config",
        "repo": "TMElyralab/MuseTalk",
        "hf_file": "musetalk/musetalk.json",
        "local": "musetalk/musetalk.json",
        "min_mb": 0.001,
    },
    {
        "name": "MuseTalk V1.0 Model",
        "repo": "TMElyralab/MuseTalk",
        "hf_file": "musetalk/pytorch_model.bin",
        "local": "musetalk/pytorch_model.bin",
        "min_mb": 400,
    },
    # ── SD VAE ft-mse ───────────────────────────────────────────────────
    {
        "name": "SD VAE Config",
        "repo": "stabilityai/sd-vae-ft-mse",
        "hf_file": "config.json",
        "local": "sd-vae/config.json",
        "min_mb": 0.001,
    },
    {
        "name": "SD VAE Model",
        "repo": "stabilityai/sd-vae-ft-mse",
        "hf_file": "diffusion_pytorch_model.bin",
        "local": "sd-vae/diffusion_pytorch_model.bin",
        "min_mb": 300,
    },
    # ── Whisper tiny (HuggingFace transformers format) ──────────────────
    {
        "name": "Whisper Config",
        "repo": "openai/whisper-tiny",
        "hf_file": "config.json",
        "local": "whisper/config.json",
        "min_mb": 0.001,
    },
    {
        "name": "Whisper Model",
        "repo": "openai/whisper-tiny",
        "hf_file": "pytorch_model.bin",
        "local": "whisper/pytorch_model.bin",
        "min_mb": 60,
    },
    {
        "name": "Whisper Preprocessor Config",
        "repo": "openai/whisper-tiny",
        "hf_file": "preprocessor_config.json",
        "local": "whisper/preprocessor_config.json",
        "min_mb": 0.001,
    },
    # ── DWPose ──────────────────────────────────────────────────────────
    {
        "name": "DWPose Body Model",
        "repo": "yzd-v/DWPose",
        "hf_file": "dw-ll_ucoco_384.pth",
        "local": "dwpose/dw-ll_ucoco_384.pth",
        "min_mb": 200,
    },
    # ── SyncNet ─────────────────────────────────────────────────────────
    {
        "name": "SyncNet (LatentSync)",
        "repo": "ByteDance/LatentSync",
        "hf_file": "latentsync_syncnet.pt",
        "local": "syncnet/latentsync_syncnet.pt",
        "min_mb": 1200,
    },
    # ── Face Parse Bisent ───────────────────────────────────────────────
    {
        "name": "Face Parse Bisent Model",
        "url": "https://drive.google.com/uc?id=154JgKpzCPW82qINcVieuPH3fZ2e0P812",
        "local": "face-parse-bisent/79999_iter.pth",
        "min_mb": 50,
        "use_gdown": True,
    },
    {
        "name": "ResNet18 (Face Parse backbone)",
        "url": "https://download.pytorch.org/models/resnet18-5c106cde.pth",
        "local": "face-parse-bisent/resnet18-5c106cde.pth",
        "min_mb": 40,
    },
]

# ── Helpers ──────────────────────────────────────────────────────────────────

GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
BOLD = "\033[1m"
NC = "\033[0m"


def log(msg):
    print(f"{GREEN}[✔]{NC} {msg}")


def warn(msg):
    print(f"{YELLOW}[!]{NC} {msg}")


def err(msg):
    print(f"{RED}[✘]{NC} {msg}")


def file_ok(path: Path, min_mb: float) -> bool:
    """Check if file exists and has reasonable size."""
    if not path.exists():
        return False
    size_mb = path.stat().st_size / (1024 * 1024)
    if size_mb < min_mb:
        warn(f"  File too small: {path.name} ({size_mb:.1f}MB < {min_mb}MB)")
        return False
    return True


def download_hf_file(repo_id: str, hf_file: str, dest: Path, max_retries: int = 3):
    """Download a single file from a HuggingFace repo using huggingface-cli."""
    url = f"{HF_MIRROR}/{repo_id}/resolve/main/{hf_file}"

    for attempt in range(1, max_retries + 1):
        try:
            result = subprocess.run(
                [
                    "huggingface-cli", "download",
                    repo_id,
                    hf_file,
                    "--local-dir", str(dest.parent),
                    "--local-dir-use-symlinks", "False",
                ],
                capture_output=True,
                text=True,
                timeout=600,
            )
            if result.returncode == 0:
                # huggingface-cli downloads to local-dir/hf_file
                # Check the expected path
                expected = dest.parent / hf_file
                if expected.exists():
                    return True
                # Sometimes it goes to a different location, try direct download
                break
        except subprocess.TimeoutExpired:
            warn(f"  Attempt {attempt} timed out for {hf_file}")
        except Exception as e:
            warn(f"  Attempt {attempt} failed: {e}")

        if attempt < max_retries:
            wait = attempt * 10
            warn(f"  Retrying in {wait}s...")
            time.sleep(wait)

    return False


def download_with_curl(url: str, dest: Path, max_retries: int = 3):
    """Download a file using curl with retries."""
    for attempt in range(1, max_retries + 1):
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            result = subprocess.run(
                [
                    "curl", "-L", "--retry", "3", "--retry-delay", "5",
                    "-o", str(dest),
                    url,
                ],
                capture_output=True,
                text=True,
                timeout=600,
            )
            if result.returncode == 0 and dest.exists():
                return True
        except subprocess.TimeoutExpired:
            warn(f"  Attempt {attempt} timed out for {dest.name}")
        except Exception as e:
            warn(f"  Attempt {attempt} failed: {e}")

        if attempt < max_retries:
            wait = attempt * 10
            warn(f"  Retrying in {wait}s...")
            time.sleep(wait)

    return False


def download_with_gdown(url: str, dest: Path, max_retries: int = 3):
    """Download from Google Drive using gdown."""
    for attempt in range(1, max_retries + 1):
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            result = subprocess.run(
                ["gdown", "--id", url.split("id=")[-1].split("&")[0], "-O", str(dest)],
                capture_output=True,
                text=True,
                timeout=600,
            )
            if result.returncode == 0 and dest.exists():
                return True
        except subprocess.TimeoutExpired:
            warn(f"  Attempt {attempt} timed out for {dest.name}")
        except Exception as e:
            warn(f"  Attempt {attempt} failed: {e}")

        if attempt < max_retries:
            wait = attempt * 10
            warn(f"  Retrying in {wait}s...")
            time.sleep(wait)

    return False


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Download MuseTalk model weights")
    parser.add_argument(
        "--models-dir",
        type=str,
        default=None,
        help="Directory to store models (default: ./models or /workspace/MuseTalk/models)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download even if files exist",
    )
    args = parser.parse_args()

    # Determine models directory
    if args.models_dir:
        models_dir = Path(args.models_dir)
    elif Path("/workspace/MuseTalk/models").exists():
        models_dir = Path("/workspace/MuseTalk/models")
    else:
        models_dir = Path("./models")

    print(f"\n{BOLD}{'='*60}{NC}")
    print(f"{BOLD}  MuseTalk Model Downloader{NC}")
    print(f"{BOLD}{'='*60}{NC}")
    print(f"  Models directory: {models_dir}\n")

    # Create all directories
    dirs_needed = set()
    for m in MODELS:
        dirs_needed.add(models_dir / Path(m["local"]).parent)
    for d in dirs_needed:
        d.mkdir(parents=True, exist_ok=True)

    # Download each model
    success = 0
    skipped = 0
    failed = 0

    for i, m in enumerate(MODELS, 1):
        name = m["name"]
        local_path = models_dir / m["local"]
        min_mb = m.get("min_mb", 0.1)

        print(f"\n[{i}/{len(MODELS)}] {BOLD}{name}{NC}")

        # Skip if already exists and valid
        if not args.force and file_ok(local_path, min_mb):
            size_mb = local_path.stat().st_size / (1024 * 1024)
            log(f"Already exists: {local_path.name} ({size_mb:.1f}MB) — skipping")
            skipped += 1
            continue

        # Ensure parent directory exists
        local_path.parent.mkdir(parents=True, exist_ok=True)

        # Download based on source
        downloaded = False

        if m.get("use_gdown"):
            log(f"Downloading from Google Drive...")
            downloaded = download_with_gdown(m["url"], local_path)
        elif m.get("url"):
            log(f"Downloading from: {m['url']}")
            downloaded = download_with_curl(m["url"], local_path)
        elif m.get("repo"):
            log(f"Downloading from HuggingFace: {m['repo']}/{m['hf_file']}")
            # Use huggingface-cli for the repo
            result = subprocess.run(
                [
                    "huggingface-cli", "download",
                    m["repo"],
                    m["hf_file"],
                    "--local-dir", str(models_dir),
                    "--local-dir-use-symlinks", "False",
                ],
                capture_output=True,
                text=True,
                timeout=600,
            )
            # Check if file landed in the right place
            if local_path.exists() and file_ok(local_path, min_mb):
                downloaded = True
            else:
                # huggingface-cli may put it at models_dir/hf_file instead
                alt_path = models_dir / m["hf_file"]
                if alt_path.exists() and alt_path != local_path:
                    import shutil
                    shutil.move(str(alt_path), str(local_path))
                    downloaded = file_ok(local_path, min_mb)

                if not downloaded:
                    # Fallback: direct curl download
                    warn("huggingface-cli failed, trying direct download...")
                    url = f"{HF_MIRROR}/{m['repo']}/resolve/main/{m['hf_file']}"
                    downloaded = download_with_curl(url, local_path)

        # Verify
        if downloaded and file_ok(local_path, min_mb):
            size_mb = local_path.stat().st_size / (1024 * 1024)
            log(f"OK — {size_mb:.1f}MB")
            success += 1
        else:
            err(f"FAILED to download {name}")
            failed += 1

    # Summary
    print(f"\n{BOLD}{'='*60}{NC}")
    print(f"{BOLD}  Download Summary{NC}")
    print(f"{BOLD}{'='*60}{NC}")
    print(f"  {GREEN}Success: {success}{NC}")
    print(f"  Skipped (already exists): {skipped}")
    if failed:
        print(f"  {RED}Failed: {failed}{NC}")
    print()

    # List all model files
    print(f"{BOLD}Model files in {models_dir}:{NC}")
    for m in MODELS:
        p = models_dir / m["local"]
        if p.exists():
            size_mb = p.stat().st_size / (1024 * 1024)
            print(f"  {GREEN}✔{NC} {m['local']} ({size_mb:.1f}MB)")
        else:
            print(f"  {RED}✘{NC} {m['local']} — MISSING")

    if failed:
        print(f"\n{RED}Some models failed to download. Check errors above.{NC}")
        sys.exit(1)
    else:
        print(f"\n{GREEN}All models downloaded successfully!{NC}")


if __name__ == "__main__":
    main()
