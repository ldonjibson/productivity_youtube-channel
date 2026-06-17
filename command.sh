#!/bin/bash

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update -qq
sudo apt-get install -y -qq nvidia-container-toolkit

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

docker run -d --gpus all \
  -p 8000:8000 \
  -e FFMPEG_PATH=/workspace/ffmpeg-static \
  -e API_KEY="any_secret_string" \
  --name musetalk \
  ldonjibson/musetalk:latest \
  python3 -m uvicorn musetalk_server:app --host 0.0.0.0 --port 8000 --log-level info