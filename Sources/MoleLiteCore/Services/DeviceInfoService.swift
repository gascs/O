import Foundation
import Darwin
import IOKit

#if canImport(Metal)
import Metal
#endif

// MARK: - 设备与系统信息
//
// 全部通过系统 API（sysctl / IOKit / ProcessInfo / getifaddrs / Metal）读取。
// 任何一项读不到时保持 nil，由界面显示「不可用」与原因，绝不伪造。

public struct HardwareInfo: Sendable, Equatable {
    public var modelIdentifier: String?
    public var chipName: String?
    public var totalCores: Int
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var memoryBytes: Int64
    public var gpuName: String?
    /// 序列号后四位（脱敏标识），不暴露完整序列号。
    public var serialSuffix: String?
    public var memoryPressure: String?

    public init(modelIdentifier: String? = nil, chipName: String? = nil,
                totalCores: Int = 0, performanceCores: Int? = nil, efficiencyCores: Int? = nil,
                memoryBytes: Int64 = 0, gpuName: String? = nil,
                serialSuffix: String? = nil, memoryPressure: String? = nil) {
        self.modelIdentifier = modelIdentifier
        self.chipName = chipName
        self.totalCores = totalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.memoryBytes = memoryBytes
        self.gpuName = gpuName
        self.serialSuffix = serialSuffix
        self.memoryPressure = memoryPressure
    }

    public var coreSummary: String? {
        guard totalCores > 0 else { return nil }
        if let performanceCores, let efficiencyCores, performanceCores + efficiencyCores > 0 {
            return "\(totalCores) 核（\(performanceCores) 性能 + \(efficiencyCores) 能效）"
        }
        return "\(totalCores) 核"
    }
}

public struct BatteryDetail: Sendable, Equatable {
    public var isPresent: Bool
    public var healthPercent: Int?
    public var cycleCount: Int?
    public var condition: String?
    public var isCharging: Bool
    public var chargePercent: Int?
    public var isOnAC: Bool

    public init(isPresent: Bool = false, healthPercent: Int? = nil, cycleCount: Int? = nil,
                condition: String? = nil, isCharging: Bool = false,
                chargePercent: Int? = nil, isOnAC: Bool = false) {
        self.isPresent = isPresent
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.condition = condition
        self.isCharging = isCharging
        self.chargePercent = chargePercent
        self.isOnAC = isOnAC
    }

    public static let absent = BatteryDetail()

    public var statusText: String {
        guard isPresent else { return "无电池" }
        if isCharging { return "充电中" }
        if isOnAC { return "已接电源" }
        return "使用电池"
    }
}

public struct NetworkInterfaceInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var address: String
    public var isPrimary: Bool

    public var id: String { "\(name)-\(address)" }

    public init(name: String, address: String, isPrimary: Bool = false) {
        self.name = name
        self.address = address
        self.isPrimary = isPrimary
    }
}

public struct SystemInfo: Sendable, Equatable {
    public var osVersion: String
    public var buildNumber: String?
    public var uptime: TimeInterval
    public var bootVolume: DiskSnapshot?
    public var battery: BatteryDetail
    public var thermalState: String
    public var networkInterfaces: [NetworkInterfaceInfo]
    public var hostName: String?

    public init(osVersion: String, buildNumber: String? = nil, uptime: TimeInterval = 0,
                bootVolume: DiskSnapshot? = nil, battery: BatteryDetail = .absent,
                thermalState: String = "", networkInterfaces: [NetworkInterfaceInfo] = [],
                hostName: String? = nil) {
        self.osVersion = osVersion
        self.buildNumber = buildNumber
        self.uptime = uptime
        self.bootVolume = bootVolume
        self.battery = battery
        self.thermalState = thermalState
        self.networkInterfaces = networkInterfaces
        self.hostName = hostName
    }
}

public struct DeviceInfoService: Sendable {
    public init() {}

    // MARK: 硬件

