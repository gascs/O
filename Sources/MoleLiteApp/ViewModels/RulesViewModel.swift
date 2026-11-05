import AppKit
import Foundation
import MoleLiteCore

/// 规则预计空间的共享缓存：清理页扫描与规则页估算都写这里，避免重复遍历。
@MainActor
final class RuleEstimateStore: ObservableObject {
    static let shared = RuleEstimateStore()

    @Published private(set) var outcomes: [String: RuleScanOutcome] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var scannedAt: Date?
    @Published private(set) var lastError: String?

    private init() {}

    func begin() {
        isScanning = true
        lastError = nil
    }

    func apply(_ report: RuleScanReport) {
        outcomes = Dictionary(uniqueKeysWithValues: report.outcomes.map { ($0.ruleID, $0) })
        isScanning = false
        scannedAt = report.finishedAt
        lastError = nil
    }

    func fail(_ message: String) {
        isScanning = false
        lastError = message
    }

    func bytes(for ruleID: String) -> Int64? { outcomes[ruleID]?.bytes }
    func itemCount(for ruleID: String) -> Int? { outcomes[ruleID]?.itemCount }
    func skipReason(for ruleID: String) -> String? { outcomes[ruleID]?.skippedReason }
}

/// 规则页状态：规则增删改、预设、保护清单、JSON 导入导出与预计空间估算。
@MainActor
final class RulesViewModel: ObservableObject {
    @Published private(set) var configuration: CleanupRulesConfiguration
    @Published var message: String?
    @Published var showingMessage = false
    @Published private(set) var isEstimating = false
    @Published var editingRule: CleanupRule?

    private let store: RulesStore
    private let home: URL
    private let estimateStore = RuleEstimateStore.shared
    private var estimateTask: Task<Void, Never>?
    private var cancellation: ScanCancellation?

    init(store: RulesStore = RulesStore(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.store = store
        self.home = home
        self.configuration = store.load()
    }

    // MARK: 读取

    var enabledCount: Int { configuration.enabledRules.count }
    var cautionCount: Int { configuration.cautionEnabledCount }

    func reload() {
        configuration = store.load()
    }

    func displayPath(_ path: String) -> String {
        RuleValidator.display(RuleValidation.normalized(path, home: home) ?? path, home: home)
    }

    // MARK: 预设

    func applyPreset(_ preset: RulePreset) {
        let next = CleanupRuleCatalog.configuration(for: preset,
                                                     protectedPaths: configuration.protectedPaths)
        configuration = next
        persist()
        present("已套用「\(preset.title)」预设：\(next.enabledRules.count) 条启用规则。")
        scanEstimates()
    }

    func resetRules() {
        let next = CleanupRuleCatalog.configuration(for: .standard,
                                                     protectedPaths: configuration.protectedPaths)
        configuration = next
        persist()
        present("已恢复默认规则（标准预设），保护清单保持不变。")
        scanEstimates()
    }

    // MARK: 单条规则

    func toggle(_ rule: CleanupRule, enabled: Bool) {
        guard var current = configuration.rule(id: rule.id) else { return }
        current.isEnabled = enabled
        replace(current)
    }

    @discardableResult
    func upsert(_ rule: CleanupRule) -> Bool {
        var candidate = rule
        candidate.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.name.isEmpty else {
            present("无法保存：规则名称不能为空。")
            return false
        }
        // 规范：同一配置内不允许两条规则指向同一路径，避免扫描重复计量。
        let normalizedPath = RuleValidation.normalized(rule.path, home: home) ?? rule.path
        if let other = configuration.rules.first(where: { existing in
            existing.id != rule.id
                && (RuleValidation.normalized(existing.path, home: home) ?? existing.path) == normalizedPath
        }) {
            present("无法保存：路径与现有规则「\(other.name)」重复，请改用别的路径。")
            return false
        }
        let verdict = RuleValidator.validate(candidate, home: home,
                                             protectedPaths: configuration.protectedPaths)
        guard verdict.isValid else {
            present("无法保存：\(verdict.reason ?? "路径不合法")")
            return false
        }
        candidate.path = normalizedPath
        candidate.minAgeDays = max(0, rule.minAgeDays)
        candidate.minSizeMB = max(0, rule.minSizeMB)
        if configuration.rule(id: candidate.id) != nil {
            replace(candidate)
        } else {
            configuration.rules.append(candidate)
            persist()
        }
        return true
    }

    func delete(_ rule: CleanupRule) {
        configuration.rules.removeAll { $0.id == rule.id }
        persist()
    }

    func duplicate(_ rule: CleanupRule) {
        var copy = rule
        copy.id = UUID().uuidString
        copy.name = "\(rule.name) 副本"
        configuration.rules.append(copy)
        persist()
    }

    private func replace(_ rule: CleanupRule) {
        guard let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        configuration.rules[index] = rule
        persist()
    }

    // MARK: 保护清单

    @discardableResult
    func addProtectedPath(_ raw: String) -> Bool {
        let verdict = RuleValidator.validate(path: raw, home: home)
        guard verdict.isValid else {
            present("无法添加：\(verdict.reason ?? "路径不合法")")
            return false
        }
        guard let normalized = RuleValidation.normalized(raw, home: home) else {
            present("无法添加：路径无法解析")
            return false
        }
        guard !configuration.protectedPaths.contains(normalized) else {
            present("该路径已在保护清单中。")
            return false
        }
        configuration.protectedPaths.append(normalized)
        persist()
        return true
    }

    func removeProtectedPath(_ path: String) {
        configuration.protectedPaths.removeAll { $0 == path }
        persist()
    }

    // MARK: JSON

    /// 已选好待导入文件、等待用户选择「合并 / 替换」时的文件名（非 nil 时显示选择弹窗）。
    @Published private(set) var pendingImportFileName: String?
    private var pendingImportData: Data?

    func exportJSON() {
        let panel = NSSavePanel()
        panel.title = "导出清理规则"
        let stamp = Self.exportStamp.string(from: Date())
        panel.nameFieldStringValue = "O-rules-\(stamp).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try RulesStore.exportJSON(configuration, appVersion: AppInfo.version)
            try data.write(to: url, options: .atomic)
            present("已导出 \(configuration.rules.count) 条规则到 \(url.lastPathComponent)。")
        } catch {
            present("导出失败：\(error.localizedDescription)")
        }
    }

