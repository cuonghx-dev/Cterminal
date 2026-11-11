#!/bin/bash
# Sign a CTerminal app bundle.
#
# Uses the "cter-local" identity from scripts/create-signing-cert.sh when it exists,
# so macOS privacy grants (network volumes, folders, ...) survive rebuilds.
# Falls back to ad-hoc signing, which loses those grants on every new build.
#
# Usage:
#   scripts/sign-app.sh <CTerminal.app>
#   CTER_SIGN_IDENTITY=<name> scripts/sign-app.sh <CTerminal.app>
set -euo pipefail

APP="${1:?usage: sign-app.sh <app bundle>}"
IDENTITY="${CTER_SIGN_IDENTITY:-cter-local}"

# Self-signed certs are not trusted, so search without -v (valid only).
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null
  echo "==> Signed with \"$IDENTITY\""
else
  codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
  echo "==> Signed ad-hoc (privacy grants reset on each build; run scripts/create-signing-cert.sh)"
fi
