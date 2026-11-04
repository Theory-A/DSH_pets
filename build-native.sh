#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Use the developer's selected Xcode SDK; respect an explicit DEVELOPER_DIR.
APP="$ROOT/app/DSH Window Cat.app"
BREEDS=(silver-siberian tuxedo sheltie)
for BREED in "${BREEDS[@]}"; do
  for KIND in colony mini; do
    ATLAS="$ROOT/art/${BREED}-${KIND}.png"
    if [[ ! -f "$ATLAS" ]]; then
      printf 'Missing parent-generated pet atlas: %s\n' "$ATLAS" >&2
      exit 1
    fi
  done
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/native/.module-cache"
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -sdk "$(/usr/bin/xcrun --show-sdk-path)" \
  -module-cache-path "$ROOT/native/.module-cache" \
  -framework AppKit -framework ApplicationServices -framework ImageIO \
  "$ROOT/native/main.swift" -o "$APP/Contents/MacOS/DSHWindowCat"
/usr/bin/ditto "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
for BREED in "${BREEDS[@]}"; do
  for KIND in colony mini; do
    /usr/bin/ditto "$ROOT/art/${BREED}-${KIND}.png" "$APP/Contents/Resources/${BREED}-${KIND}.png"
  done
done
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
# Explicit ad-hoc identity: no certificate lookup, keychain, or notarization.
/usr/bin/codesign --force --sign - --identifier local.dsh.window-cat "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
"$APP/Contents/MacOS/DSHWindowCat" --self-test
if [[ -f "$ROOT/menagerie/native-fixtures.json" ]]; then
  "$APP/Contents/MacOS/DSHWindowCat" --validate-fixtures "$ROOT/menagerie/native-fixtures.json"
fi
printf 'Built: %s\n' "$APP/Contents/MacOS/DSHWindowCat"
