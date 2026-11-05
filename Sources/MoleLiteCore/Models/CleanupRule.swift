import Foundation

// MARK: - 规则模型
//
// 每条清理规则描述「去哪找、找什么、多旧、多大、风险多高」。
// 规则只产生候选条目；真正删除仍逐条经过 PathSafety 校验并移入废纸篓。

/// 规则的扫描方式。
public enum RuleScanMode: String, Codable, CaseIterable, Sendable {
    /// 只统计根目录下的直接子项（缓存、容器这类「一个应用一个目录」的来源）。
    case topLevel
    /// 递归收集符合条件的单个文件（下载 / 桌面这类个人文件来源）。
    case recursiveFiles

    public var title: String {
        switch self {
        case .topLevel: return "按目录汇总"
        case .recursiveFiles: return "递归找文件"
        }
    }
}

public struct CleanupRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: ScanCategory
    /// 规则根路径，支持 `~` 展开；保存前统一展开为绝对路径。
    public var path: String
    /// 最小文件年龄（天），0 表示不限。
    public var minAgeDays: Int
    /// 最小文件体积（MB），0 表示不限。
    public var minSizeMB: Int
    public var grade: SafetyGrade
    public var isEnabled: Bool
    public var note: String
    public var scanMode: RuleScanMode

    public init(id: String = UUID().uuidString,
                name: String,
                category: ScanCategory,
                path: String,
                minAgeDays: Int = 0,
                minSizeMB: Int = 0,
                grade: SafetyGrade = .suggested,
                isEnabled: Bool = true,
                note: String = "",
                scanMode: RuleScanMode = .topLevel) {
        self.id = id
        self.name = name
        self.category = category
        self.path = path
        self.minAgeDays = max(0, minAgeDays)
        self.minSizeMB = max(0, minSizeMB)
        self.grade = grade
        self.isEnabled = isEnabled
        self.note = note
        self.scanMode = scanMode
    }

    public var minAgeSeconds: TimeInterval { TimeInterval(max(0, minAgeDays)) * 86_400 }
    public var minSizeBytes: Int64 { Int64(max(0, minSizeMB)) * 1_048_576 }

    public var conditionText: String {
        var parts: [String] = []
        parts.append(minAgeDays > 0 ? "\(minAgeDays) 天以上未修改" : "不限年龄")
        parts.append(minSizeMB > 0 ? "单文件 ≥ \(minSizeMB) MB" : "不限体积")
        return parts.joined(separator: " · ")
    }
}

/// 预设等级。
public enum RulePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case conservative
    case standard
    case aggressive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .conservative: return "保守"
        case .standard: return "标准"
        case .aggressive: return "激进"
        }
    }

    public var summary: String {
        switch self {
        case .conservative: return "只清理可自动重建的缓存、日志与开发派生数据"
        case .standard: return "在保守基础上加入应用残留、诊断报告与包管理器缓存"
        case .aggressive: return "再加入个人文件、备份与容器数据，逐条确认后才清理"
        }
    }
}

public struct CleanupRulesConfiguration: Codable, Sendable, Equatable {
    public var rules: [CleanupRule]
    public var protectedPaths: [String]
    public var appliedPreset: RulePreset?

    public init(rules: [CleanupRule], protectedPaths: [String] = [], appliedPreset: RulePreset? = nil) {
        self.rules = rules
        self.protectedPaths = protectedPaths
        self.appliedPreset = appliedPreset
    }

    public var enabledRules: [CleanupRule] { rules.filter(\.isEnabled) }

    public var cautionEnabledCount: Int {
        rules.filter { $0.isEnabled && $0.grade == .caution }.count
    }

    public func rule(id: String) -> CleanupRule? { rules.first { $0.id == id } }
}

// MARK: - 校验

public struct RuleValidation: Equatable, Sendable {
    public let reason: String?

    public var isValid: Bool { reason == nil }

    public static let ok = RuleValidation(reason: nil)
    public static func reject(_ reason: String) -> RuleValidation { RuleValidation(reason: reason) }

