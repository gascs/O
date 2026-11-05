import Foundation
import MoleLiteCore

/// 扫描与清理页面的状态。
@MainActor
final class ScanViewModel: ObservableObject {
    @Published private(set) var report: ScanReport?
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var expandedIDs: Set<String> = []
    @Published private(set) var banner: String?
    @Published private(set) var recommendations: [RecommendationGroup] = []
    @Published private(set) var failedItems: [TrashFailure] = []
    @Published var showingConfirm = false
    @Published var showingResult = false
    @Published private(set) var resultMessage = ""
    @Published private(set) var cleanHasPermissionIssue = false
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    /// 防抖后的搜索词：输入停顿 200ms 才真正过滤，避免每次按键全量重算。
    @Published private(set) var appliedSearchText = ""

    /// 扫描 / 清理的耗时预估（都来自同一套轻量模型）。
    @Published private(set) var scanEstimate: DurationEstimate?
    @Published private(set) var remainingEstimate: DurationEstimate?
    @Published private(set) var cleanEstimate: DurationEstimate?
    @Published private(set) var cleanProgress = (completed: 0, total: 0)

    struct TrashFailure: Identifiable {
        let url: URL
        let size: Int64
        var id: String { url.path }
    }

    /// 清理行动共用的安全校验（也用于判断选中项是否落在废纸篓内）。
    private let safety = PathSafety()

    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var cancellation: ScanCancellation?
    private var scanStartedAt: Date?
    private let estimator = DurationEstimator()

    var totalBytes: Int64 { report?.totalBytes ?? 0 }

