import AppKit
import CoreGraphics
import MoleLiteCore

/// 隐藏的生命周期自检：`O --lifecycle-audit`。
/// 依次验证主窗口存在、状态栏项存在、关闭后进程存活、再激活后复用同一扇窗口。
enum LifecycleAudit {
    static var isEnabled: Bool { CommandLine.arguments.contains("--lifecycle-audit") }

    @MainActor
    static func runIfNeeded() {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        let previousCloseBehavior = defaults.string(forKey: AppBehaviorSettings.Keys.windowCloseBehavior)
        // 自检固定为默认的「驻留菜单栏」，结束后恢复原值。
        defaults.set(WindowCloseBehavior.keepInMenuBar.rawValue,
                     forKey: AppBehaviorSettings.Keys.windowCloseBehavior)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)

            guard let window = mainWindow() else {
                print("[life] FAIL 启动后没有主窗口")
                NSApp.terminate(nil)
                return
            }
            let number = window.windowNumber
            print("[life] main-window number=\(number) visible=\(window.isVisible)")
            print("[life] status-item-windows=\(statusItemWindowCount())")

            window.performClose(nil)
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            let aliveAfterClose = NSApp.isRunning && mainWindowCount() == 0
            print("[life] after-close app-running=\(NSApp.isRunning) main-windows=\(mainWindowCount()) resident=\(aliveAfterClose)")

            InstanceGuard.postActivationRequest()
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            let reopened = mainWindow()
            print("[life] after-reopen main-windows=\(mainWindowCount()) same-window=\(reopened?.windowNumber == number) visible=\(reopened?.isVisible ?? false)")

            if let previousCloseBehavior {
                defaults.set(previousCloseBehavior, forKey: AppBehaviorSettings.Keys.windowCloseBehavior)
            } else {
                defaults.removeObject(forKey: AppBehaviorSettings.Keys.windowCloseBehavior)
            }
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.canBecomeMain && !$0.isMiniaturized && $0.contentView != nil
        }
    }

    @MainActor
    private static func mainWindowCount() -> Int {
        NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !$0.isMiniaturized }.count
    }

    /// 菜单栏项由系统创建为 layer 25 的窗口；按自身 PID 过滤即可确认存在。
    @MainActor
    private static func statusItemWindowCount() -> Int {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { entry in
            let pid = entry[kCGWindowOwnerPID as String] as? Int32
            let layer = entry[kCGWindowLayer as String] as? Int
            return pid == getpid() && layer == 25
        }.count
    }
}
