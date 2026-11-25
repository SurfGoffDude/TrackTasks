#!/bin/zsh
# Версия задаётся один раз — CLI.version в Sources/TrackTasksCore/CLI.swift. Скрипт печатает её,
# а с путём к Info.plist ещё и вписывает в него.
set -euo pipefail
SRC="${0:A:h}/../Sources/TrackTasksCore/CLI.swift"
VERSION="$(sed -nE 's/^ *public static let version = "([0-9]+(\.[0-9]+){1,2})".*/\1/p' "$SRC")"
[[ "$VERSION" =~ '^[0-9.]+$' ]] || { echo "Не найдена версия вида 1.2 или 1.2.3: CLI.version в $SRC" >&2; exit 1; }
if [[ -n "${1:-}" ]]; then
  for key in CFBundleShortVersionString CFBundleVersion; do
    plutil -replace "$key" -string "$VERSION" "$1"
  done
fi
echo "$VERSION"
