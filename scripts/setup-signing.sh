#!/bin/bash
# Creates a self-signed code-signing identity in a keychain file inside the
# project (.signing/), so rebuilds keep the same code-signing identity and macOS
# keeps the app's Accessibility and Screen Recording permissions.
#
# Nothing is added to your login keychain or your trust settings; build.sh adds
# .signing/signing.keychain-db to the keychain search list only while signing.
# Run once. Delete .signing/ to go back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=".signing"
NAME="Harbor Local Signing"
KEYCHAIN="$PWD/$DIR/signing.keychain-db"

if [[ -f "$KEYCHAIN" ]]; then
  echo "Signing identity already set up in $DIR/"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"

cat > cert.cnf <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
O = Harbor (local build)
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
# Random passwords for this keychain file and the import bundle.
/usr/bin/openssl rand -hex 24 > keychain-password
P12_PASSWORD="$(/usr/bin/openssl rand -hex 16)"
chmod 600 keychain-password key.pem
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out identity.p12 -passout "pass:$P12_PASSWORD"

security create-keychain -p "$(cat keychain-password)" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$(cat keychain-password)" "$KEYCHAIN"
security import identity.p12 -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -f pkcs12
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat keychain-password)" "$KEYCHAIN" >/dev/null
rm -f identity.p12

echo "Created \"$NAME\" in $DIR/. Rebuild with ./build.sh, then grant permissions once more."
