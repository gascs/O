import Foundation

/// 启动项读取：扫描用户与系统级 LaunchAgents / LaunchDaemons 的 plist。
/// 只做只读解析，不修改任何系统数据库。
public struct LaunchItemService: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public var directories: [(scope: LaunchScope, url: URL)] {
        [
            (.userAgent, homeDirectory.appendingPathComponent("Library/LaunchAgents")),
            (.userDaemon, homeDirectory.appendingPathComponent("Library/LaunchDaemons")),
            (.systemAgent, URL(fileURLWithPath: "/Library/LaunchAgents")),
            (.systemDaemon, URL(fileURLWithPath: "/Library/LaunchDaemons"))
        ]
    }

    /// 系统「登录项」数据库所在目录。`sfltool dumpbtm` 需要管理员权限，本应用直接读文件，
    /// 读不到就降级为只读说明，不调用任何命令行工具、也不修改数据库。
    public var backgroundItemDirectories: [URL] {
        [
            homeDirectory.appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagement")
        ]
    }

    /// 读取系统登录项（尽力而为）。返回实际解析到的条目与一句说明。
    public func loadLoginItems() -> (items: [LaunchItem], note: String?) {
        var candidates: [URL] = []
        for directory in backgroundItemDirectories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            candidates.append(contentsOf: entries.filter { $0.pathExtension.lowercased() == "btm" })
        }

        guard !candidates.isEmpty else {
            return ([], "系统登录项数据库不可读（需要管理员权限），这里只显示 LaunchAgents / LaunchDaemons。O 不会修改系统数据库。")
        }

        var items: [LaunchItem] = []
        var seen = Set<String>()
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
                continue
            }
            collectLoginItems(from: object, items: &items, seen: &seen)
        }

        if items.isEmpty {
            return ([], "系统登录项数据库格式无法解析（不同 macOS 版本结构不一致）。这里只读展示，不做修改。")
        }
        return (items, nil)
    }

    /// 递归遍历 plist，提取形如应用条目的字典（含 url / bundleIdentifier）。
    private func collectLoginItems(from value: Any, items: inout [LaunchItem], seen: inout Set<String>) {
        if let dictionary = value as? [String: Any] {
            if let urlString = dictionary["url"] as? String,
               !urlString.isEmpty,
               let url = URL(string: urlString),
               url.isFileURL || urlString.hasPrefix("/") {
                let resolved = url.isFileURL ? url : URL(fileURLWithPath: urlString)
                let label = dictionary["identifier"] as? String
                    ?? dictionary["bundleIdentifier"] as? String
                    ?? resolved.lastPathComponent
                if !seen.contains(resolved.path) {
                    seen.insert(resolved.path)
                    items.append(LaunchItem(url: resolved, label: label, program: resolved.path,
                                            scope: .loginItem, runAtLoad: true, isDisabled: false))
                }
            }
            for (_, child) in dictionary {
                collectLoginItems(from: child, items: &items, seen: &seen)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectLoginItems(from: child, items: &items, seen: &seen)
            }
        }
    }

    public func load() async -> [LaunchItem] {
        await Task.detached(priority: .userInitiated) { [self] in
            loadSynchronously()
        }.value
    }

    public func loadSynchronously() -> [LaunchItem] {
        var items: [LaunchItem] = []
        for (scope, directory) in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension.lowercased() == "plist" {
                items.append(parse(entry, scope: scope))
            }
        }
        items.append(contentsOf: loadLoginItems().items)
        return items.sorted {
            if $0.scope != $1.scope { return scopeOrder($0.scope) < scopeOrder($1.scope) }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    public func parse(_ url: URL, scope: LaunchScope) -> LaunchItem {
        let fallbackLabel = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any] else {
            return LaunchItem(url: url, label: fallbackLabel, program: nil, scope: scope,
                              runAtLoad: false, isDisabled: false)
        }

        let label = plist["Label"] as? String ?? fallbackLabel
        let program: String? = {
            if let program = plist["Program"] as? String { return program }
            if let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first { return first }
            return nil
        }()
        let runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        let isDisabled = plist["Disabled"] as? Bool ?? false
        return LaunchItem(url: url, label: label, program: program, scope: scope,
                          runAtLoad: runAtLoad, isDisabled: isDisabled)
    }

    private func scopeOrder(_ scope: LaunchScope) -> Int {
        switch scope {
        case .userAgent: return 0
        case .userDaemon: return 1
        case .systemAgent: return 2
        case .systemDaemon: return 3
        case .loginItem: return 4
        }
    }
}
