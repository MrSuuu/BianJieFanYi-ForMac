#!/bin/bash
# package.sh —— 打发布包（给别人下载用）
#
# 用法: bash package.sh
# 产物: dist/译-macOS-<版本>.zip   （里面是 译.app + 安装说明）
#
# 与 build.sh 的区别（两个是不同用途，别混）：
#   build.sh   → 本地开发用：只编本机架构、用自签证书签名（TCC 授权能跨重建存活）
#   package.sh → 发布用：编 universal(x86_64+arm64)、换 ad-hoc 签名、打包成 zip
#
# 为什么要编双架构：本机是 Intel，只编 x86_64 的话 Apple Silicon 用户
#   得先装 Rosetta 2 才能跑，体验差一截。
# 为什么发布版换 ad-hoc 签名：自签证书只存在于本机钥匙串，
#   别人机器上没这张证书，带着它反而会让系统提示"签名者身份未知"。
#   ad-hoc 是通用的"无身份签名"，对方只需绕过一次 Gatekeeper 隔离即可。

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="译"
VERSION="$(grep -m1 '^APP_VERSION=' build.sh | cut -d'"' -f2)"
DIST="dist"
ZIP="$DIST/$APP_NAME-macOS-$VERSION.zip"

echo "═══════════════════════════════════════"
echo " 打发布包 $APP_NAME $VERSION"
echo "═══════════════════════════════════════"

# ---- 1. universal + ad-hoc 签名 ----
ARCHS="x86_64 arm64" SIGN_MODE=adhoc bash build.sh

if ! lipo -archs "$APP_NAME.app/Contents/MacOS/$APP_NAME" | grep -q "arm64"; then
    echo "✗ 不是 universal 二进制，检查 lipo 那步"
    exit 1
fi
echo "→ 架构: $(lipo -archs "$APP_NAME.app/Contents/MacOS/$APP_NAME")"

# ---- 2. 组装发布目录 ----
rm -rf "$DIST"
mkdir -p "$DIST/$APP_NAME"
cp -R "$APP_NAME.app" "$DIST/$APP_NAME/"

# 一键安装脚本：双击就能装到「应用程序」并自动解除 Gatekeeper 隔离
cat > "$DIST/$APP_NAME/安装.command" <<'SH'
#!/bin/bash
# 「译」一键安装：拷到「应用程序」并解除 Gatekeeper 隔离
set -e
cd "$(dirname "$0")"
APP="译.app"
echo "正在安装「译」…"
if [ ! -d "$APP" ]; then echo "✗ 没找到 $APP，请确保它和本脚本在同一目录"; read -r -p "回车退出"; exit 1; fi
# 复制（要写 /Applications，可能需要管理员密码）
if [ -w /Applications ]; then
    rm -rf "/Applications/$APP"; cp -R "$APP" "/Applications/$APP"
else
    echo "需要管理员权限写入「应用程序」目录，请输入密码："
    sudo rm -rf "/Applications/$APP"; sudo cp -R "$APP" "/Applications/$APP"
fi
# 解除隔离标记：从网上下载的 app 会被打上 com.apple.quarantine，不去掉会被 Gatekeeper 拦
xattr -dr com.apple.quarantine "/Applications/$APP" 2>/dev/null || true
open "/Applications/$APP"
echo
echo "✓ 装好了，已经启动。菜单栏会有「译」的图标，点它就能用。"
echo "  首次用「选区浮窗」需要去 系统设置 → 隐私与安全性 → 辅助功能 给「译」打勾。"
read -r -p "回车关闭本窗口"
SH
chmod +x "$DIST/$APP_NAME/安装.command"

cat > "$DIST/$APP_NAME/使用说明.txt" <<'TXT'
「译」—— macOS 菜单栏翻译工具
================================

安装
----
双击「安装.command」，输入管理员密码即可（脚本会把 app 放进「应用程序」
并自动去掉 Gatekeeper 隔离标记）。

如果不想跑脚本，手动装也行：
  1. 把「译.app」拖进「应用程序」
  2. 打开「终端」执行一次（去掉隔离标记，否则会被系统拦住）：
       xattr -dr com.apple.quarantine /Applications/译.app
  3. 双击打开

系统要求
--------
macOS 15.0 或更高（用到了苹果自带的离线翻译框架）。
Intel 与 Apple Silicon 都可以（universal 二进制）。

首次使用
--------
1. 打开后没有 Dock 图标也没有窗口 —— 它在菜单栏。看屏幕右上角找「译」图标。
2. 全局呼出窗口：⌥Space
3. 划词翻译（可选，推荐）：菜单栏「译」→ 设置 → 打开「开启选区浮窗」，
   按提示到 系统设置 → 隐私与安全性 → 辅助功能 给「译」打勾。
   之后在任意软件里选中文字，就会在旁边浮出翻译面板。
TXT

# ---- 3. 打包 ----
# ditto 而不是 zip：保留 bundle 的元数据与资源分叉，否则解压出来 app 可能签名失效
cd "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "../$ZIP"
cd ..
rm -rf "$DIST/$APP_NAME"

echo
echo "✓ 完成: $(pwd)/$ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "  内含: $APP_NAME.app（universal）+ 安装.command + 使用说明.txt"
