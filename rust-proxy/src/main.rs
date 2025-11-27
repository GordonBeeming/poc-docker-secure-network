//! Secure Network Proxy - Rust Edition
//!
//! Transparent MITM proxy that intercepts HTTPS traffic and enforces allow/block rules.

use anyhow::Result;
use rcgen::{BasicConstraints, CertificateParams, DistinguishedName, DnType, IsCa, KeyPair, Certificate};
use rustls::crypto::aws_lc_rs;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::ServerConfig;
use serde::Deserialize;
use std::{
    fs::{self, OpenOptions},
    io::Write,
    net::SocketAddr,
    path::Path,
    sync::Arc,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::{TlsAcceptor, TlsConnector};
use tracing::{info, error, Level};
use tracing_subscriber::FmtSubscriber;

// ============================================================================
// Configuration
// ============================================================================

#[derive(Debug, Clone, Deserialize)]
struct HostRule {
    host: String,
    #[serde(default)]
    allowed_paths: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct Config {
    #[serde(default = "default_mode")]
    mode: String,
    #[serde(default)]
    allowed_rules: Vec<HostRule>,
}

fn default_mode() -> String {
    "monitor".to_string()
}

impl Default for Config {
    fn default() -> Self {
        Self {
            mode: "monitor".to_string(),
            allowed_rules: vec![],
        }
    }
}

// ============================================================================
// Logging
// ============================================================================

fn log_traffic(action: &str, host: &str, path: &str, method: &str, mode: &str, reason: &str) {
    let log_path = "/logs/traffic.jsonl";
    if let Some(parent) = Path::new(log_path).parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(log_path) {
        let entry = serde_json::json!({
            "action": action,
            "host": host,
            "path": path,
            "method": method,
            "mode": mode,
            "reason": reason
        });
        let _ = writeln!(file, "{}", entry);
    }
}

// ============================================================================
// Security Check
// ============================================================================

/// Check if a host is allowed (for CONNECT-level checks, ignores path rules)
fn check_host_allowed(config: &Config, host: &str) -> (bool, String) {
    if config.mode != "enforce" {
        return (true, "Monitor Mode".to_string());
    }

    let host_rule = config.allowed_rules.iter().find(|rule| {
        host == rule.host || host.ends_with(&format!(".{}", rule.host))
    });

    match host_rule {
        None => (false, "Host Not Allowed".to_string()),
        Some(_) => (true, "Host Allowed".to_string()),
    }
}

/// Check if a request (host + path) is allowed
fn check_request(config: &Config, host: &str, path: &str) -> (bool, String) {
    if config.mode != "enforce" {
        return (true, "Monitor Mode".to_string());
    }

    let host_rule = config.allowed_rules.iter().find(|rule| {
        host == rule.host || host.ends_with(&format!(".{}", rule.host))
    });

    match host_rule {
        None => (false, "Host Not Allowed".to_string()),
        Some(rule) => {
            if rule.allowed_paths.is_empty() {
                return (true, "Host Match".to_string());
            }
            let path_match = rule.allowed_paths.iter().any(|p| path.starts_with(p));
            if path_match {
                (true, "Path Match".to_string())
            } else {
                (false, "Path Not Allowed".to_string())
            }
        }
    }
}

// ============================================================================
// SNI Parsing
// ============================================================================

fn parse_sni(buf: &[u8]) -> Option<String> {
    // TLS record: ContentType(1) + Version(2) + Length(2) + Handshake
    if buf.len() < 5 || buf[0] != 0x16 {
        return None; // Not a TLS handshake
    }

    let record_len = ((buf[3] as usize) << 8) | (buf[4] as usize);
    if buf.len() < 5 + record_len {
        return None;
    }

    let handshake = &buf[5..];
    if handshake.is_empty() || handshake[0] != 0x01 {
        return None; // Not ClientHello
    }

    // Skip handshake header (1 + 3 bytes length)
    if handshake.len() < 4 {
        return None;
    }
    let hello_len = ((handshake[1] as usize) << 16)
        | ((handshake[2] as usize) << 8)
        | (handshake[3] as usize);
    
    if handshake.len() < 4 + hello_len {
        return None;
    }

    let hello = &handshake[4..];
    
    // Skip client version (2) + random (32) = 34 bytes
    if hello.len() < 34 {
        return None;
    }
    let mut pos = 34;

    // Skip session ID
    if pos >= hello.len() {
        return None;
    }
    let session_len = hello[pos] as usize;
    pos += 1 + session_len;

    // Skip cipher suites
    if pos + 2 > hello.len() {
        return None;
    }
    let cipher_len = ((hello[pos] as usize) << 8) | (hello[pos + 1] as usize);
    pos += 2 + cipher_len;

    // Skip compression methods
    if pos >= hello.len() {
        return None;
    }
    let comp_len = hello[pos] as usize;
    pos += 1 + comp_len;

    // Extensions
    if pos + 2 > hello.len() {
        return None;
    }
    let ext_len = ((hello[pos] as usize) << 8) | (hello[pos + 1] as usize);
    pos += 2;

    let ext_end = pos + ext_len;
    while pos + 4 <= ext_end && pos + 4 <= hello.len() {
        let ext_type = ((hello[pos] as u16) << 8) | (hello[pos + 1] as u16);
        let ext_data_len = ((hello[pos + 2] as usize) << 8) | (hello[pos + 3] as usize);
        pos += 4;

        if ext_type == 0 {
            // SNI extension
            if pos + ext_data_len > hello.len() {
                return None;
            }
            let sni_data = &hello[pos..pos + ext_data_len];
            // SNI list length (2) + type (1) + name length (2) + name
            if sni_data.len() < 5 {
                return None;
            }
            let name_len = ((sni_data[3] as usize) << 8) | (sni_data[4] as usize);
            if sni_data.len() < 5 + name_len {
                return None;
            }
            return String::from_utf8(sni_data[5..5 + name_len].to_vec()).ok();
        }
        pos += ext_data_len;
    }
    None
}

// ============================================================================
// Certificate Authority
// ============================================================================

struct CaAuthority {
    ca_key: KeyPair,
    ca_cert: Certificate,
}

impl CaAuthority {
    fn new() -> Result<Self> {
        let ca_cert_path = "/ca/certs/ca.pem";
        let ca_key_path = "/ca/keys/ca.private.key";

        fs::create_dir_all("/ca/certs")?;
        fs::create_dir_all("/ca/keys")?;

        info!("Generating CA certificate...");

        let mut params = CertificateParams::default();
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, "Secure Proxy CA");
        dn.push(DnType::OrganizationName, "Secure Proxy");
        params.distinguished_name = dn;

        let key_pair = KeyPair::generate()?;
        let cert = params.self_signed(&key_pair)?;

        fs::write(ca_cert_path, cert.pem())?;
        fs::write(ca_key_path, key_pair.serialize_pem())?;

        info!("CA saved to {}", ca_cert_path);

        Ok(Self {
            ca_key: key_pair,
            ca_cert: cert,
        })
    }

    fn generate_cert_for_host(&self, hostname: &str) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
        let mut params = CertificateParams::new(vec![hostname.to_string()])?;
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, hostname);
        params.distinguished_name = dn;

        let key_pair = KeyPair::generate()?;
        let cert = params.signed_by(&key_pair, &self.ca_cert, &self.ca_key)?;

        let cert_der = CertificateDer::from(cert.der().to_vec());
        let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_pair.serialize_der()));

        Ok((vec![cert_der], key_der))
    }
}

