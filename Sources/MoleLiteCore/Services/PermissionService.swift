import AppKit
import Foundation
import ServiceManagement

/// 权限能力状态：只允许三种结论，无法判定时绝不当作已授权。
public enum CapabilityStatus: String, Sendable, Equatable {
    case granted
    case denied
    case undetermined

    public var title: String {
        switch self {
        case .granted: return "已授权"
        case .denied: return "未授权"
        case .undetermined: return "无法判定"
        }
    }

    public var isGranted: Bool { self == .granted }
}

/// 一项真实探测过的权限能力，附带判定依据。
public struct PermissionCapability: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let purpose: String
    public let status: CapabilityStatus
    /// 判定依据（读到了什么、哪一步失败、系统返回了什么）。
    public let basis: String

    public init(id: String, title: String, purpose: String, status: CapabilityStatus, basis: String) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.status = status
        self.basis = basis
    }
}

/// 「完全磁盘访问」状态检测。
///
/// 通过实际读取受 TCC 保护的路径来判断，不做任何推断：读得到就是已授权，
/// 读不到就如实显示未授权；受保护路径都不存在时返回「无法判定」，而不是当成已授权。
/// 探针只调用 `FileManager.contentsOfDirectory`，不修改任何内容。
public struct PermissionProbe: Identifiable, Sendable, Equatable {
    public enum Access: String, Sendable {
        case granted
        case denied
        case missing
    }

    public let id: String
    public let title: String
    public let path: String
    public let purpose: String
    public let access: Access

    public init(id: String, title: String, path: String, purpose: String, access: Access) {
        self.id = id
        self.title = title
        self.path = path
        self.purpose = purpose
        self.access = access
    }

    public var isReadable: Bool { access == .granted }

    public var statusText: String {
        switch access {
        case .granted: return "已授权"
        case .denied: return "未授权"
        case .missing: return "路径不存在"
        }
    }

    /// 是否作为「完全磁盘访问」的判定依据（废纸篓不算，避免误判）。
    public var contributesToFullDiskAccess: Bool {
        id == "mail" || id == "safari" || id == "tcc"
    }
}

public struct PermissionSnapshot: Sendable, Equatable {
    public let probes: [PermissionProbe]
    public let checkedAt: Date

    public init(probes: [PermissionProbe], checkedAt: Date = Date()) {
        self.probes = probes
        self.checkedAt = checkedAt
    }

    /// 完全磁盘访问只由 Mail / Safari / TCC 三个受保护位置判定；
    /// 三者都不存在时返回「无法判定」，绝不当作已授权。
    public var fullDiskAccessStatus: CapabilityStatus {
        let relevant = probes.filter(\.contributesToFullDiskAccess)
        let existing = relevant.filter { $0.access != .missing }
        guard !existing.isEmpty else { return .undetermined }
        return existing.contains(where: \.isReadable) ? .granted : .denied
    }

    public var hasFullDiskAccess: Bool { fullDiskAccessStatus == .granted }

    /// 判定依据，供设置页与引导页直接展示。
    public var fullDiskAccessBasis: String {
        let relevant = probes.filter(\.contributesToFullDiskAccess)
        let existing = relevant.filter { $0.access != .missing }
        guard !existing.isEmpty else {
            return "Mail、Safari、隐私数据库三处受保护路径都不存在，无法判定"
        }
        let parts = existing.map { "\($0.title) \($0.statusText)" }
        return "读取受保护路径：\(parts.joined(separator: " · "))"
    }

    public var checkedProbes: [PermissionProbe] {
        probes.filter { $0.access != .missing }
    }

    public var summary: String {
        switch fullDiskAccessStatus {
        case .granted: return "完全磁盘访问已授权"
        case .denied: return "完全磁盘访问未授权"
        case .undetermined: return "完全磁盘访问无法判定"
        }
    }

    public var detail: String {
        fullDiskAccessBasis
    }
}

