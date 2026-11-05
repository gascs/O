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

/// 一次完整采样的不可变快照（磁盘 / 内存 / CPU / 网络 / 电池 / 硬件与系统详情）。
///
/// 为什么引入它：这些数据原来由 OverviewViewModel（每 2 秒）和 MenuBarMonitor（每 5 秒）
/// 各自在主线程直接读 IOKit、getifaddrs 和磁盘属性，一次刷新在主要线程上串行做多件
/// 相对重的活（Metal 设备枚举、IOKit 电池、文件系统查询），并且两套循环还在重复读同一批
/// 指标。改成「后台采好一个值 → 主线程只接收这个值发布」后，主线程每 tick 只剩一次赋值，
/// 磁盘、CPU、网络、电池、系统详情也只读一遍、多处复用。
public struct SystemSample: Sendable, Equatable {
    public var disk: DiskSnapshot?
    public var memory: MemorySnapshot?
    public var cpuUsage: Double
    public var cpuHistory: [Double]
    public var network: NetworkRate
    public var battery: BatterySnapshot
    public var hardware: HardwareInfo?
    public var systemInfo: SystemInfo?
    /// 采样完成时间。UI 用它判断「采样中 / 已降频」，暂停面板也用它做冻结基准。
    public var sampledAt: Date

    public init(
        disk: DiskSnapshot? = nil,
        memory: MemorySnapshot? = nil,
        cpuUsage: Double = 0,
        cpuHistory: [Double] = [],
        network: NetworkRate = .zero,
        battery: BatterySnapshot = .absent,
        hardware: HardwareInfo? = nil,
        systemInfo: SystemInfo? = nil,
        sampledAt: Date = .distantPast
    ) {
        self.disk = disk
        self.memory = memory
        self.cpuUsage = cpuUsage
        self.cpuHistory = cpuHistory
        self.network = network
        self.battery = battery
        self.hardware = hardware
        self.systemInfo = systemInfo
        self.sampledAt = sampledAt
    }

    public static let empty = SystemSample()
}

/// 后台系统采样器。
///
/// `actor` 的方法体和它创建的对象都在 actor 的执行器上运行，不占用主线程；
/// `SharedSystemMonitor` 每次 `await sampler.sample()` 拿到的已经是纯值。
/// 采样器内部保留少量状态（上一次 CPU 计数、CPU 历史曲线、硬件缓存、系统详情缓存），
/// 因此整个 App 只需要一个实例，两处 UI 共享同一条数据流。
public actor SystemSampler {
    private let metrics = SystemMetricsService()
    private let diskService = DiskService()
    private let batteryService = BatteryService()
    private let deviceService = DeviceInfoService()
    private var networkSampler = NetworkSampler()

    private var previousCPUSample: CPUSample?
    private var cpuHistory: [Double] = []
    /// CPU 曲线只保留最近 60 个点：2 秒一个点 = 2 分钟，足够画 sparkline，
    /// 同时让主线程每次发布的数组有固定上界（避免无限增长导致 body 计算变慢）。
    private let cpuHistoryLimit = 60

    private var cachedHardware: HardwareInfo?
    private var cachedHardwareAt: Date?
    private var cachedSystemInfo: SystemInfo?
    private var tick = 0

    public init() {}

    public func sample() -> SystemSample {
        let now = Date()
        var sample = SystemSample.empty
        sample.sampledAt = now

        // 磁盘可用容量是「可用空间」卡片与菜单栏头部的核心数据，每 tick 都读；
        // 它是 URLResourceValues 的轻量查询，不会像 IOKit 枚举那样抖动。
        sample.disk = diskService.snapshot()
        sample.memory = metrics.memory()

        if let cpu = metrics.cpuSample() {
            if let previous = previousCPUSample {
                let usage = cpu.usage(since: previous)
                sample.cpuUsage = usage
                cpuHistory.append(usage)
                if cpuHistory.count > cpuHistoryLimit {
                    cpuHistory.removeFirst(cpuHistory.count - cpuHistoryLimit)
                }
            }
            previousCPUSample = cpu
        }
        sample.cpuHistory = cpuHistory

        // NetworkSampler 是差分采样，必须每 tick 调用才能得到速率；内部含 getifaddrs。
        sample.network = networkSampler.sample(at: now) ?? .zero
        sample.battery = batteryService.snapshot()

        // 硬件型号 / GPU 名称 / 序列号几乎不变，60 秒读一次即可：
        // 其中 MTLCreateSystemDefaultDevice 首次创建 Metal 设备较慢，
        // 放在每 tick 的路径上会直接拖慢菜单栏展开。
        if cachedHardware == nil || now.timeIntervalSince(cachedHardwareAt ?? .distantPast) > 60 {
            cachedHardware = deviceService.hardware()
            cachedHardwareAt = now
        }
        sample.hardware = cachedHardware

        // 系统详情里的 IOKit 电池属性、getifaddrs 接口枚举与磁盘查询相对较重，
        // 用「每 5 次采样做一次完整 live 刷新，其余只推进运行时长」稀释，
        // 既保证详情页几秒内能看到电池/温度变化，也不会每 2 秒读一次 IOKit。
        tick &+= 1
        if let previous = cachedSystemInfo {
            if tick % 5 == 0 {
                cachedSystemInfo = deviceService.liveSystemSnapshot(previous: previous)
            } else {
                var updated = previous
                updated.uptime = ProcessInfo.processInfo.systemUptime
                cachedSystemInfo = updated
            }
        } else {
            cachedSystemInfo = deviceService.systemSnapshot()
        }
        sample.systemInfo = cachedSystemInfo
        return sample
    }
}

/// 废纸篓体积探测（只读）。
///
/// 为什么单独实现：`~/.Trash` 里可能是上万个小文件，递归枚举要几十毫秒，
/// 绝不能放进 2 秒的采样循环。它只在后台每 60 秒跑一次，用于概览页展示
/// 「废纸篓」占用，而不再把废纸篓算进可清理估算（那会把用户没打算删的东西
/// 算成「可清理」，也会让估算扫描多走一遍目录树）。
public struct TrashSizeProbe: Sendable {
    public init() {}

    /// 返回废纸篓内已分配空间总字节数；废纸篓不存在时返回 0。
    public func size() -> Int64 {
        let fileManager = FileManager.default
        let trash = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        guard fileManager.fileExists(atPath: trash.path) else { return 0 }

        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: trash,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { continue }
            // 优先使用「分配大小」，与 Finder 的「大小」口径接近，且不受稀疏文件影响。
            let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            total += max(0, Int64(allocated))
        }
        return total
    }
}
