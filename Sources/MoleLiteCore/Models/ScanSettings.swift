import Foundation

/// 扫描 / 清理设置。以 UserDefaults 持久化，界面通过 @AppStorage 绑定同一批键。
public struct ScanSettings: Sendable, Equatable {
    public enum Keys {
        public static let largeFileThresholdMB = "scan.largeFileThresholdMB"
        public static let includeHiddenItems = "scan.includeHiddenItems"
        public static let preselectRecommendedItems = "scan.preselectRecommendedItems"
        /// 状态栏文字样式：icon / percent / iconAndPercent。
        public static let menuBarDisplay = "menubar.display"
        /// 状态栏刷新间隔（秒）。
        public static let menuBarRefreshSeconds = "menubar.refreshSeconds"
        /// 重复文件查找的最小文件体积（MB）。
        public static let duplicateMinSizeMB = "duplicate.minSizeMB"
        /// 重复文件查找的目录列表（存字符串路径）。
        public static let duplicateRootPaths = "duplicate.rootPaths"
        /// 重复文件返回的组数上限。
        public static let duplicateGroupLimit = "duplicate.groupLimit"
        /// 首次启动的权限引导是否已完成（完成或主动跳过都算）。
        public static let onboardingCompleted = "app.permissionOnboardingCompleted"
        /// 权限引导被关闭的时间戳（用于判断「不再重复弹出」）。
        public static let permissionGuideClosedAt = "app.permissionGuideClosedAt"
    }

    public static func menuBarStyle(from defaults: UserDefaults = .standard) -> MenuBarDisplayStyle {
        guard let raw = defaults.string(forKey: Keys.menuBarDisplay),
              let style = MenuBarDisplayStyle(rawValue: raw) else {
            return .iconAndPercent
        }
        return style
    }

    public static func menuBarRefreshInterval(from defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.object(forKey: Keys.menuBarRefreshSeconds) as? Int ?? 5
        return TimeInterval(max(1, min(60, value)))
    }

    public static func duplicateMinSizeMB(from defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: Keys.duplicateMinSizeMB) as? Int ?? 1
        return max(1, min(500, value))
    }

    /// 重复文件查找的目录（默认下载 / 文档 / 桌面）。返回的路径会过滤掉不存在的目录。
    public static func duplicateRootPaths(from defaults: UserDefaults = .standard,
                                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                         fileManager: FileManager = .default) -> [String] {
        let stored = defaults.stringArray(forKey: Keys.duplicateRootPaths) ?? []
        let candidates = stored.isEmpty
            ? ["Downloads", "Documents", "Desktop"].map { home.appendingPathComponent($0).path }
            : stored
        return candidates.filter { fileManager.fileExists(atPath: $0) }
    }

    public static func duplicateGroupLimit(from defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: Keys.duplicateGroupLimit) as? Int ?? 200
        return max(20, min(2000, value))
    }

    public static func onboardingCompleted(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Keys.onboardingCompleted)
    }

    /// 记录引导已处理（完成或跳过），之后不再自动弹出。
    public static func markPermissionGuideCompleted(from defaults: UserDefaults = .standard,
                                                    at date: Date = Date()) {
        defaults.set(true, forKey: Keys.onboardingCompleted)
        defaults.set(date.timeIntervalSince1970, forKey: Keys.permissionGuideClosedAt)
    }

    /// 在设置页重新打开引导时清除记忆。
    public static func resetPermissionGuide(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Keys.onboardingCompleted)
        defaults.removeObject(forKey: Keys.permissionGuideClosedAt)
    }

    public var largeFileThresholdMB: Int
    public var includeHiddenItems: Bool
    public var preselectRecommendedItems: Bool

    public init(largeFileThresholdMB: Int = 100, includeHiddenItems: Bool = false, preselectRecommendedItems: Bool = true) {
        self.largeFileThresholdMB = largeFileThresholdMB
        self.includeHiddenItems = includeHiddenItems
        self.preselectRecommendedItems = preselectRecommendedItems
    }

    public var largeFileThresholdBytes: Int64 {
        Int64(max(1, largeFileThresholdMB)) * 1024 * 1024
    }

    public static var defaults: ScanSettings {
        ScanSettings(largeFileThresholdMB: 100, includeHiddenItems: false, preselectRecommendedItems: true)
    }

    public static func load(from defaults: UserDefaults = .standard) -> ScanSettings {
        let fallback = ScanSettings.defaults
        let storedThreshold = defaults.object(forKey: Keys.largeFileThresholdMB) as? Int
        let storedHidden = defaults.object(forKey: Keys.includeHiddenItems) as? Bool
        let storedPreselect = defaults.object(forKey: Keys.preselectRecommendedItems) as? Bool
        return ScanSettings(
            largeFileThresholdMB: storedThreshold ?? fallback.largeFileThresholdMB,
            includeHiddenItems: storedHidden ?? fallback.includeHiddenItems,
            preselectRecommendedItems: storedPreselect ?? fallback.preselectRecommendedItems
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(largeFileThresholdMB, forKey: Keys.largeFileThresholdMB)
        defaults.set(includeHiddenItems, forKey: Keys.includeHiddenItems)
        defaults.set(preselectRecommendedItems, forKey: Keys.preselectRecommendedItems)
    }
}
