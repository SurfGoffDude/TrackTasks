#!/bin/zsh
# Лента обновлений для одного готового архива: tools/make-appcast.sh <архив.zip> <appcast.xml>
# Окружение: TT_DOWNLOAD_PREFIX, TT_SPARKLE_PUBLIC_KEY, TT_SPARKLE_ACCOUNT (запись Keychain с приватным ключом).
# Ничего не публикует. Лента содержит только этот архив, без дельт.
set -euo pipefail
(( $# == 2 )) || { echo "Использование: $0 <архив.zip> <appcast.xml>" >&2; exit 2; }
ZIP="${1:A}"
OUT="${2:A}"
ROOT="${0:A:h}/.."
BIN="${TT_SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
for v in TT_DOWNLOAD_PREFIX TT_SPARKLE_PUBLIC_KEY; do
  [[ -n "${(P)v:-}" ]] || { echo "Не задан $v" >&2; exit 1; }
done
# TT_SPARKLE_KEY_FILE — только для проверки скрипта временным ключом.
if [[ -n "${TT_SPARKLE_KEY_FILE:-}" ]]; then
  KEY=(--ed-key-file "$TT_SPARKLE_KEY_FILE")
else
  [[ -n "${TT_SPARKLE_ACCOUNT:-}" ]] || { echo "Не задан TT_SPARKLE_ACCOUNT" >&2; exit 1; }
  KEY=(--account "$TT_SPARKLE_ACCOUNT")
fi
for t in generate_appcast sign_update; do
  [[ -x "$BIN/$t" ]] || { echo "Нет $BIN/$t — сначала swift package resolve" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ZIP" "$WORK/"
"$BIN/generate_appcast" "${KEY[@]}" --download-url-prefix "$TT_DOWNLOAD_PREFIX" --maximum-deltas 0 -o "$WORK/appcast.xml" "$WORK"
[[ -s "$WORK/appcast.xml" ]] || { echo "Лента не создана" >&2; exit 1; }

# Подписи проверяются публичным ключом из приложения, а не той же записью Keychain:
# иначе релиз, подписанный не тем ключом, прошёл бы, а установленные копии его отклонили бы.
swift "$ROOT/tools/check-appcast.swift" "$WORK/appcast.xml" "$ZIP" "$TT_SPARKLE_PUBLIC_KEY"
mv -f "$WORK/appcast.xml" "$OUT"
echo "Лента: $OUT"