    /// 规范化并展开 `~`；非法时返回 nil。
    public static func normalized(_ raw: String, home: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        let path = PathSafety.normalize(trimmed, home: home)
        guard !path.isEmpty, path != "/", path.hasPrefix("/") else { return nil }
        return path
    }
}

/// 规则路径安全校验。
///
/// 与 `PathSafety` 共用同一份系统受保护前缀；区别在于规则允许把
/// `~/Downloads`、`~/.Trash` 这类目录作为**扫描根**，删除时仍逐条走 PathSafety。
public enum RuleValidator {
    /// 敏感目录（相对主目录）：整根本身及其子路径都不允许作为清理规则目标。
    /// 这些位置存放密码、密钥、通信与账户数据，误删不可恢复。
    public static let sensitiveRelativePaths: [String] = [
        ".ssh", ".gnupg", ".aws", ".kube", ".config", ".docker", ".password-store",
        "Library/Keychains", "Library/Messages", "Library/Mail", "Library/Safari",
        "Library/Cookies", "Library/Accounts", "Library/Preferences",
        "Library/IdentityServices", "Library/Calendars", "Library/Reminders",
        "Library/Sharing", "Library/Suggestions"
    ]

    public static func validate(path raw: String,
                                home: URL,
                                protectedPaths: [String] = []) -> RuleValidation {
        guard let path = RuleValidation.normalized(raw, home: home) else {
            return .reject("非法路径：必须是绝对路径或以 ~ 开头")
        }
        let homePath = PathSafety.normalize(home.path, home: home)
        guard path != homePath else {
            return .reject("不能把整个主目录设为规则路径")
        }
        for prefix in PathSafety.protectedPrefixes
        where PathSafety.isWithinCaseInsensitive(path, prefix: prefix)
            && !PathSafety.isWithinCaseInsensitive(path, prefix: homePath) {
            return .reject("系统受保护目录：\(prefix)")
        }
        guard PathSafety.isWithinCaseInsensitive(path, prefix: homePath) else {
            return .reject("只允许用户主目录内的路径（当前：\(path)）")
        }
        // 敏感目录（~/.ssh、~/Library/Keychains 等）：整根与子路径都拒绝。
        if let sensitive = sensitiveRelativePaths.first(where: {
            PathSafety.isWithinCaseInsensitive(path, prefix: homePath + "/" + $0)
        }) {
            return .reject("敏感目录：\(display(homePath + "/" + sensitive, home: home)) 内的数据不允许作为清理目标")
        }
        // 只允许「主目录本身」之外，但拒绝范围过大的 ~/Library。
        if path.lowercased() == (homePath + "/Library").lowercased() {
            return .reject("~/Library 范围过大，请选择具体子目录")
        }
        let normalizedProtected = protectedPaths
            .compactMap { RuleValidation.normalized($0, home: home) }
        for entry in normalizedProtected where PathSafety.isWithinCaseInsensitive(path, prefix: entry) {
            return .reject("路径在受保护清单中：\(display(path, home: home))")
        }
        // 符号链接逃逸：解析后必须仍在主目录内。
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let resolvedHome = URL(fileURLWithPath: homePath).resolvingSymlinksInPath().path
        if !PathSafety.isWithinCaseInsensitive(resolved, prefix: resolvedHome) {
            return .reject("符号链接指向主目录之外：\(resolved)")
        }
        return .ok
    }

    public static func validate(_ rule: CleanupRule, home: URL,
                                protectedPaths: [String] = []) -> RuleValidation {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .reject("规则名称不能为空") }
        guard rule.minAgeDays >= 0 else { return .reject("最小年龄不能为负数") }
        guard rule.minSizeMB >= 0 else { return .reject("最小体积不能为负数") }
        if rule.scanMode == .recursiveFiles, rule.minSizeMB == 0, rule.minAgeDays == 0 {
            return .reject("递归找文件时至少设置一项条件（年龄或体积），避免列出整个目录")
        }
        let verdict = validate(path: rule.path, home: home, protectedPaths: protectedPaths)
        guard verdict.isValid else { return verdict }
        return .ok
    }

    public static func display(_ path: String, home: URL) -> String {
        let homePath = PathSafety.normalize(home.path, home: home)
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }
}

