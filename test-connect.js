const net = require('net');

const PORT = 58081;
const HOST = '127.0.0.1';

console.log(`🧪 Test Script: Connecting to ${HOST}:${PORT}...`);
const start = Date.now();

const socket = net.createConnection({ port: PORT, host: HOST, timeout: 5000 }, () => {
    console.log(`✅ Test Script: Connected! (took ${Date.now() - start}ms)`);
    socket.end();
});

socket.on('error', (err) => {
    console.error(`❌ Test Script: Error: ${err.message}`);
});

socket.on('timeout', () => {
    console.error(`❌ Test Script: Timeout!`);
    socket.destroy();
});
