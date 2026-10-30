import AppKit
import SwiftUI

// MARK: - 端到端回归测试：小窗「打开主窗口」按钮 → 主窗口弹出
//
// 这个 bug 的失败方式是「静默无反应」——按钮 action 照常执行，只是里面那句
// `NSApp.delegate as? AppDelegate` 恒为 nil，所以没有任何报错、没有任何窗口，
// 人工点一遍很容易漏判。这里用真实鼠标事件把整条链路跑一遍做断言。
//
// 不依赖 AX 权限 / UI 脚本（无头环境下 AXIsProcessTrusted=false）：
//   1. 按生产拓扑接线：NSApp.delegate 挂代理对象（模拟 @NSApplicationDelegateAdaptor）
//   2. 打开 NSPopover 小窗
//   3. 用像素特征定位「打开主窗口」按钮（底部唯一的大块紫色实心块）
//   4. 派发真实 NSEvent 鼠标按下/抬起（走完整命中测试 + SwiftUI 手势）
//   5. 断言：主窗从「隐藏」变回「可见」+「拿到 key 状态」，且小窗已收起
//
// 配套脚本：Tests/run_e2e.sh

func log(_ s: String) { print(s); fflush(stdout) }

/// 模拟 SwiftUI 的 @NSApplicationDelegateAdaptor：
/// NSApp.delegate 上挂的是「代理对象」，业务 delegate 藏在里面，
/// 因此 `NSApp.delegate as? AppDelegate` 必然为 nil。
final class ProxyDelegate: NSObject, NSApplicationDelegate {
    let real: AppDelegate
    init(real: AppDelegate) { self.real = real }
    func applicationDidFinishLaunching(_ n: Notification) {
        real.applicationDidFinishLaunching(n)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        real.applicationShouldTerminateAfterLastWindowClosed(s)
    }
}

@MainActor
final class TestDriver {
    let app: NSApplication
    let delegate: AppDelegate

    init(app: NSApplication, delegate: AppDelegate) {
        self.app = app
        self.delegate = delegate
    }

    func run() -> Int32 {
        log("[1] NSApp.delegate=\(String(describing: type(of: NSApp.delegate!))) "
            + "| as? AppDelegate=\(NSApp.delegate as? AppDelegate == nil ? "nil（与生产一致）" : "非nil ⚠️")")
        log("[1] AppDelegate.current = \(AppDelegate.current == nil ? "nil ❌" : "已注册 ✅")")

        // 打开小窗
        guard let button = delegate.statusItem?.button else {
            log("[2] ❌ 拿不到 statusItem.button"); return 1
        }
        delegate.showPopover(anchoredTo: button)
        pump(0.6)
        guard delegate.popover.isShown, let popWindow = delegate.popover.contentViewController?.view.window else {
            log("[2] ❌ 小窗未弹出"); return 1
        }
        log("[2] 小窗已弹出 frame=\(popWindow.frame)")

        // 定位「打开主窗口」按钮
        guard let contentView = delegate.popover.contentViewController?.view,
              let btnRect = findVioletButton(in: contentView) else {
            log("[3] ❌ 未能定位『打开主窗口』按钮"); return 1
        }
        log("[3] 按钮像素框(视图坐标)=\(btnRect)")

        // 关键准备：先把主窗藏起来 —— 只有点击 action 真的触发，makeKeyAndOrderFront
        // 才会让它重新可见，从而把「点击是否生效」变成一个二值信号
        let mainWin = NSApp.windows.first { $0.title == "Token 用量监控" }
        if let mw = mainWin {
            mw.orderOut(nil)
            pump(0.4)
            log("[4] 点击前主窗 visible=\(mw.isVisible) (已主动隐藏，期望 false)")
        } else {
            log("[4] 点击前还没有主窗")
        }

        // 真实鼠标事件点击（视图坐标 → 窗口坐标）
        let winRect = contentView.convert(btnRect, to: nil)
        let winPoint = CGPoint(x: winRect.midX, y: winRect.midY)
        log("[5] 按钮视图坐标=\(btnRect) → 窗口坐标=\(winRect) 点击点=\(winPoint)")
        TestBridge.openFired = false
        sendClick(to: popWindow, at: winPoint)
        pump(1.2)
        log("[5] 按钮 action 是否触发: \(TestBridge.openFired ? "是 ✅" : "否 ❌（事件没送到按钮）")")

        // 断言 1：主窗可见
        var ok = true
        if let mw = mainWin {
            if mw.isVisible {
                log("[6] ✅ 主窗已重新可见（点击 action 生效）key=\(mw.isKeyWindow)")
            } else {
                log("[6] ❌ 主窗仍不可见 —— 点击链路是死的"); ok = false
            }
            if !mw.isKeyWindow {
                log("    ⚠️ 主窗不是 key window | NSApp.keyWindow=\(NSApp.keyWindow?.title ?? "nil") appActive=\(NSApp.isActive)")
                ok = false
            }
        } else {
            log("[6] ❌ 没有主窗对象"); ok = false
        }

        // 断言 2：小窗收起
        if delegate.popover.isShown {
            log("[7] ❌ 小窗没有收起"); ok = false
        } else {
            log("[7] ✅ 小窗已收起")
        }

        // 断言 3：二次点击可重新前置（窗口已存在时的路径）
        if let mw = mainWin {
            mw.orderOut(nil)
            pump(0.3)
            delegate.showPopover(anchoredTo: button)
            pump(0.6)
            if let cv2 = delegate.popover.contentViewController?.view,
               let r2 = findVioletButton(in: cv2),
               let pw = delegate.popover.contentViewController?.view.window {
                let wr2 = cv2.convert(r2, to: nil)
                TestBridge.openFired = false
                sendClick(to: pw, at: NSPoint(x: wr2.midX, y: wr2.midY))
                pump(1.0)
                log("[8] 二次点击 action 触发: \(TestBridge.openFired ? "是 ✅" : "否 ❌")")
                if mw.isVisible { log("[8] ✅ 二次点击可重新前置已存在的主窗") }
                else { log("[8] ❌ 二次点击没能重新前置主窗"); ok = false }
            } else {
                log("[8] ⚠️ 二次定位失败，跳过"); ok = false
            }
        }
        return ok ? 0 : 1
    }

