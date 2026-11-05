import Foundation

/// 清理结果（仅「移入废纸篓」，不做永久删除）。
public struct TrashOutcome: Identifiable, Sendable {
    public let url: URL
    public let success: Bool
    public let message: String?
    /// 移入废纸篓后的实际位置（仅成功时有值）。
    public let resultingURL: URL?

    public var id: String { url.path }

    public init(url: URL, success: Bool, message: String? = nil, resultingURL: URL? = nil) {
        self.url = url
        self.success = success
        self.message = message
        self.resultingURL = resultingURL
    }
}

public struct CleanReport: Sendable {
    public var outcomes: [TrashOutcome]
    public var bytesFreed: Int64
    public var startedAt: Date

    public init(outcomes: [TrashOutcome] = [], bytesFreed: Int64 = 0, startedAt: Date = Date()) {
        self.outcomes = outcomes
        self.bytesFreed = bytesFreed
        self.startedAt = startedAt
    }

    public var successCount: Int { outcomes.filter(\.success).count }
    public var failureCount: Int { outcomes.filter { !$0.success }.count }
    public var failures: [TrashOutcome] { outcomes.filter { !$0.success } }

    /// 是否有失败项属于「权限不足」，界面据此给出可操作的授权引导。
    public var hasPermissionIssue: Bool {
        failures.contains { ($0.message ?? "").contains("权限") }
    }

    /// 是否有失败项属于「文件已不存在」（扫描后被其他程序删除），这类不算真错误。
    public var hasDisappearedFiles: Bool {
        failures.contains { ($0.message ?? "").contains("已不存在") }
    }

    public var summary: String {
        if outcomes.isEmpty { return "没有需要清理的项目" }
        if failureCount == 0 { return "已移入废纸篓 \(successCount) 项" }
        return "成功 \(successCount) 项，失败 \(failureCount) 项"
    }
}
