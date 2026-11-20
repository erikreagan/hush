#!/bin/bash
# One-time: creates a self-signed code-signing certificate "Hush Dev" in its own small keychain
# (~/Library/Keychains/hush-signing.keychain-db), so macOS remembers Hush's microphone permission
# across rebuilds. A dedicated keychain with a fixed throwaway password means no prompts, and the
# login keychain is never touched. The key only signs this personal app.
set -euo pipefail
name="Hush Dev"; kc="$HOME/Library/Keychains/hush-signing.keychain-db"; pw=hush
if [ -f "$kc" ]; then echo "'$name' keychain already exists"; exit 0; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" -out "$tmp/id.p12" -passout pass:$pw
security create-keychain -p $pw "$kc"
security set-keychain-settings "$kc"   # no auto-lock timeout
security unlock-keychain -p $pw "$kc"
security import "$tmp/id.p12" -k "$kc" -P $pw -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k $pw "$kc" >/dev/null
echo "Created '$name' in $kc"
