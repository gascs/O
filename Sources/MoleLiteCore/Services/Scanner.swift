import Foundation

/// 扫描目标：一个分类可能对应多个根目录。
public struct ScanTarget: Sendable, Hashable {
    public let category: ScanCategory
    public let root: URL
    public let label: String

    public init(category: ScanCategory, root: URL, label: String? = nil) {
        self.category = category
        self.root = root
        self.label = label ?? root.lastPathComponent
    }
}

/// 扫描器：异步执行、可取消、按分类聚合并给出两级明细。
public struct Scanner: Sendable {
    public let homeDirectory: URL
    public let settings: ScanSettings

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                settings: ScanSettings = .defaults) {
        self.homeDirectory = homeDirectory
        self.settings = settings
    }

    public func targets(for categories: [ScanCategory]) -> [ScanTarget] {
        var result: [ScanTarget] = []
        for category in categories {
            switch category {
            case .userCaches:
                result.append(ScanTarget(category: .userCaches, root: homeDirectory.appendingPathComponent("Library/Caches"), label: "用户缓存"))
            case .logs:
                result.append(ScanTarget(category: .logs, root: homeDirectory.appendingPathComponent("Library/Logs"), label: "日志"))
            case .xcode:
                let developer = homeDirectory.appendingPathComponent("Library/Developer")
                result.append(ScanTarget(category: .xcode, root: developer.appendingPathComponent("Xcode/DerivedData"), label: "派生数据"))
                result.append(ScanTarget(category: .xcode, root: developer.appendingPathComponent("CoreSimulator/Devices"), label: "模拟器"))
                result.append(ScanTarget(category: .xcode, root: developer.appendingPathComponent("Xcode/iOS DeviceSupport"), label: "iOS 设备支持"))
                result.append(ScanTarget(category: .xcode, root: developer.appendingPathComponent("Xcode/watchOS DeviceSupport"), label: "watchOS 设备支持"))
            case .trash:
                result.append(ScanTarget(category: .trash, root: homeDirectory.appendingPathComponent(".Trash"), label: "废纸篓"))
            case .largeFiles:
                result.append(ScanTarget(category: .largeFiles, root: homeDirectory.appendingPathComponent("Downloads"), label: "下载"))
                result.append(ScanTarget(category: .largeFiles, root: homeDirectory.appendingPathComponent("Documents"), label: "文档"))
            case .appLeftovers:
                let library = homeDirectory.appendingPathComponent("Library")
                result.append(ScanTarget(category: .appLeftovers, root: library.appendingPathComponent("Application Support"), label: "应用支持"))
                result.append(ScanTarget(category: .appLeftovers, root: library.appendingPathComponent("Containers"), label: "容器"))
                result.append(ScanTarget(category: .appLeftovers, root: library.appendingPathComponent("Group Containers"), label: "分组容器"))
                result.append(ScanTarget(category: .appLeftovers, root: library.appendingPathComponent("Saved Application State"), label: "窗口状态"))
                result.append(ScanTarget(category: .appLeftovers, root: library.appendingPathComponent("HTTPStorages"), label: "HTTP 存储"))
            case .diagnostics:
                let library = homeDirectory.appendingPathComponent("Library")
                result.append(ScanTarget(category: .diagnostics, root: library.appendingPathComponent("Logs/DiagnosticReports"), label: "诊断报告"))
                result.append(ScanTarget(category: .diagnostics, root: library.appendingPathComponent("Application Support/CrashReporter"), label: "崩溃报告"))
            case .developer:
                result.append(ScanTarget(category: .developer,
                                         root: homeDirectory.appendingPathComponent("Library/Developer/Xcode/Archives"),
                                         label: "Xcode 归档"))
            case .packageCaches:
                let root = homeDirectory
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent(".npm/_cacache"), label: "npm"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent("Library/Caches/Yarn"), label: "Yarn"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent("Library/pnpm/store"), label: "pnpm"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent("Library/Caches/pip"), label: "pip"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent("Library/Caches/Homebrew"), label: "Homebrew"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent("Library/Caches/go-build"), label: "Go"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent(".cargo/registry/cache"), label: "Rust"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent(".gradle/caches"), label: "Gradle"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent(".m2/repository"), label: "Maven"))
                result.append(ScanTarget(category: .packageCaches, root: root.appendingPathComponent("Library/Caches/CocoaPods"), label: "CocoaPods"))
            case .docker:
                result.append(ScanTarget(category: .docker, root: homeDirectory.appendingPathComponent("Library/Containers/com.docker.docker"), label: "Docker"))
            case .backups:
                result.append(ScanTarget(category: .backups, root: homeDirectory.appendingPathComponent("Library/Application Support/MobileSync/Backup"), label: "iOS 备份"))
            case .mailAttachments:
                result.append(ScanTarget(category: .mailAttachments,
                                         root: homeDirectory.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                                         label: "邮件附件"))
            case .userFiles:
                for name in ["Downloads", "Desktop", "Documents", "Movies"] {
                    result.append(ScanTarget(category: .userFiles, root: homeDirectory.appendingPathComponent(name), label: name))
                }
            case .systemCaches:
                result.append(ScanTarget(category: .systemCaches, root: homeDirectory.appendingPathComponent("Library/Logs/com.apple.xpc.launchd"), label: "系统日志"))
                result.append(ScanTarget(category: .systemCaches, root: homeDirectory.appendingPathComponent("Library/Caches/com.apple.LaunchServices"), label: "系统缓存"))
            }
        }
        return result
    }

    /// 单个目标最多展示的条目数；超过即截断并同步重算合计。
    static let maximumItemsPerTarget = 300

    /// 计算「被更具体根目录覆盖」的排除表。
    ///
    /// 同一批目标里，如果某个 root 严格位于另一个 root 之下（例如
    /// `~/Library/Caches/Homebrew` 之于 `~/Library/Caches`），扫描上层 root 时必须跳过它，
    /// 否则 userCaches 与 packageCaches / systemCaches 会重复统计同一批文件。
    static func excludedRoots(for targets: [ScanTarget]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for target in targets {
            let rootPath = target.root.standardizedFileURL.path
            let nested = targets.compactMap { other -> String? in
                let otherPath = other.root.standardizedFileURL.path
                guard otherPath != rootPath,
                      PathSafety.isWithinCaseInsensitive(otherPath, prefix: rootPath) else { return nil }
                return otherPath
            }
            if !nested.isEmpty { result[rootPath] = nested }
        }
        return result
    }

    /// 执行扫描。重 IO 在 detached 任务中完成，不阻塞主线程。
    /// - Parameter progress: 后台线程回调，调用方自行切回主线程并节流。
    public func scan(categories: [ScanCategory] = ScanCategory.allCases,
                     cancellation: ScanCancellation = ScanCancellation(),
                     progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanReport {
        let targets = self.targets(for: categories)
        let excludedRoots = Self.excludedRoots(for: targets)
        let start = Date()
        let settings = self.settings

        return try await Task.detached(priority: .userInitiated) { [targets, excludedRoots] in
            let context = ScanContext(cancellation: cancellation, progress: progress)
            context.totalTargets = targets.count

            var merged: [ScanCategory: ScanCategoryResult] = [:]
            var completed = 0

            for target in targets {
                try cancellation.check()
                context.category = target.category
                context.currentPath = target.root.path
                try context.emit(force: true)

                let result: ScanCategoryResult
                do {
                    result = try self.scanTarget(target, settings: settings, context: context,
                                                 excludedRoots: excludedRoots[target.root.standardizedFileURL.path] ?? [])
                } catch let error as ScanError {
                    throw error
                } catch {
                    result = ScanCategoryResult(
                        category: target.category,
                        message: Self.friendlyMessage(for: error, path: target.root.path)
                    )
                }

                if var existing = merged[target.category] {
                    // 同分类多 root 合并时按路径去重，尽量不重复统计。
                    var seen = Set(existing.items.map { $0.url.path.lowercased() })
                    for item in result.items {
                        if seen.insert(item.url.path.lowercased()).inserted {
                            existing.items.append(item)
                        }
                    }
                    if target.category == .largeFiles {
                        // 大文件分类的 totalBytes 保留「全部命中文件之和」，items 只展示前 N 项。
                        existing.totalBytes += result.totalBytes
                    } else {
                        existing.totalBytes = existing.items.reduce(0) { $0 + $1.byteSize }
                    }
                    if existing.message == nil { existing.message = result.message }
                    existing.items.sort { $0.byteSize > $1.byteSize }
                    merged[target.category] = existing
                } else {
                    merged[target.category] = result
                }

                completed += 1
                context.completedTargets = completed
                try context.emit(force: true)
            }

            let ordered = categories.compactMap { merged[$0] }
            return ScanReport(
                results: ordered,
                scannedItemCount: context.itemsScanned,
                duration: Date().timeIntervalSince(start)
            )
        }.value
    }

    // MARK: - 单个目标

    private func scanTarget(_ target: ScanTarget, settings: ScanSettings, context: ScanContext,
                            excludedRoots: [String] = []) throws -> ScanCategoryResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.root.path, isDirectory: &isDirectory) else {
            // 受系统保护的位置在未授权时也会表现为「不存在」，给出可操作的说明而不是干巴巴的路径错误。
            if target.category == .trash {
                return ScanCategoryResult(
                    category: target.category,
                    message: "废纸篓：读不到内容。可能尚未授予「完全磁盘访问」，请在系统设置中授权后重新扫描。"
                )
            }
            return ScanCategoryResult(category: target.category, message: "\(target.label)：路径不存在")
        }
        guard isDirectory.boolValue else {
            return ScanCategoryResult(category: target.category, message: "\(target.label)：不是目录")
        }

        if target.category == .largeFiles {
            return try scanLargeFiles(in: target, settings: settings, context: context)
        }

        let children = try contentsOfDirectory(target.root, includeHidden: settings.includeHiddenItems)
        var items: [ScanItem] = []
        var total: Int64 = 0

        for child in children {
            try context.tick(path: child.path)
            // 跳过被更具体 root 覆盖的子目录，避免与 packageCaches / systemCaches 重复统计。
            let childPath = child.standardizedFileURL.path
            if excludedRoots.contains(where: { PathSafety.isWithinCaseInsensitive(childPath, prefix: $0) }) {
                continue
            }
            let values = try? child.resourceValues(forKeys: FileSizeReader.resourceKeys)
            if values?.isSymbolicLink == true { continue }
            let isDir = values?.isDirectory ?? false
            if isDir {
                let item = try describe(directory: child, includeHidden: settings.includeHiddenItems, context: context)
                items.append(item)
                total += item.byteSize
            } else {
                let size = FileSizeReader.allocatedSize(of: child)
                items.append(ScanItem(url: child, byteSize: size, isDirectory: false,
                                      modifiedAt: values?.contentModificationDate))
                total += size
            }
        }

        items.sort { $0.byteSize > $1.byteSize }
        // 统一阈值：超过上限时截断，并同步重算 totalBytes，保证界面上的合计与实际条目一致。
        guard items.count > Self.maximumItemsPerTarget else {
            return ScanCategoryResult(category: target.category, items: items, totalBytes: total)
        }
        items = Array(items.prefix(Self.maximumItemsPerTarget))
        total = items.reduce(0) { $0 + $1.byteSize }
        return ScanCategoryResult(category: target.category, items: items, totalBytes: total,
                                  message: "结果已截断，仅展示前 \(Self.maximumItemsPerTarget) 项")
    }

    /// 第一层目录：统计总量，并把第二层子项聚合为可展开的明细。
    private func describe(directory: URL, includeHidden: Bool, context: ScanContext) throws -> ScanItem {
        var total: Int64 = 0
        var subSizes: [String: Int64] = [:]
        var subIsDirectory: [String: Bool] = [:]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: FileSizeReader.resourceKeyArray,
            options: options,
            errorHandler: { _, _ in true }
        ) else {
            return ScanItem(url: directory, byteSize: 0, isDirectory: true)
        }

        let basePath = directory.path
        for case let fileURL as URL in enumerator {
            try context.tick(path: fileURL.path)
            guard let values = try? fileURL.resourceValues(forKeys: FileSizeReader.resourceKeys) else { continue }
            if values.isDirectory == true || values.isSymbolicLink == true { continue }
            let size = FileSizeReader.allocatedSize(values)
            total += size
            let relative = fileURL.path.hasPrefix(basePath) ? String(fileURL.path.dropFirst(basePath.count)) : ""
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first else { continue }
            let key = String(first)
            subSizes[key, default: 0] += size
            // 只有一层表示是直接文件，否则是第一层子目录
            subIsDirectory[key] = components.count > 1
        }

        let sorted = subSizes.sorted { $0.value > $1.value }.prefix(60)
        let children = sorted.map { key, size in
            ScanItem(
                url: directory.appendingPathComponent(key),
                name: key,
                byteSize: size,
                isDirectory: subIsDirectory[key] ?? false
            )
        }
        return ScanItem(url: directory, byteSize: total, isDirectory: true, children: Array(children))
    }

    private func scanLargeFiles(in target: ScanTarget, settings: ScanSettings, context: ScanContext) throws -> ScanCategoryResult {
        let threshold = settings.largeFileThresholdBytes
        let collected = try collectLargeFiles(root: target.root, threshold: threshold,
                                              includeHidden: settings.includeHiddenItems,
                                              limit: 300, context: context)
        return ScanCategoryResult(
            category: .largeFiles,
            items: collected.items,
            totalBytes: collected.total,
            message: collected.total == 0 ? "没有超过 \(settings.largeFileThresholdMB) MB 的文件" : collected.message
        )
    }

    /// 扫描任意目录中的大文件（供「大文件浏览器」使用）。重 IO 在 detached 任务中执行。
    public func largeFiles(in roots: [URL], thresholdBytes: Int64, includeHidden: Bool = false,
                           limit: Int = 500,
                           cancellation: ScanCancellation = ScanCancellation(),
                           progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanCategoryResult {
        let threshold = max(1, thresholdBytes)
        let limit = max(1, limit)
        return try await Task.detached(priority: .userInitiated) { [roots] in
            let context = ScanContext(cancellation: cancellation, progress: progress)
            context.totalTargets = roots.count
            var items: [ScanItem] = []
            var total: Int64 = 0
            var message: String?
            var completed = 0

            for root in roots {
                try cancellation.check()
                context.currentPath = root.path
                try context.emit(force: true)
                let collected = try self.collectLargeFiles(root: root, threshold: threshold,
                                                           includeHidden: includeHidden,
                                                           limit: limit, context: context)
                items.append(contentsOf: collected.items)
                total += collected.total
                if let note = collected.message { message = note }
                completed += 1
                context.completedTargets = completed
                try context.emit(force: true)
            }

            items.sort { $0.byteSize > $1.byteSize }
            return ScanCategoryResult(category: .largeFiles, items: Array(items.prefix(limit)),
                                      totalBytes: total, message: message)
        }.value
    }

    /// 共享实现：枚举目录，收集超过阈值的单个文件。
    private func collectLargeFiles(root: URL, threshold: Int64, includeHidden: Bool, limit: Int,
                                   context: ScanContext) throws -> (items: [ScanItem], total: Int64, message: String?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ([], 0, "\(root.lastPathComponent)：路径不存在或不是目录")
        }

        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: FileSizeReader.resourceKeyArray,
            options: options,
            errorHandler: { _, _ in true }
        ) else {
            return ([], 0, "\(root.lastPathComponent)：无法访问（可能缺少文件夹权限）")
        }

        var files: [ScanItem] = []
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            try context.tick(path: fileURL.path)
            guard let values = try? fileURL.resourceValues(forKeys: FileSizeReader.resourceKeys) else { continue }
            if values.isDirectory == true || values.isSymbolicLink == true { continue }
            let size = FileSizeReader.allocatedSize(values)
            guard size >= threshold else { continue }
            files.append(ScanItem(url: fileURL, byteSize: size, isDirectory: false,
                                  modifiedAt: values.contentModificationDate))
            total += size
        }

        files.sort { $0.byteSize > $1.byteSize }
        let message: String? = files.count > limit ? "结果较多，仅展示前 \(limit) 项" : nil
        return (Array(files.prefix(limit)), total, message)
    }

    private func contentsOfDirectory(_ url: URL, includeHidden: Bool) throws -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: options)
    }

    private static func friendlyMessage(for error: Error, path: String) -> String {
        let nsError = error as NSError
        let isPermission: Bool
        if let cocoa = error as? CocoaError {
            isPermission = cocoa.code == .fileReadNoPermission || cocoa.code == .fileWriteNoPermission
        } else {
            // POSIX: EPERM(1) / EACCES(13)
            isPermission = nsError.domain == NSPOSIXErrorDomain && (nsError.code == 1 || nsError.code == 13)
        }
        if isPermission {
            return "\(path)：权限不足，请在「系统设置 › 隐私与安全性 › 完全磁盘访问」中授权后重试"
        }
        return "\(path)：\(error.localizedDescription)"
    }
}

/// 进度与计数上下文（只在扫描的后台任务内部使用）。
private final class ScanContext: @unchecked Sendable {
    let cancellation: ScanCancellation
    let progress: @Sendable (ScanProgress) -> Void

    var totalTargets = 0
    var completedTargets = 0
    var itemsScanned = 0
    var currentPath = ""
    var category: ScanCategory?
    private var lastEmit = Date.distantPast

    init(cancellation: ScanCancellation, progress: @escaping @Sendable (ScanProgress) -> Void) {
        self.cancellation = cancellation
        self.progress = progress
    }

    func tick(path: String) throws {
        itemsScanned += 1
        currentPath = path
        if itemsScanned % 128 == 0 {
            try cancellation.check()
            try emit()
        }
    }

    func emit(force: Bool = false) throws {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) > 0.15 else { return }
        lastEmit = now
        progress(ScanProgress(
            completedTargets: completedTargets,
            totalTargets: totalTargets,
            itemsScanned: itemsScanned,
            currentPath: currentPath,
            category: category
        ))
    }
}
