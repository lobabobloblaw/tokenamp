#!/bin/bash
#
# Package Tokenamp for a GitHub Release: dist/Tokenamp-<version>.zip and its .sha256.
#
#   scripts/package_release.sh [--no-universal]
#
# 1. scripts/build_app.sh --universal  (arm64 + x86_64; --no-universal builds the host arch only)
# 2. sign: keep the ad-hoc signature, or re-sign with a Developer ID and the hardened runtime
# 3. notarize and staple, when a notary profile is configured
# 4. zip with `ditto -c -k --keepParent`, then check the zip: unpack it, verify the signature,
#    architectures and version, and run the app's --selftest from the unpacked copy
# 5. write the checksum next to the zip
#
# Signing and notarization are switched on by environment variables, so the same script makes an
# unsigned release today and a notarized one once a Developer ID exists:
#
#   TOKENAMP_SIGN_IDENTITY    unset/empty: keep build_app.sh's ad-hoc signature (not notarizable).
#                             "Developer ID Application: Name (TEAMID)" or its SHA-1 hash: re-sign
#                             with the hardened runtime, a secure timestamp and
#                             packaging/Tokenamp.entitlements.
#                             "-": ad-hoc signature WITH the hardened runtime and entitlements, to
#                             rehearse the signed configuration locally (cannot be notarized).
#   TOKENAMP_SIGN_KEYCHAIN    optional keychain file that holds the identity (CI imports into one).
#   TOKENAMP_NOTARY_PROFILE   notarytool keychain profile, created once with
#                               xcrun notarytool store-credentials <profile> \
#                                 --apple-id <id> --team-id <TEAMID> --password <app-specific pw>
#                             When set, the signed app is notarized and the ticket stapled.
#   TOKENAMP_NOTARY_KEYCHAIN  optional keychain file that holds that profile.
#   TOKENAMP_REQUIRE_NOTARIZATION=1
#                             fail rather than produce an unnotarized zip (CI sets it once the
#                             notary secrets exist, so a broken secret cannot ship unnotarized).
#
# notarytool and stapler ship with the Command Line Tools (xcrun finds them); Xcode is not needed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UNIVERSAL=1
for arg in "$@"; do
    case "$arg" in
        --no-universal) UNIVERSAL=0 ;;
        *) echo "error: unknown option '$arg' (usage: scripts/package_release.sh [--no-universal])" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/Tokenamp.app"
DIST="dist"
ZIP_NAME="Tokenamp-$VERSION.zip"
ZIP="$DIST/$ZIP_NAME"
ENTITLEMENTS="packaging/Tokenamp.entitlements"

IDENTITY="${TOKENAMP_SIGN_IDENTITY:-}"
SIGN_KEYCHAIN="${TOKENAMP_SIGN_KEYCHAIN:-}"
NOTARY_PROFILE="${TOKENAMP_NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${TOKENAMP_NOTARY_KEYCHAIN:-}"
REQUIRE_NOTARIZATION="${TOKENAMP_REQUIRE_NOTARIZATION:-0}"

# ---- preflight: refuse combinations that cannot work before spending minutes on a build ----------

for tool in codesign ditto lipo shasum plutil; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
        die "TOKENAMP_NOTARY_PROFILE is set but TOKENAMP_SIGN_IDENTITY is not a Developer ID identity; an ad-hoc signature cannot be notarized"
    fi
    xcrun --find notarytool >/dev/null 2>&1 || die "xcrun cannot find notarytool (install the Command Line Tools)"
    xcrun --find stapler >/dev/null 2>&1 || die "xcrun cannot find stapler (install the Command Line Tools)"
fi
if [[ "$REQUIRE_NOTARIZATION" == "1" && -z "$NOTARY_PROFILE" ]]; then
    die "TOKENAMP_REQUIRE_NOTARIZATION=1 but TOKENAMP_NOTARY_PROFILE is not set"
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
    find_args=(-v -p codesigning)
    [[ -n "$SIGN_KEYCHAIN" ]] && find_args+=("$SIGN_KEYCHAIN")
    # Captured, not piped into `grep -q`: an early grep exit can SIGPIPE the writer, and under
    # pipefail that reads as "no match".
    IDENTITIES="$(security find-identity "${find_args[@]}")"
    if ! grep -qF -- "$IDENTITY" <<< "$IDENTITIES"; then
        die "signing identity '$IDENTITY' not found among valid codesigning identities (security find-identity -v -p codesigning)"
    fi
