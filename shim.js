const net = require('net');
const dns = require('dns');

// --- 0. FORCE IPv4 ---
if (dns.setDefaultResultOrder) {
    dns.setDefaultResultOrder('ipv4first');
}

const INTERNAL_PROXY_PORT = 58081; // Logic Proxy (Localhost)
const TRANSPARENT_PORT = 58080;    // Shim (0.0.0.0 for iptables)

console.log(`👤 Shim Process Running as UID: ${process.getuid()}`);

// --- 5. THE TRANSPARENT SHIM ---
const server = net.createServer((socket) => {
    socket.once('data', (data) => {
        socket.pause();

        // SNI Parsing
        let hostname = null;
        if (data[0] === 0x16) { 
            console.log("🔍 [Shim] Parsing SNI...");
            const t0 = Date.now();
            hostname = parseSNI(data);
            console.log(`🔍 [Shim] SNI Parsed: ${hostname} (took ${Date.now() - t0}ms)`);
        } else {
            const match = data.toString().match(/Host: ([a-zA-Z0-9.-]+)/);
            if (match) hostname = match[1];
        }

        if (!hostname) {
            console.log("⚠️  Shim: Could not determine hostname. Dropping.");
            socket.end();
            return;
        }

        // Connect to Logic Proxy
        console.log(`🔍 [Shim] Connecting to Logic Proxy at 127.0.0.1:${INTERNAL_PROXY_PORT}...`);
        const proxySocket = net.createConnection({ 
            port: INTERNAL_PROXY_PORT, 
            host: '127.0.0.1', 
            timeout: 5000 
        });

        proxySocket.on('connect', () => {
            console.log("✅ [Shim] Connected to Logic Proxy. Sending Handshake...");
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
                console.log(`🔍 [Shim] Received data from Logic Proxy (First packet): ${str.substring(0, 50).replace(/\r\n/g, ' ')}...`);
                if (str.includes('200 Connection Established') || str.includes('200 OK')) {
                    established = true;
                    proxySocket.setTimeout(0); // Disable timeout
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
            if (e.code === 'ECONNRESET' || e.message.includes('ended by the other party')) return;
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