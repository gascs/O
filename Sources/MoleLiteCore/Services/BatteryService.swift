import Foundation
import IOKit.ps

/// 电池状态读取。使用 IOKit 电源信息，不执行任何 shell 命令。
public struct BatteryService: Sendable {
    public init() {}

    public func snapshot() -> BatterySnapshot {
        guard let infoRef = IOPSCopyPowerSourcesInfo() else { return .absent }
        let info = infoRef.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(info) else { return .absent }
        let list = listRef.takeRetainedValue() as Array

        for source in list {
            guard let descriptionRef = IOPSGetPowerSourceDescription(info, source as CFTypeRef) else { continue }
            guard let description = descriptionRef.takeUnretainedValue() as? [String: Any] else { continue }

            let current = description["Current Capacity"] as? Int ?? 0
            let maximum = description["Max Capacity"] as? Int ?? 0
            let isCharging = description["Is Charging"] as? Bool ?? false
            let isCharged = description["Is Charged"] as? Bool ?? false
            let state = description["Power Source State"] as? String ?? ""
            let isOnAC = state == "AC Power"
            let minutes = description["Time to Empty"] as? Int

            guard maximum > 0 else { continue }
            return BatterySnapshot(
                isPresent: true,
                chargeFraction: Double(current) / Double(maximum),
                isCharging: isCharging,
                isCharged: isCharged,
                timeRemainingMinutes: (minutes ?? -1) > 0 ? minutes : nil,
                isOnAC: isOnAC
            )
        }
        return .absent
    }
}
