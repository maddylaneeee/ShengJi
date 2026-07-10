#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-MLCCS Local Code Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mlccs-codesign.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

if security find-identity -v -p codesigning | grep -F "\"$NAME\"" >/dev/null; then
  echo "$NAME already exists"
  exit 0
fi

cat > "$WORKDIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[ req_distinguished_name ]
CN = $NAME

[ v3_codesign ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req -new -newkey rsa:4096 -nodes -x509 -days 3650 \
  -keyout "$WORKDIR/codesign.key" \
  -out "$WORKDIR/codesign.crt" \
  -config "$WORKDIR/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export \
  -legacy \
  -inkey "$WORKDIR/codesign.key" \
  -in "$WORKDIR/codesign.crt" \
  -name "$NAME" \
  -out "$WORKDIR/codesign.p12" \
  -passout pass:mlccs-local-codesign >/dev/null 2>&1

security import "$WORKDIR/codesign.p12" -k "$KEYCHAIN" -P "mlccs-local-codesign" -T /usr/bin/codesign -A >/dev/null
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORKDIR/codesign.crt" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

security find-identity -v -p codesigning | grep -F "\"$NAME\""