    /// 导入入口：先选文件，再由界面弹窗让用户选择合并还是替换。
    func importJSON() {
        let panel = NSOpenPanel()
        panel.title = "导入清理规则"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImportData = try Data(contentsOf: url)
            pendingImportFileName = url.lastPathComponent
        } catch {
            pendingImportData = nil
            pendingImportFileName = nil
            present("读取文件失败：\(error.localizedDescription)")
        }
    }

    func cancelImport() {
        pendingImportData = nil
        pendingImportFileName = nil
    }

    /// 按用户选择的模式真正执行导入，并给出摘要（接受 / 拒绝 / 重复）。
    func applyImport(mode: RulesImportMode) {
        let data = pendingImportData
        pendingImportData = nil
        pendingImportFileName = nil
        guard let data else { return }
        do {
            let summary = try store.importRules(data,
                                                mode: mode,
                                                current: mode == .merge ? configuration : nil)
            switch mode {
            case .replace:
                configuration = CleanupRulesConfiguration(rules: summary.acceptedRules,
                                                           protectedPaths: summary.protectedPaths,
                                                           appliedPreset: summary.appliedPreset)
            case .merge:
                var merged = configuration
                merged.rules.append(contentsOf: summary.acceptedRules)
                merged.protectedPaths = summary.protectedPaths
                merged.appliedPreset = nil
                configuration = merged
            }
            persist()
            present(summary.message)
            scanEstimates()
        } catch {
            present("导入失败：\(error.localizedDescription)")
        }
    }

    private static let exportStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    // MARK: 预计空间

    func scanEstimates() {
        estimateTask?.cancel()
        cancellation?.cancel()
        let rules = configuration.rules
        let protected = configuration.protectedPaths
        let scanner = CleanupRuleScanner(home: home,
                                         includeHidden: ScanSettings.load().includeHiddenItems)
        let cancellation = ScanCancellation()
        self.cancellation = cancellation
        estimateStore.begin()
        isEstimating = true

        estimateTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                try? scanner.scan(rules: rules, protectedPaths: protected, cancellation: cancellation)
            }.value
            guard let self else { return }
            self.isEstimating = false
            if let result {
                self.estimateStore.apply(result)
            } else {
                self.estimateStore.fail("估算失败，请稍后重试")
            }
        }
    }

    func cancelEstimates() {
        cancellation?.cancel()
        estimateTask?.cancel()
        isEstimating = false
        estimateStore.fail("估算已取消")
    }

    // MARK: 私有

    private func persist() {
        store.save(configuration)
        objectWillChange.send()
        NotificationCenter.default.post(name: .oRulesChanged, object: nil)
    }

    private func present(_ text: String) {
        message = text
        showingMessage = true
    }
}

extension Notification.Name {
    /// 规则变更后，清理页下次扫描自动读取新配置。
    static let oRulesChanged = Notification.Name("o.rulesChanged")
}
