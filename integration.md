# Integration Plan: Airlock Proxy into copilot_here

This document outlines the step-by-step integration of the **airlock** secure proxy into the **copilot_here** project.

## Overview

The airlock proxy provides network isolation and traffic filtering for Docker containers:
- **Isolated network**: App container cannot reach the internet directly
- **Proxy-based egress**: All HTTPS traffic goes through a MITM proxy
- **Allow/Block rules**: Host and path-level filtering via `rules.json`
- **Dynamic CA**: Generates certificates on-the-fly for HTTPS interception

## New CLI Arguments

Two new flags will be added to `copilot_here` and `copilot_yolo`:

| Flag | Description |
|------|-------------|
| `--enable-network-proxy` | Enable network proxy with project-local rules (`.copilot_here/network.json`) |
| `--enable-global-network-proxy` | Enable network proxy with global rules (`~/.config/copilot_here/network.json`) |

When either flag is used, the container runs in an isolated Docker network with egress only through the secure proxy.

---

## Integration Steps

### Phase 1: Proxy Container Infrastructure

#### Step 1.1: Add Proxy Dockerfile to copilot_here ✅ COMPLETED (2025-11-27)

Copy and adapt `Dockerfile.proxy` to the copilot_here repository.

**Files added:**
- `Dockerfile.proxy` - Multi-stage Rust build for the proxy binary

**Changes made:**
- Updated COPY paths to reference `proxy/` subdirectory
- Added Cargo.lock to build context

**Tests:**
- [ ] Dockerfile builds successfully on both amd64 and arm64
- [ ] Proxy binary starts and listens on port 58080

---

#### Step 1.2: Add Proxy Rust Source ✅ COMPLETED (2025-11-27)

Copy the Rust proxy source code to copilot_here.

**Files added:**
- `proxy/Cargo.toml`
- `proxy/Cargo.lock`
- `proxy/src/main.rs`

**Tests:**
- [ ] `cargo build --release` succeeds
- [ ] Proxy starts with default (monitor) mode
- [ ] Proxy starts with enforce mode and rules.json

---

#### Step 1.3: Add Proxy Entrypoint Script ✅ COMPLETED (2025-11-27)

**Files added:**
- `proxy-entrypoint.sh`

**Tests:**
- [ ] Entrypoint initializes CA directory
- [ ] Entrypoint starts proxy with correct permissions

---

### Phase 2: App Container Modifications

#### Step 2.1: Create Airlock-Mode App Entrypoint ✅ COMPLETED (2025-11-27)

Create a modified entrypoint that:
1. Waits for proxy CA certificate
2. Installs CA into system trust store
3. Sets `NODE_EXTRA_CA_CERTS` environment variable
4. Chains to original entrypoint

**Files added:**
- `entrypoint-airlock.sh` - Isolated network entrypoint wrapper

**Tests:**
- [ ] Entrypoint waits for `/ca/certs/ca.pem`
- [ ] CA certificate is installed in container trust store
- [ ] `NODE_EXTRA_CA_CERTS` environment variable is set
- [ ] Original entrypoint is called correctly

---

#### Step 2.2: Modify Base Dockerfile for Airlock Mode Support ✅ COMPLETED (2025-11-27)

Update the base `Dockerfile` to include `gosu` (already exists) and copy the airlock entrypoint.

**Files modified:**
- `Dockerfile` - Added `COPY entrypoint-airlock.sh` and made it executable

**Tests:**
- [x] `gosu` command is available in container (already was)
- [x] Original entrypoint is accessible at `/usr/local/bin/entrypoint.sh`
- [x] `entrypoint-airlock.sh` is copied to `/usr/local/bin/`

---

### Phase 3: Shell Script Integration

#### Step 3.1: Add Network Proxy Flags to Argument Parser ✅ COMPLETED (2025-11-27)

Update `copilot_here.sh` to parse the new flags:
- `--enable-network-proxy`
- `--enable-global-network-proxy`

**Files modified:**
- `copilot_here.sh` - Added flag parsing in both `copilot_here` and `copilot_yolo` functions
- `copilot_here.ps1` - Added `-EnableNetworkProxy` and `-EnableGlobalNetworkProxy` parameters

**Tests:**
- [x] `--enable-network-proxy` flag is recognized
- [x] `--enable-global-network-proxy` flag is recognized
- [x] Flags are mutually exclusive (error if both provided)
- [x] Help text includes new flags

---

#### Step 3.2: Add Default Rules Configuration ✅ COMPLETED (2025-11-27)

Create default rules.json and configuration loading logic.

**Files added to repository root:**
- `default-network-rules.json` - Default allow rules for Copilot API (downloaded during `--update-scripts`)

