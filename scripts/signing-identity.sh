#!/usr/bin/env bash
# Print the code-signing identity imctl uses (first match wins):
#   1. $IMCTL_SIGN_IDENTITY  2. "Developer ID Application" for $IMCTL_SIGN_TEAM_ID (default FCZGS779KT)
#   3. "Apple Development" for $IMCTL_SIGN_TEAM (default JVL9CBM345)
set -euo pipefail
TEAM="${IMCTL_SIGN_TEAM:-JVL9CBM345}"
TEAM_ID="${IMCTL_SIGN_TEAM_ID:-FCZGS779KT}"
if [[ -n "${IMCTL_SIGN_IDENTITY:-}" ]]; then echo "$IMCTL_SIGN_IDENTITY"; exit 0; fi
pick() { grep "$1" | grep -E "\((${TEAM}|${TEAM_ID})\)" | head -1 | sed -E 's/.*"(.*)".*/\1/'; }
IDS="$(security find-identity -v -p codesigning)"
IDENTITY="$(pick "Developer ID Application" <<<"$IDS" || true)"
[[ -n "$IDENTITY" ]] || IDENTITY="$(pick "Apple Development" <<<"$IDS" || true)"
[[ -n "$IDENTITY" ]] || { echo "no code-signing identity for team $TEAM/$TEAM_ID; set IMCTL_SIGN_IDENTITY" >&2; exit 1; }
echo "$IDENTITY"
