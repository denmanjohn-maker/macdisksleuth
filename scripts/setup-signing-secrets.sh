#!/usr/bin/env bash
# Store the signing and notarization secrets the Release workflow needs.
#
# Run once, on a Mac that has your "Developer ID Application" certificate
# installed and your App Store Connect API key (.p8) downloaded:
#
#   scripts/setup-signing-secrets.sh
#
# It exports the certificate to a temporary .p12, encodes it and the .p8,
# and stores all six secrets on the GitHub repository with the GitHub CLI.
# macOS will ask you to allow access to the certificate's private key.
# Nothing is committed, and the temporary files are deleted on exit.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/signing-common.sh
. scripts/signing-common.sh

[ "$(uname)" = Darwin ] || die "run this on the Mac that has the certificate"

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# 1. GitHub CLI, logged in, pointing at this repository.
if ! command -v gh >/dev/null; then
  note "Installing the GitHub CLI"
  command -v brew >/dev/null || die "Homebrew is needed to install gh: https://brew.sh"
  brew install gh
fi
if ! gh auth status >/dev/null 2>&1; then
  note "Signing in to GitHub (a browser window will open)"
  gh auth login --hostname github.com --git-protocol https --web
fi
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
note "Repository: $repo"

# 2. Certificate and API key.
find_developer_id_identity
resolve_asc_api_key

# 3. Export the certificate with its private key.
echo
echo "Exporting \"$IDENTITY_NAME\" from your login keychain."
echo "macOS will show one or more dialogs asking to allow access; enter your login"
echo "password and click Allow (or Always Allow) for each."
echo
p12_password=$(openssl rand -base64 24)
security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 \
  -P "$p12_password" -o "$tmp/cert.p12"
# Verify the way the workflow will use it: import into a throwaway keychain
# and look for the identity there. (The bundled openssl is LibreSSL and
# cannot read the PKCS#12 format that recent macOS versions export.)
verify_keychain="$tmp/verify.keychain-db"
verify_password=$(openssl rand -hex 16)
security create-keychain -p "$verify_password" "$verify_keychain"
security import "$tmp/cert.p12" -k "$verify_keychain" -P "$p12_password" \
  -T /usr/bin/codesign -T /usr/bin/security > /dev/null
found=$(security find-identity -v -p codesigning "$verify_keychain")
security delete-keychain "$verify_keychain"
echo "$found"
echo "$found" | grep -q 'Developer ID Application' \
  || die "the exported .p12 does not contain the Developer ID Application certificate.
If macOS asked to allow access to the private key and you clicked Deny, run this
script again and click Allow."

# 4. Store the secrets.
note "Storing secrets on $repo"
gh secret set MACOS_CERTIFICATE_P12      --repo "$repo" --body "$(base64 -i "$tmp/cert.p12")"
gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$repo" --body "$p12_password"
gh secret set APPLE_TEAM_ID              --repo "$repo" --body "$TEAM_ID"
gh secret set ASC_KEY_ID                 --repo "$repo" --body "$ASC_KEY_ID"
gh secret set ASC_ISSUER_ID              --repo "$repo" --body "$ASC_ISSUER_ID"
gh secret set ASC_API_KEY_P8             --repo "$repo" --body "$(base64 -i "$ASC_API_KEY_PATH")"

echo
gh secret list --repo "$repo"
echo
note "Done. The next tag you push (see RELEASING.md) will be signed and notarized."
note "For a notarized build on this Mac right now: scripts/build-notarized-app.sh --install"
