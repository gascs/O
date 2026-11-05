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
        // 临时目录位于 /private 下，会被系统受保护前缀拦截；这里改用真实主目录内的临时沙盒。
        let tempHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MoleLiteSymlink-\(UUID().uuidString)")
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
}
