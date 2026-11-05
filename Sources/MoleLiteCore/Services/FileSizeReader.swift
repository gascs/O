import Foundation

/// 文件体积读取工具。
public enum FileSizeReader {
    public static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    public static var resourceKeyArray: [URLResourceKey] { Array(resourceKeys) }

    /// 优先使用磁盘实际占用（allocated size），拿不到再退回逻辑大小。
    public static func allocatedSize(_ values: URLResourceValues) -> Int64 {
        if let total = values.totalFileAllocatedSize { return Int64(total) }
        if let allocated = values.fileAllocatedSize { return Int64(allocated) }
        if let size = values.fileSize { return Int64(size) }
        return 0
    }

    public static func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return 0 }
        return allocatedSize(values)
    }

    /// 递归统计目录体积；不跟随符号链接，跳过目录自身。
    public static func treeSize(at url: URL, includeHidden: Bool = false, cancellation: ScanCancellation? = nil) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue { return allocatedSize(of: url) }

        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeyArray,
            options: options,
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let cancellation, cancellation.isCancelled { break }
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
            if values.isDirectory == true || values.isSymbolicLink == true { continue }
            total += allocatedSize(values)
        }
        return total
    }
}

/// 跨线程取消标记。detached 任务不继承父任务取消状态，因此需要显式的标志位。
public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    public func check() throws {
        if isCancelled { throw ScanError.cancelled }
    }
}
