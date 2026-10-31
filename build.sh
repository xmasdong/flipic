#!/bin/bash
# 构建 Flipic.app：swift build + 手工组装 .app bundle + 临时签名
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Flipic.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Flipic" "$APP/Contents/MacOS/Flipic"
strip -x "$APP/Contents/MacOS/Flipic" 2>/dev/null || true
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "Resources/Flipic.icns" ]; then
    cp "Resources/Flipic.icns" "$APP/Contents/Resources/"
fi
LANGS="zh-Hans zh-Hant en ja ko fr de es it pt-BR ru ar tr vi"
for lang in $LANGS; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "Resources/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/"
done
codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
echo "✔ 构建完成: $APP"
