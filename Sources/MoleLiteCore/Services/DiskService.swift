import Foundation

/// 磁盘容量读取。
public struct DiskService: Sendable {
    public init() {}

    public func snapshot(for url: URL = URL(fileURLWithPath: "/")) -> DiskSnapshot? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }

        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let name = values.volumeName ?? "磁盘"
        return DiskSnapshot(
            volumeName: name,
            totalBytes: Int64(total),
            availableBytes: max(0, Int64(available))
        )
    }
}
