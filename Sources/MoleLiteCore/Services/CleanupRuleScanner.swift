import Foundation

// MARK: - 规则驱动的扫描
//
// 扫描严格按「已启用规则」执行；每条规则独立产出体积与条目数。
// 根目录不可读 / 不存在 / 权限不足时记录原因并继续，不中断整次扫描。
// 所有候选条目在进入结果前都要通过 PathSafety 与受保护清单。

public struct RuleScanOutcome: Sendable, Identifiable {
    public let ruleID: String
    public var bytes: Int64
    public var items: [ScanItem]
    public var skippedReason: String?

    public var id: String { ruleID }
    public var itemCount: Int { items.count }

    public init(ruleID: String, bytes: Int64 = 0, items: [ScanItem] = [], skippedReason: String? = nil) {
        self.ruleID = ruleID
        self.bytes = bytes
        self.items = items
        self.skippedReason = skippedReason
    }
}

public struct RuleScanReport: Sendable {
    public var outcomes: [RuleScanOutcome]
    public var scannedFileCount: Int
    public var duration: TimeInterval
    public var finishedAt: Date
    /// 有扫描根被跳过的规则数（权限不足 / 路径不存在等）。
    public var skippedRuleCount: Int

    public init(outcomes: [RuleScanOutcome], scannedFileCount: Int,
                duration: TimeInterval, finishedAt: Date = Date()) {
        self.outcomes = outcomes
        self.scannedFileCount = scannedFileCount
        self.duration = duration
        self.finishedAt = finishedAt
        self.skippedRuleCount = outcomes.filter { $0.skippedReason != nil }.count
    }

    public func outcome(for ruleID: String) -> RuleScanOutcome? {
        outcomes.first { $0.ruleID == ruleID }
    }
}

