import Foundation

/// 应用改名后的一次性偏好迁移。
///
/// 旧版本以 `com.molelite.app` 为 bundle id，偏好、扫描历史与磁盘趋势都存在该域；
/// 新版本改用 `com.o.app`。启动时把旧域中缺失的键原样搬到新域，避免用户设置丢失。
public enum PreferenceMigration {
    /// 迁移完成标记，避免每次启动重复搬运。
    public static let markerKey = "app.preferencesMigratedFromMoleLite"

    /// 旧 bundle id（按新→旧顺序尝试，先找到的生效）。
    public static let legacyBundleIdentifiers = ["com.molelite.app"]

    /// 执行迁移，返回实际复制的键数量。
    ///
    /// - Parameters:
    ///   - target: 新域（通常是 `.standard`）。
    ///   - legacyDomains: 旧域的持久化域名，默认读取 `legacyBundleIdentifiers`。
    ///   - force: 忽略完成标记（自检与单元测试使用）。
    @discardableResult
    public static func migrateIfNeeded(to target: UserDefaults = .standard,
                                       legacyDomains: [String] = legacyBundleIdentifiers,
                                       markerKey: String = markerKey,
                                       force: Bool = false) -> Int {
        if !force, target.bool(forKey: markerKey) { return 0 }

        var copied = 0
        for domain in legacyDomains {
            guard let values = target.persistentDomain(forName: domain), !values.isEmpty else { continue }
            for (key, value) in values {
                guard key != markerKey else { continue }
                // 新域已有值时以新域为准，不用旧值覆盖。
                guard target.object(forKey: key) == nil else { continue }
                target.set(value, forKey: key)
                copied += 1
            }
            if copied > 0 { break }
        }
        target.set(true, forKey: markerKey)
        return copied
    }

    /// 调试 / 自检用：列出旧域中可迁移的键。
    public static func legacyKeys(from defaults: UserDefaults = .standard,
                                 legacyDomains: [String] = legacyBundleIdentifiers) -> [String] {
        for domain in legacyDomains {
            if let values = defaults.persistentDomain(forName: domain), !values.isEmpty {
                return values.keys.sorted()
            }
        }
        return []
    }
}
