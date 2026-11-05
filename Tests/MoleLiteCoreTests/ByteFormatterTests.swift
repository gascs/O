import XCTest
@testable import MoleLiteCore

final class ByteFormatterTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(ByteFormatter.string(0), "0 B")
        XCTAssertEqual(ByteFormatter.string(512), "512 B")
    }

    func testKilobytes() {
        XCTAssertEqual(ByteFormatter.string(1024), "1 KB")
        XCTAssertEqual(ByteFormatter.string(1536), "1.5 KB")
    }

    func testMegabytesAndGigabytes() {
        XCTAssertEqual(ByteFormatter.string(1_048_576), "1 MB")
        XCTAssertEqual(ByteFormatter.string(1_073_741_824), "1 GB")
        XCTAssertEqual(ByteFormatter.string(1_610_612_736), "1.5 GB")
        XCTAssertEqual(ByteFormatter.string(1_099_511_627_776), "1 TB")
    }

    func testNegativeValuesAreClamped() {
        XCTAssertEqual(ByteFormatter.string(-1), "0 B")
    }

    func testPercent() {
        XCTAssertEqual(ByteFormatter.percent(0), "0%")
        XCTAssertEqual(ByteFormatter.percent(0.256), "26%")
        XCTAssertEqual(ByteFormatter.percent(1), "100%")
        XCTAssertEqual(ByteFormatter.percent(1.4), "100%", "超过 100% 应截断")
    }

    func testDetailedContainsBytes() {
        XCTAssertTrue(ByteFormatter.detailed(1_048_576).contains("字节"))
    }
}

final class ScanSettingsTests: XCTestCase {
    func testThresholdConversion() {
        let settings = ScanSettings(largeFileThresholdMB: 100)
        XCTAssertEqual(settings.largeFileThresholdBytes, 100 * 1024 * 1024)
    }

    func testRoundTripThroughUserDefaults() {
        let suite = UserDefaults(suiteName: "MoleLiteTests")!
        suite.removePersistentDomain(forName: "MoleLiteTests")
        var settings = ScanSettings.defaults
        settings.largeFileThresholdMB = 512
        settings.includeHiddenItems = true
        settings.preselectRecommendedItems = false
        settings.save(to: suite)

        let loaded = ScanSettings.load(from: suite)
        XCTAssertEqual(loaded, settings)
    }

    func testCategoryPreselectionRules() {
        XCTAssertTrue(ScanCategory.userCaches.isRecommended)
        XCTAssertTrue(ScanCategory.logs.isRecommended)
        XCTAssertTrue(ScanCategory.xcode.isRecommended)
        XCTAssertFalse(ScanCategory.trash.isRecommended)
        XCTAssertFalse(ScanCategory.largeFiles.isRecommended)
    }
}