// ============================================================================
// Connection Handler
// ============================================================================

async fn handle_connection(
    mut client: TcpStream,
    ca: Arc<CaAuthority>,
    config: Arc<Config>,
) -> Result<()> {
    // Read initial data to parse SNI
    let mut buf = vec![0u8; 4096];
    let n = client.peek(&mut buf).await?;
    
    let hostname = match parse_sni(&buf[..n]) {
        Some(h) => h,
        None => {
            error!("Failed to parse SNI");
            return Ok(());
        }
    };

    // Check if host is allowed (for CONNECT-level blocking)
    let (host_allowed, reason) = check_host_allowed(&config, &hostname);
    
    if !host_allowed {
        log_traffic("BLOCK", &hostname, "/", "CONNECT", &config.mode, &reason);
        println!("⛔ [{}] CONNECT {} -> {}", config.mode, hostname, reason);
        // Close connection immediately for blocked hosts
        return Ok(());
    }

    // Generate certificate for this host
    let (certs, key) = ca.generate_cert_for_host(&hostname)?;

    // Create TLS config for client-facing connection
    let server_config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;
    
    let acceptor = TlsAcceptor::from(Arc::new(server_config));

    // Accept TLS from client
    let mut client_tls = acceptor.accept(client).await?;

    // Connect to upstream
    let upstream_addr = format!("{}:443", hostname);
    let upstream = TcpStream::connect(&upstream_addr).await?;

    // Create TLS connection to upstream
    let connector = TlsConnector::from(Arc::new(
        rustls::ClientConfig::builder()
            .with_root_certificates(rustls::RootCertStore::from_iter(
                webpki_roots::TLS_SERVER_ROOTS.iter().cloned()
            ))
            .with_no_client_auth()
    ));

    let server_name = hostname.clone().try_into()?;
    let mut upstream_tls = connector.connect(server_name, upstream).await?;

    // Now we have decrypted streams. Read HTTP request.
    let mut request_buf = vec![0u8; 8192];
    let n = client_tls.read(&mut request_buf).await?;
    let request_data = &request_buf[..n];

    // Parse HTTP request line
    let request_str = String::from_utf8_lossy(request_data);
    let first_line = request_str.lines().next().unwrap_or("");
    let parts: Vec<&str> = first_line.split_whitespace().collect();
    let (method, path) = if parts.len() >= 2 {
        (parts[0], parts[1])
    } else {
        ("?", "/")
    };

    // Check path-level rules
    let (allowed, reason) = check_request(&config, &hostname, path);
    let action = if allowed { "ALLOW" } else { "BLOCK" };
    log_traffic(action, &hostname, path, method, &config.mode, &reason);

    let icon = if allowed { "✅" } else { "⛔" };
    println!("{} [{}] {} {}{} -> {}", icon, config.mode, method, hostname, path, reason);

    if !allowed {
        // Send 403 response
        let response = format!(
            "HTTP/1.1 403 Forbidden\r\n\
             Content-Type: text/plain\r\n\
             Content-Length: 24\r\n\
             Connection: close\r\n\r\n\
             Blocked by Secure Proxy"
        );
        client_tls.write_all(response.as_bytes()).await?;
        return Ok(());
    }

    // Forward request to upstream
    upstream_tls.write_all(request_data).await?;

    // Bidirectional copy
    let (mut client_read, mut client_write) = tokio::io::split(client_tls);
    let (mut upstream_read, mut upstream_write) = tokio::io::split(upstream_tls);

    let client_to_upstream = tokio::io::copy(&mut client_read, &mut upstream_write);
    let upstream_to_client = tokio::io::copy(&mut upstream_read, &mut client_write);

    tokio::select! {
        _ = client_to_upstream => {},
        _ = upstream_to_client => {},
    }

    Ok(())
}

