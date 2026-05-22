#!/bin/bash
# setup-inference.sh — Deploy inference-worker on the private VM
set -e

CALLER_IP="${1:-10.0.1.247}"
PROJECT_DIR="$HOME/hiring/may-2026/devops/quickstart"
WORKER_DIR="$PROJECT_DIR/workers/inference-worker"

echo "=== Setting up Inference VM ==="

# Install dependencies
sudo apt-get update -y
sudo apt-get install -y curl git python3.11 python3.11-venv python3.11-dev

# Install iii
curl -fsSL https://iii.dev/install.sh | bash
source ~/.bashrc

# Clone project
if [ ! -d "$HOME/hiring" ]; then
  git clone https://github.com/Alchemyst-ai/hiring.git "$HOME/hiring"
fi

# Add 4GB swap (model needs ~2GB RAM)
if [ ! -f /swapfile ]; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# Create Python 3.11 venv and install deps
cd "$WORKER_DIR"
python3.11 -m venv venv
venv/bin/pip install --upgrade pip
venv/bin/pip install --default-timeout=300 -r requirements.txt

# Write the fixed inference worker
cat > "$WORKER_DIR/inference_worker.py" << 'PYEOF'
import os
from typing import Any, Dict
import torch
from iii import InitOptions, Logger, register_worker
from transformers import AutoModelForCausalLM, AutoTokenizer

iii = register_worker(
    os.environ.get("III_URL", "ws://localhost:49134"),
    InitOptions(worker_name="math-worker"),
)
logger = Logger()

model_id = "ggml-org/gemma-3-270m-GGUF"
gguf_file = "gemma-3-270m-Q8_0.gguf"

print("Loading tokenizer...")
tokenizer = AutoTokenizer.from_pretrained(model_id, gguf_file=gguf_file)
print("Loading model...")
model = AutoModelForCausalLM.from_pretrained(model_id, gguf_file=gguf_file)
print("Model loaded.")

def run_inference_handler(payload: Dict[str, Any]) -> Dict[str, Any]:
    try:
        messages = payload.get("messages", [])
        prompt = ""
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            if role == "user":
                prompt += f"<start_of_turn>user\n{content}<end_of_turn>\n"
            elif role == "assistant":
                prompt += f"<start_of_turn>model\n{content}<end_of_turn>\n"
        prompt += "<start_of_turn>model\n"
        inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
        with torch.no_grad():
            output = model.generate(**inputs, max_new_tokens=128, do_sample=False)
        result = tokenizer.decode(
            output[0][inputs["input_ids"].shape[-1]:],
            skip_special_tokens=True
        )
        print(f"Generated: {result[:80]}")
        return {"response": result}
    except Exception as e:
        print(f"Error: {e}")
        return {"response": str(e)}

iii.register_function("inference::run_inference", run_inference_handler)
print("Inference worker started - listening for calls")
PYEOF

# Install systemd service
sudo tee /etc/systemd/system/inference-worker.service << EOF
[Unit]
Description=Inference Worker (Python/Gemma)
After=network.target

[Service]
User=ubuntu
WorkingDirectory=$WORKER_DIR
Environment=III_URL=ws://$CALLER_IP:49134
ExecStart=$WORKER_DIR/venv/bin/python inference_worker.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable inference-worker
sudo systemctl start inference-worker

echo "=== Inference VM setup complete ==="
echo "Inference worker: $(sudo systemctl is-active inference-worker)"
echo "Watch logs: journalctl -u inference-worker -f"
