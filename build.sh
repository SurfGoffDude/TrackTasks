#!/bin/zsh
# Собирает TrackTasks.app и CLI tt. Флаг --install копирует приложение в ~/Applications, tt — в ~/.local/bin (или $TT_BIN_DIR).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/TrackTasks.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/TrackTasks "$APP/Contents/MacOS/"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp Info.plist "$APP/Contents/"
tools/stamp-version.sh "$APP/Contents/Info.plist" >/dev/null
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/TrackTasks.app
  cp -R "$APP" ~/Applications/
  # Не держим вторую копию: иначе Spotlight/Launchpad показывают две TrackTasks.
  rm -rf "$APP"
  echo "Installed ~/Applications/TrackTasks.app"
  BIN_DIR="${TT_BIN_DIR:-$HOME/.local/bin}"
  # Чужую программу с тем же именем не трогаем.
  if [[ -e "$BIN_DIR/tt" || -L "$BIN_DIR/tt" ]] && ! grep -qa TrackTasks "$BIN_DIR/tt"; then
    echo "Пропущено: $BIN_DIR/tt — другая программа (задай TT_BIN_DIR)" >&2
  else
    mkdir -p "$BIN_DIR"
    # Через mv: перезапись на месте убила бы уже запущенный tt.
    cp .build/release/tt "$BIN_DIR/.tt.new"
    mv -f "$BIN_DIR/.tt.new" "$BIN_DIR/tt"
    echo "Installed $BIN_DIR/tt"
    [[ ":$PATH:" == *":$BIN_DIR:"* ]] || echo "Добавь $BIN_DIR в PATH"
  fi
fi
