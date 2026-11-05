import AppKit
import MoleLiteCore
import SwiftUI

@main
struct MoleLiteApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @StateObject private var menuBarMonitor = MenuBarMonitor()

    init() {
        // 改名后的一次性偏好迁移：旧域名是 com.molelite.app，新域名是 com.o.app。
        PreferenceMigration.migrateIfNeeded()

        // 单实例：拿不到锁说明已有实例在运行，请求它把窗口提到前台后退出本进程。
        if !InstanceGuard.shared.acquire() {
            InstanceGuard.postActivationRequest()
            exit(0)
        }
    }

    var body: some Scene {
        // 使用单例 Window 场景，openWindow 只会显示同一扇窗口，不会产生重复窗口。
        Window("O", id: "main") {
            RootView(menuBarMonitor: menuBarMonitor)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // 文件：扫描 / 清理 / 导出报告（并入系统「文件」菜单，不另建重复菜单）。
            CommandGroup(after: .newItem) {
                Divider()
                Button("扫描") {
                    NotificationCenter.default.post(name: .moleLiteQuickScan, object: nil)
                    AppWindowBridge.shared.presentMainWindow()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("清理已选") {
                    NotificationCenter.default.post(name: .oCleanSelected, object: nil)
                    AppWindowBridge.shared.presentMainWindow()
                }
                .keyboardShortcut(.delete, modifiers: .command)

                Button("导出报告…") {
                    NotificationCenter.default.post(name: .oExportReport, object: nil)
                    AppWindowBridge.shared.presentMainWindow()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            // 显示：页面切换 + 搜索 + 跟随系统外观。
            CommandMenu("显示") {
                ForEach(AppSection.allCases) { section in
                    Button(section.title) {
                        AppCoordinator.shared.show(section)
                        NotificationCenter.default.post(name: .moleLiteSelectSection,
                                                        object: section.rawValue)
                        AppWindowBridge.shared.presentMainWindow()
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(section.shortcutNumber)")),
                                      modifiers: .command)
                }
                Divider()
                Button("聚焦搜索") {
                    NotificationCenter.default.post(name: .oFocusSearch, object: nil)
                    AppWindowBridge.shared.presentMainWindow()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("跟随系统外观") {
                    NSApp.appearance = nil
                }
                Button("刷新当前页面") {
                    NotificationCenter.default.post(name: .moleLiteRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            // 工具：权限、规则与设置。
            CommandMenu("工具") {
                Button("权限检查") {
                    AppCoordinator.shared.show(.system, systemTab: .permissions)
                    NotificationCenter.default.post(name: .moleLiteSelectSection,
                                                    object: AppSection.system.rawValue)
                    AppWindowBridge.shared.presentMainWindow()
                }
                Button("清理规则") {
                    AppCoordinator.shared.show(.rules)
                    NotificationCenter.default.post(name: .moleLiteSelectSection,
                                                    object: AppSection.rules.rawValue)
                    AppWindowBridge.shared.presentMainWindow()
                }
                Divider()
                Button("打开设置") {
                    openSettings()
                }
            }
        }

        MenuBarExtra {
            MenuBarPanel(monitor: menuBarMonitor, coordinator: AppCoordinator.shared)
        } label: {
            MenuBarLabel(monitor: menuBarMonitor)
        }
        .menuBarExtraStyle(.window)
    }

    /// 系统「设置」入口：切到系统页的设置分区并唤起主窗口。
    private func openSettings() {
        AppCoordinator.shared.show(.system, systemTab: .settings)
        NotificationCenter.default.post(name: .moleLiteSelectSection,
                                        object: AppSection.system.rawValue)
        AppWindowBridge.shared.presentMainWindow()
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从命令行直接启动未打包的可执行文件时，也保证有 Dock 图标与可聚焦窗口。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 第二个进程发出的激活请求：由已有实例重新显示主窗口。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActivationRequest),
            name: InstanceGuard.activationNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        UIAudit.runIfNeeded()
        UIScanBenchmark.runIfNeeded()
        LifecycleAudit.runIfNeeded()
        LoginItemAudit.runIfNeeded()
    }

    /// 点击 Dock 图标时回到已有主窗口，而不是新建窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppWindowBridge.shared.presentMainWindow()
        }
        return true
    }

    /// 关闭最后一个窗口时是否退出，完全跟随设置项；默认驻留菜单栏。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        WindowCloseBehavior.current() == .quitApp
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        InstanceGuard.shared.release()
    }

    @objc private func handleActivationRequest() {
        AppWindowBridge.shared.presentMainWindow()
    }
}
