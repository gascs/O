import Foundation

/// 应用清单：枚举 /Applications 与 ~/Applications，并查找关联残留。
public struct AppInventoryService: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public var applicationRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"), homeDirectory.appendingPathComponent("Applications")]
    }

    public func loadApplications() async -> [AppBundle] {
        await Task.detached(priority: .userInitiated) { [self] in
            scanApplications()
        }.value
    }

    public func scanApplications() -> [AppBundle] {
        var apps: [AppBundle] = []
        for root in applicationRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension.lowercased() == "app" {
                let info = bundleInfo(at: entry)
                let size = FileSizeReader.treeSize(at: entry)
                let leftovers = leftoverItems(bundleIdentifier: info.identifier, appName: info.name)
                apps.append(AppBundle(
                    url: entry,
                    name: info.name,
                    bundleIdentifier: info.identifier,
                    version: info.version,
                    byteSize: size,
                    leftovers: leftovers
                ))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func bundleInfo(at appURL: URL) -> (name: String, identifier: String?, version: String?) {
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any] else {
            return (fallbackName, nil, nil)
        }
        let displayName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? fallbackName
        return (displayName, plist["CFBundleIdentifier"] as? String, plist["CFBundleShortVersionString"] as? String)
    }

    /// 根据 bundle id / 应用名推定残留位置。
    public func leftoverItems(bundleIdentifier: String?, appName: String? = nil) -> [LeftoverItem] {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return [] }
        let library = homeDirectory.appendingPathComponent("Library")
        let candidates: [(String, LeftoverKind)] = [
            ("Caches/\(bundleIdentifier)", .cache),
            ("Preferences/\(bundleIdentifier).plist", .preference),
            ("Preferences/\(bundleIdentifier)", .preference),
            ("Containers/\(bundleIdentifier)", .container),
            ("Application Support/\(bundleIdentifier)", .applicationSupport),
            ("Application Scripts/\(bundleIdentifier)", .applicationScripts),
            ("Logs/\(bundleIdentifier)", .log),
            ("Saved Application State/\(bundleIdentifier).savedState", .savedState),
            ("HTTPStorages/\(bundleIdentifier)", .networkCache),
            ("HTTPStorages/\(bundleIdentifier).binarycookies", .networkCache),
            ("WebKit/\(bundleIdentifier)", .webkit),
            ("Cookies/\(bundleIdentifier).binarycookies", .networkCache),
            ("LaunchAgents/\(bundleIdentifier).plist", .launchAgent)
        ]

        var items: [LeftoverItem] = []
        var seen = Set<String>()
        for (relative, kind) in candidates {
            let url = library.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard seen.insert(url.path).inserted else { continue }
            items.append(LeftoverItem(url: url, kind: kind, byteSize: FileSizeReader.treeSize(at: url)))
        }

        // 共享容器：目录名可能是 group.<bid> 或 <TeamID>.<bid>。
        let groupRoot = library.appendingPathComponent("Group Containers")
        if let entries = try? FileManager.default.contentsOfDirectory(at: groupRoot, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name == bundleIdentifier
                        || name.hasSuffix(".\(bundleIdentifier)")
                        || name.hasPrefix("group.\(bundleIdentifier)") else { continue }
                guard seen.insert(entry.path).inserted else { continue }
                items.append(LeftoverItem(url: entry, kind: .groupContainer,
                                          byteSize: FileSizeReader.treeSize(at: entry)))
            }
        }

        // ByHost 偏好设置：文件名形如 <bid>.<UUID>.plist。
        let preferences = library.appendingPathComponent("Preferences")
        if let entries = try? FileManager.default.contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix(bundleIdentifier + ".") {
                guard seen.insert(entry.path).inserted else { continue }
                items.append(LeftoverItem(url: entry, kind: .preference,
                                          byteSize: FileSizeReader.allocatedSize(of: entry)))
            }
        }

        // 崩溃报告：~/Library/Logs/DiagnosticReports 下以应用名开头的文件。
        if let appName, !appName.isEmpty {
            let reports = library.appendingPathComponent("Logs/DiagnosticReports")
            if let entries = try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil) {
                for entry in entries {
                    let name = entry.lastPathComponent
                    guard name.hasPrefix(appName + "-") || name.hasPrefix(appName + "_") else { continue }
                    guard seen.insert(entry.path).inserted else { continue }
                    items.append(LeftoverItem(url: entry, kind: .crashReport,
                                              byteSize: FileSizeReader.allocatedSize(of: entry)))
                }
            }
        }

        return items.sorted { $0.byteSize > $1.byteSize }
    }
}
