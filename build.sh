#!/bin/bash
# 构建 PixDeck.app：swift build + 手工组装 .app bundle + 临时签名
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/PixDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/PixDeck" "$APP/Contents/MacOS/PixDeck"
strip -x "$APP/Contents/MacOS/PixDeck" 2>/dev/null || true
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "Resources/PixDeck.icns" ]; then
    cp "Resources/PixDeck.icns" "$APP/Contents/Resources/"
fi
LANGS="zh-Hans zh-Hant en ja ko fr de es it pt-BR ru ar tr vi"
for lang in $LANGS; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "Resources/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/"
done
codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
echo "✔ 构建完成: $APP"
