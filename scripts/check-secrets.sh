#!/usr/bin/env bash
# Warning-only scan of tracked files for things that must never be committed:
# private keys, WeCom app parameters, proxy tokens, broker credentials, LAN
# addresses and machine-specific absolute paths. It prints file:line hits and
# never the matched value's context beyond the line itself, so its own output
# can be pasted into a gate report. Exit code is 0 unless --strict is given,
# because some hits (docs explaining what a corpsecret is) are legitimate and
# a human decides. Usage: scripts/check-secrets.sh [--strict]
set -euo pipefail
cd "$(dirname "$0")/.."
STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

# Patterns are case-insensitive extended regexes; keep them broad and let a
# human triage. Excluded paths: build output, lockfiles, this script.
PATTERNS=(
  'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
  'corpsecret[[:space:]]*[:=]'
  'corpid[[:space:]]*[:=][[:space:]]*"?ww[0-9a-f]{8,}'
  'EncodingAESKey[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9]{43}'
  'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{16,}'
  '"password"[[:space:]]*:[[:space:]]*"[^"]+"'
  'mqtt://[^ ]+@'
  'LTAI[A-Za-z0-9]{12,}'
  # The JSON form ("accessKeySecret": "...") needs the optional closing quote after
  # the name; oss.json is written that way, so without it the scanner saw nothing.
  'accessKeySecret"?[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9]{20,}'
  '\b(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b'
  '/Users/[A-Za-z0-9_.-]+/'
  '/Volumes/[^ )`"]+'
)
EXCLUDE='(^|/)(\.build|\.swiftpm|Package\.resolved|scripts/check-secrets\.sh)'

hits=0
while IFS= read -r file; do
  [[ "$file" =~ $EXCLUDE ]] && continue
  for p in "${PATTERNS[@]}"; do
    if out="$(grep -nEi -- "$p" "$file" 2>/dev/null)"; then
      while IFS= read -r line; do
        printf 'WARN %s:%s\n' "$file" "$line"
        hits=$((hits + 1))
      done <<<"$out"
    fi
  done
done < <(git ls-files)

if (( hits == 0 )); then
  echo "check-secrets: no hits"
else
  echo "check-secrets: $hits hit(s) — review each; broker addresses, credentials and machine paths must not be committed" >&2
  (( STRICT )) && exit 1
fi
exit 0
