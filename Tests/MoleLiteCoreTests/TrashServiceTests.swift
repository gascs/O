import XCTest
@testable import MoleLiteCore

final class TrashServiceTests: XCTestCase {
    func testProtectedSystemPathIsRejected() {
        let report = TrashService().trash(entries: [(URL(fileURLWithPath: "/System/Library/CoreServices"), 0)])
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertEqual(report.bytesFreed, 0)
        XCTAssertTrue((report.outcomes.first?.message ?? "").contains("受保护"))
    }

    func testItemInsideTrashIsNotTrashedTwice() {
        let item = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/MoleLiteTestItem")
        let report = TrashService().trash(entries: [(item, 100)])
        XCTAssertFalse(report.outcomes.first?.success ?? true)
        XCTAssertTrue((report.outcomes.first?.message ?? "").contains("手动清空"))
    }

    func testMissingFileIsSkippedWithoutFailure() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MoleLiteNotExist-\(UUID().uuidString)")
        let report = TrashService().trash(entries: [(url, 0)])
        XCTAssertEqual(report.successCount, 1)
        XCTAssertEqual(report.bytesFreed, 0)
    }

    func testSafetyAllowsOnlyInsideHomeOrApplications() {
        let safety = PathSafety()
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(safety.verdict(for: home.appendingPathComponent("Library/Logs/app.log")).isAllowed)
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "/usr/local/bin/tool")).isAllowed)
    }

    func testEmptyEntriesProduceEmptySummary() {
        let report = TrashService().trash(entries: [])
        XCTAssertEqual(report.outcomes.count, 0)
        XCTAssertEqual(report.summary, "没有需要清理的项目")
    }
}
