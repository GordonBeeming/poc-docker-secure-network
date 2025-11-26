const MitmProxy = require('@bjowes/http-mitm-proxy');
const fs = require('fs');
const dns = require('dns');

// --- 0. FORCE IPv4 ---
if (dns.setDefaultResultOrder) {
    dns.setDefaultResultOrder('ipv4first');
}

// --- 1. CONFIGURATION ---
const INTERNAL_PROXY_PORT = 58081; // Logic Proxy (Localhost)
const CONFIG_PATH = '/config/rules.json';
const LOG_PATH = '/logs/traffic.jsonl';

console.log(`👤 Logic Proxy Process Running as UID: ${process.getuid()}`);

// Robust import
const ProxyFactory = (typeof MitmProxy === 'function') ? MitmProxy : (MitmProxy.Proxy || MitmProxy.default);
if (typeof ProxyFactory !== 'function') {
    console.error("❌ Critical Error: Could not load 'http-mitm-proxy'.");
    process.exit(1);
}

const proxy = new ProxyFactory();

// --- 2. LOAD RULES ---
let config = { mode: 'monitor', allowed_rules: [] };

function loadConfig() {
    try {
        if (fs.existsSync(CONFIG_PATH)) {
            config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
            console.log(`[Config] Loaded mode: ${config.mode.toUpperCase()}`);
        }
    } catch (e) {
        console.error("[Config] Error loading rules, defaulting to MONITOR.", e);
    }
}
loadConfig();

// --- 3. LOGGING & LOGIC ---
function logTraffic(entry) {
    const line = JSON.stringify({ timestamp: new Date().toISOString(), ...entry }) + '\n';
    fs.appendFile(LOG_PATH, line, () => {});
}

proxy.onError((ctx, err) => {
    if (err && (err.code === 'ECONNRESET' || err.code === 'EPIPE')) return;
    console.error('Proxy Error:', err);
});

proxy.onCertificateMissing = (ctx, files, callback) => {
    console.log('[Logic] Generating certificate for:', ctx.hostname);
    return callback(null, files);
};

proxy.onRequest((ctx, callback) => {
    const req = ctx.clientToProxyRequest;
    const host = req.headers.host;
    let action = 'ALLOW';
    let reason = 'Monitor Mode';

    if (config.mode === 'enforce') {
        const hostRule = config.allowed_rules.find(r => host === r.host || host.endsWith('.' + r.host));
        
        if (!hostRule) {
            action = 'BLOCK';
            reason = 'Host Not Allowed';
        } else if (hostRule.allowed_paths && hostRule.allowed_paths.length > 0) {
            const pathMatch = hostRule.allowed_paths.some(p => req.url.startsWith(p));
            if (!pathMatch) {
                action = 'BLOCK';
                reason = `Path Not Allowed (Allowed: ${JSON.stringify(hostRule.allowed_paths)})`;
            } else {
                reason = 'Path Match';
            }
        } else {
            reason = 'Host Match';
        }
    }

    logTraffic({ action, host, path: req.url, method: req.method, mode: config.mode, reason });
    
    const icon = action === 'ALLOW' ? '✅' : '⛔';
    console.log(`${icon} [${config.mode}] ${req.method} ${host}${req.url} -> ${reason}`);

    if (action === 'BLOCK') {
        ctx.proxyToClientResponse.writeHead(403, { 'Content-Type': 'text/plain' });
        ctx.proxyToClientResponse.end('⛔ Blocked by Copilot_Here Security');
        return;
    }
    return callback();
});

// --- 4. START MAIN PROXY ---
// Listen on Localhost (127.0.0.1) so we don't expose this port externally
proxy.listen({ port: INTERNAL_PROXY_PORT, host: '127.0.0.1', sslCaDir: '/ca' }, (err) => {
    if (err) {
        console.error("❌ Failed to start Logic Proxy:", err);
        process.exit(1);
    }
    console.log(`🤖 Logic Proxy listening on 127.0.0.1:${INTERNAL_PROXY_PORT}`);
});