**Default rules content (in repo, downloaded to `~/.config/copilot_here/`):**
```json
{
  "allowed_rules": [
    {
      "host": "api.github.com",
      "allowed_paths": ["/user", "/graphql"]
    },
    {
      "host": "api.individual.githubcopilot.com",
      "allowed_paths": ["/models", "/mcp/readonly", "/chat/completions"]
    }
  ]
}
```

**User config template (generated on first use):**
```json
{
  "inherit_default_rules": true,
  "mode": "enforce",
  "allowed_rules": [...]
}
```

**Files modified:**
- `copilot_here.sh` - Added `__copilot_ensure_network_config` helper, updated `__copilot_update_scripts` to download network rules
- `copilot_here.ps1` - Added `Ensure-NetworkConfig` function, updated `Update-CopilotScripts` to download network rules
- `devtest.sh` - Updated to copy `default-network-rules.json` during local testing

**Tests:**
- [x] Default rules file exists in repo
- [x] User is prompted for enforce/monitor mode on first use
- [x] Generated config has `inherit_default_rules: true` explicitly visible
- [x] `--update-scripts` downloads and caches `default-network-rules.json`
- [x] Existing config is reused without prompting

---

#### Step 3.3: Implement Docker Compose Mode ✅ COMPLETED (2025-11-27)

When network proxy is enabled, switch from `docker run` to `docker compose`:

**Logic implemented:**
1. Generate temporary `docker-compose.yml` from template
2. Substitute environment variables and paths
3. Run `docker compose up`
4. Cleanup on exit via trap

**Files modified:**
- `copilot_here.sh` - Added `__copilot_run_airlock` helper function
- `copilot_here.sh` - Updated network proxy handling to call isolated run
- `devtest.sh` - Updated to copy compose template

**Files added:**
- `docker-compose.airlock.yml.template` - Template for airlock compose

**Key features:**
- Project name matches terminal title format: `{dirname}-{session_id}`
- Uses `docker compose up --abort-on-container-exit --attach app`
- Cleanup removes containers, volumes, and temp compose file
- Terminal title shows `[proxy]` suffix in airlock mode

**Tests:**
- [ ] Compose file is generated correctly
- [ ] Proxy container starts before app container
- [ ] App container can reach proxy
- [ ] App container cannot reach internet directly
- [ ] Cleanup removes temporary compose file

---

#### Step 3.4: Add Configuration Management Commands

Add commands to manage proxy rules:

| Command | Description |
|---------|-------------|
| `--show-proxy-rules` | Display current proxy rules |
| `--edit-proxy-rules` | Open local rules in $EDITOR |
| `--edit-global-proxy-rules` | Open global rules in $EDITOR |

**Files to modify:**
- `copilot_here.sh` - Add configuration management commands

**Tests:**
- [ ] `--show-proxy-rules` displays merged rules
- [ ] `--edit-proxy-rules` opens local config
- [ ] `--edit-global-proxy-rules` opens global config

---

### Phase 4: CI/CD Integration

#### Step 4.1: Add Proxy Image to Build Pipeline ✅ COMPLETED (2025-11-27)

Updated GitHub Actions workflow to build and publish the proxy image.

**Files modified:**
- `.github/workflows/publish.yml` - Added proxy image build steps (Step 11a/11b)

**New image tags:**
- `ghcr.io/gordonbeeming/copilot_here:proxy`
- `ghcr.io/gordonbeeming/copilot_here:proxy-sha-<sha>`

**Tests:**
- [x] Workflow includes proxy image build for amd64 and arm64
- [x] Proxy image is pushed to GHCR
- [x] Workflow summary includes proxy image

---

#### Step 4.2: Add Integration Tests for Airlock Mode

Add tests to verify airlock functionality.

**Files to add:**
- `tests/integration/test_airlock.sh` - Isolated network integration tests

**Test cases:**
- [ ] Proxy starts and becomes healthy
- [ ] App can reach allowed hosts
- [ ] App is blocked from non-allowed hosts
- [ ] CA certificate is properly trusted
- [ ] Traffic is logged correctly

---

### Phase 5: Documentation

#### Step 5.1: Update README

Add documentation for the network proxy feature.

**Files to modify:**
- `README.md` - Add network proxy section

**Content to add:**
- Feature description
- Usage examples
- Configuration format
- Security considerations

---

#### Step 5.2: Add Detailed Documentation

**Files to add:**
- `docs/network-proxy.md` - Detailed network proxy documentation

**Content:**
- Architecture diagram
- Configuration reference
- Troubleshooting guide
- Performance considerations

---

## Configuration File Locations

| Type | Path | Priority |
|------|------|----------|
| Local | `.copilot_here/network.json` | Highest (overrides global) |
| Global | `~/.config/copilot_here/network.json` | Lower |
| Cached Defaults | `~/.config/copilot_here/default-network-rules.json` | Used when `inherit_default_rules: true` |

---

## Default Rules Distribution

Default network rules are distributed via GitHub (same as `copilot_here.sh`/`copilot_here.ps1`):

