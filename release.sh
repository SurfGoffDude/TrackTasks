#!/bin/zsh
# Релиз: universal TrackTasks.app (tt внутри), hardened runtime, Developer ID, нотаризация, staple, zip и SHA-256.
#   TT_SIGN_IDENTITY="Developer ID Application: …" TT_NOTARY_PROFILE=<профиль notarytool> ./release.sh
#   Обновления (всё вместе или ничего): TT_FEED_URL=https://…/appcast.xml TT_DOWNLOAD_PREFIX=https://…/
#     TT_SPARKLE_PUBLIC_KEY=<ключ> TT_SPARKLE_ACCOUNT=<запись Keychain с приватным ключом>
#   ./release.sh --dry-run   — те же шаги на ad-hoc подписи, Apple ничего не отправляется
set -euo pipefail
cd "$(dirname "$0")"

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "Использование: ./release.sh [--dry-run]" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { echo "Использование: ./release.sh [--dry-run]" >&2; exit 2; }

# Предпосылки: собрать все проблемы сразу, до сборки.
PROBLEMS=()
for t in swift codesign ditto lipo plutil shasum xcrun git; do
  command -v $t >/dev/null || PROBLEMS+=("нет программы $t")
done
VERSION="$(tools/stamp-version.sh)" || PROBLEMS+=("не определена версия")
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw Info.plist)"
plutil -lint -s release.entitlements || PROBLEMS+=("release.entitlements не читается")
if (( ! DRY )); then
  IDENTITY="${TT_SIGN_IDENTITY:-}"
  PROFILE="${TT_NOTARY_PROFILE:-}"
  if [[ -z "$IDENTITY" ]]; then
    PROBLEMS+=("не задан TT_SIGN_IDENTITY (список: security find-identity -v -p codesigning)")
  elif [[ "$IDENTITY" != "Developer ID Application: "* ]]; then
    PROBLEMS+=("TT_SIGN_IDENTITY — не «Developer ID Application: …», для нотаризации нужен он")
  elif ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    PROBLEMS+=("в Keychain нет действующего сертификата «$IDENTITY»")
  fi
  for t in notarytool stapler; do
    xcrun --find $t >/dev/null 2>&1 || PROBLEMS+=("нет xcrun $t (нужен Xcode)")
  done
  if [[ -z "$PROFILE" ]]; then
    PROBLEMS+=("не задан TT_NOTARY_PROFILE (создать: xcrun notarytool store-credentials <имя>)")
  elif (( ! $#PROBLEMS )) && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    PROBLEMS+=("профиль notarytool «$PROFILE» не найден или Apple его не принимает")
  fi
  [[ "$BUNDLE_ID" != local.* ]] || PROBLEMS+=("в Info.plist временный идентификатор $BUNDLE_ID — сменить до публикации")
  [[ -z "$(git status --porcelain)" ]] || PROBLEMS+=("есть незакоммиченные изменения")
fi
# Обновления: либо настроены полностью, либо их нет. Приватный ключ остаётся в Keychain.
UPDATES=0
if (( ! DRY )); then
  MISSING=()
  for v in TT_FEED_URL TT_DOWNLOAD_PREFIX TT_SPARKLE_PUBLIC_KEY TT_SPARKLE_ACCOUNT; do
    [[ -n "${(P)v:-}" ]] || MISSING+=($v)
  done
  if (( $#MISSING == 0 )); then
    UPDATES=1
    for v in TT_FEED_URL TT_DOWNLOAD_PREFIX; do
      [[ "${(P)v}" == https://?* ]] || PROBLEMS+=("$v — не https")
    done
    [[ "$TT_DOWNLOAD_PREFIX" == */ ]] || PROBLEMS+=("TT_DOWNLOAD_PREFIX не кончается на /")
    KEY_BYTES="$(print -rn -- "$TT_SPARKLE_PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" || KEY_BYTES=0
    [[ "$KEY_BYTES" == 32 ]] || PROBLEMS+=("TT_SPARKLE_PUBLIC_KEY — не ключ Ed25519 (base64, 32 байта)")
  elif (( $#MISSING < 4 )); then
    PROBLEMS+=("обновления настроены не полностью, не задано: ${(j:, :)MISSING}")
  fi
fi
if (( $#PROBLEMS )); then
  echo "Релиз невозможен:" >&2
  printf '  - %s\n' "${PROBLEMS[@]}" >&2
  exit 1
fi

if (( DRY )); then
  SIGN=(--sign - --timestamp=none)
  OUT=build/release-dry-run
  NAME="TrackTasks-$VERSION-dry-run.zip"
else
  SIGN=(--sign "$IDENTITY" --timestamp)
  OUT=build/release
  NAME="TrackTasks-$VERSION.zip"
fi
APP="$OUT/TrackTasks.app"
TT="$APP/Contents/Helpers/tt"
ZIP="$OUT/$NAME"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/TrackTasks" "$APP/Contents/MacOS/"
cp "$BIN/tt" "$TT"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN/Sparkle.framework" "$SPARKLE"
# XPC-службы нужны только приложениям в песочнице.
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"
cp Info.plist "$APP/Contents/"
if (( UPDATES )); then
  PLIST="$APP/Contents/Info.plist"
  plutil -insert SUFeedURL -string "$TT_FEED_URL" "$PLIST"
  plutil -insert SUPublicEDKey -string "$TT_SPARKLE_PUBLIC_KEY" "$PLIST"
  plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$PLIST"
  plutil -insert SURequireSignedFeed -bool YES "$PLIST"
  plutil -insert SUAllowsAutomaticUpdates -bool NO "$PLIST"
  plutil -insert SUEnableSystemProfiling -bool NO "$PLIST"
else
  echo "Обновления: выключены — в сборке нет адреса ленты и ключа"
fi
tools/stamp-version.sh "$APP/Contents/Info.plist" >/dev/null
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
NESTED=("$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE")
for f in "$APP/Contents/MacOS/TrackTasks" "$TT" "$SPARKLE/Versions/B/"{Sparkle,Autoupdate,Updater.app/Contents/MacOS/Updater}; do
  A=" $(lipo -archs "$f") "
  [[ "$A" == *" arm64 "* && "$A" == *" x86_64 "* ]] || { echo "Не universal: $f" >&2; exit 1; }
done
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
TT_VERSION="$("$TT" --version)"
[[ "$TT_VERSION" == "tt $APP_VERSION "* ]] || { echo "Версии разошлись: приложение $APP_VERSION, $TT_VERSION" >&2; exit 1; }

# Изнутри наружу; tt — без entitlements: Напоминания и Apple Events использует только приложение.
for f in "${NESTED[@]}"; do
  codesign --force --options runtime "${SIGN[@]}" "$f"
done
codesign --force --options runtime "${SIGN[@]}" --identifier "$BUNDLE_ID.tt" "$TT"
codesign --force --options runtime "${SIGN[@]}" --entitlements release.entitlements "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
for f in "${NESTED[@]}" "$TT" "$APP"; do
  INFO="$(codesign -d --verbose=2 "$f" 2>&1)"
  [[ "$INFO" == *flags=*runtime* ]] || { echo "Нет hardened runtime: $f" >&2; exit 1; }
done

if (( ! DRY )); then
  UPLOAD="$OUT/notarize.zip"
  ditto -c -k --keepParent "$APP" "$UPLOAD"
  # Код выхода notarytool не различает Invalid и Accepted: смотреть status.
  RESULT="$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait --output-format json)" || true
  STATUS="$(print -r -- "$RESULT" | plutil -extract status raw - 2>/dev/null)" || STATUS=""
  ID="$(print -r -- "$RESULT" | plutil -extract id raw - 2>/dev/null)" || ID=""
  if [[ "$STATUS" != Accepted ]]; then
    echo "Нотаризация не пройдена: ${STATUS:-нет ответа}" >&2
    print -r -- "$RESULT" >&2
    [[ -z "$ID" ]] || xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
  rm -f "$UPLOAD"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  codesign --verify --strict --deep "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# zip — только после staple; проверяется распакованная копия.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --strict --deep "$CHECK/TrackTasks.app"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256" && shasum -c "$NAME.sha256")
echo "Готово: $ZIP ($(du -h "$ZIP" | cut -f1))"
if (( UPDATES )); then
  tools/make-appcast.sh "$ZIP" "$OUT/appcast.xml"
fi
(( DRY )) && echo "Проверочная сборка: ad-hoc подпись, не нотаризована, не для раздачи." || true