// MARK: - 预设

public enum CleanupRuleCatalog {
    /// 保守预设：只包含可自动重建的缓存、日志与派生数据。
    public static let conservative: [CleanupRule] = [
        CleanupRule(id: "cache.user", name: "用户缓存", category: .userCaches,
                    path: "~/Library/Caches", grade: .safe,
                    note: "应用缓存会在下次启动时自动重建，清理后首次打开可能稍慢。"),
        CleanupRule(id: "log.user", name: "应用日志", category: .logs,
                    path: "~/Library/Logs", minAgeDays: 7, grade: .safe,
                    note: "用户级日志，保留最近 7 天，便于回溯近期问题。", scanMode: .topLevel),
        CleanupRule(id: "xcode.derived", name: "Xcode 派生数据", category: .xcode,
                    path: "~/Library/Developer/Xcode/DerivedData", grade: .safe,
                    note: "构建中间产物，重新编译会自动生成。"),
        CleanupRule(id: "xcode.devicesupport", name: "iOS 设备支持", category: .xcode,
                    path: "~/Library/Developer/Xcode/iOS DeviceSupport", minAgeDays: 30, grade: .safe,
                    note: "旧版本设备的符号缓存，下次连接设备时按需重建。"),
        CleanupRule(id: "trash.user", name: "废纸篓", category: .trash,
                    path: "~/.Trash", minAgeDays: 7, grade: .caution,
                    note: "废纸篓中的项目，清理前请确认不再需要恢复。")
    ]

