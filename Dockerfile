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
RUN npm install http-mitm-proxy

# 4. Copy our scripts
COPY proxy.js /app/proxy.js
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 5. Prepare Directories & Permissions
# We give ownership to our new 'copilot-proxy' user
RUN mkdir -p /config /logs /ca && \
  chown -R copilot-proxy:copilot-proxy /app /config /logs /ca

# 6. Set Entrypoint
ENTRYPOINT ["/entrypoint.sh"]

CMD ["bash"]