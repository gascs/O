import Darwin
import Foundation

/// 网络流量采样：读取 getifaddrs 的累计字节数，求区间差值得到速率。
/// 只统计已启用、非回环、非虚拟隧道以外的常规接口，不读取任何报文内容。
public struct NetworkSampler: Sendable {
    private var previousTotal: (received: Int64, sent: Int64)?
    private var previousDate: Date?

    public init() {}

    public mutating func sample(at date: Date = Date()) -> NetworkRate? {
        guard let total = NetworkSampler.counterTotals() else { return nil }
        defer {
            previousTotal = total
            previousDate = date
        }
        guard let previous = previousTotal, let lastDate = previousDate else {
            return NetworkRate(downBytesPerSecond: 0, upBytesPerSecond: 0,
                               totalReceivedBytes: total.received, totalSentBytes: total.sent)
        }
        let elapsed = date.timeIntervalSince(lastDate)
        guard elapsed > 0.05 else { return nil }
        let down = Double(total.received - previous.received) / elapsed
        let up = Double(total.sent - previous.sent) / elapsed
        return NetworkRate(downBytesPerSecond: max(0, down), upBytesPerSecond: max(0, up),
                           totalReceivedBytes: total.received, totalSentBytes: total.sent)
    }

    /// 汇总所有外部接口的收发字节数（排除回环）。
    public static func counterTotals() -> (received: Int64, sent: Int64)? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var received: Int64 = 0
        var sent: Int64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let name = current.pointee.ifa_name else { continue }
            if String(cString: name) == "lo0" { continue }
            let flags = current.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0 else { continue }
            guard (flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            guard let data = current.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            received += Int64(stats.ifi_ibytes)
            sent += Int64(stats.ifi_obytes)
        }
        return (received, sent)
    }
}
