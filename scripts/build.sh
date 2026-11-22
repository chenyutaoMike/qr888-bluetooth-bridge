#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

architecture=${1:-universal}
app=${2:-"$PWD/build/QR888 Bluetooth Bridge.app"}
if [[ "$app" != /* ]]; then app="$PWD/$app"; fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/qr888-build.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
candidate="$scratch/QR888 Bluetooth Bridge.app"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
cp Sources/Info.plist "$candidate/Contents/Info.plist"
cp Examples/test-label-100x100.pdf "$candidate/Contents/Resources/"
cp LICENSE "$candidate/Contents/Resources/"

compile() {
  xcrun --sdk macosx swiftc -target "$1-apple-macos11.0" -O Sources/*.swift -o "$2"
}

binary="$candidate/Contents/MacOS/QR888BluetoothBridge"
case "$architecture" in
  universal)
    compile arm64 "$scratch/arm64"
    compile x86_64 "$scratch/x86_64"
    xcrun lipo -create "$scratch/arm64" "$scratch/x86_64" -output "$binary"
    xcrun lipo "$binary" -verify_arch arm64 x86_64
    ;;
  arm64|x86_64) compile "$architecture" "$binary" ;;
  *) printf 'Usage: %s [universal|arm64|x86_64] [path/to/App.app]\n' "$0" >&2; exit 1 ;;
esac

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$candidate"
else
  codesign --force --sign - "$candidate"
fi
codesign --verify --strict "$candidate"
if [[ -e "$app" ]]; then
  printf 'Output already exists: %s\n' "$app" >&2
  exit 1
fi
mkdir -p "$(dirname -- "$app")"
ditto "$candidate" "$app"
printf '%s\n' "$app"
