import XCTest
@testable import MoleLiteCore

final class RecommendationTests: XCTestCase {
    private func item(_ path: String, size: Int64) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), byteSize: size, isDirectory: false)
    }

    func testGradesFollowCategoryRules() {
        XCTAssertEqual(RecommendationEngine.baseGrade(for: .userCaches), .safe)
        XCTAssertEqual(RecommendationEngine.baseGrade(for: .xcode), .safe)
        XCTAssertEqual(RecommendationEngine.baseGrade(for: .logs), .suggested)
        XCTAssertEqual(RecommendationEngine.baseGrade(for: .trash), .caution)
        XCTAssertEqual(RecommendationEngine.baseGrade(for: .largeFiles), .caution)
    }

    func testHugeItemEscalatesToCaution() {
        let huge = item("/tmp/demo/huge", size: RecommendationEngine.itemCautionThreshold)
        XCTAssertEqual(RecommendationEngine.grade(for: huge, in: .userCaches), .caution)
        XCTAssertTrue(RecommendationEngine.oneClickItemIDs(in: ScanReport(
            results: [ScanCategoryResult(category: .userCaches, items: [huge], totalBytes: huge.byteSize)],
            scannedItemCount: 1, duration: 0
        )).isEmpty)
    }

    func testGroupsSplitsIntoThreeLevels() {
        let cache = item("/tmp/demo/cache", size: 1_000)
        let log = item("/tmp/demo/app.log", size: 500)
        let trash = item("/tmp/demo/trash", size: 200)
        let report = ScanReport(results: [
            ScanCategoryResult(category: .userCaches, items: [cache], totalBytes: 1_000),
            ScanCategoryResult(category: .logs, items: [log], totalBytes: 500),
            ScanCategoryResult(category: .trash, items: [trash], totalBytes: 200)
        ], scannedItemCount: 3, duration: 0)

        let groups = RecommendationEngine.groups(in: report)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first { $0.grade == .safe }?.itemIDs, [cache.id])
        XCTAssertEqual(groups.first { $0.grade == .suggested }?.itemIDs, [log.id])
        XCTAssertEqual(groups.first { $0.grade == .caution }?.itemIDs, [trash.id])
        XCTAssertEqual(RecommendationEngine.oneClickItemIDs(in: report).sorted(), [cache.id, log.id].sorted())
    }
}

final class ScanReportExporterTests: XCTestCase {
    private func makeReport(name: String = "a,b\"c") -> ScanReport {
        let item = ScanItem(url: URL(fileURLWithPath: "/tmp/demo/x"), name: name, byteSize: 1024, isDirectory: false)
        return ScanReport(results: [
            ScanCategoryResult(category: .userCaches, items: [item], totalBytes: 1024)
        ], scannedItemCount: 1, duration: 0.5)
    }

    func testCSVEscapesSpecialCharacters() {
        let csv = ScanReportExporter.csv(makeReport())
        XCTAssertTrue(csv.hasPrefix("分类,名称,路径,字节数"))
        XCTAssertTrue(csv.contains("\"a,b\"\"c\""))
        XCTAssertTrue(csv.contains("1 KB"))
    }

    func testCSVRowsMatchItems() {
        let csv = ScanReportExporter.csv(makeReport(name: "plain"))
        XCTAssertEqual(csv.split(separator: "\n").count, 2)
    }

    func testMarkdownStructure() {
        let markdown = ScanReportExporter.markdown(makeReport())
        XCTAssertTrue(markdown.contains("# O 扫描报告"))
        XCTAssertTrue(markdown.contains("## 用户缓存"))
        XCTAssertTrue(markdown.contains("| 名称 | 大小 | 修改时间 | 路径 |"))
    }

    func testMarkdownEscapesPipe() {
        let markdown = ScanReportExporter.markdown(makeReport(name: "a|b"))
        XCTAssertTrue(markdown.contains("a\\|b"))
    }
}

final class DuplicateFinderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MoleLiteDup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    private func makeFile(_ relative: String, bytes: Int, fill: UInt8) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: fill, count: bytes))
    }

    func testFindsIdenticalFilesOnly() async throws {
        try makeFile("one/photo.bin", bytes: 1_048_576, fill: 7)
        try makeFile("two/photo-copy.bin", bytes: 1_048_576, fill: 7)
        try makeFile("three/photo-other.bin", bytes: 1_048_576, fill: 9)
        try makeFile("small.txt", bytes: 10_240, fill: 1)

        let groups = try await DuplicateFinder(roots: [root], minFileSize: 524_288).find()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.files.count, 2)
        XCTAssertFalse(groups.first?.files.contains { $0.name == "photo-other.bin" } ?? true)
        XCTAssertFalse(groups.first?.files.contains { $0.name == "small.txt" } ?? true)
        if let group = groups.first {
            XCTAssertEqual(group.reclaimableBytes, group.fileSize)
        }
    }

    func testHashIsStableForSameContentAndDiffersOtherwise() throws {
        try makeFile("a.bin", bytes: 4096, fill: 3)
        try makeFile("b.bin", bytes: 4096, fill: 4)
        let a = try XCTUnwrap(DuplicateFinder.hash(root.appendingPathComponent("a.bin"), limitBytes: nil))
        let b = try XCTUnwrap(DuplicateFinder.hash(root.appendingPathComponent("b.bin"), limitBytes: nil))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }

    func testCancelledFindThrows() {
        let cancellation = ScanCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try DuplicateFinder.scan(roots: [root], minFileSize: 1,
                                                      maxCandidates: 10, cancellation: cancellation,
                                                      progress: { _ in }))
    }
}

