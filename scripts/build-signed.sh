#!/usr/bin/env bash
# Build imctl and re-sign it with a stable identity so TCC (Accessibility)
# recognises the same program across rebuilds. Usage: scripts/build-signed.sh [debug|release]
#
# Identity selection: scripts/signing-identity.sh ($IMCTL_SIGN_IDENTITY, else
# Developer ID Application for $IMCTL_SIGN_TEAM_ID, else Apple Development for $IMCTL_SIGN_TEAM).
# Switching from Apple Development to Developer ID changes the designated
# requirement; re-check `imctl permission` afterwards (gate: TCC keeps the grant).
# IMCTL_HARDENED=1 adds the hardened runtime (needed for notarization; not for AX).
set -euo pipefail
cd "$(dirname "$0")/.."
CFG="${1:-debug}"
IDENT_ID="com.sunkailun.imctl"

swift build -c "$CFG" >/dev/null
BINDIR="$(swift build -c "$CFG" --show-bin-path)"
BIN="$BINDIR/imctl"
DAEMON="$BINDIR/imctld"

IDENTITY="$(scripts/signing-identity.sh)"
echo "signing with: $IDENTITY" >&2

# Notarization needs the hardened runtime and a secure timestamp; development builds skip both.
OPTS=(--timestamp=none)
[[ "${IMCTL_HARDENED:-0}" == "1" ]] && OPTS=(--options runtime --timestamp)

# Both executables carry the same identifier so TCC treats them as one client.
for B in "$BIN" "$DAEMON"; do
  [[ -x "$B" ]] || continue
  codesign --force --sign "$IDENTITY" --identifier "$IDENT_ID" "${OPTS[@]}" "$B"
  INFO="$(codesign -dv --verbose=2 "$B" 2>&1)"
  grep -q "^Identifier=$IDENT_ID$" <<<"$INFO" || { echo "identifier mismatch:"; echo "$INFO"; exit 1; }
  grep -q "^Signature=adhoc" <<<"$INFO" && { echo "still ad-hoc:"; echo "$INFO"; exit 1; }
done
echo "$BIN"
