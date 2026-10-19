#!/usr/bin/env bash
# Build out/imctl-<version>.pkg from out/imctl.app. Unsigned by default
# (development: install with `installer -pkg … -target CurrentUserHomeDirectory`
# or `sudo installer -pkg … -target /`). With IMCTL_INSTALLER_IDENTITY
# ("Developer ID Installer: …") the product is signed; with IMCTL_NOTARY_PROFILE
# (a `notarytool store-credentials` profile) it is also notarized and stapled —
# then build with IMCTL_HARDENED=1 so the binaries pass notarization.
# Usage: scripts/build-pkg.sh [debug|release]   (prints the .pkg path)
set -euo pipefail
cd "$(dirname "$0")/.."
CFG="${1:-release}"
OUT="${IMCTL_OUT_DIR:-out}"
APP="$(scripts/build-app.sh "$CFG")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
# Stage on the internal disk: on an external (exFAT) volume extended attributes
# live in AppleDouble "._" files, and pkgbuild would seal them into the payload.
# (The payload still lists "._" records for com.apple.provenance — a
# system-managed attribute macOS 14+ does not let anyone strip; harmless.)
STAGE="$(mktemp -d /tmp/imctl-pkg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root/Applications"
ditto --norsrc --noextattr "$APP" "$STAGE/root/Applications/imctl.app"
xattr -cr "$STAGE/root"
pkgbuild --root "$STAGE/root" --identifier com.sunkailun.imctl.pkg --version "$VERSION" --install-location / \
  --scripts packaging/pkg/scripts "$STAGE/imctl-component.pkg" >/dev/null
sed -e "s/__VERSION__/$VERSION/g" packaging/pkg/distribution.xml.in > "$STAGE/distribution.xml"
productbuild --distribution "$STAGE/distribution.xml" --resources packaging/pkg/resources --package-path "$STAGE" \
  "$STAGE/imctl-unsigned.pkg" >/dev/null
PKG="$OUT/imctl-$VERSION.pkg"
if [[ -n "${IMCTL_INSTALLER_IDENTITY:-}" ]]; then
  productsign --sign "$IMCTL_INSTALLER_IDENTITY" "$STAGE/imctl-unsigned.pkg" "$PKG" >/dev/null
  if [[ -n "${IMCTL_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$PKG" --keychain-profile "$IMCTL_NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
  fi
  echo "signed pkg: $PKG" >&2
else
  mv -f "$STAGE/imctl-unsigned.pkg" "$PKG"
  echo "unsigned development pkg: $PKG (install: installer -pkg \"$PKG\" -target CurrentUserHomeDirectory, or sudo … -target /)" >&2
fi
echo "$PKG"
