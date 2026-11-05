import AppKit
import MoleLiteCore

/// 隐藏登录项自检：`O --loginitem-audit`。
/// 仅在显式参数下运行，注册后立即注销并回读状态，避免留下登录项。
enum LoginItemAudit {
    static var isEnabled: Bool { CommandLine.arguments.contains("--loginitem-audit") }

    @MainActor
    static func runIfNeeded() {
        guard isEnabled else { return }
        let controller = LoginItemController()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("[login] bundle=\(Bundle.main.bundlePath)")
            print("[login] id=\(Bundle.main.bundleIdentifier ?? "nil") in-app=\(controller.isRunningFromAppBundle)")
            print("[login] before=\(controller.currentState().rawDescription)")

            guard controller.currentState() != .enabled else {
                print("[login] 已存在登录项，跳过自动注册以免影响现有配置")
                NSApp.terminate(nil)
                return
            }

            do {
                try controller.setEnabled(true)
                print("[login] after-register=\(controller.currentState().rawDescription)")
            } catch {
                print("[login] register-failed=\(error.localizedDescription)")
                NSApp.terminate(nil)
                return
            }

            do {
                try controller.setEnabled(false)
                print("[login] after-unregister=\(controller.currentState().rawDescription)")
            } catch {
                print("[login] unregister-failed=\(error.localizedDescription)")
                do {
                    try controller.setEnabled(false)
                    print("[login] after-unregister-retry=\(controller.currentState().rawDescription)")
                } catch {
                    print("[login] unregister-retry-failed=\(error.localizedDescription)")
                }
            }

            print("[login] clean=\(controller.currentState() != .enabled)")
            NSApp.terminate(nil)
        }
    }
}
