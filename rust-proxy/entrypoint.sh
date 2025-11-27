#!/bin/bash
set -e

echo "🔧 Initializing Secure Environment (Rust Edition)..."

# Setup permissions
rm -rf /ca/*
chown -R proxy-user:proxy-user /logs /ca

# Get proxy user ID
PROXY_UID=$(id -u proxy-user)
echo "🔎 Proxy User ID: $PROXY_UID"

# Setup Network Lock
iptables -F
iptables -t nat -F

# --- FILTER RULES ---
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow Loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -j ACCEPT

# Allow Traffic to the Proxy (58080)
iptables -A OUTPUT -p tcp --dport 58080 -j ACCEPT

# Allow Established Connections
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow Proxy User Outbound (80/443 only)
iptables -A OUTPUT -p tcp --dport 80 -m owner --uid-owner proxy-user -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner proxy-user -j ACCEPT

# Allow Custom Ports
if [ -n "$ALLOW_PORTS" ]; then
    IFS=',' read -ra PORTS <<< "$ALLOW_PORTS"
    for port in "${PORTS[@]}"; do
        echo "🔓 Opening custom port: $port"
        iptables -A OUTPUT -p tcp --dport "$port" -j ACCEPT
        iptables -A OUTPUT -p udp --dport "$port" -j ACCEPT
    done
fi

# --- NAT RULES ---
# Allow 'proxy-user' to bypass redirection
iptables -t nat -A OUTPUT -p tcp --dport 80 -m owner --uid-owner proxy-user -j ACCEPT
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner proxy-user -j ACCEPT

# Redirect everyone else to the Proxy (Port 58080)
iptables -t nat -A OUTPUT -p tcp --dport 80 -j REDIRECT --to-port 58080
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 58080

echo "🔒 Network Lock Applied (Default DENY policy active)."

# Show rules
iptables -L -n -v

# Start the Proxy
echo "🚀 Starting Secure Proxy..."
gosu proxy-user /app/secure-proxy &
PROXY_PID=$!

# Wait for CA generation
echo "⏳ Waiting for CA generation..."
while [ ! -f "/ca/certs/ca.pem" ]; do
    sleep 0.5
done

# Trust CA Certificate
echo "📜 Trusting CA Certificate..."
cp /ca/certs/ca.pem /usr/local/share/ca-certificates/secure-proxy-ca.crt
update-ca-certificates

echo "✅ Environment Ready."

# Show config
echo "📋 Current Configuration:"
cat /config/rules.json 2>/dev/null || echo "No config file found."

# Self-test
echo "🧪 Running Self-Test (curl github.com via Proxy)..."
sleep 2  # Give proxy time to fully start
http_code=$(curl -I -s -o /dev/null -w "%{http_code}" https://github.com 2>/dev/null || echo "000")

if [ "$http_code" -eq "200" ] || [ "$http_code" -eq "301" ] || [ "$http_code" -eq "302" ]; then
    echo " -> ✅ Success! (HTTP $http_code)"
else
    echo " -> ❌ Failed! (HTTP $http_code)"
fi

exec "$@"
