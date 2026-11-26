#!/bin/bash
#
# Optional: create a private code-signing identity, "Hoverbird Local Signing",
# so macOS keeps Hoverbird's privacy permissions (Accessibility, Screen Recording…)
# when you rebuild. Without it, builds are ad-hoc signed and macOS may ask again
# after each rebuild.
#
#   ./Scripts/setup-signing.sh            # set up (macOS asks for your password once, to trust the certificate)
#   ./Scripts/setup-signing.sh --remove   # undo everything
#
# What it creates:
#   ~/Library/Keychains/hoverbird-codesign.keychain-db   a separate keychain holding the identity
#   .signing/keychain.pass                                  that keychain's random password (git-ignored)
#   .signing/cert.pem                                       the public certificate
# The identity never leaves your Mac and is only trusted for code signing.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${HB_SIGNING_DIR:-$ROOT/.signing}"
KEYCHAIN="${HB_KEYCHAIN:-$HOME/Library/Keychains/hoverbird-codesign.keychain-db}"
NAME="Hoverbird Local Signing"
# For testing in isolation: HB_SKIP_SYSTEM=1 skips the keychain search list and the trust setting.
SKIP_SYSTEM="${HB_SKIP_SYSTEM:-0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if [[ "${1:-}" == "--remove" ]]; then
  security delete-keychain "$KEYCHAIN" 2>/dev/null && log "Removed $KEYCHAIN" || log "No keychain to remove"
  rm -rf "$DIR"
  log "Done. Builds are ad-hoc signed again."
  exit 0
fi

if [[ -f "$KEYCHAIN" && -f "$DIR/keychain.pass" ]]; then
  log "Already set up ($KEYCHAIN). Use --remove to start over."
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# macOS's own openssl (LibreSSL) writes .p12 files the Keychain can import. A Homebrew OpenSSL
# 3 or later needs -legacy for that (OpenSSL 4 is on PATH first on many Macs).
OPENSSL=/usr/bin/openssl
[[ -x "$OPENSSL" ]] || OPENSSL=openssl
PASS="$("$OPENSSL" rand -hex 24)"
printf '%s' "$PASS" > "$DIR/keychain.pass"
chmod 600 "$DIR/keychain.pass"

cat > "$DIR/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
O = Hoverbird Local
[ ext ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

log "Creating a self-signed code-signing certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$DIR/cert.pem" 2>/dev/null
# (bash 3.2 on macOS: empty arrays are expanded with the ${a[@]+…} idiom under set -u.)
if "$OPENSSL" version | grep -qE '^OpenSSL ([3-9]|[1-9][0-9])'; then LEGACY=(-legacy); else LEGACY=(); fi
"$OPENSSL" pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -inkey "$WORK/key.pem" -in "$DIR/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout pass:"$PASS"

log "Creating the keychain $KEYCHAIN"
security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # don't auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null

if [[ "$SKIP_SYSTEM" != 1 ]]; then
  log "Adding the keychain to your search list"
  CURRENT=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
    [[ -n "$line" ]] && CURRENT+=("$line")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "$KEYCHAIN" ${CURRENT[@]+"${CURRENT[@]}"}
  log "Trusting the certificate for code signing (macOS asks for your password)"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"
fi

IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | awk -v n="$NAME" 'index($0, n) {print $2; exit}')"
[[ -n "$IDENTITY" ]] || { echo "Could not find the new identity in $KEYCHAIN" >&2; exit 1; }
log "Ready: $NAME ($IDENTITY). ./Scripts/build.sh will use it from now on."
