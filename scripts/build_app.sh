#!/bin/bash
#
# Build Tokenamp and assemble build/Tokenamp.app.
#
# Command Line Tools only: no Xcode, no xcodebuild. The bundle is put together by hand and
# ad-hoc signed, which is all macOS needs to let a local app use notifications and the menu bar.
#
# Re-runnable: the app directory is rebuilt from scratch every time.
#
#   scripts/build_app.sh [--debug] [--universal]
#
#   --debug       debug configuration (default: release)
#   --universal   arm64 + x86_64 in one binary. The other architecture is cross-compiled with
#                 `--triple` into its own scratch path (.build-app-<arch>) and the two are joined
#                 with lipo. Opt-in because it doubles a clean build; releases use it.
#
# The version is read from VERSION at the repo root (MAJOR.MINOR.PATCH, the single source of
# truth) and written into CFBundleShortVersionString and CFBundleVersion.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --universal) UNIVERSAL=1 ;;
        *) echo "error: unknown option '$arg' (usage: scripts/build_app.sh [--debug] [--universal])" >&2; exit 2 ;;
    esac
done

SCRATCH=".build-app"
# Keep in step with `platforms: [.macOS(.v13)]` in Package.swift.
MIN_MACOS="13.0"

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION must be MAJOR.MINOR.PATCH (got '$VERSION')" >&2
    exit 1
fi

APP="build/Tokenamp.app"
CONTENTS="$APP/Contents"

# The host architecture builds in the usual scratch path, so a universal build reuses the dev
# cache; any other architecture is cross-compiled into .build-app-<arch>.
HOST_ARCH="$(uname -m)"
SLICE_BIN=""
build_slice() {
    local arch="$1" scratch="$SCRATCH"
    local triple=()
    if [[ "$arch" != "$HOST_ARCH" ]]; then
        scratch="$SCRATCH-$arch"
        triple=(--triple "$arch-apple-macosx$MIN_MACOS")
    fi
    # ${a[@]+"${a[@]}"}: an empty array is "unbound" under `set -u` in macOS's bash 3.2.
    echo "==> swift build -c $CONFIG --scratch-path $scratch --product Tokenamp ${triple[*]+${triple[*]}}"
    swift build -c "$CONFIG" --scratch-path "$scratch" --product Tokenamp ${triple[@]+"${triple[@]}"}
    SLICE_BIN="$(swift build -c "$CONFIG" --scratch-path "$scratch" --product Tokenamp ${triple[@]+"${triple[@]}"} --show-bin-path)/Tokenamp"
    if [[ ! -x "$SLICE_BIN" ]]; then
        echo "error: built binary not found at $SLICE_BIN" >&2
        exit 1
    fi
    if ! lipo "$SLICE_BIN" -verify_arch "$arch"; then
        echo "error: $SLICE_BIN is not $arch (lipo: $(lipo -archs "$SLICE_BIN"))" >&2
        exit 1
    fi
}

if [[ "$UNIVERSAL" -eq 1 ]]; then
    build_slice arm64
    BIN_ARM64="$SLICE_BIN"
    build_slice x86_64
    BIN_X86_64="$SLICE_BIN"
else
    build_slice "$HOST_ARCH"
    BIN="$SLICE_BIN"
fi

echo "==> assembling $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Skins"
if [[ "$UNIVERSAL" -eq 1 ]]; then
    lipo -create -output "$CONTENTS/MacOS/Tokenamp" "$BIN_ARM64" "$BIN_X86_64"
    # One arch per -verify_arch: this lipo rejects a list ("requires exactly one input file").
    for arch in arm64 x86_64; do
        if ! lipo "$CONTENTS/MacOS/Tokenamp" -verify_arch "$arch"; then
            echo "error: lipo did not produce an arm64 + x86_64 binary (missing $arch)" >&2
            exit 1
        fi
    done
else
    cp "$BIN" "$CONTENTS/MacOS/Tokenamp"
fi
echo "    architectures: $(lipo -archs "$CONTENTS/MacOS/Tokenamp")"

ICON_LINE=""
if [[ -f "assets/Tokenamp.icns" ]]; then
    cp "assets/Tokenamp.icns" "$CONTENTS/Resources/Tokenamp.icns"
    ICON_LINE=$'\t<key>CFBundleIconFile</key>\n\t<string>Tokenamp</string>'
    echo "    icon: assets/Tokenamp.icns"
fi

# Document types: .wsz only, through an *imported* type declaration. Tokenamp does not define the
# classic Winamp skin format, so it imports the type (an app that exports one takes precedence)
# and names it in its own namespace, since the format has no registered identifier. It conforms to
# public.zip-archive, so Finder still knows it is a zip. Claiming com.pkware.zip-archive made
# LaunchServices ignore the extension list: Tokenamp was offered for every .zip, never for .wsz.
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Tokenamp</string>
	<key>CFBundleDisplayName</key>
	<string>Tokenamp</string>
	<key>CFBundleExecutable</key>
	<string>Tokenamp</string>
	<key>CFBundleIdentifier</key>
	<string>local.tokenamp.app</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
${ICON_LINE}
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Winamp Classic Skin</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Default</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>local.tokenamp.wsz</string>
			</array>
		</dict>
	</array>
	<key>UTImportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>local.tokenamp.wsz</string>
			<key>UTTypeDescription</key>
			<string>Winamp Classic Skin</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.zip-archive</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>wsz</string>
				</array>
			</dict>
		</dict>
	</array>
</dict>
</plist>
PLIST

SKIN_COUNT=0
shopt -s nullglob
for skin in skins/dist/*.wsz; do
    cp "$skin" "$CONTENTS/Resources/Skins/"
    SKIN_COUNT=$((SKIN_COUNT + 1))
done
shopt -u nullglob
echo "    bundled skins: $SKIN_COUNT"
if [[ "$SKIN_COUNT" -eq 0 ]]; then
    echo "    warning: skins/dist/*.wsz is empty - the app will fall back to its built-in skin" >&2
fi

echo "==> ad-hoc signing"
codesign --force --deep -s - "$APP"
# Not `verify && echo`: a failing command on the left of && does not trip `set -e`.
if ! codesign --verify --deep --strict "$APP"; then
    echo "error: signature verification failed for $APP" >&2
    exit 1
fi
echo "    signature ok"

echo
echo "built $APP  (version $VERSION, $(lipo -archs "$CONTENTS/MacOS/Tokenamp"))"
echo "run it with:  open $APP            (or: $CONTENTS/MacOS/Tokenamp --demo)"
