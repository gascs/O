import AppKit
import Combine
import Foundation
import MoleLiteCore

/// 系统概览页面的状态。
///
/// 采样不再由本类执行：指标来自 `SharedSystemMonitor`（后台 actor 采样 → 主线程发布），
/// 本类只把快照镜像成 `@Published` 属性，并维护「估算可清理空间」这一次性任务。
/// 这样主线程每 2 秒只有一次赋值，不再同步读 IOKit / getifaddrs / 磁盘 / 历史 JSON。
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

    /// 废纸篓占用体积：只读展示，不计入「可清理」。
    @Published private(set) var trashBytes: Int64?

    private let shared = SharedSystemMonitor.shared
    private var cancellables: Set<AnyCancellable> = []
    private var isBound = false

    private var estimateTask: Task<Void, Never>?
    private var estimateCancellation: ScanCancellation?
    /// 估算代次：每次发起 / 取消都自增。旧任务返回时代次不匹配就直接丢弃，
    /// 不会把新一轮（或已取消）的估算状态改回旧值。
    private var estimateGeneration = 0

    private var lastSampleDate: Date?

    var processorCount: Int { ProcessInfo.processInfo.processorCount }

    var isSamplingFast: Bool {
        guard let lastSampleDate else { return true }
        return Date().timeIntervalSince(lastSampleDate) < 3
    }

    func start() {
        bindIfNeeded()
        // 概览页需要连续曲线：通知共享采样中心切到高频档位，并立刻补一次采样。
        shared.setOverviewActive(true)
        shared.refreshNow()
        mirrorSample(shared.sample)
        mirrorHistory(shared.historySummary)
        trashBytes = shared.trashBytes
    }

    func stop() {
        // 离开页面：降回低频采样，并停止可能还在跑的可清理估算。
        shared.setOverviewActive(false)
        cancelEstimate()
    }

    /// 兼容原有调用方（RootView 授权变化 / 手动刷新）：只唤醒共享采样器，立即返回。
    /// 真正的 IOKit / 磁盘读取在后台 actor 上完成，主线程不再被阻塞。
    func refresh() {
        shared.refreshNow()
    }

    // MARK: - 共享快照镜像

    private func bindIfNeeded() {
        guard !isBound else { return }
        isBound = true

        shared.$sample
            .sink { [weak self] snapshot in
                Task { @MainActor in self?.mirrorSample(snapshot) }
            }
            .store(in: &cancellables)

        shared.$historySummary
            .sink { [weak self] summary in
                Task { @MainActor in self?.mirrorHistory(summary) }
            }
            .store(in: &cancellables)

        shared.$trashBytes
            .sink { [weak self] bytes in
                Task { @MainActor in self?.trashBytes = bytes }
            }
            .store(in: &cancellables)
    }

    private func mirrorSample(_ snapshot: SystemSample) {
        lastSampleDate = snapshot.sampledAt
        disk = snapshot.disk
        memory = snapshot.memory
        cpuUsage = snapshot.cpuUsage
        cpuHistory = snapshot.cpuHistory
        network = snapshot.network
        battery = snapshot.battery
        hardware = snapshot.hardware
        systemInfo = snapshot.systemInfo
        refreshScreenInfo()
    }

    private func mirrorHistory(_ summary: HistorySummary) {
        history = summary.recent
        totalFreedBytes = summary.totalFreedBytes
        lastScanEntry = summary.lastScanEntry
        trend = summary.trend
    }

    /// 屏幕信息只在主线程读取（NSScreen 不是线程安全的），且开销极小，每次镜像时刷新。
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

    // MARK: - 可清理空间估算

    /// 估算可清理空间，并给出三档建议（缓存 + 日志 + Xcode）。
    ///
    /// 与旧实现相比多了三层保护：
    /// 1. 可取消：离开概览页（stop）或重新发起时，立刻取消底层扫描，
    ///    不再出现「人已经走了还在扫盘」；
    /// 2. 代次（generation）：旧任务即使走完，也会因代次不匹配被直接丢弃，
    ///    不会覆盖新一轮的进度 / 结果；
    /// 3. 不覆盖手动扫描：主窗口正在全盘扫描时先等待它结束（可取消），
    ///    避免两套遍历同时抢 IO；估算结果也只写自己的 cleanableBytes / recommendations，
    ///    不触碰用户手动扫描的 progress / report。
    ///
    /// 废纸篓不再算进「可清理」：用户未必想清空废纸篓，概览页改为单独展示其体积。
    func estimateCleanable() {
        // 同一时刻只允许一轮估算：切页 / 授权回调重复触发时复用在途任务。
        if isEstimating, let task = estimateTask, !task.isCancelled { return }

        estimateTask?.cancel()
        estimateGeneration &+= 1
        let generation = estimateGeneration
        isEstimating = true
        estimateMessage = nil

        let scanner = Scanner(settings: ScanSettings.load())
        let categories: [ScanCategory] = [.userCaches, .logs, .xcode]
        let cancellation = ScanCancellation()
        estimateCancellation = cancellation

        estimateTask = Task { [weak self] in
            // 主窗口正在扫描时先让路：每 0.5 秒看一次，被取消就立刻退出。
            // 最多等 5 分钟，避免协调状态异常时估算永远悬着。
            var waited: Double = 0
            while AppCoordinator.shared.isScanning, waited < 300 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
            }
            do {
                let report = try await scanner.scan(categories: categories, cancellation: cancellation)
                guard let self, !Task.isCancelled, self.estimateGeneration == generation else { return }
                self.cleanableBytes = report.totalBytes
                self.recommendations = RecommendationEngine.groups(in: report)
                self.categoryBreakdown = Dictionary(
                    report.results.map { ($0.category, $0.totalBytes) },
                    uniquingKeysWith: { $0 + $1 }
                )
                self.isEstimating = false
                self.estimateCancellation = nil
            } catch {
                guard let self, !Task.isCancelled, self.estimateGeneration == generation else { return }
                self.isEstimating = false
                self.estimateCancellation = nil
                self.estimateMessage = "估算失败：\(error.localizedDescription)"
            }
        }
    }

    private func cancelEstimate() {
        estimateGeneration &+= 1
        estimateCancellation?.cancel()
        estimateCancellation = nil
        estimateTask?.cancel()
        estimateTask = nil
        if isEstimating { isEstimating = false }
    }
}