    // MARK: 工具

    /// 像素定位「打开主窗口」按钮：
    /// 该按钮是底部操作行里唯一的大块紫色渐变填充（violetMain ≈ RGB(121,92,184)，特征 B>R>G），
    /// 高度约 29pt 的实心块；上方柱状图只有 12pt 高，用「行带高度」即可区分。
    func findVioletButton(in view: NSView) -> CGRect? {
        let bounds = view.bounds
        guard bounds.width > 10, bounds.height > 10 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            log("    (bitmapImageRepForCachingDisplay 返回 nil)"); return nil
        }
        view.cacheDisplay(in: bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }
        let scale = Double(w) / Double(bounds.width)   // 像素/点

        // 掩码：紫色特征
        var mask = [Bool](repeating: false, count: w * h)
        var rowCount = [Int](repeating: 0, count: h)
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                if b > r && r > g && (b - g) > 0.22 {
                    mask[y * w + x] = true
                    rowCount[y] += 1
                }
            }
        }
        // 连续行带
        var bands: [(Int, Int)] = []
        var start = -1
        for y in 0...h {
            let has = y < h && rowCount[y] > 0
            if has && start < 0 { start = y }
            if !has && start >= 0 { bands.append((start, y - 1)); start = -1 }
        }
        if start >= 0 { bands.append((start, h - 1)) }

        // 高度 ≥ 20pt 的行带里取最低的一个 → 按钮（柱状图仅 12pt）
        let solid = bands.filter { Double($0.1 - $0.0 + 1) / scale >= 20 }
        guard let band = solid.last else {
            log("    没有高度≥20pt 的紫色块"); return nil
        }
        var minX = w, maxX = -1
        for y in band.0...band.1 {
            for x in 0..<w where mask[y * w + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
        guard maxX > minX else { return nil }
        return CGRect(x: Double(minX) / scale,
                      y: Double(band.0) / scale,
                      width: Double(maxX - minX + 1) / scale,
                      height: Double(band.1 - band.0 + 1) / scale)
    }

    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    func sendClick(to window: NSWindow, at point: NSPoint) {
        let ts = ProcessInfo.processInfo.systemUptime
        // 先移动指针建立 hover 状态
        if let move = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                         timestamp: ts, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            window.sendEvent(move)
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let ev = NSEvent.mouseEvent(with: type, location: point,
                                              modifierFlags: [], timestamp: ts,
                                              windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            // 走 AppKit 完整事件分发（含命中测试 + SwiftUI 手势识别）
            NSApp.sendEvent(ev)
        }
    }
}

// MARK: - 启动：按生产拓扑接线后进入真实事件循环
nonisolated(unsafe) var gDriver: TestDriver?
nonisolated(unsafe) var gProxy: ProxyDelegate?
nonisolated(unsafe) var gFinished = false

@main
struct E2EMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            // 关键：NSApp.delegate 上挂的是「代理对象」，与 @NSApplicationDelegateAdaptor 的真实拓扑一致
            // （NSApplication.delegate 是 weak，必须自己持有一份强引用）
            let proxy = ProxyDelegate(real: delegate)
            gProxy = proxy
            app.delegate = proxy
            gDriver = TestDriver(app: app, delegate: delegate)

            NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    guard !gFinished else { return }
                    gFinished = true
                    // 等 delegate 的 applicationDidFinishLaunching 跑完（扫描在后台线程）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let code = gDriver!.run()
                        print(code == 0 ? "\n===== ✅ PASS: 小窗按钮 → 主窗口 全链路可用 =====" : "\n===== ❌ FAIL =====")
                        fflush(stdout)
                        exit(code)
                    }
                }
            }
            app.run()
        }
    }
}
