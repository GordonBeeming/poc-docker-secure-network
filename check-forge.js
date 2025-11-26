// Quick script to check what node-forge does
const forge = require('node-forge');
const pki = forge.pki;

// Generate a keypair
const keys = pki.rsa.generateKeyPair(2048);

// Create a certificate
const cert = pki.createCertificate();
cert.publicKey = keys.publicKey;
cert.serialNumber = '01';
cert.validity.notBefore = new Date();
cert.validity.notAfter = new Date();
cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 1);

const attrs = [{ name: 'commonName', value: 'test.example.com' }];
cert.setSubject(attrs);
cert.setIssuer(attrs);

// Sign with SHA-256
cert.sign(keys.privateKey, forge.md.sha256.create());

console.log('Certificate signature algorithm:', cert.siginfo.algorithmOid);
console.log('Signature algorithm name:', pki.oids[cert.siginfo.algorithmOid]);

// Convert to PEM and check with openssl
const pemCert = pki.certificateToPem(cert);
require('fs').writeFileSync('/tmp/test-cert.pem', pemCert);
console.log('\nCertificate PEM written to /tmp/test-cert.pem');

const { execSync } = require('child_process');
console.log('\nOpenSSL verification:');
console.log(execSync('openssl x509 -in /tmp/test-cert.pem -text -noout | grep -A1 "Signature Algorithm"').toString());
