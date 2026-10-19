#!/usr/bin/env bash
# Assemble and sign out/imctl.app: the console as the main executable plus the
# imctl CLI and the imctld daemon next to it. The CLI and daemon keep the
# identifier com.sunkailun.imctl (signed by build-signed.sh) so the
# Accessibility grant survives updates; the console is com.sunkailun.imctl.console.
# Usage: scripts/build-app.sh [debug|release]   (prints the .app path)
set -euo pipefail
cd "$(dirname "$0")/.."
CFG="${1:-release}"
OUT="${IMCTL_OUT_DIR:-out}"
APP="$OUT/imctl.app"
APP_ID="com.sunkailun.imctl.console"

CLI="$(scripts/build-signed.sh "$CFG")"
BINDIR="$(dirname "$CLI")"
swift build -c "$CFG" --product imctl-console >/dev/null

VERSION="$(sed -nE 's/.*public static let string = "([0-9]+\.[0-9]+\.[0-9]+)[^"]*".*/\1/p' Sources/ControlCore/IMCTLVersion.swift)"
[[ -n "$VERSION" ]] || { echo "cannot read the version from IMCTLVersion.swift" >&2; exit 1; }
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" packaging/console/Info.plist.in > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BINDIR/imctl-console" "$BINDIR/imctl" "$BINDIR/imctld" "$APP/Contents/MacOS/"
cp packaging/console/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The integration docs travel with the app: the console's 对接文档 page reads them from Resources/docs.
mkdir -p "$APP/Contents/Resources/docs"
cp docs/protocol/*.md "$APP/Contents/Resources/docs/"
# The agent skill travels too: `imctl mcp install --skills` copies it into ~/.claude/skills and ~/.codex/skills.
mkdir -p "$APP/Contents/Resources/agents/skills/imctl"
cp docs/agents/skills/imctl/SKILL.md "$APP/Contents/Resources/agents/skills/imctl/"
# External volumes store extended attributes as AppleDouble "._" files; never seal them into the bundle.
find "$APP" -name '._*' -delete

IDENTITY="$(scripts/signing-identity.sh)"
OPTS=(--timestamp=none)
[[ "${IMCTL_HARDENED:-0}" == "1" ]] && OPTS=(--options runtime --timestamp)
codesign --force --sign "$IDENTITY" --identifier "$APP_ID" "${OPTS[@]}" "$APP/Contents/MacOS/imctl-console"
codesign --force --sign "$IDENTITY" "${OPTS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed $APP with: $IDENTITY (version $VERSION build $BUILD)" >&2
echo "$APP"
