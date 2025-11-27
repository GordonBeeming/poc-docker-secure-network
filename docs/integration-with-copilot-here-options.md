# Integration Options: Rust Secure Proxy with copilot_here

This document outlines options for integrating the Rust-based secure network proxy from this repository into the [copilot_here](https://github.com/gordonbeeming/copilot_here) Docker images.

## Background

### What the Rust Secure Proxy Provides

- Transparent MITM HTTPS interception
- Host and path-based allow/block rules
- Traffic logging (JSON Lines format)
- iptables network lock (default deny policy)
- Dynamic CA certificate generation

### copilot_here Current Structure

copilot_here publishes multiple Docker image variants:
- `latest` - Base image (Node.js 20 + Copilot CLI)
- `dotnet` / `dotnet-8` / `dotnet-9` / `dotnet-10` - .NET variants
- `playwright` / `dotnet-playwright` - Browser automation variants

All variant images extend the base using `FROM ghcr.io/gordonbeeming/copilot_here:${BASE_IMAGE_TAG}`.

### Key Design Decision: Installed but Inactive by Default

The secure proxy will be **installed in all images** but **not activated by default**. Users opt-in via configuration at either global or repository level.

**Configuration Hierarchy:**
1. Repository-level config (`./copilot_here/network.json`) - highest priority
2. Global config (`~/.copilot_here/network.json`) - fallback
3. Built-in defaults from the image - base fallback

If repository-level config exists, global config is **completely ignored** (no merging).

---

## Integration Options

---

### Option 1: New Standalone Image Variant (e.g., `:secure`)

**Approach:** Create a new `Dockerfile.secure` that extends the base image (same pattern as `Dockerfile.dotnet`, `Dockerfile.playwright`).

```dockerfile
# Build Rust proxy in multi-stage
FROM rust:1.83-slim AS rust-builder
WORKDIR /build
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src
COPY src ./src
RUN cargo build --release

# Final image
ARG BASE_IMAGE_TAG
FROM ghcr.io/gordonbeeming/copilot_here:${BASE_IMAGE_TAG}
USER root
RUN apt-get update && apt-get install -y iptables ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=rust-builder /build/target/release/secure-proxy /app/secure-proxy
COPY opt/secure-proxy/ /opt/secure-proxy/
# Entrypoint remains the same - modified to include proxy startup
```

**Pros:**

| Category | Benefit |
|----------|---------|
| Integration | Follows existing image variant pattern (dotnet, playwright) |
| Integration | Clean separation - users opt-in by selecting image tag |
| Integration | Base image caching fully utilized |
| Integration | Independent release cycle for secure variant |
| Long-term | Easy to deprecate or evolve independently |
| Long-term | No impact on existing users |
| Long-term | Clear documentation pattern already established |

**Cons:**

| Category | Drawback |
|----------|----------|
| Integration | Requires multi-stage build (Rust compilation adds ~2-3 min) |
| Integration | Another image to maintain in CI/CD pipeline |
| Integration | Container requires `--privileged` or `--cap-add=NET_ADMIN` for iptables |

---

### Option 2: Optional Sidecar/Compose Pattern

**Approach:** Publish the secure proxy as a separate image and document a docker-compose pattern where both containers share a network namespace.

```yaml
services:
  copilot:
    image: ghcr.io/gordonbeeming/copilot_here:latest
    network_mode: "service:secure-proxy"
    depends_on: [secure-proxy]
    
  secure-proxy:
    image: ghcr.io/gordonbeeming/copilot_here:secure-proxy
    cap_add: [NET_ADMIN]
    volumes:
      - ./rules.json:/config/rules.json
```

**Pros:**

| Category | Benefit |
|----------|---------|
| Integration | Complete separation of concerns |
| Integration | Proxy can be updated independently |
| Integration | Users can mix any copilot_here variant with secure proxy |
| Long-term | Follows microservices best practices |
| Long-term | Easier to test components in isolation |
| Long-term | Proxy reusable with other projects beyond copilot_here |

**Cons:**

| Category | Drawback |
|----------|----------|
| Integration | More complex setup for users |
| Integration | Requires docker-compose or equivalent orchestration |
| Integration | Network namespace sharing can be confusing |
| Long-term | Two separate image release cycles to coordinate |
| Long-term | Documentation burden increases |
| Long-term | Debugging issues requires understanding both containers |

---

### Option 3: Build Proxy Binary into Base Image (Inactive by Default)

**Approach:** Include the compiled Rust binary in the base image but don't activate it unless environment variables are set.

```dockerfile
# In base Dockerfile - multi-stage
FROM rust:1.83-slim AS rust-builder
WORKDIR /build
RUN apt-get update && apt-get install -y pkg-config libssl-dev
COPY Cargo.toml Cargo.lock src ./
RUN cargo build --release

FROM node:20-slim
# ... existing base setup
RUN apt-get update && apt-get install -y iptables && rm -rf /var/lib/apt/lists/*
COPY --from=rust-builder /build/target/release/secure-proxy /opt/secure-proxy/secure-proxy
COPY opt/secure-proxy/ /opt/secure-proxy/
```

Activation via: config file with `enabled: true` + `--cap-add=NET_ADMIN`

**Pros:**

| Category | Benefit |
|----------|---------|
| Integration | Single image covers all use cases |
| Integration | No additional image variants to manage |
| Integration | Config-driven activation |
| Long-term | Consistent user experience |
| Long-term | Easier version coordination (always in sync) |
| Long-term | Simpler CI/CD pipeline |

**Cons:**

| Category | Drawback |
|----------|----------|
| Integration | Adds ~15-20MB to base image (Rust binary + iptables) |
| Integration | Increases base build time by ~2-3 min for Rust compilation |
| Integration | All users pay the size cost even if not using proxy |
| Long-term | Base image becomes more complex |
| Long-term | Security surface area increases for all users |

---

### Option 4: Pre-compiled Binary as Build Artifact

**Approach:** Build the Rust binary in a separate workflow, publish as a GitHub Release artifact, and download during Docker image build.

```dockerfile
ARG SECURE_PROXY_VERSION=latest
RUN curl -L https://github.com/gordonbeeming/poc-docker-secure-network/releases/download/${SECURE_PROXY_VERSION}/secure-proxy-linux-amd64 \
    -o /opt/secure-proxy/secure-proxy && chmod +x /opt/secure-proxy/secure-proxy
```

**Pros:**

| Category | Benefit |
|----------|---------|
| Integration | Docker build time significantly reduced (no Rust compilation) |
| Integration | Binary can be tested independently before Docker integration |
| Integration | Multi-arch binaries can be pre-built (amd64, arm64) |
| Long-term | Clear versioning and release notes for proxy |
| Long-term | Proxy can be used outside Docker context |
| Long-term | Faster iteration on either component |

**Cons:**

| Category | Drawback |
|----------|----------|
| Integration | Requires separate release workflow for Rust binary |
| Integration | Version coordination between image and binary |
| Integration | Additional GitHub infrastructure (Releases, artifacts) |
| Long-term | Two release processes to manage |
| Long-term | Potential version mismatch issues |
| Long-term | More complex dependency tracking |

---

### Option 5: Hybrid - Secure Variants for Each Image Type

**Approach:** Create secure variants for each existing image type.

```
copilot_here:secure               (base + proxy)
copilot_here:dotnet-secure        (dotnet + proxy)  
copilot_here:dotnet-8-secure
copilot_here:dotnet-9-secure
copilot_here:dotnet-10-secure
copilot_here:playwright-secure
copilot_here:dotnet-playwright-secure
```

**Pros:**

| Category | Benefit |
|----------|---------|
| Integration | Maximum flexibility for users |
| Integration | Matches existing image variant strategy |
| Integration | Each variant is fully self-contained |
| Long-term | Clear naming convention |
| Long-term | Users always get tested combinations |

**Cons:**

| Category | Drawback |
|----------|----------|
| Integration | Doubles the number of images (currently 7 → 14) |
| Integration | CI/CD pipeline complexity increases significantly |
| Integration | Build time roughly doubles |
| Long-term | Maintenance burden increases substantially |
| Long-term | Registry storage costs increase |
| Long-term | User confusion from many image choices |

---

## Recommendation Matrix

| Option | Complexity | Build Time Impact | User Experience | Maintenance | Recommended For |
|--------|------------|-------------------|-----------------|-------------|-----------------|
| 1. Standalone `:secure` | Medium | +3 min | Simple opt-in | Low | **Best balance** |
| 2. Sidecar Pattern | High | None | Complex | Medium | Advanced users |
| 3. Built into Base | Low | +3 min base | Seamless | Medium | Maximum simplicity |
| 4. Pre-compiled Binary | Medium | Minimal | Medium | High | Fast builds priority |
| 5. Hybrid Variants | Very High | +15 min | Complex choice | Very High | Not recommended |

---

## Implementation Notes

### Common Requirements (All Options)

1. **Single Entrypoint**: There is only ONE entrypoint (`entrypoint.sh`) that handles both proxy setup and user command execution. The entrypoint:
   - Sets up iptables network lock
   - Starts the proxy (always runs)
   - Resolves and applies network config
   - Trusts the generated CA
   - Creates the user and executes the command

2. **Capability Requirements**: All options require `NET_ADMIN` capability for iptables manipulation:
   ```bash
   docker run --cap-add=NET_ADMIN ...
   ```

3. **Configuration Mount**: Network config is mounted read-only by default for security:
   ```bash
   # Default: read-only mount (secure)
   docker run -v ./network.json:/work/.copilot_here/network.json:ro ...
   
   # With --network-config-write flag: read-write mount
   docker run -v ./network.json:/work/.copilot_here/network.json:rw ...
   ```

4. **CA Trust**: The proxy generates a CA certificate that must be trusted by the container's applications. This happens in the entrypoint via `update-ca-certificates`.

5. **Caching Considerations**: With Docker layer caching, the Rust build only re-runs when `Cargo.toml` or `src/` changes. This makes Option 1 and 3 more viable than initial build time suggests.

### Layer Caching Strategy

For options including Rust compilation, use this pattern to maximize cache hits:

```dockerfile
# Layer 1: Rust build dependencies (cached unless Dockerfile changes)
FROM rust:1.83-slim AS rust-builder
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

# Layer 2: Cargo dependencies (cached unless Cargo.toml changes)
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src

# Layer 3: Application code (only this rebuilds on code changes)
COPY src ./src
RUN cargo build --release
```

This approach means after initial build, subsequent builds only recompile if Rust source changes.

---

## Configuration System Design

### Proxy Behavior

The proxy is **always running** in all containers. The `enabled` flag controls whether rules are enforced:

| `enabled` | Behavior |
|-----------|----------|
| `false` (default) | Proxy runs in **allow-all mode** - all traffic passes through, optionally logged |
| `true` | Proxy runs in **rule-based mode** - traffic filtered by `allowed_rules` and `mode` |

This ensures consistent behavior and allows traffic monitoring even when not enforcing rules.

### Config File Structure

```json
{
  "enabled": false,
  "inherit_defaults": true,
  "mode": "monitor",
  "log_to_file": false,
  "allowed_rules": [
    {
      "host": "github.com",
      "allowed_paths": []
    },
    {
      "host": "api.github.com",
      "allowed_paths": ["/repos/", "/user"]
    }
  ]
}
```

### Config Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | `false` | When `false`: allow-all mode. When `true`: enforce `allowed_rules` |
| `inherit_defaults` | bool | `true` | Merge with built-in default rules from the image |
| `mode` | string | `"monitor"` | `"monitor"` (log only, don't block) or `"enforce"` (actually block) |
| `log_to_file` | bool | `false` | Write traffic to `/logs/traffic.jsonl`. **Forced `true` when `mode: "monitor"`** |
| `allowed_rules` | array | `[]` | User-defined host/path rules (only used when `enabled: true`) |

### Mode Behavior Matrix

| `enabled` | `mode` | `log_to_file` | Effective Behavior |
|-----------|--------|---------------|-------------------|
| `false` | - | `false` | Allow all, no logging |
| `false` | - | `true` | Allow all, log all traffic |
| `true` | `monitor` | (forced `true`) | Apply rules but only log violations, don't block |
| `true` | `enforce` | `false` | Apply rules, block violations, no logging |
| `true` | `enforce` | `true` | Apply rules, block violations, log all traffic |

### Log File Security

The traffic log file (`/logs/traffic.jsonl`) has restricted permissions:

```bash
# File ownership and permissions
chown proxy-user:proxy-user /logs/traffic.jsonl
chmod 600 /logs/traffic.jsonl

# Directory permissions
chown proxy-user:proxy-user /logs
chmod 755 /logs
```

- **Only `proxy-user` can write** to the log file
- **Other users cannot modify** the log (prevents tampering with audit trail)
- **Other users can read** the log directory listing but not write
- The `appuser` running commands can read logs but cannot alter them

### Config Resolution Logic

```
1. Check for ./copilot_here/network.json (repo-level)
   └─ If exists: Use ONLY this config (ignore global)
   
2. Else check for ~/.copilot_here/network.json (global)
   └─ If exists: Use this config
   
3. Else use built-in defaults:
   └─ enabled: false
   └─ inherit_defaults: true
   └─ mode: monitor
   └─ log_to_file: false
   └─ allowed_rules: []
```

### The `inherit_defaults` Flag

When `inherit_defaults: true`:
- The user's `allowed_rules` are **merged** with built-in defaults from the image
- Built-in defaults are maintained by the copilot_here project
- Updates to default allowed hosts (e.g., new GitHub endpoints) flow automatically

When `inherit_defaults: false`:
- **Only** the user's `allowed_rules` are used
- User has complete control over allowed hosts
- Must manually update if upstream endpoints change

**Built-in defaults example** (shipped with image):
```json
{
  "allowed_rules": [
    { "host": "github.com" },
    { "host": "api.github.com" },
    { "host": "copilot-proxy.githubusercontent.com" },
    { "host": "ghcr.io" },
    { "host": "registry.npmjs.org" },
    { "host": "pypi.org" }
  ]
}
```

---

## CLI Commands

### Network Configuration Management

```
NETWORK CONFIGURATION:
  --network-init              Create network config in current repo (.copilot_here/network.json)
  --network-init-global       Create network config globally (~/.copilot_here/network.json)
  --network-show              Show effective network config (resolved from repo/global/defaults)
  --network-enable            Enable secure proxy in current config scope
  --network-disable           Disable secure proxy in current config scope
  --network-enable-global     Enable secure proxy globally
  --network-disable-global    Disable secure proxy globally
  --network-config-write      Allow writing to network config inside container (default: readonly)
```

### Config File Mount Behavior

By default, network config files are mounted **read-only** inside the container:

| Flag | Mount Behavior | Use Case |
|------|----------------|----------|
| (default) | Config mounted as `:ro` | Production, security-focused |
| `--network-config-write` | Config mounted as `:rw` | Development, testing config changes |

**Why read-only by default:**
- Prevents processes inside container from modifying security rules
- Ensures config integrity even if container is compromised
- Config changes require explicit intent from outside the container

**When to use `--network-config-write`:**
- Testing different rule configurations interactively
- Development workflows where you want to tweak rules without restarting
- Debugging proxy behavior

### Example Usage

```bash
# Initialize repo-level config (creates .copilot_here/network.json)
copilot_here --network-init

# Initialize global config
copilot_here --network-init-global

# Enable proxy for this repo only
copilot_here --network-enable

# Show what config will be used
copilot_here --network-show

# Enable globally (all repos without local config)
copilot_here --network-enable-global

# Allow config modification inside container (development/testing)
copilot_here --network-config-write
```

### Config Init Templates

**`--network-init` creates:**
```json
{
  "enabled": false,
  "inherit_defaults": true,
  "mode": "monitor",
  "log_to_file": false,
  "allowed_rules": []
}
```

**`--network-init --no-inherit` creates:**
```json
{
  "enabled": false,
  "inherit_defaults": false,
  "mode": "monitor",
  "log_to_file": false,
  "allowed_rules": [
    { "host": "github.com" },
    { "host": "api.github.com" },
    { "host": "copilot-proxy.githubusercontent.com" }
  ]
}
```

### Script Implementation for Config Mount

The copilot_here.sh/ps1 scripts need to handle the mount mode:

```bash
# In copilot_here.sh

# Default to read-only
NETWORK_CONFIG_MOUNT_MODE=":ro"

# Check for --network-config-write flag
for arg in "$@"; do
    case $arg in
        --network-config-write)
            NETWORK_CONFIG_MOUNT_MODE=":rw"
            shift
            ;;
    esac
done

# Build mount arguments
NETWORK_MOUNTS=""

# Check for repo-level config
if [ -f "./.copilot_here/network.json" ]; then
    NETWORK_MOUNTS="-v $(pwd)/.copilot_here/network.json:/work/.copilot_here/network.json${NETWORK_CONFIG_MOUNT_MODE}"
fi

# Check for global config (only if no repo config)
if [ -z "$NETWORK_MOUNTS" ] && [ -f "$HOME/.copilot_here/network.json" ]; then
    NETWORK_MOUNTS="-v $HOME/.copilot_here/network.json:/home/appuser/.copilot_here/network.json${NETWORK_CONFIG_MOUNT_MODE}"
fi

# Run docker with network mounts
docker run \
    --cap-add=NET_ADMIN \
    $NETWORK_MOUNTS \
    ... # other args
```

---

## Unified Entrypoint

There is a **single entrypoint** (`entrypoint.sh`) that handles everything: proxy setup, config resolution, and user command execution. The proxy **always runs** - config only controls whether rules are enforced.

```bash
#!/bin/bash
set -e

# =============================================================================
# PHASE 1: Secure Proxy Setup (runs as root)
# =============================================================================

# --- Setup log directory with secure permissions ---
mkdir -p /logs
chown proxy-user:proxy-user /logs
chmod 755 /logs

# Pre-create log file with secure permissions (only proxy-user can write)
touch /logs/traffic.jsonl
chown proxy-user:proxy-user /logs/traffic.jsonl
chmod 600 /logs/traffic.jsonl

# --- Config Resolution ---
NETWORK_CONFIG=""
REPO_CONFIG="/work/.copilot_here/network.json"
GLOBAL_CONFIG="/home/appuser/.copilot_here/network.json"
DEFAULTS_CONFIG="/opt/secure-proxy/defaults.json"
ALLOW_ALL_CONFIG="/opt/secure-proxy/allow-all.json"

if [ -f "$REPO_CONFIG" ]; then
    NETWORK_CONFIG="$REPO_CONFIG"
    echo "[Network] Using repo config: $REPO_CONFIG"
elif [ -f "$GLOBAL_CONFIG" ]; then
    NETWORK_CONFIG="$GLOBAL_CONFIG"
    echo "[Network] Using global config: $GLOBAL_CONFIG"
else
    NETWORK_CONFIG=""
    echo "[Network] No config found, using allow-all defaults"
fi

# --- Build final proxy config ---
if [ -n "$NETWORK_CONFIG" ]; then
    RULES_ENABLED=$(jq -r '.enabled // false' "$NETWORK_CONFIG")
    MODE=$(jq -r '.mode // "monitor"' "$NETWORK_CONFIG")
    LOG_TO_FILE=$(jq -r '.log_to_file // false' "$NETWORK_CONFIG")
    
    # Force log_to_file=true when mode=monitor
    if [ "$MODE" = "monitor" ]; then
        LOG_TO_FILE="true"
    fi
else
    RULES_ENABLED="false"
    MODE="monitor"
    LOG_TO_FILE="false"
fi

if [ "$RULES_ENABLED" = "true" ]; then
    echo "[Network] Rules ENABLED (mode: $MODE)"
    
    # Merge config with defaults if inherit_defaults is true
    INHERIT=$(jq -r '.inherit_defaults // true' "$NETWORK_CONFIG")
    if [ "$INHERIT" = "true" ]; then
        # Merge user rules with defaults, set mode and log_to_file
        jq -s --arg mode "$MODE" --argjson log "$LOG_TO_FILE" \
            '.[0] * {mode: $mode, log_to_file: $log, allowed_rules: (.[1].allowed_rules + .[0].allowed_rules | unique_by(.host))}' \
            "$NETWORK_CONFIG" "$DEFAULTS_CONFIG" > /config/rules.json
    else
        # Use user config only, override mode and log_to_file
        jq --arg mode "$MODE" --argjson log "$LOG_TO_FILE" \
            '. + {mode: $mode, log_to_file: $log}' \
            "$NETWORK_CONFIG" > /config/rules.json
    fi
else
    echo "[Network] Rules DISABLED (allow-all mode, log_to_file: $LOG_TO_FILE)"
    # Use allow-all config
    jq --argjson log "$LOG_TO_FILE" '. + {log_to_file: $log}' \
        "$ALLOW_ALL_CONFIG" > /config/rules.json
fi

# --- Setup iptables network lock ---
iptables -F
iptables -t nat -F
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback and established connections
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow proxy-user outbound on 80/443
iptables -A OUTPUT -p tcp --dport 80 -m owner --uid-owner proxy-user -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner proxy-user -j ACCEPT

# Redirect all other traffic to proxy
iptables -t nat -A OUTPUT -p tcp --dport 80 -m owner ! --uid-owner proxy-user -j REDIRECT --to-port 58080
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner ! --uid-owner proxy-user -j REDIRECT --to-port 58080

# --- Start proxy (ALWAYS runs) ---
echo "[Network] Starting secure proxy..."
gosu proxy-user /app/secure-proxy &
PROXY_PID=$!

# Wait for CA generation
while [ ! -f "/ca/certs/ca.pem" ]; do sleep 0.5; done

# Trust CA certificate
cp /ca/certs/ca.pem /usr/local/share/ca-certificates/secure-proxy-ca.crt
update-ca-certificates

echo "[Network] Proxy ready (PID: $PROXY_PID)"

# =============================================================================
# PHASE 2: User Setup & Command Execution (existing entrypoint logic)
# =============================================================================

# Get the user and group IDs from environment variables, default to 1000 if not set.
USER_ID=${PUID:-1000}
GROUP_ID=${PGID:-1000}

# Create a group and user with the specified IDs.
groupadd --gid $GROUP_ID appuser_group >/dev/null 2>&1 || true
useradd --uid $USER_ID --gid $GROUP_ID --shell /bin/bash --create-home appuser >/dev/null 2>&1 || true

# Verify the user was created successfully
if ! id appuser >/dev/null 2>&1; then
    echo "Warning: Failed to create appuser, running as root" >&2
    mkdir -p /home/appuser/.copilot
    exec "$@"
fi

# Set up the .copilot directory with correct ownership
mkdir -p /home/appuser/.copilot
chown -R $USER_ID:$GROUP_ID /home/appuser/.copilot

# Switch to the new user and execute the command passed to the script.
exec gosu appuser "$@"
```

### Allow-All Config File

The `/opt/secure-proxy/allow-all.json` file used when rules are disabled:

```json
{
  "mode": "allow-all",
  "log_to_file": false,
  "allowed_rules": []
}
```

The proxy recognizes `mode: "allow-all"` as a special mode that bypasses all rule checking.

---

## Updated Recommendation

Given the "always running, config-driven rules" requirement, **Option 3 (Built into Base Image)** is the clear choice:

| Consideration | Impact |
|---------------|--------|
| Proxy always running | ✅ Consistent network path for all traffic |
| Allow-all by default | ✅ Zero impact on existing users |
| Config-driven rules | ✅ No image tag selection required |
| Secure log file | ✅ Tamper-proof audit trail when enabled |
| Layer caching | ✅ Rust binary cached, only rebuilds on changes |
| Single entrypoint | ✅ One place to maintain config resolution logic |

**Revised Recommendation:** **Option 3** with the configuration system described above.

### Updated Pros for Option 3

| Category | Benefit |
|----------|---------|
| Integration | Single image covers all use cases |
| Integration | Config-driven - no image tag selection |
| Integration | Works with all existing variants (dotnet, playwright) automatically |
| Integration | Always-running proxy provides consistent behavior |
| Long-term | Consistent user experience |
| Long-term | Easier version coordination (always in sync) |
| Long-term | `inherit_defaults` enables push updates for allowed hosts |
| Long-term | Simpler CI/CD pipeline |
| Long-term | Secure logging protects audit integrity |

### Updated Cons for Option 3

| Category | Drawback |
|----------|----------|
| Integration | Adds ~15-20MB to all images |
| Integration | Increases base build time by ~2-3 min |
| Integration | Requires `--cap-add=NET_ADMIN` when enabled |
| Long-term | Base image becomes more complex |
| Long-term | Must ship jq or similar for config merging |

---

## Next Steps

1. Choose preferred option based on use case priorities
2. Implement config schema and CLI commands in copilot_here scripts
3. Prototype the entrypoint integration with config resolution
4. Define built-in defaults list (allowed hosts for Copilot, npm, etc.)
5. Test with real copilot_here workflows
6. Document the chosen approach in copilot_here repo
7. Add CI/CD pipeline steps for Rust binary compilation
