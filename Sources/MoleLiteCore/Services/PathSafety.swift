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
public struct PathSafety: Sendable {
    /// 绝对禁止触碰的前缀（系统目录 / 系统级 Library）。
    public static let protectedPrefixes: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/private",
        "/dev", "/cores", "/opt", "/Volumes", "/Library", "/var", "/tmp",
        "/Applications/Utilities", "/Applications/System"
    ]

    public let homeDirectory: URL
    public let additionalAllowedRoots: [URL]
    private let allowedRootPaths: [String]
    private let forbiddenPaths: Set<String>

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                additionalAllowedRoots: [URL] = [URL(fileURLWithPath: "/Applications")]) {
        self.homeDirectory = homeDirectory
        self.additionalAllowedRoots = additionalAllowedRoots

        let home = PathSafety.normalize(homeDirectory.path, home: homeDirectory)
        var roots = [home]
        roots.append(contentsOf: additionalAllowedRoots.map { PathSafety.normalize($0.path, home: homeDirectory) })
        self.allowedRootPaths = roots

        var forbidden = Set(roots)
        forbidden.insert("/")
        forbidden.insert("/Users")
        forbidden.insert(PathSafety.normalize(home + "/Library", home: homeDirectory))
        forbidden.insert(PathSafety.normalize(home + "/.Trash", home: homeDirectory))
        for name in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"] {
            forbidden.insert(PathSafety.normalize(home + "/" + name, home: homeDirectory))
        }
        self.forbiddenPaths = forbidden
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

    /// 校验单个路径是否允许被移入废纸篓。
    public func verdict(for url: URL) -> PathSafetyVerdict {
        let raw = url.path
        guard !raw.isEmpty else { return .rejected("路径为空") }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else {
            return .rejected("非法路径：必须是绝对路径")
        }

        let path = PathSafety.normalize(raw, home: homeDirectory)
        guard path.hasPrefix("/") else { return .rejected("非法路径：无法规范化") }
        guard !path.contains("\0") else { return .rejected("非法路径：包含空字符") }

        if forbiddenPaths.contains(path) {
            return .rejected("受保护路径：不允许删除该目录本身（\(path)）")
        }

        for prefix in PathSafety.protectedPrefixes where PathSafety.isWithin(path, prefix: prefix) {
            return .rejected("系统受保护目录：\(prefix) 下的内容不允许清理")
        }

        guard let root = allowedRootPaths.first(where: { PathSafety.isWithin(path, prefix: $0) }) else {
            return .rejected("不在允许的清理范围内：\(path)")
        }
        guard path != root else {
            return .rejected("受保护路径：不允许删除允许范围的根目录")
        }

        // 符号链接逃逸检查：链接解析后必须仍落在允许范围内，且不能指向系统目录。
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved != path {
            let resolvedHome = URL(fileURLWithPath: homeDirectory.path).resolvingSymlinksInPath().path
            // 解析后仍在用户主目录内（例如 /var 与 /private/var 这类系统软链接）视为安全。
            if PathSafety.isWithin(resolved, prefix: resolvedHome) { return .allowed }

            if forbiddenPaths.contains(resolved) {
                return .rejected("符号链接指向受保护路径：\(resolved)")
            }
            for prefix in PathSafety.protectedPrefixes where PathSafety.isWithin(resolved, prefix: prefix) {
                return .rejected("符号链接指向系统受保护目录：\(prefix)")
            }
            let resolvedRoots = allowedRootPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            guard resolvedRoots.contains(where: { PathSafety.isWithin(resolved, prefix: $0) }) else {
                return .rejected("符号链接指向允许范围之外：\(resolved)")
            }
        }

        return .allowed
    }

    /// 批量过滤：只保留通过校验的路径。
    public func allowedURLs(from urls: [URL]) -> [URL] {
        urls.filter { verdict(for: $0).isAllowed }
    }
}
