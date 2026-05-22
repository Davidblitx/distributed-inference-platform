#!/bin/bash
# setup-caller.sh — Deploy caller-worker on the public VM
set -e

INFERENCE_IP="${1:-10.0.2.144}"
PROJECT_DIR="$HOME/hiring/may-2026/devops/quickstart"

echo "=== Setting up Caller VM ==="

# Install dependencies
sudo apt-get update -y
sudo apt-get install -y curl git

# Install iii
curl -fsSL https://iii.dev/install.sh | bash
source ~/.bashrc

# Install Bun
curl -fsSL https://bun.sh/install | bash
source ~/.bashrc

# Clone project
if [ ! -d "$HOME/hiring" ]; then
  git clone https://github.com/Alchemyst-ai/hiring.git "$HOME/hiring"
fi

# Fix config.yaml for cloud deployment
cat > "$PROJECT_DIR/config.yaml" << EOF
workers:
  - name: iii-observability
    config:
      enabled: true
      service_name: iii
      exporter: memory
      memory_max_spans: 10000
      metrics_enabled: true
      metrics_exporter: memory
      logs_enabled: true
      logs_exporter: memory
      logs_console_output: true
      sampling_ratio: 1.0
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: ./data/state_store.db
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 300000
      concurrency_request_limit: 1024
      cors:
        allowed_origins:
          - '*'
        allowed_methods:
          - GET
          - POST
          - PUT
          - DELETE
          - OPTIONS
  - name: caller-worker
    worker_path: $PROJECT_DIR/workers/caller-worker
EOF

# Install caller worker deps
cd "$PROJECT_DIR/workers/caller-worker"
~/.bun/bin/bun install

# Install systemd service for iii engine
sudo tee /etc/systemd/system/iii-engine.service << EOF
[Unit]
Description=iii Engine
After=network.target

[Service]
User=ubuntu
WorkingDirectory=$PROJECT_DIR
ExecStart=$HOME/.local/bin/iii --config config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Install systemd service for caller worker
sudo tee /etc/systemd/system/caller-worker.service << EOF
[Unit]
Description=Caller Worker (TypeScript)
After=iii-engine.service
Requires=iii-engine.service

[Service]
User=ubuntu
WorkingDirectory=$PROJECT_DIR/workers/caller-worker
Environment=III_URL=ws://localhost:49134
ExecStart=$HOME/.bun/bin/bun run src/worker.ts
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable iii-engine caller-worker
sudo systemctl start iii-engine
sleep 3
sudo systemctl start caller-worker

echo "=== Caller VM setup complete ==="
echo "Engine: $(sudo systemctl is-active iii-engine)"
echo "Caller: $(sudo systemctl is-active caller-worker)"
