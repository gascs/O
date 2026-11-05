import Foundation

/// 扫描 / 清理历史。以 JSON 写入 UserDefaults，避免额外文件 IO。
public struct HistoryStore {
    public enum Keys {
        public static let entries = "history.entries"
    }

    private let defaults: UserDefaults
    private let limit: Int

    public init(defaults: UserDefaults = .standard, limit: Int = 200) {
        self.defaults = defaults
        self.limit = max(1, limit)
    }

    public func load() -> [HistoryEntry] {
        guard let data = defaults.data(forKey: Keys.entries),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return []
        }
        return Array(entries.sorted { $0.date > $1.date }.prefix(limit))
    }

    public func append(_ entry: HistoryEntry) {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Keys.entries)
        }
    }

    public func clear() {
        defaults.removeObject(forKey: Keys.entries)
    }

    /// 累计已释放空间（只统计清理记录）。
    public var totalFreedBytes: Int64 {
        load().filter { $0.kind == .clean }.reduce(0) { $0 + $1.bytes }
    }

    public func recent(_ count: Int) -> [HistoryEntry] {
        Array(load().prefix(max(0, count)))
    }
}

/// 磁盘占用趋势：每天记录一个采样点，最多保留 30 天。
public struct DiskTrendStore {
    public enum Keys {
        public static let points = "disk.trend.points"
    }

    private let defaults: UserDefaults
    private let limit: Int
    private let calendar: Calendar

    public init(defaults: UserDefaults = .standard, limit: Int = 30, calendar: Calendar = .current) {
        self.defaults = defaults
        self.limit = max(1, limit)
        self.calendar = calendar
    }

    public func points() -> [DiskTrendPoint] {
        guard let data = defaults.data(forKey: Keys.points),
              let points = try? JSONDecoder().decode([DiskTrendPoint].self, from: data) else {
            return []
        }
        return points.sorted { $0.day < $1.day }
    }

    public func record(_ snapshot: DiskSnapshot, on date: Date = Date()) {
        record(usedBytes: snapshot.usedBytes, totalBytes: snapshot.totalBytes, on: date)
    }

    public func record(usedBytes: Int64, totalBytes: Int64, on date: Date = Date()) {
        let day = calendar.startOfDay(for: date)
        var points = points().filter { calendar.startOfDay(for: $0.day) != day }
        points.append(DiskTrendPoint(day: day, usedBytes: usedBytes, totalBytes: totalBytes))
        if points.count > limit {
            points = Array(points.sorted { $0.day < $1.day }.suffix(limit))
        }
        if let data = try? JSONEncoder().encode(points) {
            defaults.set(data, forKey: Keys.points)
        }
    }

    /// 最近 N 天的趋势（不足时按实际条数返回）。
    public func recent(days: Int) -> [DiskTrendPoint] {
        let cutoff = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: Date()) ?? Date())
        return points().filter { $0.day >= cutoff }
    }
}