final class HistoryStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "MoleLiteHistory-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    func testEntriesSortedAndFreedTotal() {
        let store = HistoryStore(defaults: defaults)
        store.append(HistoryEntry(date: Date(timeIntervalSince1970: 100), kind: .clean, bytes: 4096, itemCount: 2, detail: "a"))
        store.append(HistoryEntry(date: Date(timeIntervalSince1970: 200), kind: .scan, bytes: 8192, itemCount: 4, detail: "b"))
        XCTAssertEqual(store.load().first?.kind, .scan)
        XCTAssertEqual(store.totalFreedBytes, 4096)
        XCTAssertEqual(store.recent(1).count, 1)
    }

    func testLimitAndClear() {
        let store = HistoryStore(defaults: defaults)
        for index in 0..<5 {
            store.append(HistoryEntry(date: Date(timeIntervalSince1970: Double(index)),
                                      kind: .clean, bytes: 1, itemCount: 1, detail: "\(index)"))
        }
        let limited = HistoryStore(defaults: defaults, limit: 3)
        XCTAssertEqual(limited.load().count, 3)
        limited.clear()
        XCTAssertTrue(limited.load().isEmpty)
    }

    func testTrendReplacesSameDayPoint() {
        let store = DiskTrendStore(defaults: defaults)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(usedBytes: 1000, totalBytes: 2000, on: day)
        store.record(usedBytes: 1200, totalBytes: 2000, on: day.addingTimeInterval(3600))
        XCTAssertEqual(store.points().count, 1)
        XCTAssertEqual(store.points().first?.usedBytes, 1200)
        XCTAssertEqual(store.points().first?.usedFraction, 0.6)
    }
}

final class LaunchItemServiceTests: XCTestCase {
    func testParsePlistFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoleLiteLaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("com.example.agent.plist")
        let plist: [String: Any] = [
            "Label": "com.example.agent",
            "ProgramArguments": ["/usr/bin/true"],
            "RunAtLoad": true,
            "Disabled": false
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)

        let item = LaunchItemService().parse(url, scope: .userAgent)
        XCTAssertEqual(item.label, "com.example.agent")
        XCTAssertEqual(item.program, "/usr/bin/true")
        XCTAssertTrue(item.runAtLoad)
        XCTAssertEqual(item.statusText, "登录时启动")
        XCTAssertTrue(item.scope.isUserEditable)
        XCTAssertFalse(LaunchScope.systemDaemon.isUserEditable)
    }
}

final class AppInventoryServiceTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("MoleLiteApps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
    }

    func testLeftoversCoverNewKinds() throws {
        let cache = home.appendingPathComponent("Library/Caches/com.example.app")
        let group = home.appendingPathComponent("Library/Group Containers/group.com.example.app")
        let preferences = home.appendingPathComponent("Library/Preferences/com.example.app.plist")
        for directory in [cache, group] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("x.bin").path,
                                           contents: Data(count: 1024))
        }
        try FileManager.default.createDirectory(at: preferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: preferences.path, contents: Data(count: 128))

        let items = AppInventoryService(homeDirectory: home)
            .leftoverItems(bundleIdentifier: "com.example.app", appName: "Example")
        XCTAssertTrue(items.contains { $0.kind == .cache })
        XCTAssertTrue(items.contains { $0.kind == .groupContainer })
        XCTAssertTrue(items.contains { $0.kind == .preference })
        XCTAssertEqual(items.map(\.byteSize), items.map(\.byteSize).sorted(by: >))
    }
}

final class NetworkSamplerTests: XCTestCase {
    func testCountersAreReadable() {
        let totals = NetworkSampler.counterTotals()
        XCTAssertNotNil(totals)
        XCTAssertGreaterThanOrEqual(totals?.received ?? -1, 0)
        XCTAssertGreaterThanOrEqual(totals?.sent ?? -1, 0)
    }

    func testConsecutiveSamplesProduceNonNegativeRates() {
        var sampler = NetworkSampler()
        XCTAssertNotNil(sampler.sample(at: Date(timeIntervalSince1970: 1000)))
        let second = sampler.sample(at: Date(timeIntervalSince1970: 1001))
        XCTAssertGreaterThanOrEqual(second?.downBytesPerSecond ?? -1, 0)
        XCTAssertGreaterThanOrEqual(second?.upBytesPerSecond ?? -1, 0)
    }
}

