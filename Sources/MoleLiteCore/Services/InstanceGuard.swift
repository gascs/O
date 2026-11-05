import Foundation
import Darwin

/// 单实例守卫：用文件锁保证同一用户会话只运行一个进程。
/// 第二个进程拿不到锁时，通过分布式通知让已有实例把窗口提到前台，然后自行退出。
public final class InstanceGuard {
    /// 进程内共享实例：应用入口取锁，退出时释放。
    public static let shared = InstanceGuard()

    /// 分布式通知名：新进程请求已有实例显示主窗口。
    public static let activationNotificationName = "com.o.app.activate-window"

    public static var activationNotification: Notification.Name {
        Notification.Name(activationNotificationName)
    }

    private let directory: URL
    public let lockFileURL: URL
    private var descriptor: Int32 = -1

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/O", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        self.lockFileURL = base.appendingPathComponent("instance.lock")
    }

    /// 尝试取得独占锁。返回 false 表示已有实例在运行。
    /// 锁文件都无法创建时放行，避免因为沙盒或只读卷导致应用完全无法启动。
    @discardableResult
    public func acquire() -> Bool {
        if descriptor >= 0 { return true }
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        descriptor = fd
        // 必须写回同一个 fd，不能用原子替换：替换会换掉 inode，锁仍留在旧文件上，
        // 第二个进程打开新文件就能再次加锁，单实例随之失效。
        let pid = "\(getpid())"
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        pid.withCString { pointer in
            _ = write(fd, pointer, Int(strlen(pointer)))
        }
        return true
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// 当前持锁进程的 PID（从锁文件读取，仅用于日志）。
    public var heldPID: Int? {
        guard let text = try? String(contentsOf: lockFileURL, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func postActivationRequest() {
        DistributedNotificationCenter.default().postNotificationName(
            activationNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
