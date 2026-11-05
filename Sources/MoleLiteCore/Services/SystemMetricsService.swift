import Darwin
import Foundation

/// 系统指标读取（内存 / CPU）。仅使用 Mach 与 sysctl，不依赖第三方库。
public struct SystemMetricsService: Sendable {
    public init() {}

    private var pageSize: Int64 {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return Int64(size)
    }

    public func memory() -> MemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Int64(pageSize)
        let active = Int64(stats.active_count) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let used = active + wired + compressed

        let swap = swapUsage()
        return MemorySnapshot(
            totalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            usedBytes: used,
            wiredBytes: wired,
            compressedBytes: compressed,
            swapTotalBytes: swap.total,
            swapUsedBytes: swap.used
        )
    }

    /// 累计 CPU 时间片采样，配合 `CPUSample.usage(since:)` 计算区间占用率。
    public func cpuSample() -> CPUSample? {
        var info = host_cpu_load_info_data_t()
        var count = UInt32(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUSample(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3),
            idle: UInt64(info.cpu_ticks.2)
        )
    }

    private func swapUsage() -> (total: Int64, used: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        let result = sysctl(&mib, u_int(mib.count), &usage, &size, nil, 0)
        guard result == 0 else { return (0, 0) }
        return (Int64(usage.xsu_total), Int64(usage.xsu_used))
    }
}
