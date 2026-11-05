import Foundation

/// 扫描分类。界面上每个分类展示为一张卡片。
public enum ScanCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case userCaches
    case logs
    case xcode
    case trash
    case largeFiles
    /// 应用支持残留、容器、窗口恢复状态、HTTP 存储。
    case appLeftovers
    /// CrashReporter / DiagnosticReports。
    case diagnostics
    /// Xcode 归档、模拟器与设备支持之外的开发数据。
    case developer
    /// npm / yarn / pnpm / pip / brew / go / rust / gradle / maven / cocoapods。
    case packageCaches
    case docker
    case backups
    case mailAttachments
    /// 下载 / 桌面 / 文稿 / 影片中的大文件与旧文件。
    case userFiles
    /// 仅限可读的用户级系统日志与缓存副本。
    case systemCaches

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userCaches: return "用户缓存"
        case .logs: return "日志文件"
        case .xcode: return "Xcode 与模拟器"
        case .trash: return "废纸篓"
        case .largeFiles: return "大文件"
        case .appLeftovers: return "应用残留"
        case .diagnostics: return "诊断报告"
        case .developer: return "开发归档"
        case .packageCaches: return "包管理器缓存"
        case .docker: return "Docker"
        case .backups: return "iOS 备份"
        case .mailAttachments: return "邮件附件"
        case .userFiles: return "个人文件"
        case .systemCaches: return "系统缓存副本"
        }
    }

    public var subtitle: String {
        switch self {
        case .userCaches: return "~/Library/Caches 下的应用缓存"
        case .logs: return "~/Library/Logs 下的日志"
        case .xcode: return "派生数据、模拟器与设备支持"
        case .trash: return "废纸篓中的项目"
        case .largeFiles: return "下载与文档中的大文件"
        case .appLeftovers: return "Application Support · Containers · HTTPStorages"
        case .diagnostics: return "CrashReporter 与 DiagnosticReports"
        case .developer: return "Xcode Archives 与开发缓存"
        case .packageCaches: return "npm / pip / brew / go / rust / gradle 等"
        case .docker: return "仅在检测到 Docker 时出现"
        case .backups: return "MobileSync 本地备份"
        case .mailAttachments: return "邮件已下载的附件"
        case .userFiles: return "大文件与一年以上未修改的文件"
        case .systemCaches: return "仅可读的用户级日志与缓存副本"
        }
    }

    public var systemImage: String {
        switch self {
        case .userCaches: return "shippingbox"
        case .logs: return "doc.text"
        case .xcode: return "hammer"
        case .trash: return "trash"
        case .largeFiles: return "externaldrive"
        case .appLeftovers: return "square.stack.3d.up"
        case .diagnostics: return "exclamationmark.bubble"
        case .developer: return "archivebox"
        case .packageCaches: return "shippingbox.and.arrow.backward"
        case .docker: return "shippingbox.fill"
        case .backups: return "iphone"
        case .mailAttachments: return "envelope"
        case .userFiles: return "folder"
        case .systemCaches: return "gearshape.2"
        }
    }

    /// 「建议项」：默认勾选的分类。谨慎级来源需要用户自行判断。
    public var isRecommended: Bool {
        switch self {
        case .userCaches, .logs, .xcode, .appLeftovers, .diagnostics,
             .developer, .packageCaches, .systemCaches:
            return true
        case .trash, .largeFiles, .docker, .backups, .mailAttachments, .userFiles:
            return false
        }
    }
}

/// 扫描结果中的一个条目（可展开查看子项）。
public struct ScanItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let byteSize: Int64
    public let isDirectory: Bool
    public let children: [ScanItem]
    public let modifiedAt: Date?

    public init(url: URL, name: String? = nil, byteSize: Int64, isDirectory: Bool,
                children: [ScanItem] = [], modifiedAt: Date? = nil) {
        self.url = url
        self.id = url.path
        self.name = name ?? url.lastPathComponent
        self.byteSize = byteSize
        self.isDirectory = isDirectory
        self.children = children
        self.modifiedAt = modifiedAt
    }

    /// 文件后缀（小写，不含点）；目录返回 "文件夹"。
    public var fileExtension: String {
        if isDirectory { return "文件夹" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "无类型" : ext
    }
}

/// 单个分类的扫描结果。
public struct ScanCategoryResult: Identifiable, Sendable {
    public let category: ScanCategory
    public var items: [ScanItem]
    public var totalBytes: Int64
    public var message: String?

    public var id: String { category.rawValue }

    public init(category: ScanCategory, items: [ScanItem] = [], totalBytes: Int64 = 0, message: String? = nil) {
        self.category = category
        self.items = items
        self.totalBytes = totalBytes
        self.message = message
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// 一次完整扫描的产物。
public struct ScanReport: Sendable {
    public var results: [ScanCategoryResult]
    public var scannedItemCount: Int
    public var duration: TimeInterval
    public var finishedAt: Date

    public init(results: [ScanCategoryResult], scannedItemCount: Int, duration: TimeInterval, finishedAt: Date = Date()) {
        self.results = results
        self.scannedItemCount = scannedItemCount
        self.duration = duration
        self.finishedAt = finishedAt
    }

    public var totalBytes: Int64 {
        results.reduce(0) { $0 + $1.totalBytes }
    }

    public func result(for category: ScanCategory) -> ScanCategoryResult? {
        results.first { $0.category == category }
    }
}

/// 扫描进度快照（后台线程产生，主线程消费）。
public struct ScanProgress: Sendable {
    public var completedTargets: Int
    public var totalTargets: Int
    public var itemsScanned: Int
    public var currentPath: String
    public var category: ScanCategory?

    public init(completedTargets: Int = 0, totalTargets: Int = 0, itemsScanned: Int = 0, currentPath: String = "", category: ScanCategory? = nil) {
        self.completedTargets = completedTargets
        self.totalTargets = totalTargets
        self.itemsScanned = itemsScanned
        self.currentPath = currentPath
        self.category = category
    }

    public var fraction: Double {
        guard totalTargets > 0 else { return 0 }
        return min(1, Double(completedTargets) / Double(totalTargets))
    }
}

public enum ScanError: Error, LocalizedError, Equatable {
    case cancelled
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "扫描已取消"
        case .unavailable(let reason): return reason
        }
    }
}
