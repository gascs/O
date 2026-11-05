import Foundation
import MoleLiteCore

struct LaunchGroup: Identifiable {
    let scope: LaunchScope
    let items: [LaunchItem]
    var id: String { scope.rawValue }
}

/// 启动项管理：只读解析 plist，允许用户级启动项移入废纸篓。
@MainActor
final class LaunchItemsViewModel: ObservableObject {
    @Published private(set) var items: [LaunchItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var banner: String?
    /// 系统登录项数据库的读取说明（读不到时给出真实原因）。
    @Published private(set) var loginNote: String?
    @Published var scopeFilter: LaunchScope?
    @Published var searchText = ""
    @Published var showingConfirm = false
    @Published var showingResult = false
    @Published private(set) var resultMessage = ""

    private let service = LaunchItemService()

    var filteredItems: [LaunchItem] {
        guard let scopeFilter else { return items }
        return items.filter { $0.scope == scopeFilter }
    }

    var groupedItems: [LaunchGroup] {
        LaunchScope.allCases.compactMap { scope in
            let list = filteredItems.filter { $0.scope == scope }
            return list.isEmpty ? nil : LaunchGroup(scope: scope, items: list)
        }
    }

    var selectedItems: [LaunchItem] { items.filter { selectedIDs.contains($0.id) } }
    var editableCount: Int { items.filter { $0.scope.isUserEditable }.count }
    var systemCount: Int { items.filter { !$0.scope.isUserEditable }.count }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        banner = nil
        Task { [weak self] in
            guard let self else { return }
            let list = await self.service.load()
            let login = self.service.loadLoginItems()
            self.items = list + login.items
            self.loginNote = login.note
            self.isLoading = false
            if list.isEmpty {
                self.banner = "没有读取到启动项（相关目录可能不存在）"
            }
            let valid = Set(list.map(\.id))
            self.selectedIDs = self.selectedIDs.intersection(valid)
        }
    }

    func toggle(_ item: LaunchItem) {
        guard item.scope.isUserEditable else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func trashSelected() async {
        let targets = selectedItems.filter { $0.scope.isUserEditable }
        guard !targets.isEmpty, !isWorking else { return }
        isWorking = true
        let service = TrashService()
        let report = await Task.detached(priority: .userInitiated) {
            service.trash(entries: targets.map { (url: $0.url, size: FileSizeReader.allocatedSize(of: $0.url)) })
        }.value
        isWorking = false

        var lines = [report.summary]
        if !report.failures.isEmpty {
            lines.append(contentsOf: report.failures.prefix(3).map { "· \($0.url.lastPathComponent)：\($0.message ?? "未知错误")" })
        }
        if report.bytesFreed > 0 {
            lines.append("释放 \(ByteFormatter.string(report.bytesFreed))")
        }
        resultMessage = lines.joined(separator: "\n")
        showingResult = true
        load()
    }
}
