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

struct RootOption: Identifiable {
    let id: String
    let title: String
    let url: URL
}

/// 大文件浏览器：可切换目录、排序、批量移入废纸篓。
@MainActor
final class LargeFilesViewModel: ObservableObject {
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

    /// 工具栏搜索过滤（名称或完整路径）。
    var filteredItems: [ScanItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) ||
            $0.url.path.localizedCaseInsensitiveContains(keyword)
        }
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
        isScanning = true
        message = nil
        items = []
        selectedIDs = []
        progress = ScanProgress(totalTargets: 1, itemsScanned: 0, currentPath: rootPath, category: .largeFiles)

        let roots = [rootURL]
        let threshold = Int64(max(1, thresholdMB)) * 1024 * 1024

        scanTask = Task { [weak self] in
            let owner = self
            do {
                let result = try await scanner.largeFiles(
                    in: roots,
                    thresholdBytes: threshold,
                    includeHidden: settings.includeHiddenItems,
                    limit: 500,
                    cancellation: cancellation,
                    progress: { snapshot in
                        Task { @MainActor in owner?.progress = snapshot }
                    }
                )
                guard let model = owner, !Task.isCancelled else { return }
                model.apply(result)
            } catch let error as ScanError {
                owner?.finish(with: error.errorDescription)
            } catch {
                owner?.finish(with: "扫描失败：\(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func apply(_ result: ScanCategoryResult) {
        items = result.items
        totalBytes = result.totalBytes
        message = result.message
        isScanning = false
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
        isCleaning = true
        let service = TrashService()
        let report = await Task.detached(priority: .userInitiated) { service.trash(items: targets) }.value
        isCleaning = false

        let succeeded = Set(report.outcomes.filter(\.success).map { $0.url.path })
        items.removeAll { succeeded.contains($0.url.path) }
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
