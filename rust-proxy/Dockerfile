# Build stage
FROM rust:1.83-slim AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy source
COPY Cargo.toml Cargo.toml
COPY src src

# Build release binary
RUN cargo build --release

# Runtime stage
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    iptables \
    ca-certificates \
    curl \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Create proxy user
RUN groupadd -r proxy-user && \
    useradd -r -g proxy-user -s /bin/false -d /app proxy-user

# Copy binary from builder
COPY --from=builder /build/target/release/secure-proxy /app/secure-proxy

# Create directories
RUN mkdir -p /config /logs /ca && \
    chown -R proxy-user:proxy-user /app /config /logs /ca

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
