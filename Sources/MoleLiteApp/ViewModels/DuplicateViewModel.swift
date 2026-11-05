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
        isScanning = true
        message = nil
        scannedFiles = 0
        groups = []
        selectedIDs = []

        scanTask = Task { [weak self] in
            let owner = self
            do {
                let found = try await DuplicateFinder(roots: roots, minFileSize: minSize, maxGroups: limit).find(
                    cancellation: cancellation,
                    progress: { count in
                        Task { @MainActor in owner?.scannedFiles = count }
                    }
                )
                guard let model = owner, !Task.isCancelled else { return }
                model.apply(found)
            } catch let error as ScanError {
                owner?.finish(with: error.errorDescription)
            } catch {
                owner?.finish(with: "查找失败：\(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func apply(_ found: [DuplicateGroup]) {
        groups = found
        isScanning = false
        // 默认保留每组第一个（按修改时间最新），其余勾选。
        var selection: Set<String> = []
        for group in found {
            for file in group.files.dropFirst() {
                selection.insert(file.id)
            }
        }
        selectedIDs = selection
        if found.isEmpty {
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
        isCleaning = true
        let entries = targets.map { (url: $0.url, size: $0.byteSize) }
        let service = TrashService()
        let report = await Task.detached(priority: .userInitiated) { service.trash(entries: entries) }.value
        isCleaning = false

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
