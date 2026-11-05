import Foundation

/// 清理结果（默认移入废纸篓；废纸篓内的条目可显式选择永久删除）。
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
    /// 移入废纸篓的字节数（可随时从废纸篓恢复）。
    public var movedBytes: Int64
    /// 永久删除的字节数（仅限废纸篓内容，不可恢复）。
    public var freedBytes: Int64
    public var startedAt: Date

    public init(outcomes: [TrashOutcome] = [], movedBytes: Int64 = 0, freedBytes: Int64 = 0,
                startedAt: Date = Date()) {
        self.outcomes = outcomes
        self.movedBytes = movedBytes
        self.freedBytes = freedBytes
        self.startedAt = startedAt
    }

    /// 旧版构造器：`bytesFreed` 语义为移入废纸篓的字节数。
    public init(outcomes: [TrashOutcome] = [], bytesFreed: Int64, startedAt: Date = Date()) {
        self.init(outcomes: outcomes, movedBytes: bytesFreed, freedBytes: 0, startedAt: startedAt)
    }

    /// 兼容旧字段：本次清理实际处理的字节数（移入废纸篓 + 永久删除）。
    public var bytesFreed: Int64 { movedBytes + freedBytes }

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

    /// 是否包含永久删除（不可恢复），界面据此强调风险。
    public var hasPermanentDeletion: Bool { freedBytes > 0 }

    public var summary: String {
        if outcomes.isEmpty { return "没有需要清理的项目" }
        if failureCount == 0 {
            if freedBytes > 0 && movedBytes == 0 { return "已永久删除 \(successCount) 项" }
            if freedBytes > 0 { return "已清理 \(successCount) 项（其中含永久删除）" }
            return "已移入废纸篓 \(successCount) 项"
        }
        return "成功 \(successCount) 项，失败 \(failureCount) 项"
    }
}
