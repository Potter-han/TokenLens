#!/bin/bash
# TokenLens 端到端回归测试
#
# 覆盖的链路：菜单栏小窗 → 点「打开主窗口」按钮 → 主窗口弹出并取得焦点 → 小窗收起
# 这个 bug 的失败方式是「静默无反应」（action 执行了但里面一句 nil 强转短路），
# 没有这个自动断言，人工点一遍很容易漏判。
#
# 用法: ./Tests/run_e2e.sh
set -e
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)/tl_e2e"
mkdir -p "$WORK"

echo "▶ 生成测试副本..."
python3 Tests/prepare_e2e.py "$WORK"

echo "▶ 编译测试台..."
swiftc -O \
    Tests/e2e_main.swift \
    "$WORK"/Sources/*.swift \
    -o "$WORK/tl_e2e" \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Combine

echo "▶ 运行端到端测试..."
echo
set +e
"$WORK/tl_e2e"
CODE=$?
set -e

echo
if [ $CODE -eq 0 ]; then
    echo "✅ 端到端测试通过"
else
    echo "❌ 端到端测试失败 (exit=$CODE)"
fi
rm -rf "$(dirname "$WORK")"
exit $CODE
