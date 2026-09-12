#!/bin/bash
# 编译并打包 DeepSeek Balance.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/DeepSeek Balance.app"
BUILD="$ROOT/.build"

echo "==> 清理旧产物"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

echo "==> 编译主程序"
swiftc -O -swift-version 5 "$ROOT/Sources/main.swift" \
    -o "$APP/Contents/MacOS/DeepSeekBalance" \
    -framework AppKit

echo "==> 生成图标"
if swiftc -O -swift-version 5 "$ROOT/Tools/MakeIcon.swift" -o "$BUILD/makeicon" >/dev/null 2>&1 \
   && "$BUILD/makeicon" "$BUILD" >/dev/null 2>&1 \
   && iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
    echo "    图标 OK"
else
    echo "    图标生成失败，跳过（不影响功能）"
fi

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DeepSeek Balance</string>
    <key>CFBundleDisplayName</key><string>DeepSeek Balance</string>
    <key>CFBundleIdentifier</key><string>com.deepseek.balance</string>
    <key>CFBundleExecutable</key><string>DeepSeekBalance</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "    已签名" || echo "    签名跳过（不影响本机运行）"

echo "==> 完成：$APP"
