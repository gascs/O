import AppKit
import Foundation
import MoleLiteCore

/// 系统概览页面的状态。
@MainActor
final class OverviewViewModel: ObservableObject {
    @Published private(set) var disk: DiskSnapshot?
    @Published private(set) var memory: MemorySnapshot?
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var network: NetworkRate = .zero
    @Published private(set) var battery: BatterySnapshot = .absent
    @Published private(set) var cleanableBytes: Int64?
    @Published private(set) var recommendations: [RecommendationGroup] = []
    @Published private(set) var categoryBreakdown: [ScanCategory: Int64] = [:]
    @Published private(set) var isEstimating = false
    @Published private(set) var estimateMessage: String?
    @Published private(set) var trend: [DiskTrendPoint] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var totalFreedBytes: Int64 = 0
    @Published private(set) var lastScanEntry: HistoryEntry?

    // 设备与系统信息
    @Published private(set) var hardware: HardwareInfo?
    @Published private(set) var systemInfo: SystemInfo?
    @Published private(set) var screenSummary: String?
    @Published private(set) var screenNote: String?

    private let diskService = DiskService()
    private let metrics = SystemMetricsService()
    private let batteryService = BatteryService()
    private let deviceService = DeviceInfoService()
    private var networkSampler = NetworkSampler()
    private var lastCPUSample: CPUSample?
    private var refreshTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var lastTrendDay: Date?
    private var lastHardwareDate: Date?
    /// 窗口不可见时降频到 10 秒一次，避免后台空转。
    private var lastSampleDate: Date?

    var processorCount: Int { ProcessInfo.processInfo.processorCount }

    var isSamplingFast: Bool {
        guard let lastSampleDate else { return true }
        return Date().timeIntervalSince(lastSampleDate) < 3
    }

    func start() {
        guard refreshTask == nil else { return }
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 窗口隐藏 / 最小化（含关窗驻留菜单栏）才降频；被其它窗口盖住时仍按 2 秒采样，
                // 这样把 O 留在后台也能得到连续的实时曲线。
                let visible = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
                let interval: UInt64 = visible ? 2_000_000_000 : 10_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        // 只停采样，不打断正在进行的一次性估算。
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        lastSampleDate = Date()
        disk = diskService.snapshot()
        memory = metrics.memory()
        if let sample = metrics.cpuSample() {
            if let previous = lastCPUSample {
                let usage = sample.usage(since: previous)
                cpuUsage = usage
                cpuHistory.append(usage)
                if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
            }
            lastCPUSample = sample
        }
        network = networkSampler.sample() ?? network
        battery = batteryService.snapshot()
        refreshDeviceInfo()

        let store = HistoryStore()
        history = store.recent(6)
        totalFreedBytes = store.totalFreedBytes
        lastScanEntry = store.load().first { $0.kind == .scan }
        trend = DiskTrendStore().recent(days: 7)

        if let disk {
            let today = Calendar.current.startOfDay(for: Date())
            if lastTrendDay != today {
                lastTrendDay = today
                DiskTrendStore().record(disk)
            }
        }
    }

    /// 硬件信息变化慢：首次读取后每 60 秒刷新一次；系统状态每次采样都更新。
    private func refreshDeviceInfo() {
        if hardware == nil || Date().timeIntervalSince(lastHardwareDate ?? .distantPast) > 60 {
            hardware = deviceService.hardware()
            lastHardwareDate = Date()
        }
        if let current = systemInfo {
            systemInfo = deviceService.liveSystemSnapshot(previous: current)
        } else {
            systemInfo = deviceService.systemSnapshot()
        }
        refreshScreenInfo()
    }

    private func refreshScreenInfo() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            screenSummary = nil
            screenNote = "无法读取屏幕信息"
            return
        }
        let points = screen.frame.size
        let scale = screen.backingScaleFactor
        let pixelWidth = Int((points.width * scale).rounded())
        let pixelHeight = Int((points.height * scale).rounded())
        screenSummary = "\(pixelWidth) × \(pixelHeight) · \(String(format: "%.0f", scale))x"
        screenNote = "\(Int(points.width)) × \(Int(points.height)) 点"
    }

    /// 估算可清理空间，并给出三档建议（缓存 + 日志 + Xcode + 废纸篓）。
    func estimateCleanable() {
        guard !isEstimating else { return }
        isEstimating = true
        estimateMessage = nil
        let scanner = Scanner(settings: ScanSettings.load())
        let categories: [ScanCategory] = [.userCaches, .logs, .xcode, .trash]

        estimateTask = Task { [weak self] in
            do {
                let report = try await scanner.scan(categories: categories)
                guard let self else { return }
                self.cleanableBytes = report.totalBytes
                self.recommendations = RecommendationEngine.groups(in: report)
                self.categoryBreakdown = Dictionary(
                    report.results.map { ($0.category, $0.totalBytes) },
                    uniquingKeysWith: { $0 + $1 }
                )
                self.isEstimating = false
            } catch {
                guard let self else { return }
                self.isEstimating = false
                self.estimateMessage = "估算失败：\(error.localizedDescription)"
            }
        }
    }
}