public struct CleanupRuleScanner: Sendable {
    public let home: URL
    public let includeHidden: Bool
    /// 单条规则最多收集的条目数，避免个人文件规则把整个目录塞进结果。
    public let maxItemsPerRule: Int

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                includeHidden: Bool = false,
                maxItemsPerRule: Int = 250) {
        self.home = home
        self.includeHidden = includeHidden
        self.maxItemsPerRule = maxItemsPerRule
    }

    /// 同步执行；调用方负责放到后台线程。
    public func scan(rules: [CleanupRule],
                     protectedPaths: [String] = [],
                     cancellation: ScanCancellation = ScanCancellation(),
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) throws -> RuleScanReport {
        let started = Date()
        let enabled = rules.filter(\.isEnabled)
        let safety = PathSafety(homeDirectory: home)
        let protected = protectedPaths.compactMap {
            RuleValidation.normalized($0, home: home)
        }
        // 其它规则的扫描根：父规则遇到这些子目录时跳过，避免重复计量。
        let nestedRoots = enabled.map { RuleValidation.normalized($0.path, home: home) ?? $0.path }

        var outcomes: [RuleScanOutcome] = []
        var scannedFiles = 0

        for (index, rule) in enabled.enumerated() {
            try cancellation.check()
            let rootPath = RuleValidation.normalized(rule.path, home: home) ?? rule.path
            progress?(ScanProgress(completedTargets: index, totalTargets: enabled.count,
                                   itemsScanned: scannedFiles, currentPath: rule.name,
                                   category: rule.category))

            let rootURL = URL(fileURLWithPath: rootPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
                let reason = rule.category == .docker ? "未检测到 Docker 数据目录" : "路径不存在"
                outcomes.append(RuleScanOutcome(ruleID: rule.id, skippedReason: reason))
                continue
            }
            guard isDirectory.boolValue else {
                // 单文件规则：直接按条件判断。
                let outcome = try singleFileOutcome(rule: rule, url: rootURL, safety: safety, protected: protected)
                if outcome.skippedReason == nil { scannedFiles += 1 }
                outcomes.append(outcome)
                continue
            }

            let mode = rule.scanMode
            let outcome: RuleScanOutcome
            do {
                switch mode {
                case .topLevel:
                    outcome = try scanTopLevel(rule: rule, root: rootURL, safety: safety,
                                               protected: protected, nestedRoots: nestedRoots,
                                               cancellation: cancellation, scannedFiles: &scannedFiles)
                case .recursiveFiles:
                    outcome = try scanRecursive(rule: rule, root: rootURL, safety: safety,
                                                protected: protected,
                                                cancellation: cancellation, scannedFiles: &scannedFiles)
                }
            } catch let error as ScanError {
                if case .cancelled = error { throw error }
                outcomes.append(RuleScanOutcome(ruleID: rule.id, skippedReason: "读取失败：\(error.localizedDescription)"))
                continue
            } catch {
                outcomes.append(RuleScanOutcome(ruleID: rule.id, skippedReason: "权限不足或不可读"))
                continue
            }
            outcomes.append(outcome)
        }

        progress?(ScanProgress(completedTargets: enabled.count, totalTargets: enabled.count,
                               itemsScanned: scannedFiles, currentPath: "", category: nil))
        return RuleScanReport(outcomes: outcomes, scannedFileCount: scannedFiles,
                              duration: Date().timeIntervalSince(started), finishedAt: Date())
    }

    // MARK: - 私有

    private func singleFileOutcome(rule: CleanupRule, url: URL, safety: PathSafety,
                                   protected: [String]) throws -> RuleScanOutcome {
        guard safety.verdict(for: url).isAllowed else {
            return RuleScanOutcome(ruleID: rule.id, skippedReason: "未通过 PathSafety 校验")
        }
        let values = try url.resourceValues(forKeys: FileSizeReader.resourceKeys)
        let size = FileSizeReader.allocatedSize(values)
        if rule.minSizeBytes > 0, size < rule.minSizeBytes {
            return RuleScanOutcome(ruleID: rule.id, skippedReason: "未达到最小体积")
        }
        if rule.minAgeSeconds > 0,
           let modified = values.contentModificationDate,
           Date().timeIntervalSince(modified) < rule.minAgeSeconds {
            return RuleScanOutcome(ruleID: rule.id, skippedReason: "未达到最小年龄")
        }
        let item = ScanItem(url: url, byteSize: size, isDirectory: false, modifiedAt: values.contentModificationDate)
        return RuleScanOutcome(ruleID: rule.id, bytes: size, items: [item])
    }

    private func scanTopLevel(rule: CleanupRule, root: URL, safety: PathSafety,
                              protected: [String], nestedRoots: [String],
                              cancellation: ScanCancellation,
                              scannedFiles: inout Int) throws -> RuleScanOutcome {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: FileSizeReader.resourceKeyArray,
                options: options
            )
        } catch {
            return RuleScanOutcome(ruleID: rule.id, skippedReason: "权限不足或不可读")
        }

        var items: [ScanItem] = []
        var total: Int64 = 0
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            try cancellation.check()
            let childPath = child.standardizedFileURL.path
            if isNestedRoot(childPath, roots: nestedRoots) { continue }
            guard safety.verdict(for: child).isAllowed else { continue }
            if isProtected(childPath, protected: protected) { continue }
            guard let values = try? child.resourceValues(forKeys: FileSizeReader.resourceKeys) else { continue }
            if values.isSymbolicLink == true { continue }

            let isDir = values.isDirectory == true
            let size: Int64 = isDir
                ? FileSizeReader.treeSize(at: child, includeHidden: includeHidden, cancellation: cancellation)
                : FileSizeReader.allocatedSize(values)
            try cancellation.check()
            if rule.minSizeBytes > 0, size < rule.minSizeBytes { continue }
            if rule.minAgeSeconds > 0, let modified = values.contentModificationDate,
               Date().timeIntervalSince(modified) < rule.minAgeSeconds { continue }
            if size <= 0 { continue }

            let item = ScanItem(url: child, byteSize: size, isDirectory: isDir,
                                children: [], modifiedAt: values.contentModificationDate)
            items.append(item)
            total += size
            scannedFiles += isDir ? 1 : 1
            if items.count >= maxItemsPerRule { break }
        }
        items.sort { $0.byteSize > $1.byteSize }
        let reason: String? = items.isEmpty ? "没有符合条件的条目" : nil
        return RuleScanOutcome(ruleID: rule.id, bytes: total, items: items, skippedReason: reason)
    }

    private func scanRecursive(rule: CleanupRule, root: URL, safety: PathSafety,
                               protected: [String], cancellation: ScanCancellation,
                               scannedFiles: inout Int) throws -> RuleScanOutcome {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants, .skipsHiddenFiles]
        if includeHidden { options.remove(.skipsHiddenFiles) }
        var permissionDenied = false
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: FileSizeReader.resourceKeyArray,
            options: options,
            errorHandler: { _, _ in
                permissionDenied = true
                return true
            }
        ) else {
            return RuleScanOutcome(ruleID: rule.id, skippedReason: "权限不足或不可读")
        }

        var items: [ScanItem] = []
        var total: Int64 = 0
        let now = Date()
        for case let fileURL as URL in enumerator {
            try cancellation.check()
            guard let values = try? fileURL.resourceValues(forKeys: FileSizeReader.resourceKeys) else { continue }
            if values.isSymbolicLink == true || values.isDirectory == true { continue }
            scannedFiles += 1
            let size = FileSizeReader.allocatedSize(values)
            if rule.minSizeBytes > 0, size < rule.minSizeBytes { continue }
            if rule.minAgeSeconds > 0, let modified = values.contentModificationDate,
               now.timeIntervalSince(modified) < rule.minAgeSeconds { continue }
            let path = fileURL.standardizedFileURL.path
            guard safety.verdict(for: fileURL).isAllowed else { continue }
            if isProtected(path, protected: protected) { continue }
            items.append(ScanItem(url: fileURL, byteSize: size, isDirectory: false,
                                  modifiedAt: values.contentModificationDate))
            total += size
            if items.count >= maxItemsPerRule { break }
        }
        items.sort { $0.byteSize > $1.byteSize }
        var reason: String?
        if items.isEmpty {
            reason = permissionDenied ? "部分目录权限不足，未找到符合条件的文件" : "没有符合条件的文件"
        } else if permissionDenied {
            reason = "部分目录权限不足，结果可能不完整"
        }
        return RuleScanOutcome(ruleID: rule.id, bytes: total, items: items, skippedReason: reason)
    }

    private func isNestedRoot(_ path: String, roots: [String]) -> Bool {
        roots.contains { root in
            root != path && PathSafety.isWithin(root, prefix: path)
        }
    }

    private func isProtected(_ path: String, protected: [String]) -> Bool {
        protected.contains { entry in PathSafety.isWithin(path, prefix: entry) }
    }
}
