import Foundation

/// 磁盘快照。
public struct DiskSnapshot: Sendable, Equatable {
    public let volumeName: String
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init(volumeName: String, totalBytes: Int64, availableBytes: Int64) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    public var availableFraction: Double { 1 - usedFraction }
}

/// 内存快照。
public struct MemorySnapshot: Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let wiredBytes: Int64
    public let compressedBytes: Int64
    public let swapTotalBytes: Int64
    public let swapUsedBytes: Int64

    public init(totalBytes: Int64, usedBytes: Int64, wiredBytes: Int64, compressedBytes: Int64, swapTotalBytes: Int64, swapUsedBytes: Int64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

/// CPU 累计时间片采样，用于两次采样求差值算出占用率。
public struct CPUSample: Sendable, Equatable {
    public let user: UInt64
    public let system: UInt64
    public let nice: UInt64
    public let idle: UInt64

    public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
    }

    public var busy: UInt64 { user + system + nice }
    public var total: UInt64 { busy + idle }

    /// 相对上一次采样的 CPU 占用率（0...1）。
    public func usage(since previous: CPUSample) -> Double {
        let deltaBusy = Double(busy &- previous.busy)
        let deltaTotal = Double(total &- previous.total)
        guard deltaTotal > 0 else { return 0 }
        return min(1, max(0, deltaBusy / deltaTotal))
    }
}