// ============================================================================
// Main
// ============================================================================

#[tokio::main]
async fn main() -> Result<()> {
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .with_target(false)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;

    println!("🔧 Initializing Secure Proxy (Rust Edition)...");

    // Install the crypto provider globally
    aws_lc_rs::default_provider()
        .install_default()
        .expect("Failed to install crypto provider");

    // Load config
    let config_path = "/config/rules.json";
    let config: Config = if Path::new(config_path).exists() {
        let content = fs::read_to_string(config_path)?;
        serde_json::from_str(&content)?
    } else {
        println!("[Config] No config found, using MONITOR mode");
        Config::default()
    };
    println!("[Config] Loaded mode: {}", config.mode.to_uppercase());
    let config = Arc::new(config);

    // Setup CA
    let ca = Arc::new(CaAuthority::new()?);
    println!("🔒 CA Certificate ready");

    // Create listener
    let addr = SocketAddr::from(([0, 0, 0, 0], 58080));
    let listener = TcpListener::bind(addr).await?;

    println!("🛡️  Secure Proxy listening on 0.0.0.0:58080");
    println!("✅ Environment Ready.");

    loop {
        let (client, peer_addr) = listener.accept().await?;
        let ca = ca.clone();
        let config = config.clone();

        tokio::spawn(async move {
            if let Err(e) = handle_connection(client, ca, config).await {
                error!("Connection error from {}: {}", peer_addr, e);
            }
        });
    }
}