    /// 标准预设：在保守基础上加入应用残留、诊断报告与包管理器缓存。
    public static let standard: [CleanupRule] = conservative + [
        CleanupRule(id: "state.saved", name: "窗口恢复状态", category: .appLeftovers,
                    path: "~/Library/Saved Application State", grade: .safe,
                    note: "应用窗口恢复快照，重建不影响已保存的文档。"),
        CleanupRule(id: "http.storages", name: "HTTP 存储", category: .appLeftovers,
                    path: "~/Library/HTTPStorages", minAgeDays: 7, grade: .safe,
                    note: "网络请求缓存与 Cookie 快照，部分应用会重新登录。"),
        CleanupRule(id: "support.residue", name: "应用支持残留", category: .appLeftovers,
                    path: "~/Library/Application Support", minAgeDays: 30, minSizeMB: 50, grade: .suggested,
                    note: "可能包含已卸载应用的数据；建议逐项确认后再清理。"),
        CleanupRule(id: "container.user", name: "应用容器", category: .appLeftovers,
                    path: "~/Library/Containers", minAgeDays: 30, minSizeMB: 100, grade: .caution,
                    note: "沙盒应用的数据与登录状态，清理后会丢失本地设置。"),
        CleanupRule(id: "container.group", name: "分组容器", category: .appLeftovers,
                    path: "~/Library/Group Containers", minAgeDays: 30, minSizeMB: 100, grade: .caution,
                    note: "多个应用共享的数据，可能包含插件与扩展配置。"),
        CleanupRule(id: "diag.user", name: "用户诊断报告", category: .diagnostics,
                    path: "~/Library/Logs/DiagnosticReports", minAgeDays: 7, grade: .safe,
                    note: "崩溃与诊断报告，保留最近 7 天。"),
        CleanupRule(id: "diag.crash", name: "崩溃报告", category: .diagnostics,
                    path: "~/Library/Application Support/CrashReporter", minAgeDays: 30, grade: .safe,
                    note: "旧崩溃报告，排障时可先导出。"),
        CleanupRule(id: "xcode.archives", name: "Xcode 归档", category: .developer,
                    path: "~/Library/Developer/Xcode/Archives", minAgeDays: 30, grade: .suggested,
                    note: "已发布版本的归档包；需要重新导出安装包时请保留。"),
        CleanupRule(id: "sim.devices", name: "模拟器设备", category: .developer,
                    path: "~/Library/Developer/CoreSimulator/Devices", minAgeDays: 7, grade: .suggested,
                    note: "模拟器数据与安装的应用，必要时可在 Xcode 中重建。"),
        CleanupRule(id: "pkg.npm", name: "npm 缓存", category: .packageCaches,
                    path: "~/.npm/_cacache", minAgeDays: 7, grade: .safe,
                    note: "npm 包缓存，下次安装时按需重新下载。"),
        CleanupRule(id: "pkg.yarn", name: "Yarn 缓存", category: .packageCaches,
                    path: "~/Library/Caches/Yarn", minAgeDays: 7, grade: .safe,
                    note: "Yarn 包缓存。"),
        CleanupRule(id: "pkg.pnpm", name: "pnpm 缓存", category: .packageCaches,
                    path: "~/Library/pnpm/store", minAgeDays: 7, grade: .safe,
                    note: "pnpm 内容寻址存储。"),
        CleanupRule(id: "pkg.pip", name: "pip 缓存", category: .packageCaches,
                    path: "~/Library/Caches/pip", minAgeDays: 7, grade: .safe,
                    note: "Python 包下载缓存。"),
        CleanupRule(id: "pkg.brew", name: "Homebrew 缓存", category: .packageCaches,
                    path: "~/Library/Caches/Homebrew", minAgeDays: 7, grade: .safe,
                    note: "Homebrew 下载缓存，重新安装时按需下载。"),
        CleanupRule(id: "pkg.go", name: "Go 构建缓存", category: .packageCaches,
                    path: "~/Library/Caches/go-build", minAgeDays: 7, grade: .safe,
                    note: "编译缓存，下次编译会重建。"),
        CleanupRule(id: "pkg.rust", name: "Rust 注册表", category: .packageCaches,
                    path: "~/.cargo/registry/cache", minAgeDays: 30, grade: .safe,
                    note: "已下载的 crate 压缩包。"),
        CleanupRule(id: "pkg.gradle", name: "Gradle 缓存", category: .packageCaches,
                    path: "~/.gradle/caches", minAgeDays: 30, grade: .suggested,
                    note: "依赖与构建缓存，首次编译会重新下载。"),
        CleanupRule(id: "pkg.maven", name: "Maven 仓库", category: .packageCaches,
                    path: "~/.m2/repository", minAgeDays: 90, grade: .suggested,
                    note: "本地依赖仓库，删除后需重新解析依赖。"),
        CleanupRule(id: "pkg.pods", name: "CocoaPods 缓存", category: .packageCaches,
                    path: "~/Library/Caches/CocoaPods", minAgeDays: 7, grade: .safe,
                    note: "Pod 下载缓存。"),
        CleanupRule(id: "sys.diag", name: "系统诊断缓存", category: .systemCaches,
                    path: "~/Library/Logs/com.apple.xpc.launchd", minAgeDays: 30, grade: .safe,
                    note: "仅清理可读的用户级系统日志；/Library 与 /System 始终只读。"),
        CleanupRule(id: "sys.cache", name: "系统缓存副本", category: .systemCaches,
                    path: "~/Library/Caches/com.apple.LaunchServices", minAgeDays: 30, grade: .safe,
                    note: "LaunchServices 缓存副本，系统会自行重建。")
    ] + EcosystemRules.standard

