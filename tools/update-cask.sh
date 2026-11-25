#!/bin/zsh
# Подставляет версию и SHA-256 релизного архива в cask.
#   tools/update-cask.sh <TrackTasks-1.0.zip> [путь/к/tracktasks.rb]
# Версия берётся из имени архива (TrackTasks-<версия>.zip). Без второго аргумента правится
# packaging/homebrew/Casks/tracktasks.rb. Ничего не публикует.
set -euo pipefail
ZIP="${1:-}"
CASK="${2:-${0:A:h}/../packaging/homebrew/Casks/tracktasks.rb}"
[[ -f "$ZIP" ]] || { echo "Использование: tools/update-cask.sh <TrackTasks-версия.zip> [cask.rb]" >&2; exit 2; }
[[ -f "$CASK" ]] || { echo "Нет файла cask: $CASK" >&2; exit 2; }
NAME="${ZIP:t}"
[[ "$NAME" =~ '^TrackTasks-([0-9]+(\.[0-9]+){1,2})\.zip$' ]] || { echo "Имя архива должно быть TrackTasks-<версия>.zip (не dry-run): $NAME" >&2; exit 1; }
VERSION="$match[1]"
SUM="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
[[ "$SUM" =~ '^[0-9a-f]{64}$' ]] || { echo "Не удалось посчитать сумму" >&2; exit 1; }
# Рядом с архивом лежит .sha256 от release.sh: сверяем, если он есть.
if [[ -f "$ZIP.sha256" ]]; then
  [[ "$(cut -d' ' -f1 "$ZIP.sha256")" == "$SUM" ]] || { echo "Сумма не совпадает с $NAME.sha256" >&2; exit 1; }
fi
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
sed -E -e "s/^( *version \")[^\"]*(\")/\1$VERSION\2/" -e "s/^( *sha256 \")[^\"]*(\")/\1$SUM\2/" "$CASK" > "$TMP"
grep -q "version \"$VERSION\"" "$TMP" && grep -q "sha256 \"$SUM\"" "$TMP" || { echo "В cask не найдены строки version/sha256" >&2; exit 1; }
cat "$TMP" > "$CASK"
ruby -c "$CASK" >/dev/null
echo "Cask: версия $VERSION, sha256 $SUM"