fi

TMP_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_BASE%/}/tokenamp-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A failed run must not leave an older zip behind that looks like this one.
rm -f "$ZIP" "$ZIP.sha256"

# ---- 1. build -------------------------------------------------------------------------------------

if [[ "$UNIVERSAL" -eq 1 ]]; then
    scripts/build_app.sh --universal
    EXPECTED_ARCHS="arm64 x86_64"
else
    echo "warning: --no-universal: the release will run on $(uname -m) Macs only" >&2
    scripts/build_app.sh
    EXPECTED_ARCHS="$(uname -m)"
fi
[[ -d "$APP" ]] || die "$APP was not built"

# Build products need no extended attributes, and a stray one (say, a quarantine flag on a skin)
# would ride into the zip as an AppleDouble ._ file.
xattr -cr "$APP"

# ---- 2. sign ----------------------------------------------------------------------------------------

SIGNATURE="ad-hoc"
if [[ -n "$IDENTITY" ]]; then
    # The bundle holds a single Mach-O (Contents/MacOS/Tokenamp), so signing the bundle signs it.
    # If helpers or frameworks are ever added, sign them first, inside-out, with the same flags.
    sign_args=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
    if [[ "$IDENTITY" == "-" ]]; then
        sign_args+=(--timestamp=none)
        SIGNATURE="ad-hoc + hardened runtime"
    else
        sign_args+=(--timestamp)
        SIGNATURE="Developer ID + hardened runtime"
    fi
    [[ -n "$SIGN_KEYCHAIN" ]] && sign_args+=(--keychain "$SIGN_KEYCHAIN")
    echo "==> signing ($SIGNATURE)"
    codesign "${sign_args[@]}" "$APP"
else
    echo "==> keeping the ad-hoc signature (TOKENAMP_SIGN_IDENTITY not set)"
fi
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
    die "signature verification failed for $APP"
fi

# ---- 3. notarize + staple -----------------------------------------------------------------------------

NOTARIZED=0
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> notarizing with keychain profile '$NOTARY_PROFILE'"
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
    [[ -n "$NOTARY_KEYCHAIN" ]] && notary_args+=(--keychain "$NOTARY_KEYCHAIN")
    ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
    # Not trusting the exit code alone: read the final status from the plist either way.
    xcrun notarytool submit "$WORK/notarize.zip" "${notary_args[@]}" \
        --wait --timeout 45m --output-format plist > "$WORK/submit.plist" || true
    STATUS="$(plutil -extract status raw -o - "$WORK/submit.plist" 2>/dev/null || echo unknown)"
    SUBMISSION="$(plutil -extract id raw -o - "$WORK/submit.plist" 2>/dev/null || echo "")"
    echo "    submission ${SUBMISSION:-?}: $STATUS"
    if [[ "$STATUS" != "Accepted" ]]; then
        cat "$WORK/submit.plist" >&2 || true
        if [[ -n "$SUBMISSION" ]]; then
            echo "---- notary log ----" >&2
            xcrun notarytool log "$SUBMISSION" "${notary_args[@]}" >&2 || true
        fi
        die "notarization did not succeed (status: $STATUS)"
    fi
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    NOTARIZED=1
fi

# ---- 4. zip, then check the zip itself ----------------------------------------------------------------

echo "==> packaging $ZIP"
mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$ZIP"

ZIP_ENTRIES="$(zipinfo -1 "$ZIP")"
if grep -qE '(^|/)(\._|__MACOSX/)' <<< "$ZIP_ENTRIES"; then
    die "$ZIP contains AppleDouble/__MACOSX entries; unzip-based installers would break the signature"
fi

