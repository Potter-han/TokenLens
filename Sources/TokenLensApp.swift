import SwiftUI
import AppKit
import Combine

// MARK: - App 入口: 纯菜单栏应用（NSStatusItem + NSPopover + AppKit 主窗口）
//
// 主窗口不再走 SwiftUI Window Scene：Scene 窗口生命周期由框架托管，
// 关闭后窗口对象不可靠，且无法确定性地重新唤起（上一版用启发式过滤
// "猜"主窗失败 → 落入无人监听的通知分支 → 点击按钮毫无反应）。
// 现在主窗口由 AppDelegate 全权创建与管理：
//   - isReleasedWhenClosed = false，关闭仅隐藏，可无限次重新前置；
//   - 打开逻辑确定：有窗前置、无窗创建，不存在"点了没反应"的路径。
//
// ⚠️ 关键坑: @NSApplicationDelegateAdaptor 并不是把业务 delegate 直接挂到
// NSApp.delegate 上，而是塞了一个 SwiftUI 内部的代理对象（SwiftUI.AppDelegate）。
// 因此 `NSApp.delegate as? AppDelegate` 永远为 nil，可选链一短路，
// "打开主窗口"按钮就变成了点什么都没反应的空按钮。
// 对外访问统一走 AppDelegate.current（由 applicationDidFinishLaunching 自登记）。

@main
struct TokenLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 主窗口与设置窗口均由 AppDelegate 以 AppKit 方式创建与管理
        // （纯菜单栏应用，需确定性地唤起/隐藏窗口）。这里保留一个占位场景，
        // 避免无场景报错；实际设置窗由 AppDelegate 管理。
        Settings {
            EmptyView()
        }
    }
}

