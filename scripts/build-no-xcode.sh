#!/bin/bash
# Build CTerminal without Xcode (Command Line Tools only).
#
# Compiles Sources/ with swiftc, links the prebuilt GhosttyKit static library, and
# drops the binary into a copy of an existing CTerminal.app, so Info.plist, icon,
# terminfo and the `cter` CLI come from that bundle. The copy gets
# its own bundle id, name and socket (like `reload.sh --tag`), so it runs next to
# the installed app.
#
# Usage:
#   scripts/build-no-xcode.sh [--tag <name>] [--base <CTerminal.app>] [--debug] [--open]
#
# Requires GhosttyKit.xcframework (scripts/setup.sh). Resource or Info.plist changes in
# the Xcode project are not picked up: only the binary, Resources/mermaid and
# Resources/shell-integration are refreshed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

TAG="nox"
BASE_APP="/Applications/CTerminal.app"
OPTIMIZE=(-O -wmo)
OPEN_APP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --base) BASE_APP="$2"; shift 2 ;;
    --debug) OPTIMIZE=(-Onone -g -D DEBUG); shift ;;
    --open) OPEN_APP=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
done

# Same naming as scripts/reload.sh --tag, so tests/cter.py finds the app with CTER_TAG.
TAG_ID="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//')"
TAG_SLUG="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
APP_NAME="cter DEV ${TAG}"
BUNDLE_ID="com.cuonghx.cter.debug.${TAG_ID}"
SOCKET="/tmp/cter-debug-${TAG_SLUG}.sock"
OUT_DIR="/tmp/cter-${TAG_SLUG}-swiftc"
APP="${OUT_DIR}/${APP_NAME}.app"

LIB_DIR="GhosttyKit.xcframework/macos-arm64_x86_64"
[[ -f "${LIB_DIR}/ghostty-internal.a" ]] || { echo "error: ${LIB_DIR}/ghostty-internal.a missing; run scripts/setup.sh" >&2; exit 1; }
[[ -d "$BASE_APP" ]] || { echo "error: base app $BASE_APP not found" >&2; exit 1; }

ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path)"
SOURCES=()
# TerminalView.swift (SwiftTerm) is not a member of the app target.
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' ! -name TerminalView.swift | sort)

mkdir -p "$OUT_DIR"
echo "==> Compiling ${#SOURCES[@]} Swift files (${OPTIMIZE[*]})"
swiftc "${OPTIMIZE[@]}" \
  -swift-version 5 \
  -module-name cter \
  -target "${ARCH}-apple-macos13.0" \
  -sdk "$SDK" \
  -import-objc-header cter-Bridging-Header.h \
  -I . \
  -module-cache-path "${OUT_DIR}/ModuleCache" \
  "${LIB_DIR}/ghostty-internal.a" \
  -lc++ \
  -framework Metal -framework QuartzCore -framework IOSurface \
  -framework UniformTypeIdentifiers -framework Carbon \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "${OUT_DIR}/CTerminal" \
  "${SOURCES[@]}"

echo "==> Assembling ${APP}"
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
rm -rf "$APP"
ditto "$BASE_APP" "$APP"
cp "${OUT_DIR}/CTerminal" "${APP}/Contents/MacOS/CTerminal"
rm -rf "${APP}/Contents/Resources/mermaid"
ditto Resources/mermaid "${APP}/Contents/Resources/mermaid"
rm -rf "${APP}/Contents/Resources/shell-integration"
ditto Resources/shell-integration "${APP}/Contents/Resources/shell-integration"

PLIST="${APP}/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Set :CFBundleName ${APP_NAME}"
pb "Set :CFBundleDisplayName ${APP_NAME}"
pb "Set :CFBundleIdentifier ${BUNDLE_ID}"
pb "Set :CTERCommit $(git rev-parse --short=9 HEAD)" 2>/dev/null || pb "Add :CTERCommit string $(git rev-parse --short=9 HEAD)"
pb "Delete :LSEnvironment" 2>/dev/null || true
pb "Add :LSEnvironment dict"
pb "Add :LSEnvironment:CTER_SOCKET_PATH string ${SOCKET}"
# Socket tests need list/new/close commands, which the default mode disables.
pb "Add :LSEnvironment:CTER_SOCKET_MODE string full"
echo "$SOCKET" > /tmp/cter-last-socket-path || true
rm -f "$SOCKET"

"$SCRIPT_DIR/sign-app.sh" "$APP"
echo "==> Built ${APP}"
echo "    bundle id: ${BUNDLE_ID}"
echo "    socket:    ${SOCKET}"
echo "    tests:     CTER_TAG=${TAG} python3 tests/<test>.py"

if [[ "$OPEN_APP" -eq 1 ]]; then
  env -u CTER_SOCKET_PATH -u CTER_TAB_ID -u CTER_PANEL_ID -u CTER_TAG -u CTER_BUNDLE_ID \
    CTER_SOCKET_PATH="$SOCKET" open "$APP"
fi
