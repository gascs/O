import XCTest
@testable import MoleLiteCore

final class CleanupRulesTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        // 用临时目录模拟主目录，避免测试写真实 $HOME（沙箱下也没有写入权限）。
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("O-RulesTests-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
    }

    func testPresetHierarchyAndEnabledCounts() {
        // 具体数量随规则库演进（生态缓存规则会持续补充），这里只校验层级关系与约束；
        // 发布前的准确数量由集成侧核对。
        XCTAssertEqual(CleanupRuleCatalog.conservative.count, 5)
        XCTAssertGreaterThan(CleanupRuleCatalog.standard.count, CleanupRuleCatalog.conservative.count)
        XCTAssertGreaterThan(CleanupRuleCatalog.aggressive.count, CleanupRuleCatalog.standard.count)
        XCTAssertTrue(CleanupRuleCatalog.aggressive.allSatisfy { rule in
            rule.category != .userFiles || rule.grade == .caution
        })
        XCTAssertEqual(Set(CleanupRuleCatalog.aggressive.map(\.id)).count,
                       CleanupRuleCatalog.aggressive.count)
    }

    func testAllPresetPathsPassValidation() {
        for preset in RulePreset.allCases {
            for rule in CleanupRuleCatalog.rules(for: preset) {
                let verdict = RuleValidator.validate(rule, home: tempHome)
                XCTAssertTrue(verdict.isValid, "\(preset.title) · \(rule.name)：\(verdict.reason ?? "")")
            }
        }
    }

    func testValidatorRejectsUnsafePaths() {
        let cases: [(String, String)] = [
            ("/System/Library/Caches", "系统"),
            ("/Library/Caches", "系统"),
            ("/tmp/outside", "系统"),
            ("", "非法路径"),
            ("relative/path", "非法路径"),
            ("~/Library", "范围过大"),
            ("~", "主目录")
        ]
        for (path, expected) in cases {
            let verdict = RuleValidator.validate(path: path, home: tempHome)
            XCTAssertFalse(verdict.isValid, "应拒绝：\(path)")
            XCTAssertTrue(verdict.reason?.contains(expected) == true,
                          "\(path) 的原因应包含「\(expected)」，实际：\(verdict.reason ?? "nil")")
        }
    }

    func testValidatorAcceptsTrashAndDownloadsRoots() {
        let homePath = tempHome.path
        let trash = RuleValidator.validate(path: homePath + "/.Trash", home: tempHome)
        let downloads = RuleValidator.validate(path: homePath + "/Downloads", home: tempHome)
        XCTAssertTrue(trash.isValid)
        XCTAssertTrue(downloads.isValid)
    }

    func testProtectedPathBlocksRule() {
        let protectedPath = tempHome.appendingPathComponent("Documents/合同").path
        let verdict = RuleValidator.validate(path: protectedPath, home: tempHome,
                                             protectedPaths: [protectedPath])
        XCTAssertFalse(verdict.isValid)
        XCTAssertTrue(verdict.reason?.contains("受保护清单") == true)
    }

    func testRecursiveRuleNeedsAtLeastOneCondition() {
        let rule = CleanupRule(name: "递归无门槛", category: .userFiles,
                               path: tempHome.appendingPathComponent("Downloads").path,
                               scanMode: .recursiveFiles)
        let verdict = RuleValidator.validate(rule, home: tempHome)
        XCTAssertFalse(verdict.isValid)
        XCTAssertTrue(verdict.reason?.contains("至少设置一项条件") == true)
    }

    func testPersistenceRoundTrip() throws {
        let suiteName = "O-RulesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RulesStore(defaults: defaults, home: tempHome)
        var configuration = CleanupRuleCatalog.configuration(for: .standard)
        configuration.protectedPaths = [tempHome.appendingPathComponent("Documents").path]
        store.save(configuration)

        let loaded = store.load()
        XCTAssertEqual(loaded.rules.map(\.id), configuration.rules.map(\.id))
        XCTAssertEqual(loaded.protectedPaths, configuration.protectedPaths)
        XCTAssertEqual(loaded.appliedPreset, .standard)
    }

    func testJSONExportImportRoundTrip() throws {
        let store = RulesStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "O-RulesJSON-\(UUID().uuidString)")),
                               home: tempHome)
        var configuration = CleanupRuleCatalog.configuration(for: .aggressive)
        configuration.protectedPaths = [tempHome.appendingPathComponent("ProtectedDir").path]

        let data = try RulesStore.exportJSON(configuration)
        let imported = try store.importJSON(data)
        XCTAssertEqual(imported.rules.count, configuration.rules.count)
        XCTAssertEqual(imported.rules.map(\.id), configuration.rules.map(\.id))
        XCTAssertEqual(imported.protectedPaths, configuration.protectedPaths)
    }

    func testImportRejectsInvalidJSONAndUnsafeRule() throws {
        let store = RulesStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "O-RulesBad-\(UUID().uuidString)")),
                               home: tempHome)
        XCTAssertThrowsError(try store.importJSON(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? RuleImportError, .invalidJSON)
        }

        let unsafeRule = CleanupRule(name: "系统目录", category: .systemCaches,
                                     path: "/System/Library/Caches")
        let data = try JSONEncoder().encode(CleanupRulesConfiguration(rules: [unsafeRule]))
        XCTAssertThrowsError(try store.importJSON(data)) { error in
            guard case .invalidRule(let name, _) = (error as? RuleImportError) else {
                return XCTFail("应抛出 invalidRule，实际：\(error)")
            }
            XCTAssertEqual(name, "系统目录")
        }
    }

    func testStoreValidateReportsFirstInvalidRule() {
        let store = RulesStore(home: tempHome)
        let bad = CleanupRule(name: "越界", category: .userCaches, path: "/tmp/越界")
        let verdict = store.validate(CleanupRulesConfiguration(rules: [bad]))
        XCTAssertFalse(verdict.isValid)
        XCTAssertNotNil(verdict.reason)
    }

    func testRuleScannerAppliesSizeAndAgeFilters() throws {
        let caches = tempHome.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let bigURL = caches.appendingPathComponent("big.bin")
        let smallURL = caches.appendingPathComponent("small.txt")
        try Data(repeating: 0, count: 3_000_000).write(to: bigURL)
        try Data(repeating: 0, count: 1_000).write(to: smallURL)

        let oldDate = Calendar.current.date(byAdding: .day, value: -40, to: Date())!
        try FileManager.default.setAttributes([.modificationDate: oldDate],
                                              ofItemAtPath: bigURL.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate],
                                              ofItemAtPath: smallURL.path)

        var rule = CleanupRule(name: "缓存", category: .userCaches,
                               path: caches.path, minAgeDays: 30, minSizeMB: 1)
        rule.isEnabled = true
        let scanner = CleanupRuleScanner(home: tempHome, includeHidden: true)
        let report = try scanner.scan(rules: [rule], protectedPaths: [])
        XCTAssertEqual(report.outcomes.count, 1)
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertNil(outcome.skippedReason)
        XCTAssertEqual(outcome.items.count, 1)
        XCTAssertGreaterThanOrEqual(outcome.bytes, 1_048_576)
    }

    func testRuleScannerSkipsMissingPathWithReason() throws {
        let rule = CleanupRule(name: "不存在的缓存", category: .docker,
                               path: tempHome.appendingPathComponent("NoDocker").path)
        let scanner = CleanupRuleScanner(home: tempHome, includeHidden: true)
        let report = try scanner.scan(rules: [rule], protectedPaths: [])
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertNotNil(outcome.skippedReason)
        XCTAssertEqual(report.skippedRuleCount, 1)
    }

    func testRuleScannerRespectsProtectedPaths() throws {
        let cache = tempHome.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let keep = cache.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: keep.appendingPathComponent("data.bin"))

        let rule = CleanupRule(name: "缓存", category: .userCaches, path: cache.path)
        let scanner = CleanupRuleScanner(home: tempHome, includeHidden: true)
        let report = try scanner.scan(rules: [rule], protectedPaths: [keep.path])
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertTrue(outcome.items.isEmpty)
    }

    func testParentRuleSkipsNestedRuleRoot() throws {
        let caches = tempHome.appendingPathComponent("Library/Caches")
        let nested = caches.appendingPathComponent("npm")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 2_000_000).write(to: nested.appendingPathComponent("blob"))

        let parent = CleanupRule(name: "全部缓存", category: .userCaches, path: caches.path)
        let child = CleanupRule(name: "npm", category: .packageCaches, path: nested.path)
        let scanner = CleanupRuleScanner(home: tempHome, includeHidden: true)
        let report = try scanner.scan(rules: [parent, child], protectedPaths: [])
        let parentOutcome = try XCTUnwrap(report.outcome(for: parent.id))
        let childOutcome = try XCTUnwrap(report.outcome(for: child.id))
        XCTAssertTrue(parentOutcome.items.allSatisfy { !$0.url.path.contains("/npm/") })
        XCTAssertEqual(childOutcome.items.count, 1)
    }

    // MARK: - 导出信封与宽松导入

    func testExportEnvelopeCarriesMetadata() throws {
        let configuration = CleanupRuleCatalog.configuration(for: .conservative)
        let data = try RulesStore.exportJSON(configuration, appVersion: "0.4.0")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"formatVersion\""), "导出应为信封格式")
        XCTAssertTrue(text.contains("\"appVersion\" : \"0.4.0\""))
        XCTAssertTrue(text.contains("\"exportedAt\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(RulesExportEnvelope.self, from: data)
        XCTAssertEqual(envelope.formatVersion, RulesExportEnvelope.formatVersion)
        XCTAssertEqual(envelope.appVersion, "0.4.0")
        XCTAssertEqual(envelope.configuration.rules.count, configuration.rules.count)
    }

    func testImportAcceptsLegacyBareConfiguration() throws {
        let store = RulesStore(home: tempHome)
        // 旧版导出格式：没有信封的裸配置对象。
        let bare = CleanupRulesConfiguration(rules: [
            CleanupRule(name: "缓存", category: .userCaches,
                        path: tempHome.appendingPathComponent("Library/Caches").path)
        ])
        let data = try JSONEncoder().encode(bare)
        let imported = try store.importJSON(data)
        XCTAssertEqual(imported.rules.count, 1)
        XCTAssertEqual(imported.rules.first?.name, "缓存")
    }

    func testLenientImportSkipsInvalidRulesWithSummary() throws {
        let store = RulesStore(home: tempHome)
        let good = CleanupRule(name: "缓存", category: .userCaches,
                               path: tempHome.appendingPathComponent("Library/Caches").path)
        let bad = CleanupRule(name: "系统目录", category: .systemCaches,
                              path: "/System/Library/Caches")
        let unnamed = CleanupRule(name: "   ", category: .userCaches,
                                  path: tempHome.appendingPathComponent("Downloads").path,
                                  minSizeMB: 100, scanMode: .recursiveFiles)
        let source = CleanupRulesConfiguration(rules: [good, bad, unnamed])
        let data = try RulesStore.exportJSON(source)

        let summary = try store.importRules(data, mode: .replace)
        XCTAssertEqual(summary.acceptedRules.count, 1)
        XCTAssertEqual(summary.acceptedRules.first?.name, "缓存")
        XCTAssertEqual(summary.rejectedRules.count, 2)
        XCTAssertTrue(summary.rejectedRules.contains { $0.reason.contains("受保护") || $0.reason.contains("系统") })
        XCTAssertTrue(summary.rejectedRules.contains { $0.reason == "规则名称不能为空" })
        XCTAssertTrue(summary.hasFindings)
    }

    func testValidatorRejectsSensitiveDirectories() {
        let cases = [
            tempHome.appendingPathComponent(".ssh").path,
            tempHome.appendingPathComponent(".ssh/id_ed25519").path,
            tempHome.appendingPathComponent("Library/Keychains").path,
            tempHome.appendingPathComponent("Library/Messages/chat.db").path,
            tempHome.appendingPathComponent("Library/Mail").path,
            tempHome.appendingPathComponent("Library/Safari").path,
            tempHome.appendingPathComponent("Library/Cookies").path,
            tempHome.appendingPathComponent("Library/Accounts").path,
            tempHome.appendingPathComponent("Library/Preferences").path,
            tempHome.appendingPathComponent("Library/Preferences/com.apple.finder.plist").path,
            tempHome.appendingPathComponent(".gnupg").path,
            tempHome.appendingPathComponent(".aws").path,
            tempHome.appendingPathComponent(".kube").path,
            tempHome.appendingPathComponent(".config").path,
            tempHome.appendingPathComponent(".docker").path
        ]
        for path in cases {
            let verdict = RuleValidator.validate(path: path, home: tempHome)
            XCTAssertFalse(verdict.isValid, "敏感目录不应通过校验：\(path)")
            XCTAssertTrue(verdict.reason?.contains("敏感目录") == true,
                          "\(path) 的拒绝原因应说明敏感目录，实际：\(verdict.reason ?? "nil")")
        }
    }

    func testValidatorKeepsNormalCachePathsAllowedAfterSensitivityCheck() {
        let cases = [
            tempHome.appendingPathComponent("Library/Caches").path,
            tempHome.appendingPathComponent("Library/Caches/com.example.app").path,
            tempHome.appendingPathComponent(".npm/_cacache").path,
            tempHome.appendingPathComponent(".cache/bazel").path,
            tempHome.appendingPathComponent("Library/Logs").path
        ]
        for path in cases {
            XCTAssertTrue(RuleValidator.validate(path: path, home: tempHome).isValid, "常规缓存路径应允许：\(path)")
        }
    }

    func testImportDowngradesSafeGradesAndForcesCautionForUserFiles() throws {
        let store = RulesStore(home: tempHome)
        let safeCache = CleanupRule(name: "安全缓存", category: .userCaches,
                                    path: tempHome.appendingPathComponent("Library/Caches").path,
                                    grade: .safe)
        let safeUserFile = CleanupRule(name: "个人文件", category: .userFiles,
                                       path: tempHome.appendingPathComponent("Downloads").path,
                                       grade: .safe)
        let source = CleanupRulesConfiguration(rules: [safeCache, safeUserFile])
        let data = try RulesStore.exportJSON(source)

        let imported = try store.importJSON(data)
        XCTAssertEqual(imported.rules.first?.grade, .suggested, "导入后不允许保留 safe 等级")
        XCTAssertEqual(imported.rules.last?.grade, .caution, "个人文件类规则导入后必须降为 caution")

        let summary = try store.importRules(data, mode: .replace)
        XCTAssertEqual(summary.acceptedRules.first?.grade, .suggested)
        XCTAssertEqual(summary.acceptedRules.last?.grade, .caution)
    }

    func testMergeImportDeduplicatesPathsAndMergesProtectedPaths() throws {
        let store = RulesStore(home: tempHome)
        var existing = CleanupRuleCatalog.configuration(for: .standard)
        existing.protectedPaths = [tempHome.appendingPathComponent("Documents").path]

        // 文件里一条与现有同路径、一条全新路径、一条非法。
        let samePath = CleanupRule(name: "缓存副本", category: .userCaches,
                                   path: existing.rules[0].path)
        let fresh = CleanupRule(name: "新位置", category: .userCaches,
                                 path: tempHome.appendingPathComponent("FreshCache").path)
        let invalid = CleanupRule(name: "越界", category: .systemCaches, path: "/tmp/越界")
        let incoming = CleanupRulesConfiguration(
            rules: [samePath, fresh, invalid],
            protectedPaths: [tempHome.appendingPathComponent("Movies").path])

        let summary = try store.importRules(RulesStore.exportJSON(incoming),
                                            mode: .merge,
                                            current: existing)
        XCTAssertEqual(summary.acceptedRules.count, 1, "同路径与非法条目都应被跳过")
        XCTAssertEqual(summary.acceptedRules.first?.name, "新位置")
        XCTAssertEqual(summary.skippedDuplicates, 1)
        XCTAssertEqual(summary.rejectedRules.count, 1)
        XCTAssertEqual(summary.appliedPreset, nil, "合并后不再是纯预设")
        // 保护清单是并集。
        XCTAssertEqual(Set(summary.protectedPaths),
                       Set(existing.protectedPaths + incoming.protectedPaths))
    }
}
