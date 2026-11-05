import Foundation
import MoleLiteCore

enum LargeFileSort: String, CaseIterable, Identifiable {
    case size
    case date
    case name
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: return "按大小"
        case .date: return "按修改时间"
        case .name: return "按名称"
        case .type: return "按类型"
        }
    }
}

/// 大文件表格的列排序键。放在 ViewModel 里，是为了让排序在 View 之外做并缓存。
enum LargeFileColumnSort: String, CaseIterable, Identifiable {
    case name
    case location
    case type
    case modified
    case size

    var id: String { rawValue }
}

struct RootOption: Identifiable {
    let id: String
    let title: String
    let url: URL
}

/// 大文件浏览器：可切换目录、排序、批量移入废纸篓。
@MainActor
final class LargeFilesViewModel: ObservableObject {
    /// 表格最多展示的条数（Scanner 也按同一上限截断，N 与 UI 展示数量保持一致）。
    static let displayLimit = 500

    @Published private(set) var items: [ScanItem] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var message: String?
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var selectedIDs: Set<String> = []
    @Published var sort: LargeFileSort = .size
    @Published var thresholdMB: Int
    @Published var rootPath: String
    @Published var searchText = ""
    @Published var showingConfirm = false
    @Published var showingResult = false
    @Published private(set) var resultMessage = ""

    private var scanTask: Task<Void, Never>?
    private var cancellation: ScanCancellation?
    /// 扫描代次：每次开始 / 取消都自增。旧任务迟到的 progress / 结果 / 错误
    /// 发现代次不匹配就直接丢弃，不会把新一轮扫描的状态改回「已取消」或旧结果。
    private var scanGeneration = 0

    /// 进度合并：扫描回调可能每秒上百次，150ms 才刷新一次 UI，主线程 body 重算从
    /// 「每次回调一次」降到「每秒最多 7 次」。
    private var progressCoalescer = ProgressCoalescer<ScanProgress>()
    private var progressFlushTask: Task<Void, Never>?

    /// 列排序缓存：SwiftUI 每次重算 body 都会重新求值，只有排序键 / 数据版本变了才真正排序。
    private struct SortCacheKey: Equatable {
        let column: LargeFileColumnSort
        let descending: Bool
        let keyword: String
        let version: Int
    }
    private var sortCacheKey: SortCacheKey?
    private var sortCacheResult: [ScanItem] = []
    private var itemsVersion = 0

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private static let rootKey = "largefile.lastRoot"

    init() {
        let settings = ScanSettings.load()
        thresholdMB = settings.largeFileThresholdMB
        rootPath = UserDefaults.standard.string(forKey: Self.rootKey)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    }

    var rootURL: URL { URL(fileURLWithPath: rootPath) }

    var availableRoots: [RootOption] {
        [
            RootOption(id: "downloads", title: "下载", url: home.appendingPathComponent("Downloads")),
            RootOption(id: "documents", title: "文档", url: home.appendingPathComponent("Documents")),
            RootOption(id: "desktop", title: "桌面", url: home.appendingPathComponent("Desktop")),
            RootOption(id: "movies", title: "影片", url: home.appendingPathComponent("Movies")),
            RootOption(id: "music", title: "音乐", url: home.appendingPathComponent("Music")),
            RootOption(id: "pictures", title: "图片", url: home.appendingPathComponent("Pictures")),
            RootOption(id: "home", title: "个人目录", url: home)
        ]
    }

    var sortedItems: [ScanItem] {
        switch sort {
        case .size:
            return items.sorted { $0.byteSize > $1.byteSize }
        case .date:
            return items.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .name:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .type:
            return items.sorted {
                if $0.fileExtension != $1.fileExtension {
                    return $0.fileExtension < $1.fileExtension
                }
                return $0.byteSize > $1.byteSize
            }
        }
    }

    var selectedItems: [ScanItem] { items.filter { selectedIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.byteSize } }

