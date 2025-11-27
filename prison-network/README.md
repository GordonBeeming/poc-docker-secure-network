# Prison Network - Secure Network Isolation

This example implements **Option 6** from the integration options document: a dual-network prison setup where the app container is completely isolated and can only access the internet through the proxy.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Docker Environment                           │
│                                                                   │
│  ┌──────────────────────┐      ┌──────────────────────┐         │
│  │   Prison Network     │      │   Bridge Network     │         │
│  │   (internal: true)   │      │   (internet access)  │         │
│  │                      │      │                      │         │
│  │  ┌─────────────┐     │      │                      │         │
│  │  │  Copilot    │     │      │                      │         │
│  │  │  Container  │─────┼──────┼──▶  ❌ No Route      │         │
│  │  │             │     │      │                      │         │
│  │  └──────┬──────┘     │      │                      │         │
│  │         │            │      │                      │         │
│  │         │HTTP_PROXY  │      │                      │         │
│  │         ▼            │      │                      │         │
│  │  ┌─────────────┐     │      │                      │         │
│  │  │  Proxy      │─────┼──────┼──▶  ✅ Internet     │         │
│  │  │  Container  │     │      │                      │         │
│  │  └─────────────┘     │      │                      │         │
│  │                      │      │                      │         │
│  └──────────────────────┘      └──────────────────────┘         │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

## Key Security Properties

- **Network-level isolation**: The copilot container is on an `internal: true` network with no route to the internet
- **No NET_ADMIN required**: Unlike iptables-based approaches, this uses Docker networking
- **Proxy is the only way out**: If an app ignores `HTTP_PROXY`, the request fails completely
- **MITM inspection**: All HTTPS traffic is decrypted, inspected, and re-encrypted
- **Uses copilot_here**: Built on the official copilot_here base image

## Usage

### Start a new session

```bash
./run.sh
```

This creates a unique session with:
- `prison-{session_id}-proxy` - The proxy container
- `prison-{session_id}-app` - The copilot container

The GitHub Copilot CLI launches automatically. When you exit, containers are cleaned up.

### Run with a specific session ID

```bash
./run.sh my-test-session
```

### View traffic log

All network traffic is logged in monitor mode:

```bash
cat logs/traffic.jsonl
```

### View proxy logs

```bash
docker logs -f prison-{session_id}-proxy
```

## Configuration

Edit `config/rules.json` to control allowed hosts and paths:

```json
{
  "mode": "monitor",
  "allowed_rules": [
    { "host": "github.com", "allowed_paths": [] },
    { "host": "api.github.com", "allowed_paths": [] }
  ]
}
```

### Modes

- `monitor` - Log all traffic, allow everything (current default for testing)
- `enforce` - Block requests not matching rules

## Files

- `run.sh` - Main script to start a new session
- `docker-compose.yml` - Container orchestration
- `config/rules.json` - Allow/block rules (monitor mode)
- `logs/traffic.jsonl` - Traffic log
- `src/main.rs` - Rust proxy implementation
- `Dockerfile.proxy` - Proxy container
- `Dockerfile.app` - Copilot container (based on copilot_here)