    /// 激进预设：再加入个人文件、备份与容器数据，全部为「谨慎」级。
    public static let aggressive: [CleanupRule] = standard + [
        CleanupRule(id: "docker.data", name: "Docker 数据", category: .docker,
                    path: "~/Library/Containers/com.docker.docker", minAgeDays: 30, minSizeMB: 100, grade: .caution,
                    note: "镜像与容器层；删除后需要重新拉取镜像。"),
        CleanupRule(id: "backup.ios", name: "iOS 备份", category: .backups,
                    path: "~/Library/Application Support/MobileSync/Backup", minAgeDays: 60, grade: .caution,
                    note: "iPhone / iPad 本地备份；删除后无法从本机恢复。"),
        CleanupRule(id: "mail.attachments", name: "邮件附件", category: .mailAttachments,
                    path: "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", minAgeDays: 90, grade: .caution,
                    note: "已下载的邮件附件；邮件本身仍在服务器或邮箱中。"),
        CleanupRule(id: "files.downloads", name: "下载中的大文件", category: .userFiles,
                    path: "~/Downloads", minAgeDays: 30, minSizeMB: 500, grade: .caution,
                    note: "30 天以上未修改、单文件 ≥ 500 MB；建议逐项确认。", scanMode: .recursiveFiles),
        CleanupRule(id: "files.desktop", name: "桌面大文件", category: .userFiles,
                    path: "~/Desktop", minAgeDays: 30, minSizeMB: 500, grade: .caution,
                    note: "30 天以上未修改、单文件 ≥ 500 MB。", scanMode: .recursiveFiles),
        CleanupRule(id: "files.documents", name: "文稿旧文件", category: .userFiles,
                    path: "~/Documents", minAgeDays: 365, minSizeMB: 100, grade: .caution,
                    note: "一年以上未修改、单文件 ≥ 100 MB。", scanMode: .recursiveFiles),
        CleanupRule(id: "files.movies", name: "影片大文件", category: .userFiles,
                    path: "~/Movies", minAgeDays: 90, minSizeMB: 1000, grade: .caution,
                    note: "90 天以上未修改、单文件 ≥ 1 GB。", scanMode: .recursiveFiles)
    ] + EcosystemRules.aggressiveOnly

    public static func rules(for preset: RulePreset) -> [CleanupRule] {
        switch preset {
        case .conservative: return conservative
        case .standard: return standard
        case .aggressive: return aggressive
        }
    }

    public static func configuration(for preset: RulePreset,
                                     protectedPaths: [String] = []) -> CleanupRulesConfiguration {
        CleanupRulesConfiguration(rules: rules(for: preset),
                                  protectedPaths: protectedPaths,
                                  appliedPreset: preset)
    }
}

// MARK: - 持久化与 JSON

public struct RulesStore {
    public enum Keys {
        public static let payload = "rules.payload"
    }

    private let defaults: UserDefaults
    private let home: URL

    public init(defaults: UserDefaults = .standard,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
    }

    public func load() -> CleanupRulesConfiguration {
        guard let data = defaults.data(forKey: Keys.payload),
              let configuration = try? JSONDecoder().decode(CleanupRulesConfiguration.self, from: data) else {
            return CleanupRuleCatalog.configuration(for: .standard)
        }
        return configuration
    }

