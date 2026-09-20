#!/bin/bash
# package.sh —— 打发布包（给别人下载用）
#
# 用法: bash package.sh
# 产物: dist/BianJieFanYi-macOS-<版本>.zip（里面是 便捷翻译.app + 安装.command + 使用说明）
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

# 应用名/版本号都从 build.sh 里取，避免两处写死对不上
APP_NAME="$(grep -m1 '^APP_NAME=' build.sh | cut -d'"' -f2)"
VERSION="$(grep -m1 '^APP_VERSION=' build.sh | cut -d'"' -f2)"
DIST="dist"
# 发布包用 ASCII 文件名：中文名贴到聊天/终端里会变成一长串百分号编码
ZIP="$DIST/BianJieFanYi-macOS-$VERSION.zip"

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

# 一键安装脚本：双击就能装到「应用程序」并自动解除 Gatekeeper 隔离。
# 注意这里用带引号的 heredoc（'SH'）：里面的 $APP / $0 必须留到**对方机器上**再展开；
# 若让生成时就展开，`cd "$(dirname "$0")"` 会被替换成本脚本的目录（错得离谱）。
# 所以应用名不写死，改成在对方机器上用通配符找 .app。
cat > "$DIST/$APP_NAME/安装.command" <<'SH'
#!/bin/bash
# 一键安装：拷到「应用程序」并解除 Gatekeeper 隔离
set -e
cd "$(dirname "$0")"
APP="$(ls -d *.app 2>/dev/null | head -1)"
[ -n "$APP" ] || { echo "✗ 当前目录里没找到 .app，请确保它和本脚本在同一层"; read -r -p "回车退出"; exit 1; }
NAME="$(basename "$APP")"
echo "正在安装「$NAME」…"
if [ -w /Applications ]; then
    rm -rf "/Applications/$NAME"; cp -R "$APP" "/Applications/$NAME"
else
    echo "需要管理员权限写入「应用程序」目录，请输入密码："
    sudo rm -rf "/Applications/$NAME"; sudo cp -R "$APP" "/Applications/$NAME"
fi
# 解除隔离标记：从网上下载的文件会被打上 com.apple.quarantine，不去掉会被 Gatekeeper 拦
xattr -dr com.apple.quarantine "/Applications/$NAME" 2>/dev/null || true
open "/Applications/$NAME"
echo
echo "✓ 装好了，已经启动。菜单栏会有图标，点它就能用。"
echo "  首次用「选区浮窗」需要去 系统设置 → 隐私与安全性 → 辅助功能 给「$NAME」打勾。"
read -r -p "回车关闭本窗口"
SH
chmod +x "$DIST/$APP_NAME/安装.command"

# 说明文件里没有 $ 和反引号，所以用不带引号的 heredoc，好把应用名插进去
cat > "$DIST/$APP_NAME/使用说明.txt" <<TXT
${APP_NAME} —— macOS 菜单栏翻译工具
================================

安装
----
双击「安装.command」，输入管理员密码即可（脚本会把 app 放进「应用程序」
并自动去掉 Gatekeeper 隔离标记）。

如果不想跑脚本，手动装也行：
  1. 把「${APP_NAME}.app」拖进「应用程序」
  2. 打开「终端」执行一次（去掉隔离标记，否则会被系统拦住）：
       xattr -dr com.apple.quarantine "/Applications/${APP_NAME}.app"
  3. 双击打开

系统要求
--------
macOS 15.0 或更高（用到了苹果自带的离线翻译框架）。
Intel 与 Apple Silicon 都可以（universal 二进制）。

首次使用
--------
1. 打开后没有 Dock 图标也没有窗口 —— 它在菜单栏。看屏幕右上角找图标。
2. 全局呼出窗口：⌥Space
3. 划词翻译（可选，推荐）：菜单栏图标 → 设置 → 打开「开启选区浮窗」，
   按提示到 系统设置 → 隐私与安全性 → 辅助功能 给「${APP_NAME}」打勾。
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