public enum PermissionService {
    /// 受保护路径探针（按重要性排序）。废纸篓单独作为一项能力展示，不计入完全磁盘访问。
    public static func probes(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              fileManager: FileManager = .default) -> [PermissionProbe] {
        let candidates: [(String, String, String, String)] = [
            ("mail", "邮件数据", "Library/Mail", "读取邮件附件缓存与本地副本"),
            ("safari", "Safari 数据", "Library/Safari", "统计浏览器缓存与下载残留"),
            ("tcc", "隐私数据库", "Library/Application Support/com.apple.TCC",
             "确认系统隐私授权状态"),
            ("trash", "废纸篓", ".Trash", "读取并统计废纸篓占用")
        ]

        return candidates.map { id, title, relative, purpose in
            let url = home.appendingPathComponent(relative)
            let access: PermissionProbe.Access
            if !fileManager.fileExists(atPath: url.path) {
                access = .missing
            } else {
                let readable = (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil
                access = readable ? .granted : .denied
            }
            return PermissionProbe(id: id, title: title, path: url.path,
                                   purpose: purpose, access: access)
        }
    }

    public static func snapshot(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileManager: FileManager = .default) -> PermissionSnapshot {
        PermissionSnapshot(probes: probes(home: home, fileManager: fileManager))
    }

    /// 四项能力的结构化报告：完全磁盘访问、废纸篓、应用目录、登录项。
    public static func capabilities(from snapshot: PermissionSnapshot,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    fileManager: FileManager = .default) -> [PermissionCapability] {
        let trash = snapshot.probes.first { $0.id == "trash" }
        let trashStatus: CapabilityStatus
        let trashBasis: String
        switch trash?.access {
        case .granted:
            trashStatus = .granted
            trashBasis = "读取 \(trash?.path.replacingOccurrences(of: home.path, with: "~") ?? "~/.Trash") 目录列表成功"
        case .denied:
            trashStatus = .denied
            trashBasis = "目录存在但读取被拒绝，通常是隐私保护或尚未授权"
        case .missing, .none:
            trashStatus = .undetermined
            trashBasis = "废纸篓目录不存在，无法判定"
        }

        let apps = applicationsReadable(home: home, fileManager: fileManager)
        let login = loginItemCapability()

        return [
            PermissionCapability(
                id: "fda",
                title: "完全磁盘访问",
                purpose: "读取邮件、Safari、隐私数据库等受保护位置，让缓存与废纸篓统计完整",
                status: snapshot.fullDiskAccessStatus,
                basis: snapshot.fullDiskAccessBasis
            ),
            PermissionCapability(
                id: "trash",
                title: "废纸篓访问",
                purpose: "统计废纸篓占用，并能把清理项移入废纸篓",
                status: trashStatus,
                basis: trashBasis
            ),
            PermissionCapability(
                id: "applications",
                title: "应用目录可读",
                purpose: "列出已安装应用、版本与体积，识别关联残留",
                status: apps.status,
                basis: apps.basis
            ),
            PermissionCapability(
                id: "loginItem",
                title: "登录项能力",
                purpose: "把 O 注册为登录项，登录时自动启动",
                status: login.status,
                basis: login.basis
            )
        ]
    }

    /// 应用目录是否可读：/Applications 与 ~/Applications 任一可读即视为可读。
    public static func applicationsReadable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                            fileManager: FileManager = .default) -> (status: CapabilityStatus, basis: String) {
        let candidates = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications")
        ]
        var existing: [String] = []
        var readable: [String] = []
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            existing.append(url.path)
            if (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil {
                readable.append(url.path)
            }
        }
        if readable.isEmpty {
            if existing.isEmpty {
                return (.undetermined, "没有找到 /Applications 或 ~/Applications")
            }
            return (.denied, "目录存在但读取被拒绝：\(existing.joined(separator: "、"))")
        }
        return (.granted, "可读取：\(readable.joined(separator: "、"))")
    }

    /// 登录项能力来自 SMAppService 的真实状态。
    public static func loginItemCapability() -> (status: CapabilityStatus, basis: String) {
        let state = LoginItemController().currentState()
        switch state {
        case .enabled:
            return (.granted, "SMAppService 返回 enabled（已注册，登录时启动）")
        case .requiresApproval:
            return (.granted, "SMAppService 返回 requiresApproval（已登记，需在系统设置批准）")
        case .notRegistered:
            return (.denied, "SMAppService 返回 notRegistered（尚未注册）")
        case .notFound:
            return (.denied, "SMAppService 返回 notFound（通常应用不在「应用程序」文件夹）")
        case .unsupported:
            return (.undetermined, "当前系统不支持 SMAppService")
        case .failed(let message):
            return (.undetermined, message)
        }
    }

    /// 直接打开「系统设置 › 隐私与安全性 › 完全磁盘访问」。
    public static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// 打开「系统设置 › 通用 › 登录项」。
    public static func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings") {
            NSWorkspace.shared.open(url)
        }
    }
}
