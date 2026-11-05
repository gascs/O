import AppKit
import SwiftUI

/// 主窗口入口的桥接：SwiftUI 的 openWindow 动作由 RootView 注册，
/// AppKit 的 Dock 重新打开、单实例激活通知都通过这里回到同一扇窗口。
final class AppWindowBridge {
    static let shared = AppWindowBridge()

    var present: (() -> Void)?

    func presentMainWindow() {
        present?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 一级导航：顶部水平排列，⌘1–⌘6 对应六个页面。
enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case clean
    case space
    case apps
    case system
    case rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "首页"
        case .clean: return "清理"
        case .space: return "空间"
        case .apps: return "应用"
        case .system: return "系统"
        case .rules: return "规则"
        }
    }

    /// 顶部导航下方 / 状态栏用的次要信息。
    var subtitle: String {
        switch self {
        case .overview: return "设备与实时状态"
        case .clean: return "缓存 · 日志 · 废纸篓"
        case .space: return "大文件 · 重复"
        case .apps: return "卸载与残留"
        case .system: return "启动项 · 权限 · 设置"
        case .rules: return "预设 · 来源 · 保护清单"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.medium"
        case .clean: return "trash"
        case .space: return "internaldrive"
        case .apps: return "square.grid.2x2"
        case .system: return "gearshape"
        case .rules: return "slider.horizontal.3"
        }
    }

    /// 页面快捷键：⌘1 … ⌘6。
    var shortcutNumber: Int {
        switch self {
        case .overview: return 1
        case .clean: return 2
        case .space: return 3
        case .apps: return 4
        case .system: return 5
        case .rules: return 6
        }
    }
}

/// 二级切换：空间页的「大文件 / 重复文件」。
enum SpaceTab: String, CaseIterable, Identifiable {
    case files
    case duplicates

    var id: String { rawValue }
    var title: String { self == .files ? "大文件" : "重复文件" }
}

/// 二级切换：系统页的「启动项 / 权限 / 设置」。
enum SystemTab: String, CaseIterable, Identifiable {
    case launchItems
    case permissions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launchItems: return "启动项"
        case .permissions: return "权限"
        case .settings: return "设置"
        }
    }
}

/// 全局导航状态。主窗口与菜单栏面板共享同一份，便于菜单栏直接跳到某个页面。
/// 视觉方向已收敛为唯一的 M2 版本，不再保留可切换的样式分支。
@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    @Published var section: AppSection = .overview
    @Published var spaceTab: SpaceTab = .files
    @Published var systemTab: SystemTab = .settings
    /// 工具栏搜索词。各列表页按需消费。
    @Published var searchText = ""
    /// 主窗口是否正在扫描；菜单栏面板据此同步按钮状态。
    @Published var isScanning = false
    /// 每次自增代表一次扫描请求，主窗口据此启动扫描。
    @Published private(set) var quickScanToken = 0
    /// 用户在受限整页选择「仍然扫描可见范围」后，本次会话不再拦截；不持久化。
    @Published var allowLimitedScan = false
    /// 仅渲染自检使用：强制三个数据页显示整页受限态，便于出图核对。
    @Published var auditForceRestricted = false

    private init() {}

    func requestQuickScan() {
        section = .clean
        quickScanToken += 1
    }

    /// 菜单栏或命令菜单跳转，同时带上二级页签。
    func show(_ section: AppSection, systemTab: SystemTab? = nil, spaceTab: SpaceTab? = nil) {
        self.section = section
        if let systemTab { self.systemTab = systemTab }
        if let spaceTab { self.spaceTab = spaceTab }
    }
}

extension Notification.Name {
    /// 由菜单命令发出，主窗口收到后刷新当前页面。
    static let moleLiteRefresh = Notification.Name("MoleLiteRefresh")
    /// 由菜单命令发出，主窗口收到后切换到指定分区（object 为 AppSection.rawValue）。
    static let moleLiteSelectSection = Notification.Name("MoleLiteSelectSection")
    /// 由菜单命令发出，主窗口收到后启动扫描。
    static let moleLiteQuickScan = Notification.Name("MoleLiteQuickScan")
    /// ⌘F：聚焦工具栏搜索框。
    static let oFocusSearch = Notification.Name("o.focusSearch")
    /// 文件菜单：清理当前已勾选条目。
    static let oCleanSelected = Notification.Name("o.cleanSelected")
    /// 文件菜单：导出当前扫描报告。
    static let oExportReport = Notification.Name("o.exportReport")
    /// 设置页请求重新打开权限引导。
    static let oShowPermissionGuide = Notification.Name("o.showPermissionGuide")
    /// 渲染自检专用：直接触发规则页的预计空间估算，避免依赖辅助功能点击。
    static let oAuditEstimateRules = Notification.Name("o.auditEstimateRules")
}
