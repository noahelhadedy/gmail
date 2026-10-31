#!/usr/bin/env bash
set -euo pipefail

# Builds Gmail.app from the SPM executable and substitutes the Google OAuth
# client ID into Info.plist. Requires Swift 6.0+ and macOS 14+.
#
# Usage:
#   ./scripts/build.sh                      # reads the client from Keychain
#   OAUTH_CLIENT_ID="123-abc.apps.googleusercontent.com" \
#   OAUTH_CLIENT_SECRET="GOCSPX-..." ./scripts/build.sh
#
# After building, move Gmail.app to /Applications and launch via Spotlight or
# `open Gmail.app`.

# Resolution order for the OAuth client: env vars, then macOS Keychain items
# saved with ~/noah-brain/bin/save-secret (see SETUP.md). Nothing is ever
# written to the repo; the values only land in the gitignored Gmail.app bundle.
KEYCHAIN_ID_NAME="gmail-menubar-client-id"
KEYCHAIN_SECRET_NAME="gmail-menubar-client-secret"

CLIENT_ID="${OAUTH_CLIENT_ID:-}"
CLIENT_SECRET="${OAUTH_CLIENT_SECRET:-}"
if [[ -z "$CLIENT_ID" ]]; then
    CLIENT_ID="$(security find-generic-password -s "$KEYCHAIN_ID_NAME" -w 2>/dev/null || true)"
fi
if [[ -z "$CLIENT_SECRET" ]]; then
    CLIENT_SECRET="$(security find-generic-password -s "$KEYCHAIN_SECRET_NAME" -w 2>/dev/null || true)"
fi

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
    if [[ "${ALLOW_UNCONFIGURED:-}" != "1" ]]; then
        echo "ERROR: No OAuth client found (env vars or Keychain)."
        echo
        echo "Follow SETUP.md, then save both values to Keychain:"
        echo "  ~/noah-brain/bin/save-secret $KEYCHAIN_ID_NAME \"Gmail OAuth Client ID\""
        echo "  ~/noah-brain/bin/save-secret $KEYCHAIN_SECRET_NAME \"Gmail OAuth Client Secret\""
        echo
        echo "Or pass them as env vars:"
        echo "  OAUTH_CLIENT_ID=\"<id>.apps.googleusercontent.com\" \\"
        echo "  OAUTH_CLIENT_SECRET=\"GOCSPX-...\" \\"
        echo "  ./scripts/build.sh"
        echo
        echo "To build a UI-only app with no Google sign-in: ALLOW_UNCONFIGURED=1 ./scripts/build.sh"
        exit 1
    fi
    echo "WARNING: building without an OAuth client. The app will show setup help only."
    CLIENT_ID="__OAUTH_CLIENT_ID__"
    CLIENT_SECRET="__OAUTH_CLIENT_SECRET__"
    REVERSED="__OAUTH_REVERSED_ID__"
else
    if [[ "$CLIENT_ID" != *.apps.googleusercontent.com ]]; then
        echo "ERROR: OAuth client ID must end with .apps.googleusercontent.com"
        exit 1
    fi
    REVERSED="${CLIENT_ID%.apps.googleusercontent.com}"
fi

# Zoho Mail is optional: with both Keychain items (or env vars) the app gets
# "Add Zoho Account"; without them that entry point is simply hidden.
# See SETUP-ZOHO.md.
ZOHO_ID="${ZOHO_CLIENT_ID:-}"
ZOHO_SECRET="${ZOHO_CLIENT_SECRET:-}"
if [[ -z "$ZOHO_ID" ]]; then
    ZOHO_ID="$(security find-generic-password -s "zoho-menubar-client-id" -w 2>/dev/null || true)"
fi
if [[ -z "$ZOHO_SECRET" ]]; then
    ZOHO_SECRET="$(security find-generic-password -s "zoho-menubar-client-secret" -w 2>/dev/null || true)"
fi
if [[ -z "$ZOHO_ID" || -z "$ZOHO_SECRET" ]]; then
    echo "Note: no Zoho client in Keychain, building without Zoho (see SETUP-ZOHO.md)."
    ZOHO_ID="__ZOHO_CLIENT_ID__"
    ZOHO_SECRET="__ZOHO_CLIENT_SECRET__"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "Building release binary..."
swift build -c release

APP="$REPO_ROOT/Gmail.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$REPO_ROOT/.build/release/Gmail" "$APP/Contents/MacOS/Gmail"

if [[ -f "$REPO_ROOT/scripts/AppIcon.icns" ]]; then
    cp "$REPO_ROOT/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

sed \
    -e "s|__OAUTH_CLIENT_ID__|${CLIENT_ID}|g" \
    -e "s|__OAUTH_CLIENT_SECRET__|${CLIENT_SECRET}|g" \
    -e "s|__OAUTH_REVERSED_ID__|${REVERSED}|g" \
    -e "s|__ZOHO_CLIENT_ID__|${ZOHO_ID}|g" \
    -e "s|__ZOHO_CLIENT_SECRET__|${ZOHO_SECRET}|g" \
    "$REPO_ROOT/scripts/Info.plist.template" > "$APP/Contents/Info.plist"

echo
echo "Built: $APP"
echo "Launch with: open \"$APP\""
echo
echo "Note: macOS Gatekeeper will prompt on first launch (unsigned binary)."
echo "Right-click → Open the first time, or run:"
echo "  xattr -d com.apple.quarantine \"$APP\""
