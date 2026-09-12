#!/bin/bash
# 编译 + 安装到 ~/Applications + 启动
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Applications"
APPNAME="DeepSeek Balance.app"

"$ROOT/build.sh"

echo "==> 停止正在运行的旧实例"
pkill -f "DeepSeekBalance" 2>/dev/null || true
sleep 0.5

echo "==> 安装到 $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/$APPNAME"
cp -R "$ROOT/$APPNAME" "$DEST/"

echo "==> 启动"
open "$DEST/$APPNAME"
sleep 1
echo
echo "已启动 ✅  请看屏幕右上角菜单栏：¥ 余额 + 绿点(谷) / 橙点(峰)"
echo "应用位置：$DEST/$APPNAME"
