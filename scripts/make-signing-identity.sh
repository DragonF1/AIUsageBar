#!/bin/bash
# Creates a self-signed "AI Usage Bar Dev" code signing identity in the login keychain.
# scripts/build-app.sh signs with it when present. An ad-hoc signature is keyed to the
# binary's hash, so every rebuild looks like a new app to macOS privacy (TCC) and the
# permissions it asks for (Removable Volumes when Antigravity's files sit on an external
# disk) are asked again after each build. A certificate-based signature gives the app a
# stable designated requirement, so a grant survives rebuilds.
set -euo pipefail

NAME="${CODESIGN_IDENTITY:-AI Usage Bar Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists in $KEYCHAIN"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF

# A throwaway export password: the .p12 lives only in this temp directory.
PASS="$(openssl rand -hex 16)"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASS" -name "$NAME"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

echo "Imported \"$NAME\" into $KEYCHAIN"
echo "codesign accepts it as is; 'security find-identity -v' lists it as untrusted, which is fine."
echo "Rebuild with scripts/build-app.sh --install. The next privacy prompt is the last one:"
echo "the signature no longer changes between builds."
