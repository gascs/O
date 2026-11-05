import Foundation

/// 清理服务：默认只调用 FileManager.trashItem（移入废纸篓，可恢复）。
/// 对「废纸篓内的条目」只有在调用方显式传入 `allowPermanentRemoval: true`
/// 或走 `empty(...)` 时才会永久删除，其余情况一律拒绝。
public struct TrashService: Sendable {
    public let safety: PathSafety

    public init(safety: PathSafety = PathSafety()) {
        self.safety = safety
    }

    public func trash(entries: [(url: URL, size: Int64)],
                      allowPermanentRemoval: Bool = false,
                      progress: ((_ completed: Int, _ total: Int) -> Void)? = nil) -> CleanReport {
        var outcomes: [TrashOutcome] = []
        var moved: Int64 = 0
        var freed: Int64 = 0
        let fileManager = FileManager.default
        let trashPath = safety.homeDirectory.appendingPathComponent(".Trash").path
        let total = entries.count
        progress?(0, total)

        for (index, entry) in entries.enumerated() {
            defer { progress?(index + 1, total) }
            let verdict = safety.verdict(for: entry.url)
            guard verdict.isAllowed else {
                outcomes.append(TrashOutcome(url: entry.url, success: false, message: verdict.rejectionReason ?? "路径校验未通过"))
                continue
            }

            let insideTrash = PathSafety.isWithinCaseInsensitive(entry.url.path, prefix: trashPath)
            if insideTrash {
                // 默认行为不变：废纸篓内容需用户在 Finder 中清空。
                let isTrashRootItself = PathSafety.isWithinCaseInsensitive(trashPath, prefix: entry.url.path)
                    && PathSafety.isWithinCaseInsensitive(entry.url.path, prefix: trashPath)
                guard allowPermanentRemoval, !isTrashRootItself else {
                    outcomes.append(TrashOutcome(url: entry.url, success: false,
                                                 message: "项目位于废纸篓内，请在 Finder 中手动清空废纸篓"))
                    continue
                }

                guard fileManager.fileExists(atPath: entry.url.path) else {
                    outcomes.append(TrashOutcome(url: entry.url, success: true, message: "文件已不存在，已跳过"))
                    continue
                }

                do {
                    try fileManager.removeItem(at: entry.url)
                    outcomes.append(TrashOutcome(url: entry.url, success: true, message: "已永久删除，不可恢复"))
                    freed += entry.size
                } catch {
                    outcomes.append(TrashOutcome(url: entry.url, success: false,
                                                 message: friendlyMessage(for: error, action: "永久删除")))
                }
                continue
            }

            guard fileManager.fileExists(atPath: entry.url.path) else {
                outcomes.append(TrashOutcome(url: entry.url, success: true, message: "文件已不存在，已跳过"))
                continue
            }

            do {
                var resulting: NSURL?
                try fileManager.trashItem(at: entry.url, resultingItemURL: &resulting)
                outcomes.append(TrashOutcome(url: entry.url, success: true, resultingURL: resulting as URL?))
                moved += entry.size
            } catch {
                outcomes.append(TrashOutcome(url: entry.url, success: false,
                                             message: friendlyMessage(for: error, action: "移入废纸篓")))
            }
        }

        return CleanReport(outcomes: outcomes, movedBytes: moved, freedBytes: freed)
    }

    public func trash(items: [ScanItem],
                      allowPermanentRemoval: Bool = false,
                      progress: ((_ completed: Int, _ total: Int) -> Void)? = nil) -> CleanReport {
        trash(entries: items.map { (url: $0.url, size: $0.byteSize) },
              allowPermanentRemoval: allowPermanentRemoval, progress: progress)
    }

    public func trash(leftovers: [LeftoverItem]) -> CleanReport {
        trash(entries: leftovers.map { (url: $0.url, size: $0.byteSize) })
    }

    /// 永久删除（仅限废纸篓内的条目，不可恢复）。
    public func empty(entries: [(url: URL, size: Int64)],
                      progress: ((_ completed: Int, _ total: Int) -> Void)? = nil) -> CleanReport {
        trash(entries: entries, allowPermanentRemoval: true, progress: progress)
    }

    /// 永久删除（仅限废纸篓内的条目，不可恢复）。
    public func empty(items: [ScanItem],
                      progress: ((_ completed: Int, _ total: Int) -> Void)? = nil) -> CleanReport {
        empty(entries: items.map { (url: $0.url, size: $0.byteSize) }, progress: progress)
    }

    private func friendlyMessage(for error: Error, action: String = "移入废纸篓") -> String {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteNoPermission, .fileReadNoPermission:
                return "权限不足，无法\(action)。请在「系统设置 › 隐私与安全性 › 完全磁盘访问」中授权后手动处理"
            case .fileNoSuchFile:
                return "文件已不存在"
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError {
            return "权限不足，无法\(action)。请在「系统设置 › 隐私与安全性 › 完全磁盘访问」中授权后手动处理"
        }
        return nsError.localizedDescription
    }
}
