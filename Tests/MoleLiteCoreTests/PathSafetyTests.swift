import XCTest
@testable import MoleLiteCore

final class PathSafetyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")

    private var safety: PathSafety { PathSafety(homeDirectory: home) }

    func testSystemPathsAreRejected() {
        let paths = ["/System/Library", "/usr/local/bin/tool", "/bin/ls", "/etc/hosts", "/Library/Caches", "/private/var/db"]
        for path in paths {
            let verdict = safety.verdict(for: URL(fileURLWithPath: path))
            XCTAssertFalse(verdict.isAllowed, "应拒绝系统路径 \(path)")
        }
    }

    func testProtectedRootsThemselvesAreRejected() {
        let paths = ["/", "/Users", "/Users/tester", "/Users/tester/Library", "/Applications", "/Applications/Utilities"]
        for path in paths {
            XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: path)).isAllowed, "应拒绝受保护根目录 \(path)")
        }
    }

    func testUserCacheIsAllowed() {
        let url = home.appendingPathComponent("Library/Caches/com.example.app")
        XCTAssertTrue(safety.verdict(for: url).isAllowed)
    }

    func testUserLogsAndDownloadsAreAllowed() {
        XCTAssertTrue(safety.verdict(for: home.appendingPathComponent("Library/Logs/app.log")).isAllowed)
        XCTAssertTrue(safety.verdict(for: home.appendingPathComponent("Downloads/Film.mp4")).isAllowed)
        XCTAssertTrue(safety.verdict(for: home.appendingPathComponent("Documents/report.pdf")).isAllowed)
    }

    func testApplicationBundleIsAllowed() {
        XCTAssertTrue(safety.verdict(for: URL(fileURLWithPath: "/Applications/Example.app")).isAllowed)
    }

    func testPathOutsideAllowedRootsIsRejected() {
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "/tmp/scratch")).isAllowed)
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "/Volumes/ExtDisk/file")).isAllowed)
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "/Users/someoneelse/Library/Caches")).isAllowed)
    }

    func testRelativePathIsRejected() {
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "Library/Caches")).isAllowed)
    }

    func testTildePathIsNormalized() {
        let normalized = PathSafety.normalize("~/Library/Logs/app.log", home: home)
        XCTAssertEqual(normalized, "/Users/tester/Library/Logs/app.log")
        XCTAssertTrue(safety.verdict(for: URL(fileURLWithPath: normalized)).isAllowed)
    }

    func testSymlinkEscapingHomeIsRejected() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("MoleLiteSymlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let caches = tempHome.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let link = caches.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System/Library"))

        let tempSafety = PathSafety(homeDirectory: tempHome)
        XCTAssertFalse(tempSafety.verdict(for: link).isAllowed, "指向系统目录的符号链接应被拒绝")
    }

    func testSymlinkInsideHomeIsAllowed() throws {
        // 用临时目录模拟真实主目录，避免测试写真实 ~/Library。
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoleLiteSymlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let caches = tempHome.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let target = caches.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = caches.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let tempSafety = PathSafety(homeDirectory: tempHome)
        XCTAssertTrue(tempSafety.verdict(for: link).isAllowed, "主目录内部的符号链接应被允许")
    }

    func testSymlinkPointingIntoProtectedLibraryIsRejected() throws {
        // 旧实现会在「解析后仍在主目录内」时提前放行，导致 ~/Library 这类受保护目录被绕过。
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoleLiteSymlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let caches = tempHome.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let link = caches.appendingPathComponent("into-library")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: tempHome.appendingPathComponent("Library")
        )

        let tempSafety = PathSafety(homeDirectory: tempHome)
        XCTAssertFalse(tempSafety.verdict(for: link).isAllowed, "指向主目录内受保护目录的符号链接也应被拒绝")
    }

    func testForbiddenPathComparisonIsCaseInsensitive() {
        // macOS 默认大小写不敏感，比较时不能区分大小写，否则 ~/library 能绕过。
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "/Users/TESTER/Library")).isAllowed)
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "/users/tester/library")).isAllowed)
        XCTAssertFalse(safety.verdict(for: URL(fileURLWithPath: "/system/library")).isAllowed)
    }

    func testTemporaryHomeUnderVarIsAllowed() {
        // 临时 home 位于 /var/folders（解析后是 /private/var），不应被 /var 受保护前缀误拦。
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoleLiteSafety-\(UUID().uuidString)")
        let tempSafety = PathSafety(homeDirectory: tempHome)
        XCTAssertTrue(tempSafety.verdict(for: tempHome.appendingPathComponent("Library/Caches/com.example.app")).isAllowed)
        XCTAssertFalse(tempSafety.verdict(for: URL(fileURLWithPath: "/var/db/anything")).isAllowed)
    }
}
