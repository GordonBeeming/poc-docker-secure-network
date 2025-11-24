#!/bin/bash
set -e

echo "🔧 Initializing Secure Environment..."

# 0. Ensure Permissions
chown -R copilot-proxy:copilot-proxy /logs /ca

# Debug: Print User ID to ensure we match iptables rules
PROXY_UID=$(id -u copilot-proxy)
echo "🔎 Proxy User ID: $PROXY_UID"

# 1. Setup Network Lock
iptables -F
iptables -t nat -F

# --- A. FILTER RULES ---
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# 1. Allow Loopback & Local Communication
iptables -A OUTPUT -o lo -j ACCEPT
# Explicitly allow traffic between Shim (58080) and Logic (58081)
iptables -A OUTPUT -p tcp --dport 58080 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 58081 -j ACCEPT

# 2. Allow Established Connections
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 3. Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# 4. Allow Proxy User Outbound (80/443 only)
iptables -A OUTPUT -p tcp --dport 80 -m owner --uid-owner copilot-proxy -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner copilot-proxy -j ACCEPT

# 5. Allow Custom Ports
if [ -n "$ALLOW_PORTS" ]; then
    IFS=',' read -ra PORTS <<< "$ALLOW_PORTS"
    for port in "${PORTS[@]}"; do
        echo "🔓 Opening custom port: $port"
        iptables -A OUTPUT -p tcp --dport "$port" -j ACCEPT
        iptables -A OUTPUT -p udp --dport "$port" -j ACCEPT
    done
fi

# --- B. NAT RULES ---
# 1. Allow 'copilot-proxy' to bypass redirection
iptables -t nat -A OUTPUT -p tcp --dport 80 -m owner --uid-owner copilot-proxy -j ACCEPT
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner copilot-proxy -j ACCEPT

# 2. Redirect everyone else to the Shim (Port 58080)
iptables -t nat -A OUTPUT -p tcp --dport 80 -j REDIRECT --to-port 58080
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 58080

echo "🔒 Network Lock Applied (Default DENY policy active)."

# 2. Start the Proxy using GOSU
# This ensures the process actually runs as the user, avoiding weird shell nesting issues
gosu copilot-proxy node /app/proxy.js &
PROXY_PID=$!

# 3. Wait for CA
echo "⏳ Waiting for CA generation..."
while [ ! -f "/ca/certs/ca.pem" ]; do
  sleep 0.5
done

echo "📜 Trusting CA Certificate..."
cp /ca/certs/ca.pem /usr/local/share/ca-certificates/copilot-here-ca.crt
update-ca-certificates

echo "✅ Environment Ready."

exec "$@"