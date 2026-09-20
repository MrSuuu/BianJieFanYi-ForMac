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
echo "  https://github.com/MrSuuu/BianJieFanYi-ForMac"

# 提醒：改了源码，但发布包没跟着更新 → repo 里的 dist 已经落后于源码
# 判断条件要同时看三件事，否则会误报：
#   · 动了 Sources/main.swift（功能变了）
#   · 本次提交里 dist/*.zip 没变（没重新打包）
#   · build.sh 也没变（连版本号都没升）
CHANGED="$(git show --name-only --pretty=format: HEAD)"
if echo "$CHANGED" | grep -q "Sources/main.swift" \
   && ! echo "$CHANGED" | grep -q "^dist/.*\.zip$" \
   && ! echo "$CHANGED" | grep -q "^build.sh$"; then
    echo
    echo "提示：这次改了源码，但发布包没一起更新（dist/ 里还是旧行为）。"
    echo "      要让别人下到新版：改 build.sh 的 APP_VERSION → bash package.sh → 再跑一次 sync.sh → 打 tag"
fi
