import AppKit
import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// 登录项注册状态。全部来自系统真实返回，不做任何乐观假设。
public enum LoginItemState: Equatable, Sendable {
    /// 已注册，登录时启动。
    case enabled
    /// 尚未注册。
    case notRegistered
    /// 已注册但需要用户在系统设置里批准。
    case requiresApproval
    /// 系统找不到该登录项（通常是应用被移动或未安装到 Applications）。
    case notFound
    /// 当前环境不支持（非 macOS 13+）。
    case unsupported
    /// 注册 / 注销失败，附带系统返回的原因。
    case failed(String)

    public var title: String {
        switch self {
        case .enabled: return "已启用"
        case .notRegistered: return "未启用"
        case .requiresApproval: return "需在系统设置批准"
        case .notFound: return "未找到登录项"
        case .unsupported: return "当前系统不支持"
        case .failed: return "注册失败"
        }
    }

    public var detail: String {
        switch self {
        case .enabled:
            return "已通过 SMAppService 注册，登录时自动打开 O。"
        case .notRegistered:
            return "尚未注册为登录项。"
        case .requiresApproval:
            return "系统已记录该登录项，但需要在「系统设置 › 通用 › 登录项」中允许。"
        case .notFound:
            return "系统未找到该应用的登录项记录，请先把 O.app 放到「应用程序」文件夹再试。"
        case .unsupported:
            return "仅 macOS 13 及以上支持通过 SMAppService 注册登录项。"
        case .failed(let message):
            return message
        }
    }

    /// 自检与日志用的稳定描述。
    public var rawDescription: String {
        switch self {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        case .unsupported: return "unsupported"
        case .failed(let message): return "failed(\(message))"
        }
    }

    /// 开关状态：只有真实 enabled 才算开启。
    public var isEnabled: Bool { self == .enabled }

    /// 需要跳系统设置才能继续。
    public var needsSystemSettings: Bool {
        switch self {
        case .requiresApproval, .failed:
            return true
        default:
            return false
        }
    }

    /// 把 SMAppService.Status 的原始值映射为界面状态，便于在不依赖框架的情况下测试。
    public static func map(rawStatus: Int) -> LoginItemState {
        switch rawStatus {
        case 0: return .notRegistered
        case 1: return .enabled
        case 2: return .requiresApproval
        case 3: return .notFound
        default: return .failed("系统返回未知登录项状态（\(rawStatus)）")
        }
    }
}

/// 登录项控制器：封装 SMAppService，失败时保留系统原文。
public final class LoginItemController {
    public init() {}

    public var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public func currentState() -> LoginItemState {
        guard #available(macOS 13.0, *) else { return .unsupported }
        #if canImport(ServiceManagement)
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .failed("系统返回未知登录项状态")
        }
        #else
        return .unsupported
        #endif
    }

    /// 注册或注销登录项。抛出系统原始错误，由界面如实展示。
    public func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LoginItemError.unsupported
        }
        guard isRunningFromAppBundle else {
            throw LoginItemError.notBundled
        }
        #if canImport(ServiceManagement)
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        #else
        throw LoginItemError.unsupported
        #endif
    }

    public func openSystemSettings() {
        guard #available(macOS 13.0, *) else {
            openPrivacySettingsFallback()
            return
        }
        #if canImport(ServiceManagement)
        SMAppService.openSystemSettingsLoginItems()
        #else
        openPrivacySettingsFallback()
        #endif
    }

    private func openPrivacySettingsFallback() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

public enum LoginItemError: LocalizedError {
    case unsupported
    case notBundled

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "当前系统版本不支持 SMAppService 登录项注册（需要 macOS 13 及以上）。"
        case .notBundled:
            return "当前可执行文件不在 .app 包内，系统拒绝注册登录项。请通过构建产物 O.app 启动后再试。"
        }
    }
}
