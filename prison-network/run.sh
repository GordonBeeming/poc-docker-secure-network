#!/bin/bash
# Prison Network - Run Script
# Each run creates a unique session with its own containers

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Generate unique session ID (timestamp + random)
SESSION_ID="${1:-$(date +%Y%m%d_%H%M%S)_$$}"
PROJECT_NAME="prison-${SESSION_ID}"

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up session ${SESSION_ID}..."
    cd "$SCRIPT_DIR"
    docker compose -p "$PROJECT_NAME" down -v 2>/dev/null || true
    echo "👋 Session cleaned up."
}

# Register cleanup on exit
trap cleanup EXIT

echo "🔒 Prison Network - Session: ${SESSION_ID}"
echo "=============================================="
echo ""
echo "📦 Docker group: ${PROJECT_NAME}"
echo "   - ${PROJECT_NAME}-proxy (Proxy container)"
echo "   - ${PROJECT_NAME}-app   (Copilot container)"
echo ""

# Ensure directories exist in script dir
mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/config"

# Get the directory where the user invoked the script (their working directory)
CALLER_DIR="$(pwd)"
HOST_WORK_DIR="$CALLER_DIR"

# Determine container path - map to container home if under user's home
if [[ "$CALLER_DIR" == "$HOME"* ]]; then
    RELATIVE_PATH="${CALLER_DIR#$HOME}"
    CONTAINER_WORK_DIR="/home/appuser${RELATIVE_PATH}"
else
    CONTAINER_WORK_DIR="$CALLER_DIR"
fi

# Get GitHub token
GITHUB_TOKEN=$(gh auth token 2>/dev/null || echo "")
if [ -z "$GITHUB_TOKEN" ]; then
    echo "⚠️  Warning: Could not get GitHub token. Run 'gh auth login' first."
fi

# Copilot config path
COPILOT_CONFIG_PATH="$HOME/.config/copilot-cli-docker"
mkdir -p "$COPILOT_CONFIG_PATH"

# Export environment for docker compose
export PUID=$(id -u)
export PGID=$(id -g)
export GITHUB_TOKEN
export COPILOT_CONFIG_PATH
export HOST_WORK_DIR
export CONTAINER_WORK_DIR

# Change to script directory for docker compose
cd "$SCRIPT_DIR"

# Build containers
echo "🏗️  Building containers..."
docker compose -p "$PROJECT_NAME" build --quiet

# Start only the proxy first (in background)
echo "🚀 Starting proxy..."
docker compose -p "$PROJECT_NAME" up -d proxy

# Wait for proxy to be ready
echo "⏳ Waiting for proxy to initialize..."
sleep 3

# Check if proxy CA is ready
for i in {1..30}; do
    if docker compose -p "$PROJECT_NAME" exec -T proxy test -f /ca/certs/ca.pem 2>/dev/null; then
        break
    fi
    sleep 1
done

echo "✅ Proxy Ready!"
echo ""
echo "📂 Working directory: $CONTAINER_WORK_DIR"
echo "   (mounted from: $HOST_WORK_DIR)"
echo ""
echo "📋 Available Commands (in another terminal):"
echo "   docker logs -f ${PROJECT_NAME}-proxy"
echo "   cat $SCRIPT_DIR/logs/traffic.jsonl"
echo ""
echo "---------------------------------------------------"
echo "🚀 Launching GitHub Copilot CLI..."
echo "---------------------------------------------------"
echo ""

# Run the app container interactively (not detached)
# This will run copilot and exit when done
docker compose -p "$PROJECT_NAME" run --rm app

# Cleanup happens automatically via trap
