#!/usr/bin/env bash
#
# Wraps the hum binary in a minimal .app bundle.
#
# Why this exists: macOS only hands media keys and Now Playing to a process with
# bundle identity. A bare SwiftPM executable has none, so `hum` built straight
# from `swift build` plays fine but F8/F9 and Control Center do nothing. The
# binary inside a bundle still works as a normal CLI — Bundle.main resolves to
# the .app no matter how it is launched — so the bundle is how hum ships, and
# `dist/hum` is a symlink into it.
set -euo pipefail

CONFIGURATION="${1:-release}"
BUNDLE_ID="com.hum.player"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^public let humVersion = "\(.*\)"$/\1/p' Sources/HumPlex/PlexAuth.swift)"
: "${VERSION:?could not read humVersion from Sources/HumPlex/PlexAuth.swift}"

echo "==> building ($CONFIGURATION)"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)/hum"
[ -x "$BIN_PATH" ] || { echo "no binary at $BIN_PATH" >&2; exit 1; }

# Stage the new bundle beside the old one and swap at the end.
#
# Writing into a live bundle is how you get a running ad-hoc-signed app killed:
# macOS re-validates pages against the on-disk signature, and a half-written
# binary fails that check. Staging keeps the window to a single rename.
APP="dist/hum.app"
STAGING="dist/.hum.app.staging"

if pgrep -f "dist/hum.app/Contents/MacOS/hum" >/dev/null 2>&1; then
	echo "==> note: hum is running from dist/ — restart it to pick this build up"
fi

echo "==> assembling $APP"
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_PATH" "$STAGING/Contents/MacOS/hum"
APP="$STAGING"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>                   <string>hum</string>
	<key>CFBundleDisplayName</key>            <string>hum</string>
	<key>CFBundleExecutable</key>             <string>hum</string>
	<key>CFBundleIdentifier</key>             <string>${BUNDLE_ID}</string>
	<key>CFBundlePackageType</key>            <string>APPL</string>
	<key>CFBundleShortVersionString</key>     <string>${VERSION}</string>
	<key>CFBundleVersion</key>                <string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>         <string>14.0</string>
	<!-- Agent, not a dock app: hum lives in a terminal and only opens a window
	     for the visualizer. -->
	<key>LSUIElement</key>                    <true/>
	<key>NSHighResolutionCapable</key>        <true/>
	<key>NSSupportsAutomaticTermination</key> <false/>
	<key>NSSupportsSuddenTermination</key>    <false/>
</dict>
</plist>
PLIST

# Optional icon: only if a converter is on the box. Not worth a hard dependency.
if command -v rsvg-convert >/dev/null 2>&1; then
	echo "==> rendering icon from branding/hum-icon.svg"
	ICONSET="$(mktemp -d)/hum.iconset"
	mkdir -p "$ICONSET"
	for size in 16 32 64 128 256 512 1024; do
		rsvg-convert -w "$size" -h "$size" branding/hum-icon.svg \
			-o "$ICONSET/icon_${size}x${size}.png"
	done
	iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/hum.icns" 2>/dev/null || true
	if [ -f "$APP/Contents/Resources/hum.icns" ]; then
		/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string hum" "$APP/Contents/Info.plist"
	fi
else
	echo "==> skipping icon (install librsvg for one: brew install librsvg)"
fi

# Signature. Media-key registration wants bundle identity; unsigned bundles get
# re-evaluated by the system on every launch.
#
# Ad-hoc (`--sign -`) has no certificate, so the bundle's designated requirement
# is the cdhash of that exact binary:
#
#     $ codesign -d --requirements - dist/hum.app
#     # designated => cdhash H"d1954aa1fc..."
#
# A keychain ACL records that requirement, so every rebuild invalidates the
# stored Plex token's access and macOS prompts again — and a CLI that asks for
# the token blocks in SecItemCopyMatching until someone answers the dialog.
#
# With a real signing identity the requirement becomes identifier-plus-
# certificate, which survives rebuilds, and the prompt stops. Any identity
# works, including a self-signed one made in Keychain Access:
#
#     HUM_SIGN_IDENTITY="hum dev" bash Scripts/make-app-bundle.sh
#
# Falls back to ad-hoc so the default path needs no setup.
if [ -n "${HUM_SIGN_IDENTITY:-}" ]; then
	echo "==> signing as '$HUM_SIGN_IDENTITY'"
	codesign --force --sign "$HUM_SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
	echo "==> signing (ad-hoc; set HUM_SIGN_IDENTITY to stop keychain re-prompts)"
	codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

# Swap: one rename, so a running instance is never reading a partial bundle.
rm -rf dist/hum.app
mv "$STAGING" dist/hum.app
APP="dist/hum.app"
ln -sfn hum.app/Contents/MacOS/hum dist/hum

cat <<DONE

built dist/hum.app  (version ${VERSION})

  run it:        ./dist/hum
  install it:    cp -R dist/hum.app /Applications/ && \\
                 ln -sf /Applications/hum.app/Contents/MacOS/hum /usr/local/bin/hum

Media keys need the bundle, so run ./dist/hum rather than .build/*/hum.
DONE
