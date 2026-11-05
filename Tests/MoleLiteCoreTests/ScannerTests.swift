import XCTest
@testable import MoleLiteCore

final class ScannerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("MoleLiteScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
        tempHome = nil
    }

    @discardableResult
    private func makeFile(_ relative: String, bytes: Int) throws -> URL {
        let url = tempHome.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        return url
    }

    func testCacheScanAggregatesByTopLevelFolder() async throws {
        try makeFile("Library/Caches/AppA/a.bin", bytes: 1_048_576)
        try makeFile("Library/Caches/AppA/b.bin", bytes: 1_048_576)
        try makeFile("Library/Caches/AppB/c.bin", bytes: 524_288)

        let report = try await Scanner(homeDirectory: tempHome, settings: ScanSettings()).scan(categories: [.userCaches])
        let result = try XCTUnwrap(report.result(for: .userCaches))

        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items.first?.name, "AppA", "结果应按体积降序")
        XCTAssertGreaterThanOrEqual(result.totalBytes, 2_621_440)
    }

    func testHiddenItemsAreExcludedByDefault() async throws {
        try makeFile("Library/Caches/AppA/visible.bin", bytes: 1_048_576)
        try makeFile("Library/Caches/AppA/.hidden.bin", bytes: 1_048_576)

        let plain = try await Scanner(homeDirectory: tempHome, settings: ScanSettings(includeHiddenItems: false))
            .scan(categories: [.userCaches])
        let withHidden = try await Scanner(homeDirectory: tempHome, settings: ScanSettings(includeHiddenItems: true))
            .scan(categories: [.userCaches])

        XCTAssertEqual(plain.totalBytes, 1_048_576)
        XCTAssertEqual(withHidden.totalBytes, 2_097_152)
    }

    func testLargeFileThresholdFilters() async throws {
        try makeFile("Downloads/big.dat", bytes: 2_097_152)
        try makeFile("Downloads/small.dat", bytes: 102_400)

        let report = try await Scanner(homeDirectory: tempHome, settings: ScanSettings(largeFileThresholdMB: 1))
            .scan(categories: [.largeFiles])
        let result = try XCTUnwrap(report.result(for: .largeFiles))

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.name, "big.dat")
        XCTAssertEqual(result.totalBytes, 2_097_152)
    }

    func testMissingRootProducesMessage() async throws {
        let report = try await Scanner(homeDirectory: tempHome).scan(categories: [.logs])
        let result = try XCTUnwrap(report.result(for: .logs))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNotNil(result.message)
    }

    func testXcodeTargetsCoverage() {
        let targets = Scanner(homeDirectory: tempHome).targets(for: [.xcode])
        XCTAssertEqual(targets.count, 4)
        XCTAssertTrue(targets.allSatisfy { $0.category == .xcode })
    }

    func testCancelledScanThrows() async {
        let cancellation = ScanCancellation()
        cancellation.cancel()
        do {
            _ = try await Scanner(homeDirectory: tempHome).scan(categories: [.userCaches], cancellation: cancellation)
            XCTFail("应抛出取消错误")
        } catch let error as ScanError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testSpecificRootsAreNotDoubleCountedAcrossCategories() async throws {
        // ~/Library/Caches 是 userCaches 的根，但 Homebrew / LaunchServices 又分别是
        // packageCaches / systemCaches 的根：扫描多个分类时不能重复统计。
        try makeFile("Library/Caches/com.example.app/cache.bin", bytes: 1_048_576)
        try makeFile("Library/Caches/Homebrew/downloads.tmp", bytes: 524_288)
        try makeFile("Library/Caches/com.apple.LaunchServices/ls.bin", bytes: 262_144)

        let report = try await Scanner(homeDirectory: tempHome, settings: ScanSettings())
            .scan(categories: [.userCaches, .packageCaches, .systemCaches])

        let user = try XCTUnwrap(report.result(for: .userCaches))
        XCTAssertEqual(user.items.count, 1, "被更具体 root 覆盖的子目录不应出现在 userCaches 中")
        XCTAssertEqual(user.items.first?.name, "com.example.app")

        // packageCaches / systemCaches 的 root 就是 Homebrew、com.apple.LaunchServices 本身，
        // 所以条目是 root 下的内容而不是 root 目录。
        let package = try XCTUnwrap(report.result(for: .packageCaches))
        XCTAssertEqual(package.totalBytes, 524_288)

        let system = try XCTUnwrap(report.result(for: .systemCaches))
        XCTAssertEqual(system.totalBytes, 262_144)

        // 三个分类合计应等于真实占用之和，不能把同一份数据算两遍。
        XCTAssertEqual(report.totalBytes, 1_048_576 + 524_288 + 262_144)
    }

    func testTruncationRewritesTotalBytesAndSetsMessage() async throws {
        // 301 项正好跨越截断阈值：旧实现只截断不给提示，且 totalBytes 仍是全部之和。
        for index in 0..<301 {
            try makeFile(String(format: "Library/Caches/file-%03d.bin", index), bytes: 4_096)
        }

        let report = try await Scanner(homeDirectory: tempHome, settings: ScanSettings())
            .scan(categories: [.userCaches])
        let result = try XCTUnwrap(report.result(for: .userCaches))

        XCTAssertEqual(result.items.count, 300)
        XCTAssertEqual(result.totalBytes, 300 * 4_096, "截断后 totalBytes 必须按展示项重算")
        XCTAssertTrue(result.message?.contains("截断") == true, "截断时必须给出提示，实际：\(result.message ?? "nil")")
    }

    func testTreeSizeSkipsSymbolicLinks() throws {
        try makeFile("Library/Caches/real.bin", bytes: 1_048_576)
        let link = tempHome.appendingPathComponent("Library/Caches/link.bin")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: tempHome.appendingPathComponent("Library/Caches/real.bin")
        )
        XCTAssertEqual(FileSizeReader.treeSize(at: tempHome.appendingPathComponent("Library/Caches")), 1_048_576)
    }
}