// MARK: - 生命周期: 菜单栏图标、弹窗、主窗口与设置窗口全部 AppKit 托管

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 当前生效的 delegate 实例（自登记）。
    /// SwiftUI 的 @NSApplicationDelegateAdaptor 挂到 NSApp.delegate 上的是它自己的
    /// 代理对象，拿不到业务实例，所以外部（小窗按钮等）一律通过这里访问。
    static private(set) weak var current: AppDelegate?

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// 订阅今日数据以刷新菜单栏图标
    private var gaugeCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 自登记实例，供小窗按钮等外部调用点使用
        AppDelegate.current = self
        // Dock 策略按用户设置应用：默认 .accessory（纯菜单栏，程序坞无图标）；
        // 开了「在程序坞显示图标」则为 .regular
        AppSettings.shared.applyDockIconPolicy()
        setupStatusItem()
        // 启动即自动扫描本机已安装的 AI 工具（Codex / WorkBuddy / Claude Code 等），
        // 把探测到的日志目录写入「应用配置」里对应工具的配置项，再按新配置扫描
        AppSettings.shared.detectAndConfigureTools()
        // 与原版一致: 启动时展示主面板（不抢焦点）
        showMainWindow(activate: false)
    }

    /// 点击程序坞图标（仅 .regular 模式下会出现图标）：没有可见窗口时唤起主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(activate: true) }
        return true
    }

    /// 全局入口：打开 / 前置主窗口（菜单栏小窗的「打开主窗口」按钮走这里）
    static func openMainWindow(activate: Bool = true) {
        current?.showMainWindow(activate: activate)
    }

    /// 全局入口：打开 / 前置设置窗口（小窗与主窗的「设置」按钮走这里）
    static func openSettings() {
        current?.showSettings()
    }

    /// 全局入口：关闭设置窗口（左侧「返回」按钮走这里）
    static func closeSettings() {
        current?.settingsWindow?.orderOut(nil)
    }

    // MARK: 菜单栏图标 + 弹窗

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarGaugeIcon.image(tokens: 0, ratio: 0)
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        // 数据变化时同步刷新图标（今日用量 → 环形进度与状态色）
        observeGauge()

        popover.behavior = .transient          // 点击弹窗外任意处自动收起
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 520)
        // 外观跟随系统：白色毛玻璃主题在浅/深色菜单栏下都由材质自动适配
    }

    /// 订阅 ScanStore 的今日数据，实时刷新菜单栏环形图标
    private func observeGauge() {
        gaugeCancellable = ScanStore.shared.$todayData
            .receive(on: RunLoop.main)
            .sink { [weak self] data in
                self?.refreshGaugeIcon()
                _ = data
            }
    }

    /// 依据今日用量与近 30 天总量，重绘菜单栏图标
    private func refreshGaugeIcon() {
        let store = ScanStore.shared
        let tokens = store.todayData?.today.total ?? 0
        let ratio = tokens / max(store.monthlyTotal, 1)
        let level = GaugeLevel.level(for: ratio)
        let img = MenuBarGaugeIcon.image(tokens: tokens, ratio: ratio)
        statusItem?.button?.image = img
        statusItem?.button?.toolTip = String(
            format: "今日已用 %@ tokens（%@ · %.0f%%）",
            Fmt.cn(tokens), level.label, min(ratio, 1) * 100)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)        // 官方关闭 API，确定生效
        } else {
            showPopover(anchoredTo: button)
        }
    }

    private func showPopover(anchoredTo button: NSStatusBarButton) {
        // 每次打开都新建 SwiftUI 内容视图 → @State 全新 → 入场动画天然重放
        let ctrl = NSHostingController(rootView: PopoverView(store: .shared))
        ctrl.sizingOptions = [.intrinsicContentSize]
        popover.contentViewController = ctrl
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: 主窗口（AppKit 托管，关闭仅隐藏，可反复唤起）

    func showMainWindow(activate: Bool = true) {
        // 1) 先把主窗口准备好并前置（此时弹窗还在，不存在"关窗动画抢焦点"的问题）
        if mainWindow == nil {
            let ctrl = NSHostingController(rootView: DashboardView(store: .shared))
            let w = NSWindow(contentViewController: ctrl)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = "Token 用量监控"
            w.setContentSize(NSSize(width: 880, height: 640))
            w.minSize = NSSize(width: 780, height: 580)
            w.isReleasedWhenClosed = false      // 关闭仅隐藏，窗口对象永久可用
            w.tabbingMode = .disallowed
            // 统一深色外观：主窗口与菜单栏小窗同一套深空蓝玻璃主题
            // 外观跟随系统
            w.center()
            mainWindow = w
        }
        guard let win = mainWindow else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }
        // 菜单栏应用(.accessory) 先激活再前置，否则窗口能显示但拿不到 key 状态，
        // 看起来「点了没反应」——用户还得再点一次标题栏才能交互
        if activate { NSApp.activate(ignoringOtherApps: true) }
        win.makeKeyAndOrderFront(nil)

        // 2) 再收起小窗：延后一拍执行。
        //    小窗按钮的 action 此刻仍在栈上，同步 performClose 会在 action 未返回时
        //    拆掉承载它的 NSHostingView / SwiftUI 视图层级，存在崩溃与焦点回抢风险。
        let popover = self.popover
        DispatchQueue.main.async {
            if popover.isShown { popover.performClose(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // 关窗后驻留菜单栏
    }

    // MARK: 设置窗口（AppKit 托管，关闭仅隐藏，可反复唤起）

    func showSettings() {
        if settingsWindow == nil {
            let ctrl = NSHostingController(rootView: SettingsView(settings: .shared))
            let w = NSWindow(contentViewController: ctrl)
            w.styleMask = [.titled, .closable, .resizable]
            w.title = "设置"
            w.setContentSize(NSSize(width: 720, height: 520))
            w.minSize = NSSize(width: 640, height: 460)
            w.isReleasedWhenClosed = false      // 关闭仅隐藏，窗口对象永久可用
            w.tabbingMode = .disallowed
            w.delegate = self                   // 接管关闭行为（最小化到托盘 / 退出）
            // 外观跟随系统
            w.center()
            settingsWindow = w
        }
        guard let win = settingsWindow else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // 打开设置时顺手收起菜单栏小窗
        let popover = self.popover
        DispatchQueue.main.async {
            if popover.isShown { popover.performClose(nil) }
        }
    }

    // MARK: NSWindowDelegate —— 接管窗口关闭行为

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            // 设置窗口：直接隐藏，可再次打开
            sender.orderOut(nil)
            return false
        }
        if sender === mainWindow {
            // 主窗口：按「关闭时最小化到托盘」开关决定行为
            if AppSettings.shared.minimizeToTrayOnClose {
                sender.orderOut(nil)        // 最小化到托盘（隐藏，留在菜单栏）
                return false
            } else {
                NSApp.terminate(nil)        // 关闭即退出
                return false
            }
        }
        return true
    }
}

// MARK: - 菜单栏图标绘制

enum MenuBarIcon {
    static var icon: NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setFill()
            // 三根柱子: 高中低
            let bars = [(x: 1.5, h: 7.0), (x: 6.5, h: 12.0), (x: 11.5, h: 4.5)]
            for b in bars {
                NSBezierPath(roundedRect: NSRect(x: b.x, y: 1.5, width: 3.6, height: b.h), xRadius: 1.4, yRadius: 1.4).fill()
            }
            return true
        }
        img.isTemplate = true   // 自动适配深浅菜单栏
        return img
    }
}

// MARK: - 设置页（双栏布局，见 SettingsView.swift）
//
// 旧版单页 Form 设置已迁移到 SettingsView.swift，由 AppDelegate 以独立 NSWindow 托管。
