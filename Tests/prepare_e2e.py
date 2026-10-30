#!/usr/bin/env python3
"""把生产源码复制成可测试副本，供 Tests/run_e2e.sh 使用。

做三件事：
  1) 去掉 @main App（测试台自己驱动 NSApplication）
  2) 放开测试所需的访问级别（statusItem / popover / togglePopover / showPopover）
  3) 注入「按钮 action 是否触发」探针（只在 action 入口打标记，不改变行为）

用法: prepare_e2e.py <目标目录>
"""
import os
import re
import shutil
import sys

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources")
FILES = ["Models.swift", "JSON.swift", "Parser.swift", "DateRange.swift", "Glass.swift",
         "DashboardView.swift", "PopoverView.swift", "FilterBar.swift", "TokenGauge.swift",
         "ToolScanner.swift", "DirPicker.swift", "AppSettings.swift",
         "SettingsView.swift", "TokenLensApp.swift"]


def main():
    dst = sys.argv[1]
    src = os.path.abspath(SRC)
    out = os.path.join(dst, "Sources")
    os.makedirs(out, exist_ok=True)

    for f in FILES:
        shutil.copy(os.path.join(src, f), os.path.join(out, f))

    # 1) 去掉 @main App
    p = os.path.join(out, "TokenLensApp.swift")
    s = open(p).read()
    s = re.sub(r"@main\s*\nstruct TokenLensApp: App \{.*?\n\}\n",
               "// (测试副本不需要 @main，测试台自行驱动 NSApplication)\n", s, flags=re.S)

    # 2) 放开访问级别
    for a, b in [
        ("private var statusItem: NSStatusItem?", "var statusItem: NSStatusItem?"),
        ("private let popover = NSPopover()", "let popover = NSPopover()"),
        ("@objc private func togglePopover(", "@objc func togglePopover("),
        ("private func showPopover(", "func showPopover("),
    ]:
        assert a in s, "TokenLensApp.swift 里找不到: " + a
        s = s.replace(a, b)
    open(p, "w").write(s)

    # 2.5) 可选：不做探针注入（--no-probe）
    if "--no-probe" in sys.argv:
        open(os.path.join(out, "TestBridge.swift"), "w").write(
            "import Foundation\n\n"
            "/// 测试副本专用探针：记录「打开主窗口」按钮 action 是否被触发\n"
            "enum TestBridge {\n"
            "    nonisolated(unsafe) static var openFired = false\n"
            "    nonisolated(unsafe) static var openFiredAt: Date?\n"
            "}\n")
        print("测试副本已生成（无探针注入）:", os.path.abspath(dst))
        return

    # 3) 注入探针
    p = os.path.join(out, "PopoverView.swift")
    s = open(p).read()
    old = "            Button {\n                openMainWindow()\n            } label: {"
    new = ("            Button {\n"
           "                TestBridge.openFired = true\n"
           "                TestBridge.openFiredAt = Date()\n"
           "                openMainWindow()\n"
           "            } label: {")
    assert old in s, "PopoverView.swift 里找不到「打开主窗口」按钮的 action"
    s = s.replace(old, new)
    open(p, "w").write(s)

    open(os.path.join(out, "TestBridge.swift"), "w").write(
        "import Foundation\n\n"
        "/// 测试副本专用探针：记录「打开主窗口」按钮 action 是否被触发\n"
        "enum TestBridge {\n"
        "    nonisolated(unsafe) static var openFired = false\n"
        "    nonisolated(unsafe) static var openFiredAt: Date?\n"
        "}\n")
    print("测试副本已生成:", os.path.abspath(dst))


if __name__ == "__main__":
    main()
