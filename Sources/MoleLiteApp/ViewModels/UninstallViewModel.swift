import Foundation
import MoleLiteCore

/// 应用卸载页面的状态。
@MainActor
final class UninstallViewModel: ObservableObject {
    @Published private(set) var apps: [AppBundle] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var selectedAppIDs: Set<String> = []
    @Published private(set) var selectedLeftoverIDs: Set<String> = []
    @Published private(set) var banner: String?
    @Published var showingConfirm = false
    @Published var showingResult = false
    @Published private(set) var resultMessage = ""
    @Published var searchText = ""

    private let service = AppInventoryService()

    var filteredApps: [AppBundle] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) ||
            ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(keyword)
        }
    }

    var totalLeftoverBytes: Int64 {
        apps.reduce(0) { $0 + $1.leftoverBytes }
    }

    var selectedApps: [AppBundle] {
        apps.filter { selectedAppIDs.contains($0.id) }
    }

    var selectedLeftovers: [LeftoverItem] {
        selectedApps.flatMap(\.leftovers).filter { selectedLeftoverIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedApps.reduce(0) { $0 + $1.byteSize } + selectedLeftovers.reduce(0) { $0 + $1.byteSize }
    }

    var totalByteCount: Int64 { apps.reduce(0) { $0 + $1.byteSize } }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        banner = nil
        Task { [weak self] in
            let list = await AppInventoryService().loadApplications()
            guard let self else { return }
            self.apps = list
            self.isLoading = false
            if list.isEmpty {
                self.banner = "未找到应用（/Applications 可能不可读）"
            }
            // 保留仍然存在的选中项
            let validAppIDs = Set(list.map(\.id))
            self.selectedAppIDs = self.selectedAppIDs.intersection(validAppIDs)
            let validLeftoverIDs = Set(list.flatMap(\.leftovers).map(\.id))
            self.selectedLeftoverIDs = self.selectedLeftoverIDs.intersection(validLeftoverIDs)
        }
    }

    func toggle(app: AppBundle) {
        if selectedAppIDs.contains(app.id) {
            selectedAppIDs.remove(app.id)
            for leftover in app.leftovers {
                selectedLeftoverIDs.remove(leftover.id)
            }
        } else {
            selectedAppIDs.insert(app.id)
            for leftover in app.leftovers {
                selectedLeftoverIDs.insert(leftover.id)
            }
        }
    }

    func toggle(leftover: LeftoverItem) {
        if selectedLeftoverIDs.contains(leftover.id) {
            selectedLeftoverIDs.remove(leftover.id)
        } else {
            selectedLeftoverIDs.insert(leftover.id)
        }
    }

    func uninstallSelected() async {
        let appEntries = selectedApps.map { (url: $0.url, size: $0.byteSize) }
        let leftoverEntries = selectedLeftovers.map { (url: $0.url, size: $0.byteSize) }
        guard !appEntries.isEmpty || !leftoverEntries.isEmpty else { return }

        isWorking = true
        let trash = TrashService()
        let report = await Task.detached(priority: .userInitiated) {
            trash.trash(entries: appEntries + leftoverEntries)
        }.value
        isWorking = false

        var lines = [report.summary, "释放 \(ByteFormatter.string(report.bytesFreed))"]
        if !report.failures.isEmpty {
            lines.append(contentsOf: report.failures.prefix(3).map { "· \($0.url.lastPathComponent)：\($0.message ?? "未知错误")" })
        }
        resultMessage = lines.joined(separator: "\n")
        showingResult = true

        if report.bytesFreed > 0 {
            HistoryStore().append(HistoryEntry(
                kind: .clean,
                bytes: report.bytesFreed,
                itemCount: report.successCount,
                detail: "卸载应用"
            ))
        }
        load()
    }
}
