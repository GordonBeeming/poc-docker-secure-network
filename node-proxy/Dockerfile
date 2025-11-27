FROM node:20-slim

# 1. Install System Dependencies
RUN apt-get update && apt-get install -y \
  iptables \
  ca-certificates \
  curl \
  gosu \
  && rm -rf /var/lib/apt/lists/*

# 2. Create a Dedicated Proxy User
# -r: system account
# -s /bin/false: no login shell (security)
# -d /app: home directory set to app (optional, but good practice)
RUN groupadd -r copilot-proxy && \
  useradd -r -g copilot-proxy -s /bin/false -d /app copilot-proxy

# 3. Setup Proxy App
WORKDIR /app
RUN npm install @bjowes/http-mitm-proxy && npm list @bjowes/http-mitm-proxy

# Patch http-mitm-proxy for OpenSSL 3 compatibility
# The issue is that https.createServer() needs explicit TLS options for Node 20+
RUN sed -i "s/var httpsServer = https.createServer(options);/options.minVersion = 'TLSv1.2'; options.ciphers = 'DEFAULT:@SECLEVEL=0'; var httpsServer = https.createServer(options);/" /app/node_modules/@bjowes/http-mitm-proxy/lib/proxy.js

# 4. Copy our scripts
COPY logic.js /app/logic.js
COPY shim.js /app/shim.js
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 5. Prepare Directories & Permissions
# We give ownership to our new 'copilot-proxy' user
RUN mkdir -p /config /logs /ca && \
  chown -R copilot-proxy:copilot-proxy /app /config /logs /ca

# 6. Set Entrypoint
ENTRYPOINT ["/entrypoint.sh"]

CMD ["bash"]