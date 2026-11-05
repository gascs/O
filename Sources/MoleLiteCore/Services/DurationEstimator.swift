import Foundation

/// 一个耗时预估结果。`basis` 说明数字从哪来，界面直接展示，避免让用户以为是精确值。
public struct DurationEstimate: Sendable, Equatable {
    public let seconds: TimeInterval
    public let basis: String

    public init(seconds: TimeInterval, basis: String) {
        self.seconds = max(0, seconds)
        self.basis = basis
    }

    public var text: String { DurationEstimator.format(seconds) }

    public var detailedText: String {
        "\(text)（\(basis)）"
    }
}

/// 轻量耗时模型：用「每项耗时 + 每 MB 耗时」的线性模型，并根据实测结果做指数滑动平均校正。
///
/// 初始系数来自经验值；每次真实扫描 / 清理后都会更新，越用越接近本机实际情况。
public struct PerformanceCalibration: Codable, Sendable, Equatable {
    public var scanSecondsPerItem: Double = 0.0011
    public var scanItemsSeen: Int = 0
    public var averageScanSeconds: Double = 0
    public var averageScanItems: Double = 0
    public var cleanSecondsPerItem: Double = 0.0055
    public var cleanSecondsPerMB: Double = 0.018
    public var cleanRuns: Int = 0

    public init() {}

    public var hasScanHistory: Bool { scanItemsSeen >= 2 && averageScanItems > 0 }
    public var hasCleanHistory: Bool { cleanRuns >= 1 }
}

public final class DurationEstimator {
    public static let storageKey = "perf.durationCalibration"

    private let defaults: UserDefaults
    private(set) public var calibration: PerformanceCalibration

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(PerformanceCalibration.self, from: data) {
            calibration = decoded
        } else {
            calibration = PerformanceCalibration()
        }
    }

    // MARK: - 预估

    /// 扫描前的整体预估。没有历史样本时返回 nil，界面显示「首次扫描，无法预估」。
    public func scanEstimate(itemsHint: Int? = nil) -> DurationEstimate? {
        if let itemsHint, calibration.scanItemsSeen >= 1 {
            let seconds = Double(itemsHint) * calibration.scanSecondsPerItem
            return DurationEstimate(seconds: seconds, basis: "按历史每项耗时推算")
        }
        guard calibration.hasScanHistory else { return nil }
        return DurationEstimate(seconds: calibration.averageScanSeconds,
                                basis: "基于最近 \(calibration.scanItemsSeen) 次扫描均值")
    }

    /// 清理前预估：按条目数 + 体积。
    public func cleanEstimate(items: Int, bytes: Int64) -> DurationEstimate {
        let megabyte = Double(max(0, bytes)) / 1_048_576
        let seconds = Double(items) * calibration.cleanSecondsPerItem
            + megabyte * calibration.cleanSecondsPerMB
        let basis = calibration.hasCleanHistory ? "按最近 \(calibration.cleanRuns) 次清理校正" : "按经验系数估算"
        return DurationEstimate(seconds: seconds, basis: basis)
    }

    /// 进行中按已完成比例外推剩余时间（标准换算，不需要历史样本）。
    public func projectedRemaining(elapsed: TimeInterval, fraction: Double) -> DurationEstimate? {
        guard elapsed > 0.5, fraction > 0.02, fraction < 0.995 else { return nil }
        let remaining = elapsed * (1 - fraction) / fraction
        return DurationEstimate(seconds: remaining, basis: "按已完成进度推算")
    }

    // MARK: - 实测校正

    public func recordScan(seconds: TimeInterval, items: Int, bytes: Int64) {
        guard seconds > 0.05, items > 0 else { return }
        let samplePerItem = seconds / Double(items)
        if calibration.scanItemsSeen == 0 {
            calibration.scanSecondsPerItem = samplePerItem
        } else {
            calibration.scanSecondsPerItem = calibration.scanSecondsPerItem * 0.7 + samplePerItem * 0.3
        }
        if calibration.scanItemsSeen == 0 {
            calibration.averageScanSeconds = seconds
            calibration.averageScanItems = Double(items)
        } else {
            calibration.averageScanSeconds = calibration.averageScanSeconds * 0.6 + seconds * 0.4
            calibration.averageScanItems = calibration.averageScanItems * 0.6 + Double(items) * 0.4
        }
        calibration.scanItemsSeen += 1
        _ = bytes
        save()
    }

    public func recordClean(seconds: TimeInterval, items: Int, bytes: Int64) {
        guard seconds > 0.02, items > 0 else { return }
        let megabyte = max(0, Double(bytes)) / 1_048_576
        let perItemSample = seconds / Double(items)
        calibration.cleanSecondsPerItem = calibration.cleanSecondsPerItem * 0.65 + perItemSample * 0.35
        if megabyte >= 0.5 {
            let perMBSample = max(0, seconds - perItemSample * 0.5) / megabyte
            calibration.cleanSecondsPerMB = calibration.cleanSecondsPerMB * 0.7 + perMBSample * 0.3
        }
        calibration.cleanRuns += 1
        save()
    }

    public func reset() {
        calibration = PerformanceCalibration()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(calibration) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - 格式化

    /// 把秒数格式化成中文耗时描述。
    public static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0.05 else { return "不到 1 秒" }
        if seconds < 1 { return "不到 1 秒" }
        if seconds < 60 { return "约 \(Int(seconds.rounded())) 秒" }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.truncatingRemainder(dividingBy: 60).rounded())
        if minutes >= 60 {
            let hours = minutes / 60
            return "约 \(hours) 小时 \(minutes % 60) 分"
        }
        return remainder == 0 ? "约 \(minutes) 分钟" : "约 \(minutes) 分 \(remainder) 秒"
    }
}
