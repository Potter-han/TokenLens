#!/bin/bash
# TokenLens 工具目录探测 + 选择目录起始目录 回归测试
#
# 覆盖两条链路：
#   1) 应用启动时自动扫描本机已安装的 AI 工具（Codex / WorkBuddy / Claude Code /
#      OpenCode / Gemini CLI / Grok Build / Trae），把日志目录写入对应工具的应用配置
#   2) 每个工具的「选择目录」按钮，面板起始目录属于自己的位置（不串到别的工具）
#
# 用法: ./Tests/run_detect.sh
set -e
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)/tl_detect"
mkdir -p "$WORK"

echo "▶ 生成测试副本..."
python3 Tests/prepare_e2e.py "$WORK" --no-probe

echo "▶ 编译测试台..."
# 测试副本已含全部 Sources（含 @main App 剥离），只需补上测试入口
swiftc -O \
    "$WORK"/Sources/*.swift \
    Tests/main.swift \
    Tests/picker_main.swift \
    Tests/range_main.swift \
    -o "$WORK/tl_detect" \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Combine

echo "▶ 运行探测测试..."
echo
set +e
"$WORK/tl_detect"
CODE=$?
set -e

echo
if [ $CODE -eq 0 ]; then
    echo "✅ 探测测试通过"
else
    echo "❌ 探测测试失败 (exit=$CODE)"
fi
rm -rf "$(dirname "$WORK")"
exit $CODE