    public func save(_ configuration: CleanupRulesConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Keys.payload)
    }

    public func reset() {
        defaults.removeObject(forKey: Keys.payload)
    }

    /// 导出：稳定排序 + 缩进，便于人工阅读与版本管理。
    /// 外层是带格式版本与导出时间的信封；`importJSON` 同时兼容旧版裸配置文件。
    public static func exportJSON(_ configuration: CleanupRulesConfiguration,
                                  appVersion: String = "") throws -> Data {
        let envelope = RulesExportEnvelope(appVersion: appVersion, configuration: configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// 解码规则文件：优先按新信封格式（含 formatVersion），失败后按旧版裸配置。
    /// 两种都不是则抛出原始解码错误，由调用方映射为 invalidJSON。
    static func decodeConfiguration(from data: Data) throws -> CleanupRulesConfiguration {
        let envelopeDecoder = JSONDecoder()
        envelopeDecoder.dateDecodingStrategy = .iso8601
        if let envelope = try? envelopeDecoder.decode(RulesExportEnvelope.self, from: data) {
            return envelope.configuration
        }
        return try JSONDecoder().decode(CleanupRulesConfiguration.self, from: data)
    }

    /// 导入：解码后逐条走 RuleValidator，有任何非法规则就整体拒绝并给出原因。
    public func importJSON(_ data: Data) throws -> CleanupRulesConfiguration {
        let configuration: CleanupRulesConfiguration
        do {
            configuration = try Self.decodeConfiguration(from: data)
        } catch {
            throw RuleImportError.invalidJSON
        }
        guard !configuration.rules.isEmpty else { throw RuleImportError.empty }
        for rule in configuration.rules {
            let verdict = RuleValidator.validate(rule, home: home,
                                                 protectedPaths: configuration.protectedPaths)
            if let reason = verdict.reason {
                throw RuleImportError.invalidRule(name: rule.name, reason: reason)
            }
        }
        var seen = Set<String>()
        let deduplicated = configuration.rules.map { rule -> CleanupRule in
            var copy = rule
            // 导入的规则不允许保留 safe 级；个人文件类强制 caution。
            copy.grade = Self.importedGrade(for: rule)
            if seen.contains(copy.id) { copy.id = UUID().uuidString }
            seen.insert(copy.id)
            return copy
        }
        return CleanupRulesConfiguration(rules: deduplicated,
                                         protectedPaths: configuration.protectedPaths,
                                         appliedPreset: configuration.appliedPreset)
    }

    /// 宽松导入：逐条校验，非法规则跳过并记录原因，而不是整份拒绝。
    /// 合并模式下与现有规则同路径的条目按重复跳过，不再重复计量。
    public func importRules(_ data: Data,
                            mode: RulesImportMode,
                            current: CleanupRulesConfiguration? = nil) throws -> RuleImportSummary {
        let source: CleanupRulesConfiguration
        do {
            source = try Self.decodeConfiguration(from: data)
        } catch {
            throw RuleImportError.invalidJSON
        }
        guard !source.rules.isEmpty else { throw RuleImportError.empty }

        var accepted: [CleanupRule] = []
        var rejected: [RejectedRule] = []
        var skippedDuplicates = 0
        var seenPaths = Set<String>()
        var seenIDs = Set<String>()

        if mode == .merge, let current {
            for rule in current.rules {
                seenIDs.insert(rule.id)
                if let normalized = RuleValidation.normalized(rule.path, home: home) {
                    seenPaths.insert(normalized)
                }
            }
        }

        for rule in source.rules {
            var candidate = rule
            candidate.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.name.isEmpty else {
                rejected.append(RejectedRule(name: "（未命名）", reason: "规则名称不能为空"))
                continue
            }
            let verdict = RuleValidator.validate(candidate, home: home,
                                                 protectedPaths: source.protectedPaths)
            guard verdict.isValid else {
                rejected.append(RejectedRule(name: candidate.name,
                                              reason: verdict.reason ?? "路径不合法"))
                continue
            }
            candidate.path = RuleValidation.normalized(candidate.path, home: home) ?? candidate.path
            // 导入的规则不允许保留 safe 级；个人文件类强制 caution。
            candidate.grade = Self.importedGrade(for: candidate)
            if seenPaths.contains(candidate.path) {
                skippedDuplicates += 1
                continue
            }
            if seenIDs.contains(candidate.id) { candidate.id = UUID().uuidString }
            seenIDs.insert(candidate.id)
            seenPaths.insert(candidate.path)
            accepted.append(candidate)
        }

        switch mode {
        case .replace:
            return RuleImportSummary(mode: .replace,
                                     acceptedRules: accepted,
                                     rejectedRules: rejected,
                                     skippedDuplicates: skippedDuplicates,
                                     protectedPaths: source.protectedPaths,
                                     appliedPreset: source.appliedPreset)
        case .merge:
            var mergedProtected = current?.protectedPaths ?? []
            for path in source.protectedPaths where !mergedProtected.contains(path) {
                mergedProtected.append(path)
            }
            return RuleImportSummary(mode: .merge,
                                     acceptedRules: accepted,
                                     rejectedRules: rejected,
                                     skippedDuplicates: skippedDuplicates,
                                     protectedPaths: mergedProtected,
                                     // 合并过就不再是一套纯预设。
                                     appliedPreset: nil)
        }
    }

    /// 导入时的安全等级归一化：不允许导入 safe（用户配置一律至少「建议」级），
    /// 个人文件类规则强制 caution（清理后可能无法重建）。
    static func importedGrade(for rule: CleanupRule) -> SafetyGrade {
        if rule.category == .userFiles { return .caution }
        return rule.grade == .safe ? .suggested : rule.grade
    }

    /// 保存前统一校验；返回第一条不合法原因。
    public func validate(_ configuration: CleanupRulesConfiguration) -> RuleValidation {
        for rule in configuration.rules {
            let verdict = RuleValidator.validate(rule, home: home,
                                                 protectedPaths: configuration.protectedPaths)
            if !verdict.isValid { return verdict }
        }
        for path in configuration.protectedPaths {
            let verdict = RuleValidator.validate(path: path, home: home)
            if !verdict.isValid { return verdict }
        }
        return .ok
    }
}

public enum RuleImportError: LocalizedError, Equatable {
    case invalidJSON
    case empty
    case invalidRule(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "不是有效的规则 JSON 文件"
        case .empty: return "规则文件里没有任何规则"
        case .invalidRule(let name, let reason): return "规则「\(name)」被拒绝：\(reason)"
        }
    }
}

