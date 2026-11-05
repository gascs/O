import Foundation

/// 残留文件类型。
public enum LeftoverKind: String, Sendable, CaseIterable {
    case cache
    case preference
    case container
    case groupContainer
    case applicationSupport
    case applicationScripts
    case log
    case crashReport
    case networkCache
    case savedState
    case webkit
    case launchAgent

    public var label: String {
        switch self {
        case .cache: return "缓存"
        case .preference: return "偏好设置"
        case .container: return "沙盒容器"
        case .groupContainer: return "共享容器"
        case .applicationSupport: return "应用数据"
        case .applicationScripts: return "应用脚本"
        case .log: return "日志"
        case .crashReport: return "崩溃报告"
        case .networkCache: return "网络缓存"
        case .savedState: return "窗口状态"
        case .webkit: return "WebKit 数据"
        case .launchAgent: return "登录启动项"
        }
    }

    public var systemImage: String {
        switch self {
        case .cache: return "shippingbox"
        case .preference: return "slider.horizontal.3"
        case .container: return "cube"
        case .groupContainer: return "square.stack.3d.up"
        case .applicationSupport: return "folder"
        case .applicationScripts: return "applescript"
        case .log: return "doc.text"
        case .crashReport: return "exclamationmark.octagon"
        case .networkCache: return "network"
        case .savedState: return "macwindow"
        case .webkit: return "globe"
        case .launchAgent: return "power"
        }
    }
}

/// 应用关联残留项。
public struct LeftoverItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let kind: LeftoverKind
    public let byteSize: Int64

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL, kind: LeftoverKind, byteSize: Int64) {
        self.url = url
        self.kind = kind
        self.byteSize = byteSize
    }
}

/// 已安装应用。
public struct AppBundle: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let byteSize: Int64
    public let leftovers: [LeftoverItem]

    public var id: String { url.path }

    public init(url: URL, name: String, bundleIdentifier: String?, version: String?, byteSize: Int64, leftovers: [LeftoverItem]) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.byteSize = byteSize
        self.leftovers = leftovers
    }

    public var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.byteSize } }
    public var totalBytes: Int64 { byteSize + leftoverBytes }
}
