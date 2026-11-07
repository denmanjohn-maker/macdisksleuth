#!/usr/bin/env bash
# Shared helpers for the signing scripts. Sourced, not executed.

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# Find the Developer ID Application identity in the user's keychains.
# Sets IDENTITY_HASH, IDENTITY_NAME and TEAM_ID.
find_developer_id_identity() {
  local line
  line=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 || true)
  [ -n "$line" ] || die "no \"Developer ID Application\" certificate in your keychain.
Create one at https://developer.apple.com/account/resources/certificates/add
(type: Developer ID Application), download it, and double-click it to install."
  IDENTITY_HASH=$(echo "$line" | sed -n 's/.*\([0-9A-F]\{40\}\) "Developer ID Application.*/\1/p')
  IDENTITY_NAME=$(echo "$line" | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p')
  TEAM_ID=$(echo "$IDENTITY_NAME" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
  [ -n "$IDENTITY_HASH" ] && [ -n "$TEAM_ID" ] || die "could not parse identity line: $line"
  note "Signing identity: $IDENTITY_NAME"
  note "Team ID: $TEAM_ID"
}

# Resolve the App Store Connect API key. Honors ASC_API_KEY_PATH and
# ASC_ISSUER_ID from the environment, otherwise prompts.
# Sets ASC_API_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID.
resolve_asc_api_key() {
  if [ -z "${ASC_API_KEY_PATH:-}" ]; then
    local newest
    newest=$(ls -t "$HOME"/Downloads/AuthKey_*.p8 2>/dev/null | head -1 || true)
    read -r -p "Path to the App Store Connect .p8 key [${newest:-none found}]: " ASC_API_KEY_PATH
    ASC_API_KEY_PATH=${ASC_API_KEY_PATH:-$newest}
  fi
  ASC_API_KEY_PATH=${ASC_API_KEY_PATH/#\~/$HOME}
  [ -f "$ASC_API_KEY_PATH" ] || die "no such file: $ASC_API_KEY_PATH"
  local base
  base=$(basename "$ASC_API_KEY_PATH")
  ASC_KEY_ID=${ASC_KEY_ID:-$(echo "$base" | sed -n 's/^AuthKey_\([A-Z0-9]*\)\.p8$/\1/p')}
  [ -n "$ASC_KEY_ID" ] || read -r -p "Key ID (the file is not named AuthKey_<ID>.p8): " ASC_KEY_ID
  [ -n "$ASC_KEY_ID" ] || die "a Key ID is required"

  while [ -z "${ASC_ISSUER_ID:-}" ]; do
    echo "The Issuer ID is shown at the top of App Store Connect > Users and Access > Integrations > Team Keys."
    read -r -p "Issuer ID: " ASC_ISSUER_ID
    if ! echo "$ASC_ISSUER_ID" | grep -Eq '^[0-9a-fA-F-]{36}$'; then
      echo "That does not look like an Issuer ID (expected a UUID such as 69a6de8e-...)." >&2
      ASC_ISSUER_ID=""
    fi
  done
  note "API key: $ASC_API_KEY_PATH (Key ID $ASC_KEY_ID)"
}

# Submit a zip to the notary service and fail with the log if not accepted.
notarize_zip() { # notarize_zip <zip>
  local out id
  note "Submitting $(basename "$1") for notarization (this usually takes a few minutes)"
  out=$(xcrun notarytool submit "$1" --key "$ASC_API_KEY_PATH" \
    --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait 2>&1) || true
  echo "$out"
  id=$(echo "$out" | sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' | head -1)
  if ! echo "$out" | grep -q 'status: Accepted'; then
    [ -n "$id" ] && xcrun notarytool log "$id" --key "$ASC_API_KEY_PATH" \
      --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true
    die "notarization of $1 was not accepted"
  fi
}