    public func hardware() -> HardwareInfo {
        let chip = sysctlString("machdep.cpu.brand_string")
        let cores = ProcessInfo.processInfo.processorCount
        let performance = sysctlInt("hw.perflevel0.physicalcpu")
        let efficiency = sysctlInt("hw.perflevel1.physicalcpu")
        let memory = Int64(ProcessInfo.processInfo.physicalMemory)
        return HardwareInfo(
            modelIdentifier: sysctlString("hw.model"),
            chipName: chip,
            totalCores: cores,
            performanceCores: performance,
            efficiencyCores: efficiency,
            memoryBytes: memory,
            gpuName: gpuName(),
            serialSuffix: serialSuffix(),
            memoryPressure: memoryPressureText()
        )
    }

    // MARK: 系统

    public func systemSnapshot() -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion: String
        if version.patchVersion > 0 {
            osVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        } else {
            osVersion = "macOS \(version.majorVersion).\(version.minorVersion)"
        }
        return SystemInfo(
            osVersion: osVersion,
            buildNumber: sysctlString("kern.osversion"),
            uptime: ProcessInfo.processInfo.systemUptime,
            bootVolume: DiskService().snapshot(for: URL(fileURLWithPath: "/")),
            battery: batteryDetail(),
            thermalState: thermalStateText(ProcessInfo.processInfo.thermalState),
            networkInterfaces: networkInterfaces(),
            hostName: ProcessInfo.processInfo.hostName
        )
    }

    /// 实时刷新较便宜的部分（运行时长、电池、热压力、网络），用于 2 秒采样。
    public func liveSystemSnapshot(previous: SystemInfo) -> SystemInfo {
        var snapshot = previous
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.battery = batteryDetail()
        snapshot.thermalState = thermalStateText(ProcessInfo.processInfo.thermalState)
        snapshot.networkInterfaces = networkInterfaces()
        snapshot.bootVolume = DiskService().snapshot(for: URL(fileURLWithPath: "/"))
        return snapshot
    }

    // MARK: - 私有读取

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    private func gpuName() -> String? {
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            return device.name
        }
        #endif
        return nil
    }

    private func serialSuffix() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service,
                                                          "IOPlatformSerialNumber" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        return String(trimmed.suffix(4))
    }

    private func memoryPressureText() -> String? {
        var status: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &status, &size, nil, 0) == 0 else {
            return nil
        }
        switch status {
        case 1: return "正常"
        case 2: return "警告"
        case 4: return "严重"
        default: return nil
        }
    }

    private func batteryDetail() -> BatteryDetail {
        let snapshot = BatteryService().snapshot()
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .absent }
        defer { IOObjectRelease(service) }
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any] else {
            return .absent
        }
        let cycle = properties["CycleCount"] as? Int
        let design = properties["DesignCapacity"] as? Int
        let rawMax = (properties["AppleRawMaxCapacity"] as? Int) ?? (properties["MaxCapacity"] as? Int)
        var health: Int?
        if let design, design > 0, let rawMax, rawMax > 0 {
            health = max(0, min(100, Int((Double(rawMax) / Double(design) * 100).rounded())))
        }
        var condition: String?
        if let health {
            condition = health >= 80 ? "正常" : "建议检修"
        } else if let permanent = properties["PermanentFailureStatus"] as? Int, permanent != 0 {
            condition = "异常"
        }
        let detail = BatteryDetail(
            isPresent: true,
            healthPercent: health,
            cycleCount: cycle,
            condition: condition,
            isCharging: snapshot.isCharging,
            chargePercent: snapshot.isPresent ? Int((snapshot.chargeFraction * 100).rounded()) : nil,
            isOnAC: snapshot.isOnAC
        )
        return detail
    }

    private func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "偏高"
        case .serious: return "较高"
        case .critical: return "临界"
        @unknown default: return "未知"
        }
    }

    private func networkInterfaces() -> [NetworkInterfaceInfo] {
        var interfaces: [NetworkInterfaceInfo] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addressPointer = current.pointee.ifa_addr else { continue }
            guard addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var address = addressPointer.pointee
            var buffer = [CChar](repeating: 0, count: 64)
            if inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil {
                let ip = String(cString: buffer)
                if ip.hasPrefix("169.254.") { continue }
                let entry = NetworkInterfaceInfo(name: name, address: ip,
                                                 isPrimary: name == "en0" && !interfaces.contains { $0.isPrimary })
                if !interfaces.contains(where: { $0.name == name && $0.address == ip }) {
                    interfaces.append(entry)
                }
            }
        }
        return interfaces.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.name < rhs.name
        }
    }
}
