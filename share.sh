#!/bin/zsh
# Собирает TrackTasks для друга: universal (Apple Silicon + Intel), ad-hoc подпись, zip с инструкцией.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
OUT=build/share
APP="$OUT/TrackTasks.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/TrackTasks" "$APP/Contents/MacOS/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Info.plist "$APP/Contents/"
tools/stamp-version.sh "$APP/Contents/Info.plist" >/dev/null
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
cp "share/Как установить.md" "$OUT/"
ZIP="build/TrackTasks.zip"
rm -f "$ZIP"
# ditto сохраняет подпись и атрибуты .app
(cd "$OUT" && ditto -c -k --sequesterRsrc . "../TrackTasks.zip")
echo "Готово: $ZIP ($(du -h "$ZIP" | cut -f1))"
