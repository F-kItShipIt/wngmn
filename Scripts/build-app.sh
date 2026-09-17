#!/bin/bash
#
# Builds wngmn.app — the binary wrapped in a bundle so it owns its own permissions.
#
# Run from a shell, `wngmn` has no identity of its own: System Audio Recording and
# Microphone are granted to the *parent* process, so the grant belongs to Terminal or
# Ghostty and a denial returns noErr from every Core Audio call. A bundle with its own
# identifier and usage strings is what lets macOS prompt for wngmn, list it in System
# Settings under its own name, and remember the answer.
#
#   Scripts/build-app.sh              universal, ad-hoc signed
#   ARCHS=arm64 Scripts/build-app.sh  this machine only, faster
#   SIGN_ID="Developer ID Application: ..." Scripts/build-app.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# `.local` is reserved by RFC 6762, so this can never collide with a real domain and makes
# no claim to one. Reverse-DNS convention wants a domain you control; until the tool has
# one, squatting somebody else's — or borrowing an unrelated company's — is worse than
# saying plainly that it is unpublished.
#
# Changing this later creates a new TCC subject, so macOS forgets any permission already
# granted and asks again. Pick it once.
BUNDLE_ID="${BUNDLE_ID:-local.wngmn.Wngmn}"
VERSION="${VERSION:-0.3.1}"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_ID="${SIGN_ID:--}"          # `-` is ad-hoc
APP="build/wngmn.app"

echo "==> Building for: $ARCHS"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release "${ARCH_FLAGS[@]}"

# Ask the build system where it put the binary rather than guessing from a list of paths.
# Guessing picked the first path that EXISTED, so a single-arch build (which lands in
# .build/<arch>-apple-macosx/release) packaged the stale universal binary left behind by an
# earlier default build — shipping code that was not the code just compiled, silently.
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/wngmn"
[ -f "$BINARY" ] || { echo "no binary at $BINARY after a successful build"; exit 1; }
echo "==> Built $(lipo -archs "$BINARY")"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/wngmn"

# Usage strings are not decoration: macOS refuses the permission outright if the key for a
# protected resource is missing, and the text is what the user is shown when deciding.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>wngmn</string>
    <key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>wngmn</string>
    <key>CFBundleDisplayName</key>            <string>Wngmn</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>         <string>26.0</string>
    <!-- No Dock icon: this is a terminal tool that happens to need an identity. -->
    <key>LSUIElement</key>                    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Wngmn transcribes your side of a call so the transcript shows both speakers.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Wngmn transcribes the audio of your call so you can read it as text.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing ($SIGN_ID)"
# Signed as one bundle, not as a loose binary: TCC keys its grant to the signing identity
# plus the bundle id, so an unsigned or separately-signed executable is a different subject
# every build and the user is asked again each time.
# The entitlements are not optional alongside --options runtime: the hardened runtime denies
# microphone access before TCC is ever consulted, so without them the failure is not a refused
# prompt but no prompt at all and a capture full of silence. The file carries no XML comments
# on purpose — AMFI's parser rejects them, and codesign then reports "Failed to parse
# entitlements" while still exiting 0.
ENTITLEMENTS="$(dirname "$0")/wngmn.entitlements"
# Not piped into sed. A pipeline's status is its LAST command's, so `codesign ... | sed || …`
# reported success however codesign failed, and the fallback below was unreachable — which is
# how the bundle came to be signed with neither the hardened runtime nor the entitlements
# while the build printed nothing at all.
if ! codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime --timestamp=none "$APP" 2>&1; then
    echo "    hardened runtime failed; retrying without it"
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
fi

# Signing can "succeed" having silently dropped what was asked for, so this is checked rather
# than assumed: without the entitlement the microphone is denied before any prompt appears.
if ! codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "audio-input"; then
    echo "    WARNING  the bundle carries no microphone entitlement; --mic will capture silence"
fi

codesign -dv "$APP" 2>&1 | sed 's/^/    /'
echo
echo "==> Done: $APP"
echo "    Run it as:  $APP/Contents/MacOS/wngmn --serve --listen"
