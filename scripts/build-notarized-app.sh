#!/usr/bin/env bash
# Build, sign, notarize and staple MacDiskSleuth.app on this Mac.
#
#   scripts/build-notarized-app.sh            # leaves the app in build/
#   scripts/build-notarized-app.sh --install  # also replaces /Applications/MacDiskSleuth.app
#
# Needs: Xcode, xcodegen (brew install xcodegen), a "Developer ID Application"
# certificate in your keychain, and an App Store Connect API key (.p8).
# ASC_ISSUER_ID and ASC_API_KEY_PATH may be set in the environment; otherwise
# the script prompts for them.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/signing-common.sh
. scripts/signing-common.sh

[ "$(uname)" = Darwin ] || die "run this on a Mac with Xcode"

# xcodebuild needs the full Xcode. If xcode-select points at the Command Line
# Tools (the default on many Macs), use Xcode.app directly, like the Makefile.
if ! xcodebuild -version >/dev/null 2>&1; then
  xcode=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)
  xcode=${xcode:-/Applications/Xcode.app}
  [ -d "$xcode/Contents/Developer" ] || die "Xcode is required to build the app.
Install it from the App Store, open it once to finish setup, then run this again.
(Optionally make it the default: sudo xcode-select -s $xcode/Contents/Developer)"
  export DEVELOPER_DIR="$xcode/Contents/Developer"
  note "Using $xcode"
  xcodebuild -version >/dev/null 2>&1 || die "xcodebuild still fails with DEVELOPER_DIR=$DEVELOPER_DIR. Open Xcode once to accept its license and install components, then retry."
fi
install=0
[ "${1:-}" = "--install" ] && install=1

find_developer_id_identity
resolve_asc_api_key

note "Generating the Xcode project"
make generate

note "Building and signing MacDiskSleuth.app"
xcodebuild -project App/MacDiskSleuth.xcodeproj -scheme MacDiskSleuth \
  -configuration Release -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$IDENTITY_HASH" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build | tail -5
app=build/Build/Products/Release/MacDiskSleuth.app
codesign --verify --deep --strict --verbose=2 "$app"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ditto -c -k --keepParent "$app" "$tmp/MacDiskSleuth.zip"
notarize_zip "$tmp/MacDiskSleuth.zip"

note "Stapling the notarization ticket"
xcrun stapler staple "$app"
spctl -a -vv -t exec "$app"

if [ "$install" = 1 ]; then
  note "Installing to /Applications"
  rm -rf /Applications/MacDiskSleuth.app
  ditto "$app" /Applications/MacDiskSleuth.app
  open /Applications/MacDiskSleuth.app
  note "Installed and launched /Applications/MacDiskSleuth.app"
else
  note "Notarized app: $app  (re-run with --install to copy it to /Applications)"
fi