final class LoginItemStateTests: XCTestCase {
    func testRawStatusMapping() {
        XCTAssertEqual(LoginItemState.map(rawStatus: 0), .notRegistered)
        XCTAssertEqual(LoginItemState.map(rawStatus: 1), .enabled)
        XCTAssertEqual(LoginItemState.map(rawStatus: 2), .requiresApproval)
        XCTAssertEqual(LoginItemState.map(rawStatus: 3), .notFound)
    }

    func testUnknownStatusReportsFailureHonestly() {
        guard case .failed(let message) = LoginItemState.map(rawStatus: 42) else {
            return XCTFail("未知状态必须映射为 failed")
        }
        XCTAssertTrue(message.contains("42"))
        XCTAssertFalse(LoginItemState.map(rawStatus: 42).isEnabled)
    }

    func testOnlyEnabledCountsAsOn() {
        XCTAssertTrue(LoginItemState.enabled.isEnabled)
        XCTAssertFalse(LoginItemState.notRegistered.isEnabled)
        XCTAssertFalse(LoginItemState.requiresApproval.isEnabled)
        XCTAssertFalse(LoginItemState.notFound.isEnabled)
        XCTAssertFalse(LoginItemState.failed("x").isEnabled)
    }

    func testApprovalAndFailureNeedSystemSettings() {
        XCTAssertTrue(LoginItemState.requiresApproval.needsSystemSettings)
        XCTAssertTrue(LoginItemState.failed("x").needsSystemSettings)
        XCTAssertFalse(LoginItemState.notRegistered.needsSystemSettings)
        XCTAssertFalse(LoginItemState.enabled.needsSystemSettings)
    }

    func testUnbundledExecutableRefusesRegistration() {
        let controller = LoginItemController()
        guard !controller.isRunningFromAppBundle else { return }
        XCTAssertThrowsError(try controller.setEnabled(true)) { error in
            XCTAssertTrue(error.localizedDescription.contains(".app"))
        }
    }
}

final class WindowCloseBehaviorTests: XCTestCase {
    private let suiteName = "O-window-close-\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        makeDefaults().removePersistentDomain(forName: suiteName)
    }

    func testDefaultsToKeepInMenuBar() {
        XCTAssertEqual(WindowCloseBehavior.current(from: makeDefaults()), .keepInMenuBar)
    }

    func testQuitAppRoundTrip() {
        makeDefaults().set(WindowCloseBehavior.quitApp.rawValue,
                           forKey: AppBehaviorSettings.Keys.windowCloseBehavior)
        XCTAssertEqual(WindowCloseBehavior.current(from: makeDefaults()), .quitApp)
    }

    func testInvalidValueFallsBackToKeepInMenuBar() {
        makeDefaults().set("deleteEverything", forKey: AppBehaviorSettings.Keys.windowCloseBehavior)
        XCTAssertEqual(WindowCloseBehavior.current(from: makeDefaults()), .keepInMenuBar)
    }
}

final class InstanceGuardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("O-instance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSecondInstanceIsRejectedAndReleasedLockCanBeReacquired() {
        let first = InstanceGuard(directory: directory)
        XCTAssertTrue(first.acquire())
        XCTAssertEqual(first.heldPID, Int(getpid()))

        let second = InstanceGuard(directory: directory)
        XCTAssertFalse(second.acquire())

        first.release()
        let third = InstanceGuard(directory: directory)
        XCTAssertTrue(third.acquire())
        third.release()
    }

    func testActivationNotificationNameIsStable() {
        XCTAssertEqual(InstanceGuard.activationNotificationName, "com.o.app.activate-window")
    }
}

final class ScanSettingsPreferenceTests: XCTestCase {
    private let suite = UserDefaults(suiteName: "MoleLitePrefs")!

    override func setUp() {
        suite.removePersistentDomain(forName: "MoleLitePrefs")
    }

    func testMenuBarStyleDefaultsAndRoundTrip() {
        XCTAssertEqual(ScanSettings.menuBarStyle(from: suite), .iconAndPercent)
        suite.set(MenuBarDisplayStyle.icon.rawValue, forKey: ScanSettings.Keys.menuBarDisplay)
        XCTAssertEqual(ScanSettings.menuBarStyle(from: suite), .icon)
    }

    func testRefreshIntervalAndDuplicateSizeAreClamped() {
        suite.set(0, forKey: ScanSettings.Keys.menuBarRefreshSeconds)
        XCTAssertEqual(ScanSettings.menuBarRefreshInterval(from: suite), 1)
        suite.set(999, forKey: ScanSettings.Keys.menuBarRefreshSeconds)
        XCTAssertEqual(ScanSettings.menuBarRefreshInterval(from: suite), 60)

        suite.set(0, forKey: ScanSettings.Keys.duplicateMinSizeMB)
        XCTAssertEqual(ScanSettings.duplicateMinSizeMB(from: suite), 1)
        suite.set(9000, forKey: ScanSettings.Keys.duplicateMinSizeMB)
        XCTAssertEqual(ScanSettings.duplicateMinSizeMB(from: suite), 500)
    }
}