    /// 工具栏搜索过滤（名称或完整路径）。供其它调用方使用；表格走 `columnSortedItems`。
    var filteredItems: [ScanItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) ||
            $0.url.path.localizedCaseInsensitiveContains(keyword)
        }
    }

    // MARK: - 表格排序（带缓存）

    /// 列排序 + 搜索过滤，结果按「列 + 方向 + 关键词 + 数据版本」缓存。
    ///
    /// 旧实现写在 View 的 body 里：SwiftUI 每次重算 body（悬停、勾选、进度刷新、
    /// 窗口缩放）都会对最多 500 条重新全量排序；比较器还写成
    /// `descending ? !result : result`，相等元素返回 true 违反严格弱序
    ///（排序结果不稳定，极端情况下可能触达排序实现的下标断言）。
    /// 现在只有排序键或数据真正变化时才排序一次，其余 body 重算直接命中缓存。
    func columnSortedItems(for column: LargeFileColumnSort, descending: Bool) -> [ScanItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SortCacheKey(column: column, descending: descending, keyword: keyword, version: itemsVersion)
        if key == sortCacheKey { return sortCacheResult }

        let filtered: [ScanItem]
        if keyword.isEmpty {
            filtered = items
        } else {
            filtered = items.filter {
                $0.name.localizedCaseInsensitiveContains(keyword) ||
                $0.url.path.localizedCaseInsensitiveContains(keyword)
            }
        }
        let sorted = filtered.sorted { lhs, rhs in
            isOrdered(lhs, before: rhs, column: column, descending: descending)
        }
        sortCacheKey = key
        sortCacheResult = sorted
        return sorted
    }

    /// 严格弱序比较器：先按列比较，键相等时统一按路径升序（次级排序键，方向无关）。
    /// 「相等返回 false」保证排序算法看到的是合法顺序关系，结果稳定可复现。
    private func isOrdered(_ lhs: ScanItem, before rhs: ScanItem, column: LargeFileColumnSort,
                           descending: Bool) -> Bool {
        let order: ComparisonResult
        switch column {
        case .name:
            order = lhs.name.localizedStandardCompare(rhs.name)
        case .location:
            let left = lhs.url.deletingLastPathComponent().path
            let right = rhs.url.deletingLastPathComponent().path
            order = left.localizedStandardCompare(right)
        case .type:
            order = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
        case .modified:
            order = (lhs.modifiedAt ?? .distantPast).compare(rhs.modifiedAt ?? .distantPast)
        case .size:
            if lhs.byteSize == rhs.byteSize {
                order = .orderedSame
            } else {
                order = lhs.byteSize < rhs.byteSize ? .orderedAscending : .orderedDescending
            }
        }
        if order != .orderedSame {
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        return lhs.url.path < rhs.url.path
    }

    private func invalidateSortCache() {
        itemsVersion &+= 1
    }

    /// 原生 Table 的多选绑定入口。
    func setSelection(_ ids: Set<String>) {
        selectedIDs = ids
    }

    func changeRoot(_ url: URL) {
        rootPath = url.path
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        startScan()
    }

    func startScan() {
        cancel()
        let settings = ScanSettings.load()
        let scanner = Scanner(settings: settings)
        let cancellation = ScanCancellation()
        self.cancellation = cancellation
        scanGeneration &+= 1
        let generation = scanGeneration

        isScanning = true
        message = nil
        items = []
        invalidateSortCache()
        selectedIDs = []
        progress = ScanProgress(totalTargets: 1, itemsScanned: 0, currentPath: rootPath, category: .largeFiles)
        progressCoalescer.reset()

        let roots = [rootURL]
        let threshold = Int64(max(1, thresholdMB)) * 1024 * 1024

        scanTask = Task { [weak self] in
            let owner = self
            do {
                let result = try await scanner.largeFiles(
                    in: roots,
                    thresholdBytes: threshold,
                    includeHidden: settings.includeHiddenItems,
                    limit: Self.displayLimit,
                    cancellation: cancellation,
                    progress: { snapshot in
                        Task { @MainActor in
                            guard let owner, owner.scanGeneration == generation else { return }
                            owner.receiveProgress(snapshot)
                        }
                    }
                )
                guard let model = owner, !Task.isCancelled, model.scanGeneration == generation else { return }
                model.apply(result)
            } catch let error as ScanError {
                // 旧任务（用户已取消 / 已重新开始扫描）的 catch 直接 return：
                // 否则会在这里把新任务的 isScanning 改成 false、message 改成「已取消」。
                guard let model = owner, !Task.isCancelled, model.scanGeneration == generation else { return }
                model.finish(with: error.errorDescription)
            } catch {
                guard let model = owner, !Task.isCancelled, model.scanGeneration == generation else { return }
                model.finish(with: "扫描失败：\(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        // 代次自增让旧任务的迟到回调全部失效（见 startScan 里的代次校验）。
        scanGeneration &+= 1
        cancellation?.cancel()
        cancellation = nil
        scanTask?.cancel()
        scanTask = nil
        progressFlushTask?.cancel()
        progressFlushTask = nil
        progressCoalescer.reset()
        isScanning = false
    }

    /// 合并进度回调：只保留最新值，150ms 刷新一次界面。
    private func receiveProgress(_ snapshot: ScanProgress) {
        guard progressCoalescer.submit(snapshot) else { return }
        progressFlushTask = Task { [weak self] in
            let interval = ProgressCoalescer<ScanProgress>.recommendedInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if let latest = self.progressCoalescer.flush() {
                self.progress = latest
            }
            self.progressFlushTask = nil
        }
    }

    private func apply(_ result: ScanCategoryResult) {
        // 有界 Top-N 收集：只保留最大的 displayLimit 条（O(n·log k)，内存固定 O(k)），
        // 而不是先收全量再全量排序。上游 Scanner 目前已按同一上限截断，这里再兜一层，
        // 保证 ViewModel 的 items 永远有界，也保留上游给的总字节数（totalBytes）。
        var collector = BoundedTopN<ScanItem>(limit: Self.displayLimit) { $0.byteSize > $1.byteSize }
        for item in result.items { collector.insert(item) }
        items = collector.ranked()
        invalidateSortCache()
        totalBytes = result.totalBytes
        message = result.message
        isScanning = false
        progressFlushTask?.cancel()
        progressFlushTask = nil
        progressCoalescer.reset()
    }

    private func finish(with message: String?) {
        isScanning = false
        if let message { self.message = message }
    }

    func toggle(_ item: ScanItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func selectAll() {
        selectedIDs = Set(items.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func trashSelected() async {
        let targets = selectedItems
        guard !targets.isEmpty, !isCleaning else { return }
        let generation = scanGeneration
        isCleaning = true
        let service = TrashService()
        let report = await Task.detached(priority: .userInitiated) { service.trash(items: targets) }.value
        isCleaning = false

        // 清理期间可能已经开始新一轮扫描：旧结果不要作用在新列表上。
        guard scanGeneration == generation else { return }

        let succeeded = Set(report.outcomes.filter(\.success).map { $0.url.path })
        items.removeAll { succeeded.contains($0.url.path) }
        invalidateSortCache()
        selectedIDs.subtract(succeeded)
        totalBytes = items.reduce(0) { $0 + $1.byteSize }

        if report.bytesFreed > 0 {
            HistoryStore().append(HistoryEntry(
                kind: .clean, bytes: report.bytesFreed,
                itemCount: report.successCount, detail: "大文件"
            ))
        }

        var lines = [report.summary, "释放 \(ByteFormatter.string(report.bytesFreed))"]
        if !report.failures.isEmpty {
            lines.append(contentsOf: report.failures.prefix(3).map { "· \($0.url.lastPathComponent)：\($0.message ?? "未知错误")" })
        }
        resultMessage = lines.joined(separator: "\n")
        showingResult = true
    }
}
