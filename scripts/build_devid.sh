#!/bin/bash
# 构建 App Store 之外分发的 PixDeck：通用二进制 + Developer ID 签名 + 公证 + DMG
# 不开沙盒：沙盒下双击单张图拿不到同文件夹其他图片的读取权限，核心的连续翻页会失效
set -euo pipefail
cd "$(dirname "$0")/.."

# 签名与公证凭据从 scripts/devid.env 读取（不进版本库），格式见 scripts/devid.env.example
ENV_FILE="scripts/devid.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
: "${IDENTITY:?缺少 IDENTITY（Developer ID Application 证书名）}"
: "${KEY_ID:?缺少 KEY_ID（App Store Connect API Key ID）}"
: "${ISSUER:?缺少 ISSUER（App Store Connect Issuer ID）}"
KEY_PATH="${KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
OUT="build/devid"
APP="$OUT/PixDeck.app"
DMG="$OUT/PixDeck-$VERSION.dmg"

swift build -c release --arch arm64 --arch x86_64

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/apple/Products/Release/PixDeck" "$APP/Contents/MacOS/PixDeck"
strip -x "$APP/Contents/MacOS/PixDeck"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/PixDeck.icns" "$APP/Contents/Resources/"
LANGS="zh-Hans zh-Hant en ja ko fr de es it pt-BR ru ar tr vi"
for lang in $LANGS; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "Resources/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/"
done

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

STAGE="$OUT/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PixDeck" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "✔ 分发包: $DMG"