**Repository location:**
- `https://raw.githubusercontent.com/GordonBeeming/copilot_here/main/default-network-rules.json`

**Local cache:**
- `~/.config/copilot_here/default-network-rules.json`

### Update Mechanism

The `--update-scripts` command will:
1. Download latest `copilot_here.sh` / `copilot_here.ps1`
2. Download latest `default-network-rules.json`
3. Save defaults to `~/.config/copilot_here/default-network-rules.json`

This ensures:
- Users get updated Copilot API endpoints without waiting for Docker image rebuild
- Defaults are available even before first proxy run
- Offline usage works with cached defaults

---

## Configuration Schema

The `network.json` file supports inheriting default rules from the proxy image:

```json
{
  "inherit_default_rules": true,
  "mode": "enforce",
  "allowed_rules": [
    {
      "host": "my-custom-api.example.com",
      "allowed_paths": ["/api/v1"]
    }
  ]
}
```

### Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `inherit_default_rules` | boolean | `true` | When `true`, merges user rules with built-in default rules for Copilot API endpoints. This ensures users automatically get updates when Copilot CLI changes its endpoints. |
| `mode` | string | `"enforce"` | `"enforce"` blocks non-matching requests; `"monitor"` logs but allows all traffic. |
| `allowed_rules` | array | `[]` | Additional host/path rules to allow beyond the defaults. |

### How Inheritance Works

When `inherit_default_rules: true`:
1. Proxy loads built-in default rules (maintained in the proxy image)
2. User's `allowed_rules` are merged/appended
3. User rules can extend but not remove default rules

This means:
- **Updates are automatic**: When we update the proxy image with new Copilot endpoints, users get them on next `docker pull`
- **User customizations are preserved**: Custom rules in `network.json` are always applied
- **Explicit opt-out available**: Set `inherit_default_rules: false` to fully control the allowlist

### Example: Generated Config File

When a user runs `--edit-proxy-rules` for the first time, we generate:

```json
{
  "inherit_default_rules": true,
  "mode": "enforce",
  "allowed_rules": [
    // Add your custom rules here, e.g.:
    // { "host": "api.example.com", "allowed_paths": ["/v1"] }
  ]
}
```

The `inherit_default_rules: true` is **explicitly visible** in the config so users know it exists and can disable it if needed.

---

## Progress Summary

| Phase | Step | Status | Date |
|-------|------|--------|------|
| 1 | 1.1 Proxy Dockerfile | ✅ Done | 2025-11-27 |
| 1 | 1.2 Proxy Rust Source | ✅ Done | 2025-11-27 |
| 1 | 1.3 Proxy Entrypoint | ✅ Done | 2025-11-27 |
| 2 | 2.1 Airlock-Mode Entrypoint | ✅ Done | 2025-11-27 |
| 2 | 2.2 Base Dockerfile Updates | ✅ Done | 2025-11-27 |
| 3 | 3.1 CLI Flag Parsing | ✅ Done | 2025-11-27 |
| 3 | 3.2 Default Rules Config | ✅ Done | 2025-11-27 |
| 3 | 3.3 Docker Compose Mode | ✅ Done | 2025-11-27 |
| 3 | 3.4 Config Management Commands | ⏳ Pending | |
| 4 | 4.1 CI/CD Pipeline | ✅ Done | 2025-11-27 |
| 4 | 4.2 Integration Tests | ⏳ Pending | |
| 5 | 5.1 README Updates | ⏳ Pending | |
| 5 | 5.2 Detailed Documentation | ⏳ Pending | |

---

## Implementation Order

Recommended order to implement:

1. ~~**Phase 3.1** - Shell script flag parsing~~ ✅
2. ~~**Phase 3.2** - Default rules configuration~~ ✅
3. ~~**Phase 1.2** - Proxy source code (can test standalone)~~ ✅
4. ~~**Phase 1.1** - Proxy Dockerfile (build the proxy)~~ ✅
5. ~~**Phase 1.3** - Proxy entrypoint~~ ✅
6. ~~**Phase 2.1** - Isolated mode app entrypoint~~ ✅
7. **Phase 2.2** - Base Dockerfile updates
8. ~~**Phase 3.3** - Docker Compose integration~~ ✅
9. **Phase 4.1** - CI/CD for proxy image
10. **Phase 3.4** - Configuration management commands
11. **Phase 4.2** - Integration tests
12. **Phase 5** - Documentation

---

## Rollback Plan

If issues arise:
1. Flags are opt-in, so existing behavior is unaffected
2. Can disable proxy image publishing in CI without affecting other images
3. Shell script changes are isolated to new code paths

---

## Open Questions

- [ ] Should we support multiple config files merged together?
- [ ] How should we handle proxy logs (mount to host, or container-only)?
- [ ] Should monitor mode be the default, or enforce mode?
- [ ] Do we need a `--proxy-rules-file <path>` flag for one-off custom rules?
