import Foundation

public enum PathSafetyVerdict: Equatable, Sendable {
    case allowed
    case rejected(String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var rejectionReason: String? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }
}

/// 路径安全校验。所有清理动作都必须先通过这里，绝不对系统路径做 rm -rf。
///
/// 两道关卡：先按用户给出的路径本身校验，再在解析符号链接之后用真实路径重复一遍。
/// 两步都做 forbidden / 受保护前缀 / 允许范围检查，否则 `~/Library/Caches/foo -> ~/Library`
/// 这类链接会绕过「受保护路径」判断。
public struct PathSafety: Sendable {
    /// 绝对禁止触碰的前缀（系统目录 / 系统级 Library）。
    public static let protectedPrefixes: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/private",
        "/dev", "/cores", "/opt", "/Volumes", "/Library", "/var", "/tmp",
        "/Applications/Utilities", "/Applications/System"
    ]

    /// 小写前缀表，用于大小写不敏感比较（macOS 默认 APFS 不区分大小写）。
    private static let protectedPrefixKeys: [String] = protectedPrefixes.map { $0.lowercased() }

    /// `/var`、`/tmp`、`/etc` 在 macOS 上是指向 `/private` 的系统别名。
    private static let systemAliasPrefixes: [String] = ["/var", "/tmp", "/etc"]

    public let homeDirectory: URL
    public let additionalAllowedRoots: [URL]

    /// 以下均为小写形式的预计算值。
    private let homeKey: String
    private let allowedRootKeys: [String]
    private let forbiddenKeys: Set<String>
    private let resolvedHomeKey: String
    private let resolvedRootKeys: [String]
    private let resolvedForbiddenKeys: Set<String>

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                additionalAllowedRoots: [URL] = [URL(fileURLWithPath: "/Applications")]) {
        self.homeDirectory = homeDirectory
        self.additionalAllowedRoots = additionalAllowedRoots

        let home = PathSafety.normalize(homeDirectory.path, home: homeDirectory)
        var roots = [home]
        roots.append(contentsOf: additionalAllowedRoots.map { PathSafety.normalize($0.path, home: homeDirectory) })

        self.homeKey = home.lowercased()
        self.allowedRootKeys = roots.map { $0.lowercased() }
        self.forbiddenKeys = PathSafety.forbiddenKeys(roots: roots, home: home, base: homeDirectory)

        // 主目录本身可能就是系统别名的解析结果（沙盒 / 测试临时目录），这里同时预计算解析后的集合。
        let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        self.resolvedHomeKey = resolvedHome.lowercased()
        self.resolvedRootKeys = roots.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.lowercased()
        }
        self.resolvedForbiddenKeys = PathSafety.forbiddenKeys(roots: roots, home: resolvedHome, base: homeDirectory)
    }

    /// 不能作为清理目标的「整根本身」：允许范围根、系统根、用户主目录下的隐私文件夹。
    private static func forbiddenKeys(roots: [String], home: String, base: URL) -> Set<String> {
        var forbidden = Set(roots.map { $0.lowercased() })
        forbidden.insert("/")
        forbidden.insert("/users")
        forbidden.insert(PathSafety.normalize(home + "/Library", home: base).lowercased())
        forbidden.insert(PathSafety.normalize(home + "/.Trash", home: base).lowercased())
        for name in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"] {
            forbidden.insert(PathSafety.normalize(home + "/" + name, home: base).lowercased())
        }
        return forbidden
    }

    /// 规范化：展开 `~`、解析 `..`，但不跟随符号链接。
    public static func normalize(_ path: String, home: URL) -> String {
        var value = path
        if value == "~" {
            value = home.path
        } else if value.hasPrefix("~/") {
            value = home.path + String(value.dropFirst())
        }
        guard !value.isEmpty else { return "" }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    public static func isWithin(_ path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    /// 大小写不敏感的包含判断，语义同 `isWithin`。
    public static func isWithinCaseInsensitive(_ path: String, prefix: String) -> Bool {
        isWithin(path.lowercased(), prefix: prefix.lowercased())
    }

    /// 校验单个路径是否允许被移入废纸篓（或永久删除）。
    public func verdict(for url: URL) -> PathSafetyVerdict {
        let raw = url.path
        guard !raw.isEmpty else { return .rejected("路径为空") }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else {
            return .rejected("非法路径：必须是绝对路径")
        }

        let path = PathSafety.normalize(raw, home: homeDirectory)
        guard path.hasPrefix("/") else { return .rejected("非法路径：无法规范化") }
        guard !path.contains("\0") else { return .rejected("非法路径：包含空字符") }

        // 第一轮：原始路径。
        if let reason = forbiddenOrProtectedRejection(path: path, homeKey: homeKey, forbidden: forbiddenKeys) {
            return .rejected(reason)
        }
        if let reason = containmentRejection(path: path, rootKeys: allowedRootKeys, resolvedHint: false) {
            return .rejected(reason)
        }

        // 第二轮：解析符号链接后的真实路径必须重新过一遍同样的校验。
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved != path else { return .allowed }

        if let reason = forbiddenOrProtectedRejection(path: resolved, homeKey: resolvedHomeKey,
                                                       forbidden: resolvedForbiddenKeys, label: "符号链接") {
            return .rejected(reason)
        }

        // 「仍在主目录内」捷径：仅用于 /var ↔ /private/var 这类系统别名，避免别名路径被误判。
        if PathSafety.isSystemAliasPair(path, resolved),
           PathSafety.isWithin(resolved.lowercased(), prefix: resolvedHomeKey) {
            return .allowed
        }

        if let reason = containmentRejection(path: resolved, rootKeys: resolvedRootKeys, resolvedHint: true) {
            return .rejected(reason)
        }
        return .allowed
    }

    /// forbidden 精确命中与系统受保护前缀检查；返回 nil 表示通过。
    private func forbiddenOrProtectedRejection(path: String, homeKey: String,
                                               forbidden: Set<String>,
                                               label: String = "") -> String? {
        let key = path.lowercased()
        let prefix = label.isEmpty ? "" : label + "指向"
        if forbidden.contains(key) {
            return "\(prefix)受保护路径：不允许删除该目录本身（\(path)）"
        }
        for (index, prefixKey) in PathSafety.protectedPrefixKeys.enumerated()
        where PathSafety.isWithin(key, prefix: prefixKey) {
            // 主目录内的路径由「允许范围」接管：正常主目录不会落在系统前缀下，
            // 这里主要兼容沙盒 / 测试使用的临时主目录（位于 /var/folders）。
            if PathSafety.isWithin(key, prefix: homeKey) { continue }
            return "\(prefix)系统受保护目录：\(PathSafety.protectedPrefixes[index]) 下的内容不允许清理"
        }
        return nil
    }

    /// 必须落在允许范围内，且不能是允许范围的根目录本身。
    private func containmentRejection(path: String, rootKeys: [String], resolvedHint: Bool) -> String? {
        let key = path.lowercased()
        guard let root = rootKeys.first(where: { PathSafety.isWithin(key, prefix: $0) }) else {
            return resolvedHint
                ? "符号链接指向允许范围之外：\(path)"
                : "不在允许的清理范围内：\(path)"
        }
        if key == root {
            return resolvedHint
                ? "符号链接指向允许范围的根目录：\(path)"
                : "受保护路径：不允许删除允许范围的根目录"
        }
        return nil
    }

    /// 判断原始路径与解析结果是否只差一层系统别名前缀（`/var` → `/private/var`）。
    private static func isSystemAliasPair(_ path: String, _ resolved: String) -> Bool {
        for alias in systemAliasPrefixes where isWithin(path, prefix: alias) {
            let privateForm = "/private" + path
            if resolved == privateForm || resolved.hasPrefix(privateForm + "/") { return true }
        }
        return false
    }

    /// 批量过滤：只保留通过校验的路径。
    public func allowedURLs(from urls: [URL]) -> [URL] {
        urls.filter { verdict(for: $0).isAllowed }
    }
}