// MARK: - 导出信封与导入摘要

/// 导出文件的外层信封：标明格式版本、导出时间与来源应用版本，
/// 便于用户辨认文件、后续演进格式时做兼容判断。
public struct RulesExportEnvelope: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var appVersion: String
    public var exportedAt: Date
    public var configuration: CleanupRulesConfiguration

    public init(formatVersion: Int = RulesExportEnvelope.formatVersion,
                appVersion: String,
                exportedAt: Date = Date(),
                configuration: CleanupRulesConfiguration) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.configuration = configuration
    }
}

/// 导入时被跳过的单条规则与其原因。
public struct RejectedRule: Codable, Hashable, Sendable {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// 导入模式：整套替换，或合并进现有规则。
public enum RulesImportMode: String, CaseIterable, Sendable {
    /// 用文件内容整套替换当前规则与保护清单。
    case replace
    /// 把文件里的规则并入现有清单；同路径重复的条目跳过。
    case merge

    public var title: String {
        switch self {
        case .replace: return "替换全部"
        case .merge: return "合并到现有规则"
        }
    }
}

/// 宽松导入的结果摘要：接受了什么、拒绝了什么、跳过了几条重复。
public struct RuleImportSummary: Sendable, Equatable {
    public var mode: RulesImportMode
    public var acceptedRules: [CleanupRule]
    public var rejectedRules: [RejectedRule]
    /// 与现有规则（或文件内部）路径重复而跳过的条数。
    public var skippedDuplicates: Int
    public var protectedPaths: [String]
    public var appliedPreset: RulePreset?

    public init(mode: RulesImportMode,
                acceptedRules: [CleanupRule],
                rejectedRules: [RejectedRule],
                skippedDuplicates: Int,
                protectedPaths: [String],
                appliedPreset: RulePreset?) {
        self.mode = mode
        self.acceptedRules = acceptedRules
        self.rejectedRules = rejectedRules
        self.skippedDuplicates = skippedDuplicates
        self.protectedPaths = protectedPaths
        self.appliedPreset = appliedPreset
    }

    public var hasFindings: Bool { !rejectedRules.isEmpty || skippedDuplicates > 0 }

    /// 面向用户的一句话摘要。
    public var message: String {
        var parts: [String] = ["已导入 \(acceptedRules.count) 条规则"]
        if skippedDuplicates > 0 {
            parts.append("跳过 \(skippedDuplicates) 条重复路径")
        }
        if !rejectedRules.isEmpty {
            let names = rejectedRules.prefix(3).map(\.name).joined(separator: "、")
            let suffix = rejectedRules.count > 3 ? " 等 \(rejectedRules.count) 条" : ""
            parts.append("拒绝 \(names)\(suffix)（\(rejectedRules[0].reason)）")
        }
        switch mode {
        case .replace: parts.append("（替换模式）")
        case .merge: parts.append("（合并模式）")
        }
        return parts.joined(separator: " · ")
    }
}
