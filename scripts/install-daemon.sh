#!/usr/bin/env bash
# Build + sign, copy imctl/imctld to the stable directory the LaunchAgent runs
# from, then restart the agent if it is loaded. The stable copy keeps the
# daemon independent of `.build/` (which `swift test` overwrites ad-hoc signed).
# Usage: scripts/install-daemon.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CFG="${1:-debug}"
DEST="${IMCTL_BIN_DIR:-$HOME/Library/Application Support/imctl/bin}"
LABEL="${IMCTL_AGENT_LABEL:-com.sunkailun.imctl}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# A desktop installation may launch the daemon from imctl.app. Updating the
# standalone bin directory and kickstarting that job would silently keep the
# old app binary running, so stop before building or replacing either copy.
if [[ -f "$PLIST" ]]; then
  AGENT_BIN="$(plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null || true)"
  if [[ -n "$AGENT_BIN" && "$AGENT_BIN" != "$DEST/imctld" ]]; then
    echo "LaunchAgent runs $AGENT_BIN; update its app bundle instead of $DEST" >&2
    exit 2
  fi
fi

BIN="$(scripts/build-signed.sh "$CFG")"
BINDIR="$(dirname "$BIN")"
mkdir -p "$DEST"; chmod 700 "$DEST"
for B in imctl imctld; do
  cp "$BINDIR/$B" "$DEST/$B.new"
  mv -f "$DEST/$B.new" "$DEST/$B"
done
codesign -dv --verbose=2 "$DEST/imctld" 2>&1 | grep -E '^(Identifier|TeamIdentifier)=' >&2

TARGET="gui/$(id -u)/$LABEL"
if launchctl print "$TARGET" >/dev/null 2>&1; then
  launchctl kickstart -k "$TARGET"
  echo "restarted $TARGET from $DEST" >&2
else
  echo "agent not loaded; install with: \"$DEST/imctl\" agent install --mqtt" >&2
fi
echo "$DEST/imctld"
