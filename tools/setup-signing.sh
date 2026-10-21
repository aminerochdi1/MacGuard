#!/bin/bash
# One-time: create a local self-signed code-signing certificate so every build keeps the same identity.
# macOS then stops re-asking for notification / Finder / file permissions after each rebuild.
set -euo pipefail
NAME="MacGuard Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Signing identity '$NAME' already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:macguard

security import "$TMP/id.p12" -k "$KEYCHAIN" -P macguard -T /usr/bin/codesign
# Trust it for code signing (macOS asks for your login password once)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" || echo "Identity not listed yet; open Keychain Access and check '$NAME'."
echo "Done. The next ./build.sh signs with it. If codesign asks for keychain access, choose 'Always Allow'."
