#!/usr/bin/env bash
#
# One-time signing setup: checks for a Developer ID certificate, stores
# notarization credentials in the keychain, and optionally uploads everything
# CI needs as GitHub secrets.
#
# Safe to re-run. Every step detects what already exists.
#
#   ./Tools/setup-signing.sh
#
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-ipbar-notary}"
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- certificate
bold "1. Developer ID Application certificate"

IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)

if [ -z "$IDENTITIES" ]; then
  warn "No Developer ID Application certificate found in your keychain."
  cat <<'EOF'

Create one (30 seconds, needs Account Holder or Admin on the team):

  Xcode → Settings → Accounts → select your team → Manage Certificates…
  → the + button, bottom left → Developer ID Application

Apple caps these at 5 per team and they last 5 years, so create one and keep
the exported .p12 somewhere safe rather than making a new one per machine.

Then re-run this script.
EOF
  exit 1
fi

echo "$IDENTITIES"
SIGN_ID=$(echo "$IDENTITIES" | head -1 | sed -E 's/.*"(.*)"/\1/')
ok "using: $SIGN_ID"

# Warn on imminent expiry — a lapsed cert fails the release at the last step.
if EXPIRY=$(security find-certificate -c "$SIGN_ID" -p 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2); then
  echo "   expires: $EXPIRY"
fi

# ------------------------------------------------------------- notary profile
echo
bold "2. Notarization credentials"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  ok "keychain profile '$PROFILE' already works"
else
  warn "No working '$PROFILE' profile. Creating one."
  cat <<'EOF'

You need an app-specific password (NOT your Apple ID password):
  appleid.apple.com → Sign-In and Security → App-Specific Passwords

EOF
  read -r -p "Apple ID email: " APPLE_ID
  read -r -p "Team ID (10 chars, from developer.apple.com/account): " TEAM_ID
  read -r -s -p "App-specific password: " APP_PASSWORD
  echo

  xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD"
  ok "stored keychain profile '$PROFILE'"
fi

# ------------------------------------------------------------- github secrets
echo
bold "3. GitHub Actions secrets (optional)"

if ! command -v gh >/dev/null 2>&1; then
  warn "gh CLI not installed. Skipping. Run brew install gh, then try again."
  exit 0
fi

if ! gh repo view >/dev/null 2>&1; then
  warn "No GitHub remote detected. Skipping. Try again once the repo is pushed."
  exit 0
fi

read -r -p "Upload signing secrets to $(gh repo view --json nameWithOwner -q .nameWithOwner)? [y/N] " REPLY
[ "${REPLY:-n}" = "y" ] || { echo "skipped"; exit 0; }

TMP_P12=$(mktemp -t ipbar-cert).p12
trap 'rm -f "$TMP_P12"' EXIT

echo
echo "Exporting the certificate needs a password to encrypt the .p12."
read -r -s -p "Choose an export password: " P12_PWD
echo

# -x limits the export to keys marked exportable; the private key must come
# with it or CI cannot sign.
security export -t identities -f pkcs12 -P "$P12_PWD" -o "$TMP_P12" \
  || { warn "Export failed. Export manually from Keychain Access instead."; exit 1; }

read -r -p "Apple ID email for notarization: " APPLE_ID
read -r -p "Team ID: " TEAM_ID
read -r -s -p "App-specific password: " APP_PASSWORD
echo

base64 -i "$TMP_P12" | gh secret set SIGNING_CERTIFICATE_P12
printf '%s' "$P12_PWD"       | gh secret set SIGNING_CERTIFICATE_PWD
printf '%s' "$SIGN_ID"       | gh secret set SIGNING_IDENTITY
printf '%s' "$APPLE_ID"      | gh secret set APPLE_ID
printf '%s' "$TEAM_ID"       | gh secret set APPLE_TEAM_ID
printf '%s' "$APP_PASSWORD"  | gh secret set APPLE_APP_PASSWORD

ok "six secrets uploaded. Tagging v0.1.0 will now produce a signed release"
echo
echo "Local release:  make release VERSION=0.1.0 SIGN_ID=\"$SIGN_ID\""
echo "CI release:     git tag v0.1.0 && git push --tags"
