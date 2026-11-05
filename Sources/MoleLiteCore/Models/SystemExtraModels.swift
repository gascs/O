import Foundation

// MARK: - 网络

/// 网络速率快照。由两次采样的累计字节数求差得到。
public struct NetworkRate: Sendable, Equatable {
    public let downBytesPerSecond: Double
    public let upBytesPerSecond: Double
    public let totalReceivedBytes: Int64
    public let totalSentBytes: Int64

    public init(downBytesPerSecond: Double, upBytesPerSecond: Double,
                totalReceivedBytes: Int64, totalSentBytes: Int64) {
        self.downBytesPerSecond = max(0, downBytesPerSecond)
        self.upBytesPerSecond = max(0, upBytesPerSecond)
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
    }

    public static let zero = NetworkRate(downBytesPerSecond: 0, upBytesPerSecond: 0,
                                         totalReceivedBytes: 0, totalSentBytes: 0)
}

// MARK: - 电池

public struct BatterySnapshot: Sendable, Equatable {
    public let isPresent: Bool
    public let chargeFraction: Double
    public let isCharging: Bool
    public let isCharged: Bool
    /// 剩余分钟数；nil 表示系统暂时无法估算（例如正在校准）。
    public let timeRemainingMinutes: Int?
    public let isOnAC: Bool

    public init(isPresent: Bool, chargeFraction: Double, isCharging: Bool,
                isCharged: Bool, timeRemainingMinutes: Int?, isOnAC: Bool) {
        self.isPresent = isPresent
        self.chargeFraction = min(1, max(0, chargeFraction))
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.timeRemainingMinutes = timeRemainingMinutes
        self.isOnAC = isOnAC
    }

    public static let absent = BatterySnapshot(isPresent: false, chargeFraction: 0, isCharging: false,
                                              isCharged: false, timeRemainingMinutes: nil, isOnAC: true)

    public var statusText: String {
        guard isPresent else { return "无电池" }
        if isCharged { return "已充满" }
        if isCharging { return "充电中" }
        return isOnAC ? "已接通电源" : "使用电池"
    }
}

// MARK: - 启动项

public enum LaunchScope: String, CaseIterable, Identifiable, Sendable {
    case userAgent
    case userDaemon
    case systemAgent
    case systemDaemon
    /// 系统「登录项」（后台任务数据库）。只读展示，不修改系统数据库。
    case loginItem

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userAgent: return "用户代理"
        case .userDaemon: return "用户守护进程"
        case .systemAgent: return "系统代理"
        case .systemDaemon: return "系统守护进程"
        case .loginItem: return "登录项"
        }
    }

    public var detail: String {
        switch self {
        case .userAgent: return "~/Library/LaunchAgents"
        case .userDaemon: return "~/Library/LaunchDaemons"
        case .systemAgent: return "/Library/LaunchAgents"
        case .systemDaemon: return "/Library/LaunchDaemons"
        case .loginItem: return "系统后台任务数据库（只读）"
        }
    }

    /// 只有用户目录下的启动项才允许由当前用户移动。
    public var isUserEditable: Bool {
        self == .userAgent || self == .userDaemon
    }

    public var systemImage: String {
        switch self {
        case .userAgent, .systemAgent: return "person.crop.circle"
        case .userDaemon, .systemDaemon: return "gearshape.2"
        case .loginItem: return "person.badge.clock"
        }
    }
}

public struct LaunchItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let label: String
    public let program: String?
    public let scope: LaunchScope
    public let runAtLoad: Bool
    public let isDisabled: Bool

    public init(url: URL, label: String, program: String?, scope: LaunchScope,
                runAtLoad: Bool, isDisabled: Bool) {
        self.url = url
        self.label = label
        self.program = program
        self.scope = scope
        self.runAtLoad = runAtLoad
        self.isDisabled = isDisabled
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public var statusText: String {
        if isDisabled { return "已停用" }
        return runAtLoad ? "登录时启动" : "按需加载"
    }
}

// MARK: - 重复文件

public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let byteSize: Int64
    public let modifiedAt: Date?

    public init(url: URL, byteSize: Int64, modifiedAt: Date?) {
        self.url = url
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let files: [DuplicateFile]
    public let fileSize: Int64

    public init(id: String, files: [DuplicateFile], fileSize: Int64) {
        self.id = id
        self.files = files
        self.fileSize = fileSize
    }

    public var duplicateCount: Int { max(0, files.count - 1) }
    public var reclaimableBytes: Int64 { fileSize * Int64(duplicateCount) }
}

// MARK: - 推荐分级

public enum SafetyGrade: String, CaseIterable, Identifiable, Codable, Sendable {
    case safe
    case suggested
    case caution

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .safe: return "安全"
        case .suggested: return "建议"
        case .caution: return "谨慎"
        }
    }

    public var systemImage: String {
        switch self {
        case .safe: return "checkmark.shield"
        case .suggested: return "leaf"
        case .caution: return "exclamationmark.triangle"
        }
    }

    public var explanation: String {
        switch self {
        case .safe: return "系统或应用会自动重建，清理后不影响使用"
        case .suggested: return "可以清理，但可能丢失历史记录或诊断信息"
        case .caution: return "可能是你自己的文件，请确认后再处理"
        }
    }

    /// 仅这两个级别参与「一键清理建议项」。
    public var isOneClickEligible: Bool { self != .caution }
}

public struct RecommendationGroup: Identifiable, Sendable {
    public let grade: SafetyGrade
    public let itemIDs: [String]
    public let bytes: Int64
    public let categories: [ScanCategory]
    public let note: String

    public init(grade: SafetyGrade, itemIDs: [String], bytes: Int64,
                categories: [ScanCategory], note: String) {
        self.grade = grade
        self.itemIDs = itemIDs
        self.bytes = bytes
        self.categories = categories
        self.note = note
    }

    public var id: String { grade.rawValue }
    public var itemCount: Int { itemIDs.count }
}

// MARK: - 历史与趋势

public struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case scan
        case clean
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let bytes: Int64
    public let itemCount: Int
    public let detail: String

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind,
                bytes: Int64, itemCount: Int, detail: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.bytes = bytes
        self.itemCount = itemCount
        self.detail = detail
    }

    public var kindTitle: String {
        switch kind {
        case .scan: return "扫描"
        case .clean: return "清理"
        }
    }
}

public struct DiskTrendPoint: Codable, Identifiable, Sendable, Equatable {
    public let day: Date
    public let usedBytes: Int64
    public let totalBytes: Int64

    public init(day: Date, usedBytes: Int64, totalBytes: Int64) {
        self.day = day
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public var id: Double { day.timeIntervalSince1970 }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

// MARK: - 菜单栏显示模式

public enum MenuBarDisplayStyle: String, CaseIterable, Identifiable, Sendable {
    case icon
    case percent
    case iconAndPercent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .icon: return "仅图标"
        case .percent: return "百分比"
        case .iconAndPercent: return "图标 + 百分比"
        }
    }
}
