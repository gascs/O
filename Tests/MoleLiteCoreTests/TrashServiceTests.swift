import XCTest
@testable import MoleLiteCore

final class TrashServiceTests: XCTestCase {
    /// 每个用例都在临时目录里构造一个假主目录，绝不写真实 $HOME / ~/Library / ~/.Trash。
    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoleLiteTrashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeFile(in directory: URL, name: String, bytes: Int) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testProtectedSystemPathIsRejected() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = TrashService(safety: PathSafety(homeDirectory: home))

        let report = service.trash(entries: [(URL(fileURLWithPath: "/System/Library/CoreServices"), 0)])
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertEqual(report.bytesFreed, 0)
        XCTAssertTrue((report.outcomes.first?.message ?? "").contains("受保护"))
    }

    func testItemInsideTrashIsNotTrashedTwiceByDefault() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = TrashService(safety: PathSafety(homeDirectory: home))
        let item = home.appendingPathComponent(".Trash/MoleLiteTestItem")
        try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 16).write(to: item)

        let report = service.trash(entries: [(item, 100)])
        XCTAssertFalse(report.outcomes.first?.success ?? true)
        XCTAssertTrue((report.outcomes.first?.message ?? "").contains("手动清空"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path), "默认不允许永久删除，文件必须保留")
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertEqual(report.movedBytes, 0)
    }

    func testPermanentRemovalDeletesTrashItemExplicitly() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = TrashService(safety: PathSafety(homeDirectory: home))
        let item = try makeFile(in: home.appendingPathComponent(".Trash"), name: "old.log", bytes: 512)

        let report = service.trash(entries: [(item, 512)], allowPermanentRemoval: true)
        XCTAssertTrue(report.outcomes.first?.success ?? false)
        XCTAssertEqual(report.freedBytes, 512)
        XCTAssertEqual(report.movedBytes, 0)
        XCTAssertEqual(report.bytesFreed, 512)
        XCTAssertTrue(report.hasPermanentDeletion)
        XCTAssertEqual(report.summary, "已永久删除 1 项")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path), "显式允许时应真正删除")
    }

    func testEmptyConvenienceAPIForcesPermanentRemoval() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = TrashService(safety: PathSafety(homeDirectory: home))
        let item = try makeFile(in: home.appendingPathComponent(".Trash"), name: "cache.tmp", bytes: 128)

        let report = service.empty(items: [ScanItem(url: item, byteSize: 128, isDirectory: false)])
        XCTAssertEqual(report.freedBytes, 128)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
    }

    func testTrashRootItselfCannotBeDeleted() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = TrashService(safety: PathSafety(homeDirectory: home))
        let trash = home.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        let report = service.trash(entries: [(trash, 0)], allowPermanentRemoval: true)
        XCTAssertFalse(report.outcomes.first?.success ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
    }

    func testMissingFileIsSkippedWithoutFailure() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = TrashService(safety: PathSafety(homeDirectory: home))
        let url = home.appendingPathComponent("Library/Caches/MoleLiteNotExist-\(UUID().uuidString)")

        let report = service.trash(entries: [(url, 0)])
        XCTAssertEqual(report.successCount, 1)
        XCTAssertEqual(report.bytesFreed, 0)
        XCTAssertTrue((report.outcomes.first?.message ?? "").contains("已不存在"))
    }

    func testSafetyAllowsOnlyInsideHomeOrApplications() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let safety = PathSafety(homeDirectory: home)

        XCTAssertTrue(safety.verdict(for: home.appendingPathComponent("Library/Logs/app.log")).isAllowed)
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "/usr/local/bin/tool")).isAllowed)
    }

    func testEmptyEntriesProduceEmptySummary() {
        let report = TrashService().trash(entries: [])
        XCTAssertEqual(report.outcomes.count, 0)
        XCTAssertEqual(report.summary, "没有需要清理的项目")
    }
}
