import SwiftUI
import AppKit

// MARK: - 设置页（图1：左侧菜单 + 右侧功能设置区；图2：通用分区）
//
// 主窗口与设置窗口均由 AppDelegate 以 AppKit 方式托管，本视图只负责渲染。
// 左侧固定侧边栏（菜单选择），右侧按所选分区展示设置项。
// 「通用」与「应用配置」分区可用，其余分区为占位「即将上线」。

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var selected: SettingsSection = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "通用"
        case appConfig = "应用配置"
        case localRoute = "本地路由"
        case network = "网络"
        case data = "数据"
        case about = "关于"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general:    return "gearshape"
            case .appConfig:  return "folder"
            case .localRoute: return "point.3.connected.trianglepath.dotted"
            case .network:    return "network"
            case .data:       return "chart.bar.fill"
            case .about:      return "info.circle"
            }
        }
    }

    var body: some View {
        ZStack {
            DarkBackdrop(opacity: 0.64)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1)
                content
            }
        }
        .frame(minWidth: 660, minHeight: 440)
    }

    // MARK: 左侧菜单

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 品牌区
            HStack(spacing: 10) {
                BrandBadge(size: 30)
                Text("TokenLens")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // 返回
            Button { AppDelegate.closeSettings() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("返回")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("返回并关闭设置")

            // 分组标签
            HStack {
                Text("设置")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)

            // 菜单项
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsSection.allCases) { sec in
                        sidebarItem(sec)
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            // 版本号
            Text("TokenLens v1.1.0")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(width: 220)
        .background(Color.secondary.opacity(0.08))
    }

    private func sidebarItem(_ sec: SettingsSection) -> some View {
        let isSel = selected == sec
        return Button { selected = sec } label: {
            HStack(spacing: 9) {
                Image(systemName: sec.icon)
                    .font(.system(size: 14))
                    .frame(width: 18, alignment: .center)
                Text(sec.rawValue)
                    .font(.system(size: 13))
                Spacer()
                if sec == .about {
                    Circle().fill(Color.accentGreen)
                        .frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(isSel ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSel ? Color.violetBright.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSel ? Color.violetBright.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSel ? .isSelected : [])
    }





    // MARK: 右侧内容

    private var content: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack(spacing: 8) {
                Image(systemName: selected.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text(selected.rawValue)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.secondary.opacity(0.05))
            Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)

            // 内容区
            ScrollView {
                switch selected {
                case .general:    generalSection
                case .appConfig: appConfigSection
                default:         placeholder(for: selected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.04))
        }
    }

    // MARK: 通用分区

    private var generalSection: some View {
        VStack(spacing: 0) {
            settingsCard {
                SettingRow(title: "自动刷新", help: "开启后每 60 秒自动重新扫描数据目录") {
                    PillToggle(isOn: $settings.autoRefresh)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "关闭时最小化到托盘", help: "关闭主窗口时留在菜单栏，而非退出应用") {
                    PillToggle(isOn: $settings.minimizeToTrayOnClose)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "托盘样式", help: "菜单栏弹窗的展现形式（菜单模式暂未开放）") {
                    TrayStyleControl(selection: $settings.trayStyle)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "开机自启动", help: "登录系统后自动运行 TokenLens") {
                    PillToggle(isOn: $settings.launchAtLogin)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "在程序坞显示图标",
                           help: "开启后程序坞（Dock）会显示 TokenLens 图标，点击可唤起主窗口；关闭则为纯菜单栏应用") {
                    PillToggle(isOn: $settings.showDockIcon)
                }
            }
            .padding(20)
            Spacer(minLength: 0)
        }
    }

    // MARK: 应用配置分区

    private var appConfigSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 顶部：说明 + 重新探测
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动探测已安装工具的日志目录并写入下方配置")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("检测到 \(installedCount) / \(settings.tools.count) 个工具已安装")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    settings.rescanTools()
                } label: {
                    Label("重新探测", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(SpringPressStyle())
                .handCursor()
                .help("重新扫描本机已安装的 AI 工具并更新配置")
            }
            ForEach($settings.tools) { $tool in
                toolCard($tool)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 已安装的工具数量
    private var installedCount: Int {
        settings.tools.filter { $0.isInstalled }.count
    }

    /// 单个 AI 工具的配置卡片：分组标题（图标 + 名称 + 安装状态）+ 目录列表 + 选择/重置按钮
    private func toolCard(_ tool: Binding<AITool>) -> some View {
        let t = tool.wrappedValue
        let hasCustom = t.customPath != nil
        let paths = t.effectiveDirs.map(\.path)
        return VStack(alignment: .leading, spacing: 0) {
            // 分组标题
            HStack(spacing: 8) {
                Image(systemName: t.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(t.accent)
                    .frame(width: 22)
                Text(t.displayName)
                    .font(.system(size: 14, weight: .semibold))
                // 安装状态徽标
                Text(t.isInstalled ? "已安装" : "未检测到")
                    .font(.system(size: 10))
                    .foregroundStyle(t.isInstalled ? Color.accentGreen : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                if hasCustom {
                    Text("手动")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
            }
            .padding(.bottom, 10)
            // 配置卡片
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Text("配置目录").font(.system(size: 12.5))
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .help("该 AI 工具的日志/会话目录，用于统计其 token 消耗；启动时自动探测，也可手动指定")
                }
                if paths.isEmpty {
                    Text(t.isInstalled ? "已安装，但尚未找到日志目录，可点击下方按钮手动选择"
                                       : "未检测到该工具，可点击下方按钮手动选择")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor)))
                } else {
                    // 多个目录逐行列出
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(paths, id: \.self) { p in
                            Text(p)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08)))
                                .help(p)
                        }
                    }
                }
                HStack(spacing: 8) {
                    // 选择目录：从该工具自己的探测目录开始，避免面板停在别的工具目录
                    Button {
                        pickDirectory(for: t)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help("选择目录")
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1)))
                    // 恢复自动探测
                    Button {
                        settings.setCustomPath(nil, for: t.id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .help("恢复自动探测")
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1)))
                    .disabled(!hasCustom)
                    Spacer()
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07)))
        }
    }

    /// 弹出目录选择面板，选中后写入该工具的配置
    ///
    /// 起始目录取该工具自己的位置（探测目录 → 主目录 → home），
    /// 而不是系统记忆的「上次打开目录」——否则每个工具都从第一个工具的目录开始。
    private func pickDirectory(for tool: AITool) {
        let start = tool.startDirectoryForPicker
        DirPicker.pick(startDirectory: start, in: hostWindow) { url in
            settings.setCustomPath(url.path, for: tool.id)
        }
    }

    /// 承载本视图的窗口（用于把选择面板以 sheet 形式挂上去）
    private var hostWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.title == "设置" }
    }

    private func placeholder(for sec: SettingsSection) -> some View {
        VStack(spacing: 12) {
            Image(systemName: sec.icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("「\(sec.rawValue)」即将上线")
                .font(.system(size: 14, weight: .medium))
            Text("该模块正在开发中，敬请期待")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: 卡片容器（白底圆角分组）

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .liquidGlass(cornerRadius: 12, tint: Color.violetBright.opacity(0.05))
    }
}

// MARK: - 设置行（左标签 + 右控件）

struct SettingRow<Control: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13.5))
                if let help {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .help(help)
                        .accessibilityLabel("\(title) 说明：\(help)")
                }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 药丸开关（橙色开 / 灰色关，呼应设计图）

