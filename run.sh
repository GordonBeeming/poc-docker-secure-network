#!/bin/bash

# Stop on error
set -e

IMAGE_NAME="copilot-secure-proxy"
CONFIG_DIR="$(pwd)/copilot-config"
LOGS_DIR="$(pwd)/logs"

echo "🏗️  Building Docker Image..."
docker build -t $IMAGE_NAME .

# --- Setup Local Files for Volumes ---
# Ensure config directory exists
if [ ! -d "$CONFIG_DIR" ]; then
    echo "📂 Creating config directory at $CONFIG_DIR..."
    mkdir -p "$CONFIG_DIR"
fi

# Ensure rules.json exists (Create default if missing)
if [ ! -f "$CONFIG_DIR/rules.json" ]; then
    echo "📝 Creating default rules.json..."
    cat <<EOF > "$CONFIG_DIR/rules.json"
{
  "mode": "monitor",
  "allowed_rules": [
    { 
      "host": "github.com", 
      "allowed_paths": ["/gordonbeeming"] 
    },
    { "host": "api.github.com", "allowed_paths": [] },
    { "host": "copilot-proxy.githubusercontent.com", "allowed_paths": [] },
    { "host": "objects.githubusercontent.com", "allowed_paths": [] }
  ]
}
EOF
fi

# Ensure logs directory exists
if [ ! -d "$LOGS_DIR" ]; then
    echo "📂 Creating logs directory at $LOGS_DIR..."
    mkdir -p "$LOGS_DIR"
fi

# Ensure traffic log exists (so it's owned by you, not root)
if [ ! -f "$LOGS_DIR/traffic.jsonl" ]; then
    touch "$LOGS_DIR/traffic.jsonl"
fi

echo "🚀 Starting Container in Interactive Mode..."
echo "---------------------------------------------------"
echo "💡 TIP: The proxy takes a second to generate the CA."
echo "   Wait for '✅ Environment Ready' before running curl."
echo "---------------------------------------------------"

docker run -it --rm \
  --name copilot-test-runner \
  --cap-add=NET_ADMIN \
  -v "$CONFIG_DIR":/config:ro \
  -v "$LOGS_DIR":/logs \
  $IMAGE_NAME

echo "👋 Container removed."