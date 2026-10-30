# TokenLens 🔍

**TokenLens** 是一款运行在 macOS 菜单栏的 AI Token 用量监控工具。它自动探测本机安装的各类 AI 编程工具（Codex、WorkBuddy、Claude Code、Gemini CLI、Grok Build、OpenCode、Trae 等），解析它们在本地生成的会话日志，聚合出直观的 Token 消耗统计——全程**只读、不上传任何数据**。

![macOS](https://img.shields.io/badge/macOS-13.0%2B-black) ![Swift](https://swift.org/assets/images/swift.svg) ![License](https://img.shields.io/badge/license-MIT-blue)

## ✨ 功能特性

- **🪶 菜单栏常驻**：纯菜单栏应用，不占 Dock 位置，随时一键查看今日消耗。
- **📊 环形仪表盘图标**：菜单栏图标是一个环形进度表，直接显示今日已用 Token 的紧凑数值（如 `1.2K`、`12.4K`），颜色按消耗分档（灰 → 蓝 → 青 → 橙 → 红）。
- **🤖 多工具支持**：自动探测 7 款主流 AI 编程工具的本地日志目录，新装工具自动纳入统计。
- **📈 可视化仪表盘**：
  - 今日消耗大数字 + 环形进度
  - 调用次数 / 预估费用 + 较昨日变化
  - 近 7 天迷你走势图
  - 今日分时柱状图（按小时分布，tokens/费用可切换）
  - 模型使用分布（Top 3 + 其他）
- **🗓 时间范围筛选**：主窗口支持「近 N 天」及自定义日期区间，切换瞬时完成（只重新聚合，不重新扫盘）。
- **🛠 手动配置**：设置页可为每个工具手动指定日志目录，也可以点「重新探测」自动定位。
- **🔒 隐私安全**：全程只读日志文件，不联网、不收集、不上传任何用户数据。

## 📦 安装

### 方式一：下载安装包（推荐）

1. 打开仓库的 [Releases](https://github.com/Potter-han/TokenLens/releases) 页面（或直接下载仓库中的 `dist/TokenLens-v1.1.0.zip`）。
2. 下载 `TokenLens-v1.1.0.zip` 后双击解压，得到 `TokenLens.app`。
3. 将 `TokenLens.app` 拖入「应用程序」文件夹。
4. 首次打开：右键 `TokenLens.app` → 「打开」，在弹出的确认框中再点「打开」（因未做公证，需要绕过 Gatekeeper）。

> 如果仍被系统拦截，可到「系统设置 → 隐私与安全性」页面点击「仍要打开」。

### 方式二：从源码构建

```bash
git clone https://github.com/Potter-han/TokenLens.git
cd TokenLens
./build.sh
# 产物在 build/TokenLens.app
open build/TokenLens.app
```

无需 Xcode 工程，脚本用 `swiftc` 直接编译，仅需安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

## 🚀 使用说明

### 启动

安装包版（首次）需要右键打开；启动后 TokenLens 会出现在 macOS **顶部菜单栏**（右上角状态区），呈现为一个环形仪表盘图标。

### 菜单栏小窗

单击菜单栏图标弹出小窗，从上到下依次展示：

| 区块 | 内容 |
|---|---|
| 顶栏 | 应用徽标 + 「今日已用 X tokens」 |
| 今日消耗 | 大数字 + 环形进度（分档变色） |
| 双统计卡 | 调用次数、预估费用、较昨日增减、近 7 天迷你走势 |
| 今日分布 | 0–23 时分时柱状图，可切换 tokens / 费用，带「现在」指示线 |
| 模型分布 | Token 消耗 Top 3 模型 + 其他 |
| 底部 | 刷新于时间、历史统计、**打开主窗口**、**退出** |

点击底部 **「打开主窗口」** 进入完整仪表盘；**「退出」** 直接退出应用。

### 主窗口

- 顶部是**时间范围筛选栏**（近 1/3/7/30 天 + 自定义区间），数据瞬时切换。
- 中部是**今日消耗**汇总卡与**分时/按日**图表。
- 库存数据 60 秒自动刷新一次；也可手动点刷新。

### 设置页

主窗口 → 「应用配置」/ 齿轮图标进入：

- **已安装工具列表**：探测到的工具显示「已安装」徽标与其日志目录。
- **选择目录**：某工具日志位置特殊时，可手动指定目录（面板会从该工具自己的主目录开始浏览）。
- **重新探测**：一键重新扫描所有工具的安装与日志位置。
- **在程序坞显示图标**：默认关闭（纯菜单栏应用），开启后 Dock 会显示图标。

### 支持的 AI 工具

| 工具 | 日志位置（自动探测） | 环境变量覆盖 |
|---|---|---源码结构、构建方式、系统要求——信息都齐了。现在开始任务 2：编译打包。先跑 build.sh 重新构建，然后压 zip。 |

<system-reminder>Write 工具响应缺失或与编辑目标不匹配，请重试。</system-reminder>pected at the end, but got 'B'
```

写入失败，我在表格末尾多写了内容。重写一次完整文件：工具 | 日志位置（自动探测） | 环境变量覆盖 |
|---|---|---|
| WorkBuddy | `~/.workbuddy/traces`、`~/.workbuddy/projects` | — |
| Codex | `~/.codex/sessions` | `CODEX_HOME` |
| Claude Code | `~/.claude/projects` | `CLAUDE_CONFIG_DIR` |
| Gemini CLI | `~/.gemini/tmp` | `GEMINI_DATA_DIR` |
| Grok Build | `~/.grok/sessions`、`~/.grok/logs` | `GROK_HOME` |
| OpenCode | `~/.local/share/opencode/{storage,project}` | `OPENCODE_DATA_DIR` |
| Trae | `~/Library/Application Support/Trae CN/User/workspaceStorage` | — |

## 🏗 项目结构

```
Sources/          Swift 源码（16 个文件）
├── TokenLensApp.swift    入口：菜单栏 + 弹窗 + 主窗口生命周期
├── DashboardView.swift   主窗口仪表盘
├── PopoverView.swift     菜单栏小窗
├── SettingsView.swift    设置页（工具探测 + 手动配置）
├── ToolScanner.swift     AI 工具日志目录自动探测
├── Parser.swift          日志解析器 + ScanStore 全局数据源（扫描 + 聚合缓存）
├── Models.swift          数据模型
├── TokenGauge.swift      环形仪表盘图标渲染
├── DateRange.swift       时间范围筛选
├── FilterBar.swift       筛选栏组件
├── DirPicker.swift       原生目录选择面板
├── AppSettings.swift     应用设置持久化
├── Glass.swift           深空蓝玻璃主题背景
├── BrandLogo.swift       品牌徽标
├── JSON.swift            轻量 JSON 解析
└── cli.swift             命令行查询入口（独立于 App，不参与 build.sh 编译）

Tools/            图标生成器（Swift）+ Logo 脚本（Python）
Tests/            端到端回归测试
build.sh          一键编译打包脚本
```

## 🔧 工作原理

1. **自动探测**：启动时按各工具已知的子目录结构定位日志目录（不做内容嗅探，只 stat 目录存在性）。
2. **解析聚合**：解析 JSONL 会话日志中的 token 记录，按时间桶聚合成今日/近 7 天/近 30 天统计。
3. **缓存刷新**：原始记录保留在内存中，切换时间范围只重新聚合（毫秒级）；后台每 60 秒自动重扫。
4. **隐私边界**：只读文件、不联网，所有计算都在本地完成。

## ❓ FAQ

**Q: 菜单栏图标不见了？**
A: 菜单栏空间不足时系统会隐藏图标，可检查其他菜单栏应用的「隐藏应用图标」设置。

**Q: 统计数为 0？**
A: 确认你使用的 AI 工具确实已在装且产生过会话日志；到设置页点「重新探测」，或手动指定日志目录。

**Q: 预估费用准确吗？**
A: 费用按日志中的模型与 token 数估算，仅供参考，实际以服务商账单为准。

**Q: 想删除已生成的 AppLogo.png 重新生成？**
A: 运行 `python3 Tools/make_logo.py`。

## 📄 License

MIT License
