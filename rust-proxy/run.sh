#!/bin/bash
# Build and run the Rust-based secure proxy

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="secure-proxy-rust"
CONFIG_DIR="${SCRIPT_DIR}/../copilot-config"
LOGS_DIR="${SCRIPT_DIR}/../logs"

# Ensure directories exist
mkdir -p "$LOGS_DIR"

echo "🔨 Building Secure Proxy (Rust)..."
docker build -t $IMAGE_NAME "$SCRIPT_DIR"

echo ""
echo "🚀 Starting Container in Interactive Mode..."
echo "---------------------------------------------------"
echo "💡 TIP: Wait for '✅ Environment Ready' before running curl."
echo "---------------------------------------------------"

docker run --rm -it \
    --cap-add=NET_ADMIN \
    -v "$CONFIG_DIR":/config:ro \
    -v "$LOGS_DIR":/logs \
    $IMAGE_NAME
