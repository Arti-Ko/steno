#!/usr/bin/env bash
# Собирает артефакты выпуска:
#   dist/Steno.dmg — установщик (перетащить в «Программы»),
#   dist/Steno.zip — архив, который скачивает встроенное автообновление.
# Использование: Scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Steno.app"

"$ROOT/Scripts/build.sh"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

rm -f "$DIST/Steno.zip" "$DIST/Steno.dmg"

echo "==> архив для автообновления"
ditto -c -k --keepParent "$APP" "$DIST/Steno.zip"

echo "==> установщик DMG"
ditto "$APP" "$STAGING/Steno.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Steno" -srcfolder "$STAGING" -ov -format UDZO "$DIST/Steno.dmg" >/dev/null

echo "готово: $DIST/Steno.dmg, $DIST/Steno.zip"
