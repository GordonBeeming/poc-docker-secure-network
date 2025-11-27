# Use copilot_here base image
FROM ghcr.io/gordonbeeming/copilot_here:latest

USER root

# Install gosu for privilege dropping (may already exist)
RUN apt-get update && apt-get install -y gosu && rm -rf /var/lib/apt/lists/* || true

# Create CA directory
RUN mkdir -p /ca

# Preserve the original entrypoint
RUN cp /usr/local/bin/entrypoint.sh /usr/local/bin/entrypoint-original.sh

COPY app-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run entrypoint as root (it will chain to original entrypoint)
ENTRYPOINT ["entrypoint.sh"]
CMD ["copilot", "--banner"]
