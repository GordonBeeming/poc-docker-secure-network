#!/bin/bash
set -e

echo "🔧 Initializing Secure Environment..."

rm -rf /ca/* # Force regeneration of CA with new settings
chown -R copilot-proxy:copilot-proxy /logs /ca

# Debug: Print User ID
PROXY_UID=$(id -u copilot-proxy)
echo "🔎 Proxy User ID: $PROXY_UID"

# 1. Setup Network Lock
iptables -F
iptables -t nat -F

# --- A. FILTER RULES ---
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# 1. Allow Loopback (Critical for local proxy redirection)
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -j ACCEPT

# 1.5 Allow Traffic to the Transparent Shim (58080)
iptables -A OUTPUT -p tcp --dport 58080 -j ACCEPT

# 1.6 Allow Traffic to the Logic Proxy (58081) - CRITICAL
# The Shim (local) needs to connect to this port on 127.0.0.1
iptables -A OUTPUT -p tcp --dport 58081 -j ACCEPT

# 2. Allow Established Connections
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 3. Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# 4. Allow Proxy User Outbound (80/443 only)
# The proxy needs to talk to the internet, but we restrict it to web ports only.
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
# 1. Allow 'copilot-proxy' to bypass redirection (so it doesn't loop)
iptables -t nat -A OUTPUT -p tcp --dport 80 -m owner --uid-owner copilot-proxy -j ACCEPT
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner copilot-proxy -j ACCEPT

# 2. Redirect everyone else to the Shim (Port 58080)
iptables -t nat -A OUTPUT -p tcp --dport 80 -j REDIRECT --to-port 58080
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 58080

echo "🔒 Network Lock Applied (Default DENY policy active)."

# Debug: Show rules for verification
iptables -L -n -v

# 2. Start the Proxy using GOSU
echo "🚀 Starting Logic Proxy..."
gosu copilot-proxy node /app/logic.js &
LOGIC_PID=$!

echo "🚀 Starting Transparent Shim..."
gosu copilot-proxy node /app/shim.js &
SHIM_PID=$!

# 3. Wait for CA
echo "⏳ Waiting for CA generation..."
while [ ! -f "/ca/certs/ca.pem" ]; do
  sleep 0.5
done

echo "📜 Trusting CA Certificate..."
cp /ca/certs/ca.pem /usr/local/share/ca-certificates/copilot-here-ca.crt
update-ca-certificates

echo "✅ Environment Ready."

echo "📋 Current Configuration:"
cat /config/rules.json || echo "No config file found."

echo "🧪 Running Self-Test (curl github.com via Proxy)..."
http_code=$(curl -I -s -o /dev/null -w "%{http_code}" https://github.com || echo "000")

if [ "$http_code" -eq "200" ] || [ "$http_code" -eq "301" ] || [ "$http_code" -eq "302" ]; then
    echo " -> ✅ Success! (HTTP $http_code)"
else
    echo " -> ❌ Failed! (HTTP $http_code)"
fi

exec "$@"