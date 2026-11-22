#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

if [[ -n "${NOTARY_PROFILE:-}" && -z "${SIGN_IDENTITY:-}" ]]; then
  printf 'SIGN_IDENTITY is required to notarize.\n' >&2
  exit 1
fi
release=${1:-"$PWD/dist"}
if [[ "$release" != /* ]]; then release="$PWD/$release"; fi
mkdir -p "$release"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Info.plist)
variant=local-test
if [[ -n "${SIGN_IDENTITY:-}" ]]; then variant=signed; fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then variant=notarized; fi
name="QR888-Bluetooth-Bridge-$version-$variant.dmg"
if [[ -e "$release/$name" || -e "$release/$name.sha256" ]]; then
  printf 'Output already exists: %s\n' "$release/$name" >&2
  exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/qr888-package.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/image"
scripts/build.sh universal "$scratch/image/QR888 Bluetooth Bridge.app"
ln -s /Applications "$scratch/image/Applications"
cp docs/快速开始.txt "$scratch/image/"
hdiutil create -quiet -format UDZO -fs HFS+ -volname 'QR888 Bluetooth Bridge' \
  -srcfolder "$scratch/image" "$scratch/$name"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --timestamp --sign "$SIGN_IDENTITY" "$scratch/$name"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$scratch/$name" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$scratch/$name"
  xcrun stapler validate "$scratch/$name"
fi
hdiutil verify -quiet "$scratch/$name"
mv "$scratch/$name" "$release/$name"
(cd "$release" && shasum -a 256 "$name" > "$name.sha256")
printf '%s\n' "$release/$name"