    var selectedItems: [ScanItem] {
        guard let report else { return [] }
        var items: [ScanItem] = []
        for result in report.results {
            for item in result.items where selectedIDs.contains(item.id) {
                items.append(item)
            }
        }
        return items
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.byteSize } }

    /// 选中项里是否包含废纸篓内容：这类条目无法再「移入废纸篓」，只能永久删除，界面需要额外警告。
    var selectionIncludesTrash: Bool { containsTrashItems(selectedItems) }

    private func containsTrashItems(_ items: [ScanItem]) -> Bool {
        let trashPath = safety.homeDirectory.appendingPathComponent(".Trash").path
        return items.contains { PathSafety.isWithinCaseInsensitive($0.url.path, prefix: trashPath) }
    }

    var suggestedGroup: RecommendationGroup? {
        recommendations.first { $0.grade == .safe || $0.grade == .suggested }
    }

    var suggestedBytes: Int64 {
        recommendations.filter { $0.grade.isOneClickEligible }.reduce(0) { $0 + $1.bytes }
    }

    func result(for category: ScanCategory) -> ScanCategoryResult? {
        report?.result(for: category)
    }

    /// 搜索结果过滤（匹配名称与路径）。使用防抖后的关键词。
    func filteredItems(in result: ScanCategoryResult) -> [ScanItem] {
        let keyword = appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return result.items }
        return result.items.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) ||
            $0.url.path.localizedCaseInsensitiveContains(keyword)
        }
    }

    /// 过滤后仍有条目的分类数量，用于空状态判断。
    var filteredCategoryCount: Int {
        guard let report else { return 0 }
        return report.results.reduce(0) { partial, result in
            partial + (filteredItems(in: result).isEmpty ? 0 : 1)
        }
    }

    private func scheduleSearch() {
        let keyword = searchText
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.appliedSearchText = keyword
        }
    }

    // MARK: - 扫描

    /// `categories` 为 nil 时按当前规则执行扫描；显式传入分类时退回固定范围扫描（快速扫描）。
    func startScan(categories: [ScanCategory]? = nil) {
        cancelScan()
        let settings = ScanSettings.load()
        if categories == nil {
            startRuleScan(settings: settings)
            return
        }
        guard let categories else { return }
        let scanner = Scanner(settings: settings)
        let cancellation = ScanCancellation()
        self.cancellation = cancellation

        isScanning = true
        banner = nil
        selectedIDs = []
        expandedIDs = []
        failedItems = []
        remainingEstimate = nil
        cleanHasPermissionIssue = false
        scanStartedAt = Date()
        scanEstimate = estimator.scanEstimate()
        var initial = ScanProgress()
        initial.totalTargets = scanner.targets(for: categories).count
        progress = initial

        scanTask = Task { [weak self] in
            let owner = self
            do {
                let report = try await scanner.scan(categories: categories, cancellation: cancellation) { snapshot in
                    Task { @MainActor in
                        owner?.coalesce(snapshot)
                    }
                }
                guard let model = owner, !Task.isCancelled else { return }
                model.apply(report: report, settings: settings)
            } catch is CancellationError {
                owner?.finish(with: "扫描已取消")
            } catch let error as ScanError {
                owner?.finish(with: error.errorDescription ?? "扫描失败")
            } catch {
                owner?.finish(with: "扫描失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 规则驱动扫描

    private func startRuleScan(settings: ScanSettings) {
        let configuration = RulesStore().load()
        let enabled = configuration.enabledRules
        guard !enabled.isEmpty else {
            report = nil
            recommendations = []
            banner = "没有启用的规则：请到「规则」页启用至少一条规则。"
            scanEstimate = nil
            return
        }

        let scanner = CleanupRuleScanner(includeHidden: settings.includeHiddenItems)
        let cancellation = ScanCancellation()
        self.cancellation = cancellation
        isScanning = true
        banner = nil
        selectedIDs = []
        expandedIDs = []
        failedItems = []
        remainingEstimate = nil
        cleanHasPermissionIssue = false
        scanStartedAt = Date()
        scanEstimate = estimator.scanEstimate()
        var initial = ScanProgress()
        initial.totalTargets = enabled.count
        progress = initial

        scanTask = Task { [weak self] in
            let owner = self
            do {
                let ruleReport = try await Task.detached(priority: .userInitiated) {
                    try scanner.scan(rules: configuration.rules,
                                     protectedPaths: configuration.protectedPaths,
                                     cancellation: cancellation) { snapshot in
                        Task { @MainActor in owner?.coalesce(snapshot) }
                    }
                }.value
                guard let model = owner, !Task.isCancelled else { return }
                RuleEstimateStore.shared.apply(ruleReport)
                model.apply(ruleReport: ruleReport, configuration: configuration, settings: settings)
            } catch is CancellationError {
                owner?.finish(with: "扫描已取消")
            } catch let error as ScanError {
                owner?.finish(with: error.errorDescription ?? "扫描失败")
            } catch {
                owner?.finish(with: "扫描失败：\(error.localizedDescription)")
            }
        }
    }

    private func apply(ruleReport: RuleScanReport, configuration: CleanupRulesConfiguration,
                       settings: ScanSettings) {
        var groups: [ScanCategory: [ScanItem]] = [:]
        var messages: [ScanCategory: [String]] = [:]
        var seen = Set<String>()
        let quietReasons: Set<String> = [
            "没有符合条件的条目", "没有符合条件的文件",
            "未达到最小体积", "未达到最小年龄"
        ]

        for outcome in ruleReport.outcomes {
            guard let rule = configuration.rule(id: outcome.ruleID) else { continue }
            if let reason = outcome.skippedReason, !quietReasons.contains(reason) {
                messages[rule.category, default: []].append("\(rule.name)：\(reason)")
            }
            for item in outcome.items where !seen.contains(item.id) {
                seen.insert(item.id)
                groups[rule.category, default: []].append(item)
            }
        }

        let results: [ScanCategoryResult] = ScanCategory.allCases.compactMap { category in
            guard let items = groups[category], !items.isEmpty else { return nil }
            let sorted = items.sorted { $0.byteSize > $1.byteSize }
            let message = messages[category]?.isEmpty == false
                ? messages[category]?.uniqued().joined(separator: "；")
                : nil
            return ScanCategoryResult(category: category,
                                      items: sorted,
                                      totalBytes: sorted.reduce(0) { $0 + $1.byteSize },
                                      message: message)
        }

        apply(report: ScanReport(results: results,
                                 scannedItemCount: ruleReport.scannedFileCount,
                                 duration: ruleReport.duration,
                                 finishedAt: ruleReport.finishedAt),
              settings: settings)

        let skipped = ruleReport.outcomes.compactMap { outcome -> String? in
            guard let reason = outcome.skippedReason, !quietReasons.contains(reason) else { return nil }
            let name = configuration.rule(id: outcome.ruleID)?.name ?? outcome.ruleID
            return "\(name)：\(reason)"
        }
        if !skipped.isEmpty {
            banner = "已跳过 \(skipped.count) 条规则 · \(skipped.prefix(2).joined(separator: "；"))"
        }
    }

    // MARK: - 进度节流

    private var coalescer = ProgressCoalescer<ScanProgress>()
    private var flushTask: Task<Void, Never>?

    /// 后台回调可能很密，这里按 100ms 合并一次，只把最新快照推给界面。
    private func coalesce(_ snapshot: ScanProgress) {
        guard coalescer.submit(snapshot) else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            if let latest = self.coalescer.flush() {
                self.progress = latest
                self.updateEta(for: latest)
            }
            self.flushTask = nil
        }
    }

    private func updateEta(for snapshot: ScanProgress) {
        guard let started = scanStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        if let estimate = estimator.projectedRemaining(elapsed: elapsed, fraction: snapshot.fraction) {
            remainingEstimate = estimate
        }
    }

    func cancelScan() {
        cancellation?.cancel()
        scanTask?.cancel()
        scanTask = nil
        flushTask?.cancel()
        flushTask = nil
        coalescer.reset()
        if isScanning {
            isScanning = false
            banner = "扫描已取消"
        }
    }

    private func finish(with message: String?) {
        isScanning = false
        remainingEstimate = nil
        if let message { banner = message }
    }

    private func apply(report: ScanReport, settings: ScanSettings) {
        self.report = report
        isScanning = false
        remainingEstimate = nil
        recommendations = RecommendationEngine.groups(in: report)
        banner = report.results.contains(where: { $0.message != nil }) ? "部分目录不可访问，请查看卡片内的提示" : nil

        // 用真实耗时校正模型，后续预估会越来越贴近本机。
        estimator.recordScan(seconds: report.duration, items: report.scannedItemCount, bytes: report.totalBytes)
        scanEstimate = nil

        HistoryStore().append(HistoryEntry(
            kind: .scan,
            bytes: report.totalBytes,
            itemCount: report.scannedItemCount,
            detail: report.results.map(\.category.title).joined(separator: " / ")
        ))

        guard settings.preselectRecommendedItems else { return }
        var selection: Set<String> = []
        for result in report.results where result.category.isRecommended {
            for item in result.items {
                selection.insert(item.id)
            }
        }
        selectedIDs = selection
    }

    // MARK: - 选择

    func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func setSelected(_ ids: [String], selected: Bool) {
        for id in ids {
            if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        }
    }

    /// 一键勾选「安全 + 建议」两档条目，不包含废纸篓与大文件。
    func selectSuggested() {
        guard let report else { return }
        selectedIDs = Set(RecommendationEngine.oneClickItemIDs(in: report))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    /// 由界面调用的提示（例如导出失败）。
    func present(message: String) {
        resultMessage = message
        showingResult = true
    }

    func toggleExpanded(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    func isExpanded(_ id: String) -> Bool { expandedIDs.contains(id) }

    // MARK: - 清理

    func cleanSelected() async {
        let items = selectedItems
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        cleanHasPermissionIssue = false
        let bytes = items.reduce(Int64(0)) { $0 + $1.byteSize }
        cleanEstimate = estimator.cleanEstimate(items: items.count, bytes: bytes)
        cleanProgress = (0, items.count)
        let report = await performTrash(items, allowPermanentRemoval: containsTrashItems(items))
        isCleaning = false
        apply(cleanReport: report)
    }

    /// 重试上一次清理中失败的条目。
    func retryFailed() async {
        let items = failedItems.map { ScanItem(url: $0.url, byteSize: $0.size, isDirectory: false) }
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        cleanEstimate = estimator.cleanEstimate(items: items.count,
                                               bytes: items.reduce(Int64(0)) { $0 + $1.byteSize })
        cleanProgress = (0, items.count)
        let report = await performTrash(items, allowPermanentRemoval: containsTrashItems(items))
        isCleaning = false
        apply(cleanReport: report)
    }

    private func performTrash(_ items: [ScanItem], allowPermanentRemoval: Bool = false) async -> CleanReport {
        let service = TrashService()
        let started = Date()
        let owner = self
        let report = await Task.detached(priority: .userInitiated) {
            service.trash(items: items, allowPermanentRemoval: allowPermanentRemoval, progress: { completed, total in
                Task { @MainActor in
                    owner.cleanProgress = (completed, total)
                }
            })
        }.value

        // 实测校正：把真实清理耗时喂回模型。
        estimator.recordClean(seconds: Date().timeIntervalSince(started),
                              items: items.count,
                              bytes: items.reduce(Int64(0)) { $0 + $1.byteSize })
        return report
    }

    private func apply(cleanReport: CleanReport) {
        let succeededPaths = Set(cleanReport.outcomes.filter(\.success).map { $0.url.path })
        if var current = report {
            var results: [ScanCategoryResult] = []
            for result in current.results {
                let items = result.items.filter { !succeededPaths.contains($0.url.path) }
                let total = items.reduce(0) { $0 + $1.byteSize }
                results.append(ScanCategoryResult(
                    category: result.category,
                    items: items,
                    totalBytes: total,
                    message: result.message
                ))
            }
            current.results = results
            report = current
            recommendations = RecommendationEngine.groups(in: current)
        }
        selectedIDs.subtract(succeededPaths)

        failedItems = cleanReport.failures.map {
            TrashFailure(url: $0.url, size: byteSize(for: $0.url.path))
        }

        if cleanReport.bytesFreed > 0 {
            let detail: String
            if cleanReport.freedBytes > 0 && cleanReport.movedBytes > 0 {
                detail = "移入废纸篓与永久删除"
            } else if cleanReport.freedBytes > 0 {
                detail = "永久删除"
            } else {
                detail = "移入废纸篓"
            }
            HistoryStore().append(HistoryEntry(
                kind: .clean,
                bytes: cleanReport.bytesFreed,
                itemCount: cleanReport.successCount,
                detail: detail
            ))
        }

        var lines: [String] = [cleanReport.summary, "释放 \(ByteFormatter.string(cleanReport.bytesFreed))"]
        if cleanReport.hasPermanentDeletion {
            lines.append("其中永久删除 \(ByteFormatter.string(cleanReport.freedBytes))，不可恢复；移入废纸篓 \(ByteFormatter.string(cleanReport.movedBytes))，可从废纸篓恢复。")
        }
        cleanHasPermissionIssue = cleanReport.hasPermissionIssue
        if cleanReport.hasPermissionIssue {
            lines.append("有项目因权限不足无法移动。可在「系统设置 › 隐私与安全性 › 完全磁盘访问」中勾选 O 后重试。")
        }
        if cleanReport.hasDisappearedFiles {
            lines.append("部分文件在扫描后被其他程序删除，已自动跳过。")
        }
        if !cleanReport.failures.isEmpty {
            let detail = cleanReport.failures.prefix(3).map { "· \($0.url.lastPathComponent)：\($0.message ?? "未知错误")" }
            lines.append(contentsOf: detail)
            if cleanReport.failures.count > 3 {
                lines.append("（其余 \(cleanReport.failures.count - 3) 项失败）")
            }
            lines.append("可点击「重试失败项」再次尝试。")
        }
        resultMessage = lines.joined(separator: "\n")
        showingResult = true
    }

    private func byteSize(for path: String) -> Int64 {
        guard let report else { return 0 }
        for result in report.results {
            if let item = result.items.first(where: { $0.url.path == path }) { return item.byteSize }
        }
        return 0
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