CHECK="$WORK/unzipped"
mkdir -p "$CHECK"
ditto -x -k "$ZIP" "$CHECK"
CHECK_APP="$CHECK/Tokenamp.app"
CHECK_BIN="$CHECK_APP/Contents/MacOS/Tokenamp"
[[ -x "$CHECK_BIN" ]] || die "the zip does not contain Tokenamp.app/Contents/MacOS/Tokenamp"

if ! codesign --verify --deep --strict "$CHECK_APP"; then
    die "the unpacked app's signature does not verify"
fi
# One arch per -verify_arch: this lipo rejects a list ("requires exactly one input file").
for arch in $EXPECTED_ARCHS; do
    if ! lipo "$CHECK_BIN" -verify_arch "$arch"; then
        die "the unpacked binary is $(lipo -archs "$CHECK_BIN"), expected $EXPECTED_ARCHS"
    fi
done
PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$CHECK_APP/Contents/Info.plist")"
[[ "$PLIST_VERSION" == "$VERSION" ]] || die "Info.plist says $PLIST_VERSION, VERSION says $VERSION"

echo "==> selftest from the unpacked zip ($(uname -m))"
"$CHECK_BIN" --selftest > "$WORK/selftest.log" 2>&1 || { cat "$WORK/selftest.log" >&2; die "selftest failed"; }
tail -n 1 "$WORK/selftest.log" | sed 's/^/    /'
if [[ "$UNIVERSAL" -eq 1 ]]; then
    OTHER_ARCH="x86_64"
    [[ "$(uname -m)" == "x86_64" ]] && OTHER_ARCH="arm64"
    if arch "-$OTHER_ARCH" /usr/bin/true >/dev/null 2>&1; then
        echo "==> selftest from the unpacked zip ($OTHER_ARCH)"
        arch "-$OTHER_ARCH" "$CHECK_BIN" --selftest > "$WORK/selftest-$OTHER_ARCH.log" 2>&1 \
            || { cat "$WORK/selftest-$OTHER_ARCH.log" >&2; die "$OTHER_ARCH selftest failed"; }
        tail -n 1 "$WORK/selftest-$OTHER_ARCH.log" | sed 's/^/    /'
    else
        echo "    note: cannot run the $OTHER_ARCH slice on this Mac (no Rosetta); its selftest was skipped" >&2
    fi
fi

if [[ "$NOTARIZED" -eq 1 ]]; then
    xcrun stapler validate "$CHECK_APP"
    spctl --assess --type execute --verbose=2 "$CHECK_APP"
fi

# ---- 5. checksum -------------------------------------------------------------------------------------

(cd "$DIST" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
SHA256="$(cut -d ' ' -f 1 < "$ZIP.sha256")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "version=$VERSION"
        echo "zip=$ZIP"
        echo "sha256=$SHA256"
        echo "notarized=$([[ "$NOTARIZED" -eq 1 ]] && echo true || echo false)"
        echo "archs=$(lipo -archs "$CHECK_BIN")"
    } >> "$GITHUB_OUTPUT"
fi

echo
echo "packaged $ZIP"
echo "    version:    $VERSION"
echo "    archs:      $(lipo -archs "$CHECK_BIN")"
echo "    signature:  $SIGNATURE"
echo "    notarized:  $([[ "$NOTARIZED" -eq 1 ]] && echo yes || echo no)"
echo "    size:       $(du -h "$ZIP" | cut -f 1 | tr -d ' ')"
echo "    sha256:     $SHA256  ($ZIP.sha256)"
if [[ "$NOTARIZED" -eq 0 ]]; then
    echo
    echo "note: this zip is NOT notarized. It is ad-hoc signed only, so Gatekeeper blocks the first"
    echo "      launch of a downloaded copy until the user allows it (Privacy & Security > Open Anyway,"
    echo "      or: xattr -dr com.apple.quarantine /Applications/Tokenamp.app)."
    echo "      To notarize, set TOKENAMP_SIGN_IDENTITY and TOKENAMP_NOTARY_PROFILE (see packaging/README.md)."
fi
