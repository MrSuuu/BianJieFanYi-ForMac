#!/bin/bash
# sync.sh —— 一键同步到 GitHub
#
# 用法:
#   bash sync.sh                    # 自动生成提交说明
#   bash sync.sh "修了划词浮窗的防抖"   # 自己写说明
#
# 干了什么：
#   1. 类型检查（编不过就直接中止，绝不把坏代码推上去）
#   2. git add -A → commit → push origin main
#
# 没干什么（故意的）：
#   · 不自动打 tag / 发 Release —— 那是"发版本"，要单独决定（见文末提示）
#   · 不自动重新打发布包 dist/*.zip —— 二进制不该每次改代码就提交一遍
#
# 发新版本的完整流程（需要时才做）：
#   1. 改 build.sh 里的 APP_VERSION
#   2. bash package.sh
#   3. bash sync.sh "vX.Y：改了啥"
#   4. git tag vX.Y && git push origin vX.Y     # ← 触发 Actions 自动发 Release

set -euo pipefail
cd "$(dirname "$0")"

MSG="${1:-}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# ---- 1. 类型检查（闸门）----
echo "→ [1/3] 类型检查"
if ! xcrun swiftc -typecheck -parse-as-library \
        -target x86_64-apple-macosx15.0 -sdk "$SDK" Sources/main.swift; then
    echo
    echo "✗ 类型检查没过，已中止同步（先把编译错误修掉）"
    exit 1
fi
echo "  通过"

# ---- 2. 暂存 ----
echo "→ [2/3] 暂存改动"
git add -A
if git diff --cached --quiet; then
    echo "  没有改动，无需同步"
    exit 0
fi
git diff --cached --stat | tail -6

# ---- 3. 提交 + 推送 ----
echo "→ [3/3] 提交并推送"
if [ -z "$MSG" ]; then
    FILES="$(git diff --cached --name-only | head -3 | tr '\n' ' ')"
    MSG="同步改动：$FILES"
fi
git commit -q -m "$MSG"
git push -q origin main
echo "✓ 已同步 $(git log --oneline -1)"
echo "  https://github.com/MrSuuu/Yi-macOS"

# 提醒：改了源码但没动版本号 → repo 里的 dist 发布包已经落后了
if git show --name-only --pretty=format: HEAD | grep -q "Sources/main.swift"; then
    if ! git show --name-only --pretty=format: HEAD | grep -q "build.sh"; then
        echo
        echo "提示：这次改了源码但没升版本号。"
        echo "      dist/ 里的发布包还是旧版（别人下载会拿到旧行为）。"
        echo "      要让发布包跟上：改 build.sh 的 APP_VERSION → bash package.sh → 再 sync 一次 → tag"
    fi
fi
