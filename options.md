# Network Proxy Implementation Options

*Created: 2025-11-26*

This document captures the technology options considered for implementing a transparent HTTPS MITM proxy for network security/monitoring.

## Background

The original Node.js implementation using `http-mitm-proxy` failed due to OpenSSL 3 compatibility issues. The library's certificate generation (via `node-forge`) produces certificates that modern OpenSSL 3 (used in Node 20+) rejects with `ERR_SSL_NO_SUITABLE_SIGNATURE_ALGORITHM`.

---

## Option 1: Node.js with `http-mitm-proxy`

**Status:** ❌ Abandoned (OpenSSL 3 incompatibility)

### Pros
- Code was already written
- JavaScript is widely known
- Easy to modify logic
- Large ecosystem of npm packages

### Cons
- `http-mitm-proxy` has fundamental OpenSSL 3 compatibility issues
- The library uses `node-forge` which generates certificates that modern OpenSSL rejects
- No active maintenance addressing this issue
- Multiple workaround attempts failed (SECLEVEL=0, legacy provider, library patches, etc.)

---

## Option 2: Rust with `hudsucker`

**Status:** ✅ Selected

### Pros
- Native performance, small binary (~5-10MB)
- Modern TLS handling via `rustls` or native OpenSSL bindings
- Memory safe without garbage collection
- Single static binary - easy to deploy in containers
- `hudsucker` is actively maintained and designed for MITM proxying
- No runtime dependencies
- Once working, extremely stable

### Cons
- Steeper learning curve than JavaScript
- Rust syntax is more complex (lifetimes, borrowing, Result types)
- Async Rust has a learning curve
- Compile times are slower than interpreted languages
- Smaller ecosystem than Node.js (but sufficient for this use case)

### Key Libraries
- `hudsucker` - MITM proxy framework
- `rustls` or `openssl` - TLS handling
- `rcgen` - Certificate generation
- `tokio` - Async runtime
- `serde` - JSON parsing for config

---

## Option 3: Go with `goproxy`

**Status:** Considered but not selected

### Pros
- Single static binary
- `goproxy` is mature and actively maintained
- Go's `crypto/tls` handles modern TLS correctly
- Good performance
- Relatively easy to learn
- Fast compile times
- Good concurrency primitives

### Cons
- Rewrite required
- Need to learn Go if unfamiliar
- Slightly larger binaries than Rust
- Less type safety than Rust

### Key Libraries
- `goproxy` - HTTP/HTTPS proxy with MITM support
- Standard library `crypto/tls` - TLS handling

---

## Option 4: Python with `mitmproxy`

**Status:** Considered but not selected

### Pros
- `mitmproxy` is the gold standard for MITM proxies
- Extremely well-maintained, handles all modern TLS edge cases
- Scriptable with Python - very easy to customize
- Excellent documentation
- Already solves all the certificate generation issues
- Great for prototyping and debugging

### Cons
- Heavier runtime (Python interpreter + dependencies)
- Slower than compiled languages
- Requires Python environment in container
- Larger container image size
- Dependency management with pip

### Key Libraries
- `mitmproxy` - Full-featured MITM proxy

---

## Option 5: C# (.NET) with `Titanium-Web-Proxy`

**Status:** Considered but not selected

### Pros
- Strong TLS/SSL support via .NET's `SslStream`
- Cross-platform with .NET 8+
- Good performance
- `Titanium-Web-Proxy` is mature and feature-rich
- Native AOT compilation available for smaller binaries
- Strong typing and good tooling

### Cons
- Larger runtime unless using Native AOT
- Rewrite required
- Native AOT has some limitations
- .NET ecosystem is heavier than Go/Rust

### Key Libraries
- `Titanium-Web-Proxy` - MITM proxy library
- `System.Security.Cryptography` - Certificate generation

---

## Comparison Matrix

| Aspect | Node.js | Rust | Go | Python | C# |
|--------|---------|------|-----|--------|-----|
| Binary Size | N/A (runtime) | ~5-10MB | ~10-15MB | N/A (runtime) | ~20-50MB (AOT) |
| Container Size | ~200MB | ~20MB | ~20MB | ~300MB | ~100MB (AOT) |
| Performance | Good | Excellent | Excellent | Moderate | Good |
| TLS Handling | ❌ Broken | ✅ | ✅ | ✅ | ✅ |
| Learning Curve | Low | High | Medium | Low | Medium |
| Maintenance | Easy | Moderate | Easy | Easy | Easy |
| Dependencies | Many (npm) | Few | Few | Some (pip) | Some (NuGet) |

---

## Decision

**Selected: Rust with `hudsucker`**

Rationale:
1. Solves the TLS/OpenSSL compatibility issues definitively
2. Produces a minimal, self-contained binary
3. Excellent performance for a network proxy
4. Once working, very stable and low maintenance
5. Good fit for containerized deployment

The tradeoff of a steeper learning curve is acceptable given the stability benefits and the fact that the codebase will be small and focused.
