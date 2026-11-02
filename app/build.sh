#!/bin/zsh
#
#  构建 键盘背光.app（无需 Xcode，只用 Command Line Tools）
#  产物：~/Desktop/kbdlight-build/app/键盘背光.app
#
set -e
cd "$(dirname "$0")"

APP="键盘背光.app"
OUT="$PWD/$APP"
BIN="$OUT/Contents/MacOS/KbdLight"

echo "==> 清理"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "==> 编译 Swift"
swiftc -O -swift-version 5 \
    -target x86_64-apple-macos13.0 \
    -parse-as-library \
    -framework SwiftUI -framework AppKit \
    -o "$BIN" \
    Sources/KbdLightApp.swift

echo "==> 图标"
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi

echo "==> Info.plist"
cp Info.plist "$OUT/Contents/Info.plist"
plutil -lint "$OUT/Contents/Info.plist" >/dev/null

echo "==> 签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$OUT" >/dev/null 2>&1

echo "==> 完成：$OUT"
du -sh "$OUT"
