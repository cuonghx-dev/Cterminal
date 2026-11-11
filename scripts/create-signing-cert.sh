#!/bin/bash
# Create a self-signed code signing identity ("cter-local") in the login keychain.
#
# Ad-hoc signed builds get a new cdhash on every rebuild, so macOS privacy (TCC)
# grants such as "access files on a network volume" are forgotten after each
# install. Signing with a fixed certificate gives the app a stable designated
# requirement (bundle id + certificate), so grants survive rebuilds.
#
# Usage:
#   scripts/create-signing-cert.sh [--name <identity name>]
#
# Run once per machine. scripts/sign-app.sh uses the identity when it exists.
set -euo pipefail

NAME="cter-local"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
done

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "==> Certificate \"$NAME\" already exists in the login keychain"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
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
EOF

# /usr/bin/openssl (LibreSSL) writes a PKCS#12 that `security import` accepts;
# Homebrew OpenSSL 3 needs -legacy for that.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="cter-$RANDOM$RANDOM"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" -out "$TMP/cert.p12"

# -T lets codesign use the private key without a keychain prompt.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "==> Created code signing identity \"$NAME\""
security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME" || true
