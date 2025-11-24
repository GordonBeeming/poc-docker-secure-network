const MitmProxy = require('http-mitm-proxy');
const fs = require('fs');
const net = require('net');
const dns = require('dns');

// --- 0. FORCE IPv4 ---
if (dns.setDefaultResultOrder) {
    dns.setDefaultResultOrder('ipv4first');
}

// --- 1. CONFIGURATION ---
const INTERNAL_PROXY_PORT = 58081; // Logic Proxy (Localhost)
const TRANSPARENT_PORT = 58080;    // Shim (0.0.0.0 for iptables)
const CONFIG_PATH = '/config/rules.json';
const LOG_PATH = '/logs/traffic.jsonl';

console.log(`👤 Proxy Process Running as UID: ${process.getuid()}`);

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


// --- 5. THE TRANSPARENT SHIM ---
const server = net.createServer((socket) => {
    socket.once('data', (data) => {
        socket.pause();

        // SNI Parsing
        let hostname = null;
        if (data[0] === 0x16) { 
            hostname = parseSNI(data);
        } else {
            const match = data.toString().match(/Host: ([a-zA-Z0-9.-]+)/);
            if (match) hostname = match[1];
        }

        if (!hostname) {
            console.log("⚠️  Shim: Could not determine hostname. Dropping.");
            socket.end();
            return;
        }

        // console.log(`🔍 [Shim] Intercepted ${hostname}. Connecting to Logic Proxy...`);

        // Connect to Logic Proxy
        const proxySocket = net.createConnection({ 
            port: INTERNAL_PROXY_PORT, 
            host: '127.0.0.1', 
            timeout: 5000 
        });

        proxySocket.on('connect', () => {
            if (data[0] === 0x16) {
                // TLS: Send Fake CONNECT with Host header
                proxySocket.write(`CONNECT ${hostname}:443 HTTP/1.1\r\nHost: ${hostname}:443\r\n\r\n`);
            } else {
                // HTTP: Direct Pipe
                proxySocket.write(data);
                socket.pipe(proxySocket);
                proxySocket.pipe(socket);
                socket.resume();
            }
        });

        proxySocket.on('timeout', () => {
            console.error("❌ [Shim] TIMEOUT connecting to Logic Proxy (127.0.0.1:58081). Check iptables!");
            proxySocket.destroy();
            socket.end();
        });

        let established = false;
        proxySocket.on('data', (proxyData) => {
            if (!established && data[0] === 0x16) {
                const str = proxyData.toString();
                if (str.includes('200 Connection Established')) {
                    established = true;
                    proxySocket.write(data); // Send original ClientHello
                    
                    socket.pipe(proxySocket);
                    proxySocket.pipe(socket);
                    socket.resume();
                    return; 
                }
            }
            if (!established && data[0] !== 0x16) {
                 socket.write(proxyData);
            }
        });

        proxySocket.on('error', (e) => {
            console.error(`❌ [Shim] Logic Proxy Error: ${e.message}`);
            socket.end();
        });

        proxySocket.on('close', () => socket.end());
        socket.on('error', () => proxySocket.end());
        socket.on('close', () => proxySocket.end());
    });
});

server.listen(TRANSPARENT_PORT, '0.0.0.0', () => {
    console.log(`🛡️  Transparent Shim listening on 0.0.0.0:${TRANSPARENT_PORT}`);
});

// --- HELPER: Minimal SNI Parser ---
function parseSNI(buffer) {
    let pos = 43; 
    if (buffer.length < pos + 1) return null;
    const sessionIdLen = buffer[pos];
    pos += 1 + sessionIdLen;
    if (buffer.length < pos + 2) return null;
    const cipherSuitesLen = buffer.readUInt16BE(pos);
    pos += 2 + cipherSuitesLen;
    if (buffer.length < pos + 1) return null;
    const compressionMethodsLen = buffer[pos];
    pos += 1 + compressionMethodsLen;
    if (buffer.length < pos + 2) return null;
    const extensionsLen = buffer.readUInt16BE(pos);
    const extensionsEnd = pos + 2 + extensionsLen;
    pos += 2;

    while (pos < extensionsEnd) {
        if (buffer.length < pos + 4) return null;
        const extType = buffer.readUInt16BE(pos);
        const extLen = buffer.readUInt16BE(pos + 2);
        pos += 4;
        if (extType === 0) { 
            if (buffer.length < pos + 5) return null;
            const listLen = buffer.readUInt16BE(pos);
            if (buffer.length < pos + 2 + listLen) return null;
            const nameType = buffer[pos + 2];
            const nameLen = buffer.readUInt16BE(pos + 3);
            if (nameType === 0) {
                return buffer.toString('utf8', pos + 5, pos + 5 + nameLen);
            }
        }
        pos += extLen;
    }
    return null;
}