import Foundation
import MoleLiteCore

/// 重复文件查找：默认每组保留一份，其余勾选待清理。
@MainActor
final class DuplicateViewModel: ObservableObject {
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var message: String?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published var minSizeMB: Int
    @Published var searchText = ""
    @Published var showingConfirm = false
    @Published var showingResult = false
    @Published private(set) var resultMessage = ""

    private var scanTask: Task<Void, Never>?
    private var cancellation: ScanCancellation?
    /// 扫描代次：每次开始 / 取消都自增。旧任务迟到的 progress / 结果 / 错误
    /// 发现代次不匹配就直接丢弃，不会把新一轮扫描的状态改回「已取消」或旧结果。
    private var scanGeneration = 0

    /// 已扫描文件数的合并刷新：扫描时回调非常密集，150ms 刷新一次足够。
    private var countCoalescer = ProgressCoalescer<Int>()
    private var countFlushTask: Task<Void, Never>?

    private let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        minSizeMB = ScanSettings.duplicateMinSizeMB()
    }

    /// 查找目录来自设置（可增删）；为空时回退到下载 / 文档 / 桌面。
    var roots: [URL] {
        let paths = ScanSettings.duplicateRootPaths()
        if !paths.isEmpty { return paths.map { URL(fileURLWithPath: $0) } }
        return ["Downloads", "Documents", "Desktop"].map { home.appendingPathComponent($0) }
    }

    var groupLimit: Int { ScanSettings.duplicateGroupLimit() }

    var rootsDescription: String {
        roots.map { $0.path.replacingOccurrences(of: home.path, with: "~") }.joined(separator: " · ")
    }

    var selectedFiles: [DuplicateFile] {
        groups.flatMap { $0.files.filter { selectedIDs.contains($0.id) } }
    }

    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.byteSize } }
    var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    var candidateCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    /// 搜索过滤：只保留包含匹配文件的组，组内仍显示完整副本，便于判断保留哪一份。
    var filteredGroups: [DuplicateGroup] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return groups }
        return groups.filter { group in
            group.files.contains {
                $0.name.localizedCaseInsensitiveContains(keyword) ||
                $0.url.path.localizedCaseInsensitiveContains(keyword)
            }
        }
    }

    func startScan() {
        cancel()
        let roots = self.roots
        let minSize = Int64(max(1, minSizeMB)) * 1024 * 1024
        let limit = groupLimit
        let cancellation = ScanCancellation()
        self.cancellation = cancellation
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        message = nil
        scannedFiles = 0
        countCoalescer.reset()
        groups = []
        selectedIDs = []

        scanTask = Task { [weak self] in
            let owner = self
            do {
                let found = try await DuplicateFinder(roots: roots, minFileSize: minSize, maxGroups: limit).find(
                    cancellation: cancellation,
                    progress: { count in
                        Task { @MainActor in
                            guard let owner, owner.scanGeneration == generation else { return }
                            owner.receiveScannedCount(count)
                        }
                    }
                )
                guard let model = owner, !Task.isCancelled, model.scanGeneration == generation else { return }
                model.apply(found)
            } catch let error as ScanError {
                // 旧任务（用户已取消 / 已重新开始扫描）的 catch 直接 return：
                // 否则会在这里把新任务的 isScanning 改成 false、message 改成「已取消」。
                guard let model = owner, !Task.isCancelled, model.scanGeneration == generation else { return }
                model.finish(with: error.errorDescription)
            } catch {
                guard let model = owner, !Task.isCancelled, model.scanGeneration == generation else { return }
                model.finish(with: "查找失败：\(error.localizedDescription)")
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
        countFlushTask?.cancel()
        countFlushTask = nil
        countCoalescer.reset()
        isScanning = false
    }

    /// 合并「已扫描文件数」回调：150ms 刷新一次，避免扫描时主线程被高频数字刷新占满。
    private func receiveScannedCount(_ count: Int) {
        guard countCoalescer.submit(count) else { return }
        countFlushTask = Task { [weak self] in
            let interval = ProgressCoalescer<Int>.recommendedInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if let latest = self.countCoalescer.flush() {
                self.scannedFiles = latest
            }
            self.countFlushTask = nil
        }
    }

    private func apply(_ found: [DuplicateGroup]) {
        // 有界 Top-N 收集：按「可回收字节」降序只保留前 groupLimit 组，
        // 单遍插入 O(n·log k)、内存固定 O(k)，收尾才排序一次。
        // 上游 DuplicateFinder 已按 maxGroups 截断，这里再兜一层，保证列表永远有界。
        var collector = BoundedTopN<DuplicateGroup>(limit: max(1, groupLimit)) { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            // 次级键：组 id 升序，保证相等时顺序稳定（严格弱序）。
            return lhs.id < rhs.id
        }
        for group in found { collector.insert(group) }
        let limited = collector.ranked()
        groups = limited
        isScanning = false
        countFlushTask?.cancel()
        countFlushTask = nil
        countCoalescer.reset()
        // 默认保留每组第一个（按修改时间最新），其余勾选。
        var selection: Set<String> = []
        for group in limited {
            for file in group.files.dropFirst() {
                selection.insert(file.id)
            }
        }
        selectedIDs = selection
        if limited.isEmpty {
            message = "没有发现体积 ≥ \(minSizeMB) MB 的重复文件"
        }
    }

    private func finish(with message: String?) {
        isScanning = false
        if let message { self.message = message }
    }

    func toggle(_ file: DuplicateFile) {
        if selectedIDs.contains(file.id) {
            selectedIDs.remove(file.id)
        } else {
            selectedIDs.insert(file.id)
        }
    }

    func toggleGroup(_ group: DuplicateGroup) {
        let extras = Set(group.files.dropFirst().map(\.id))
        if extras.subtracting(selectedIDs).isEmpty {
            selectedIDs.subtract(extras)
        } else {
            selectedIDs.formUnion(extras)
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func trashSelected() async {
        let targets = selectedFiles
        guard !targets.isEmpty, !isCleaning else { return }
        let generation = scanGeneration
        isCleaning = true
        let entries = targets.map { (url: $0.url, size: $0.byteSize) }
        let service = TrashService()
        let report = await Task.detached(priority: .userInitiated) { service.trash(entries: entries) }.value
        isCleaning = false

        // 清理期间可能已经开始新一轮查找：旧结果不要作用在新列表上。
        guard scanGeneration == generation else { return }

        let succeeded = Set(report.outcomes.filter(\.success).map { $0.url.path })
        selectedIDs.subtract(succeeded)
        groups = groups.compactMap { group in
            let remaining = group.files.filter { !succeeded.contains($0.url.path) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(id: group.id, files: remaining, fileSize: group.fileSize)
        }

        if report.bytesFreed > 0 {
            HistoryStore().append(HistoryEntry(
                kind: .clean, bytes: report.bytesFreed,
                itemCount: report.successCount, detail: "重复文件"
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
