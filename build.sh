#!/bin/bash
# build.sh —— 把 Swift 源码编译成可直接拖进 Dock 的 .app
#
# 用法:  bash build.sh
# 产物:  ./译.app
#
# 说明：用 swiftc 直接编译，不依赖 Xcode 工程文件。
#       Translation 框架是 Apple 的离线翻译引擎（macOS 15+），不联网、不需要 API key。

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="便捷翻译"
APP_DIR="$APP_NAME.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SRC="Sources/main.swift"
APP_VERSION="3.3"        # 发布用版本号（改了记得同步 README 和 package.sh）
APP_BUILD="33"

# ARCHS：要编的架构，空格分隔。默认只编本机（Intel）用的 x86_64，构建最快；
#        发布给别人时用 `ARCHS="x86_64 arm64" bash build.sh` 编 universal，
#        否则 Apple Silicon 用户得靠 Rosetta 转译。
# SIGN_MODE：identity（默认，用自签证书签 → TCC 授权可跨重建存活）
#            adhoc（发布用：换成通用 ad-hoc 签名，不引用本机证书）
ARCHS="${ARCHS:-x86_64}"
SIGN_MODE="${SIGN_MODE:-identity}"

echo "═══════════════════════════════════════"
echo " 构建 $APP_DIR"
echo "═══════════════════════════════════════"
echo "SDK   : $(basename "$SDK")"
echo "架构  : $ARCHS"
echo "签名  : $SIGN_MODE"
echo "Swift : $(xcrun swift --version 2>&1 | grep -o 'Swift version [0-9.]*' | head -1)"
echo

# ---- 1. 编译 ----
# -parse-as-library 是必须的：源码里有 @main，不加会被当成脚本报「不能在含顶层代码的模块里用 @main」
echo "→ [1/4] 编译 (macOS 15.0+)"
rm -rf .build
mkdir -p .build
SLICES=()
for arch in $ARCHS; do
    echo "   · $arch"
    xcrun swiftc -O -parse-as-library \
        -target "${arch}-apple-macosx15.0" \
        -sdk "$SDK" \
        "$SRC" \
        -o ".build/$APP_NAME-$arch"
    SLICES+=(".build/$APP_NAME-$arch")
done
if [ "${#SLICES[@]}" -gt 1 ]; then
    # lipo 把多个架构合成一个 universal 二进制
    lipo -create "${SLICES[@]}" -output ".build/$APP_NAME"
    echo "   lipo 合成: $(lipo -archs ".build/$APP_NAME")"
else
    cp "${SLICES[0]}" ".build/$APP_NAME"
fi

if [ ! -f ".build/$APP_NAME" ]; then
    echo "✗ 编译失败"
    exit 1
fi
echo "   二进制: $(du -h ".build/$APP_NAME" | cut -f1)"

# ---- 2. 组装 bundle ----
# 标准 macOS app 结构：Contents/{Info.plist,MacOS/<可执行>,Resources/<图标>}
echo "→ [2/4] 组装 bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
# 光在 Info.plist 里声明还不够：系统要看 bundle 里真有这个语言的 .lproj 目录
# 才会把 App 当成「已本地化为中文」，从而用中文渲染系统菜单项
mkdir -p "$APP_DIR/Contents/Resources/zh-Hans.lproj"
cp ".build/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# ---- 3. Info.plist ----
# 注意 LSMinimumSystemVersion = 15.0：Translation 框架从 macOS 15.0 才开始提供。
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.zegeyoudaoli.translator</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <!-- 声明支持中文：About/Settings/Hide/Quit 这些系统菜单项才会显示成中文 -->
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- LSUIElement = 1：不显示 Dock 图标、不显示 App 自己的菜单栏，纯菜单栏常驻 -->
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>泽哥有道理</string>
    <!-- 系统「服务」菜单：任意 App 里选中文字 → 右键 → 用「译」翻译 -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>用「便捷翻译」翻译</string></dict>
            <key>NSMessage</key>
            <string>translateText</string>
            <key>NSPortName</key>
            <string>$APP_NAME</string>
            <key>NSSendTypes</key>
            <array><string>NSStringPboardType</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# ---- 4. 图标 + 签名 ----
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "→ [3/4] 图标已打入"
else
    echo "→ [3/4] 无 AppIcon.icns（跳过，用系统默认图标）"
fi

# 签名策略（影响辅助功能 TCC 授权的存活性，原理见下）：
#   ad-hoc（-）  ：TCC 授权绑死当前二进制的 cdhash → 每次重建授权即静默作废
#   自签证书身份 ：TCC 授权绑定证书 → 重建后授权依然有效，一次授权终身用
#
# 身份放在专用钥匙串 .signing/yidev.keychain-db 里（不污染 login 钥匙串）。
#
# 三个已实测的必要条件，缺一个就签不上：
#   1. 证书必须带 Extended Key Usage = Code Signing，否则 find-identity 按 codesigning
#      策略查不到（报 0 matching identities），codesign 报 item could not be found
#   2. 该钥匙串必须出现在用户的「钥匙串搜索列表」里 —— 实测这是 codesign 能否使用
#      "未打信任标记" 的自签身份的决定因素（不在列表里必失败，在列表里直接成功，
#      所以不需要跑 add-trusted-cert 那步 GUI 授权）
#   3. 证书在搜索列表里时，身份状态会显示 CSSMERR_TP_NOT_TRUSTED，这是正常的，不影响签名；
#      签出来的 DR 是 `certificate root = H"..."` → TCC 授权跨重建有效
IDENTITY="Yi Dev Codesign"
KC="$(pwd)/.signing/yidev.keychain-db"
SIGNED=0
if [ "$SIGN_MODE" != "adhoc" ] && [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$IDENTITY\""; then
    # 确保专用钥匙串在搜索列表里（幂等：已在则不动），并解锁
    if ! security list-keychains -d user | grep -q "yidev.keychain-db"; then
        security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d ' "') 2>/dev/null
    fi
    security unlock-keychain -p yi "$KC" 2>/dev/null
    if codesign --force --deep --sign "$IDENTITY" "$APP_DIR" 2>/dev/null; then
        echo "→ [4/4] 签名: \"$IDENTITY\"（TCC 授权跨重建有效）"
        SIGNED=1
    fi
fi
if [ "$SIGNED" = "0" ]; then
    codesign --force --deep --sign - "$APP_DIR" 2>/dev/null && \
        echo "→ [4/4] 签名: ad-hoc ⚠️ 每次重建后辅助功能授权需重新勾选" || \
        echo "→ [4/4] 签名跳过（不影响本地运行）"
fi

echo
echo "✓ 完成: $(pwd)/$APP_DIR"
echo
echo "安装到 Dock："
echo "   open -a \"$(pwd)/$APP_DIR\"     # 先跑一次确认能开"
echo "   然后把 $(pwd)/$APP_DIR 拖到 Dock 右侧即可"