struct PillToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? Color.violetBright : Color(nsColor: .separatorColor))
                    .frame(width: 44, height: 26)
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .offset(x: isOn ? 9 : -9)
                    .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOn)
            }
        }
        .buttonStyle(.plain)
        .handCursor()
        .accessibilityLabel("开关")
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(.isButton)
        .help(isOn ? "已开启" : "已关闭")
    }
}

// MARK: - 托盘样式分段控件（面板 / 菜单，菜单暂禁用）

struct TrayStyleControl: View {
    @Binding var selection: AppSettings.TrayStyle

    var body: some View {
        HStack(spacing: 0) {
            seg("面板", value: .panel)
            seg("菜单", value: .menu, disabled: true)
        }
        .padding(2)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func seg(_ title: String, value: AppSettings.TrayStyle, disabled: Bool = false) -> some View {
        Button {
            if !disabled { selection = value }
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: selection == value ? .semibold : .regular))
                .foregroundStyle(
                    disabled ? AnyShapeStyle(.tertiary)
                    : (selection == value ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                )
                .frame(width: 54, height: 24)
                .background(
                    Capsule()
                        .fill(selection == value ? Color.violetBright.opacity(0.85) : Color.clear)
                        .shadow(color: selection == value ? Color.violetBright.opacity(0.35) : .clear,
                                radius: 3, y: 1)
                )
                .foregroundStyle(selection == value ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(disabled)
        .help(disabled ? "菜单模式暂未开放" : "切换托盘样式为\(title)")
        .accessibilityLabel("托盘样式：\(title)\(disabled ? "（暂未开放）" : "")")
    }
}
