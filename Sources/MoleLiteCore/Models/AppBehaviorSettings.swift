import Foundation

/// 关闭主窗口后的行为。
public enum WindowCloseBehavior: String, CaseIterable, Identifiable, Sendable {
    /// 驻留菜单栏（默认）。
    case keepInMenuBar
    /// 退出应用。
    case quitApp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keepInMenuBar: return "驻留菜单栏"
        case .quitApp: return "退出应用"
        }
    }

    public var detail: String {
        switch self {
        case .keepInMenuBar:
            return "关闭窗口后进程继续运行，菜单栏图标与定时刷新仍然可用。"
        case .quitApp:
            return "关闭最后一个窗口时结束进程，菜单栏图标随之消失。"
        }
    }

    public static func current(from defaults: UserDefaults = .standard) -> WindowCloseBehavior {
        guard let raw = defaults.string(forKey: AppBehaviorSettings.Keys.windowCloseBehavior),
              let value = WindowCloseBehavior(rawValue: raw) else {
            return .keepInMenuBar
        }
        return value
    }
}

public enum AppBehaviorSettings {
    public enum Keys {
        /// 关闭窗口行为，存 WindowCloseBehavior.rawValue。
        public static let windowCloseBehavior = "app.windowCloseBehavior"
    }

    public static func windowCloseBehavior(from defaults: UserDefaults = .standard) -> WindowCloseBehavior {
        WindowCloseBehavior.current(from: defaults)
    }
}
