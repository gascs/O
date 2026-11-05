import AppKit
import Combine
import MoleLiteCore

/// 全局权限状态中心：只在应用内维护一份快照，所有页面共用，避免每页各自探测。
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var snapshot: PermissionSnapshot
    /// 四项能力的结构化结果（完全磁盘访问 / 废纸篓 / 应用目录 / 登录项）。
    @Published private(set) var capabilities: [PermissionCapability]
    /// 从「未授权」变为「已授权」时触发，供界面提示并自动刷新数据。
    @Published private(set) var justGranted = false
    @Published private(set) var lastCheckedAt: Date

    private var observer: NSObjectProtocol?

    init() {
        let initial = PermissionService.snapshot()
        snapshot = initial
        capabilities = PermissionService.capabilities(from: initial)
        lastCheckedAt = initial.checkedAt
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 用户可能刚在系统设置里授权完切回来，重新实测一次。
            // Swift 5.10 不允许把 weak 捕获的 var 带进并发闭包，这里先绑定为 let。
            guard let owner = self else { return }
            Task { @MainActor in owner.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var hasFullDiskAccess: Bool { snapshot.hasFullDiskAccess }

    /// 是否所有能力都已授权；用于概览状态行与降级提示。
    var allGranted: Bool { capabilities.allSatisfy { $0.status == .granted } }

    var restrictedCapabilities: [PermissionCapability] {
        capabilities.filter { $0.status != .granted }
    }

    func capability(id: String) -> PermissionCapability? {
        capabilities.first { $0.id == id }
    }

    /// 重新探针。只有状态真正发生翻转时才更新 `justGranted`，避免误报。
    @discardableResult
    func refresh() -> Bool {
        let previous = snapshot
        let next = PermissionService.snapshot()
        snapshot = next
        capabilities = PermissionService.capabilities(from: next)
        lastCheckedAt = next.checkedAt
        let turnedOn = previous.fullDiskAccessStatus != .granted
            && next.fullDiskAccessStatus == .granted
        justGranted = turnedOn
        if turnedOn {
            NotificationCenter.default.post(name: .oPermissionGranted, object: nil)
        }
        return turnedOn
    }

    func dismissGrantedNotice() {
        justGranted = false
    }

    func openSettings() {
        PermissionService.openFullDiskAccessSettings()
    }

    func openLoginItemSettings() {
        PermissionService.openLoginItemsSettings()
    }

    /// 权限需要重启才生效时的明确出口：先派生一个延时启动的新实例，再退出当前实例。
    func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            NSApp.terminate(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1.2; /usr/bin/open -n \"\(bundlePath)\""]
        try? process.run()
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let oPermissionGranted = Notification.Name("o.permissionGranted")
}
