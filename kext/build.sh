#!/bin/zsh
#
#  构建 TongfangKbd.kext —— 只需要 Command Line Tools，不需要完整 Xcode
#
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk macosx --show-sdk-path)
KH="$SDK/System/Library/Frameworks/Kernel.framework/Headers"

BUNDLE=TongfangKbd.kext
BIN="$BUNDLE/Contents/MacOS/TongfangKbd"

echo "==> SDK: $SDK"
rm -rf "$BUNDLE" TongfangKbd.o
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "==> 编译"
clang -x c++ -std=gnu++11 -arch x86_64 -mkernel -fapple-kext \
      -fno-rtti -fno-exceptions -fno-builtin -nostdinc -nostdlibinc \
      -DKERNEL -DKERNEL_PRIVATE \
      -I "$KH" -I "$SDK/usr/include" \
      -c TongfangKbd.cpp -o TongfangKbd.o

echo "==> 链接（-kext，不能加 -r）"
ld -arch x86_64 -kext -o "$BIN" TongfangKbd.o

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$BUNDLE"

rm -f TongfangKbd.o
echo "==> 完成：$(pwd)/$BUNDLE"
file "$BIN"
