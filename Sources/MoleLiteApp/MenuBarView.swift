import AppKit
import Combine
import MoleLiteCore
import SwiftUI

// MARK: - 历史摘要缓存

/// 历史 / 趋势的派生摘要：一次解码出界面需要的全部字段。
struct HistorySummary {
    var recent: [HistoryEntry] = []
    var totalFreedBytes: Int64 = 0
    var lastScanEntry: HistoryEntry?
    var trend: [DiskTrendPoint] = []

    static let empty = HistorySummary()
}

/// 历史 / 趋势解码缓存：UserDefaults 里的原始 Data 没变化就绝不重复解码。
///
/// 原实现每个采样 tick 要解码 4 次（概览的 recent(6)、累计释放、上次扫描、趋势），
/// 菜单栏再解码 1 次；200 条历史在主线程上每次约零点几毫秒。单次不致命，但它每 2 秒
/// 就与 SwiftUI 绘制抢同一帧。这里把「原始 Data 是否变化」当缓存键：
/// 只有真正扫描 / 清理写入后才会解码一次，其余 tick 只是一次 Data 比较。
@MainActor
final class HistorySummaryCache {
    static let shared = HistorySummaryCache()

    private let defaults = UserDefaults.standard
    private var lastEntriesData: Data?
    private var lastTrendData: Data?
    private var cachedEntries: [HistoryEntry] = []
    private var cachedTrend: [DiskTrendPoint] = []
    private var summary = HistorySummary.empty

    private init() {}

    /// 读取摘要；底层数据没变时直接返回上次结果（O(1) 命中）。
    func current() -> HistorySummary {
        let entriesData = defaults.data(forKey: HistoryStore.Keys.entries)
        let trendData = defaults.data(forKey: DiskTrendStore.Keys.points)
        var dirty = false
        if entriesData != lastEntriesData {
            lastEntriesData = entriesData
            cachedEntries = HistoryStore().load()
            dirty = true
        }
        if trendData != lastTrendData {
            lastTrendData = trendData
            cachedTrend = DiskTrendStore().points()
            dirty = true
        }
        guard dirty else { return summary }

        summary.recent = Array(cachedEntries.prefix(6))
        summary.totalFreedBytes = cachedEntries
            .filter { $0.kind == .clean }
            .reduce(0) { $0 + $1.bytes }
        summary.lastScanEntry = cachedEntries.first { $0.kind == .scan }
        let calendar = Calendar.current
        let cutoff = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        summary.trend = cachedTrend.filter { $0.day >= cutoff }
        return summary
    }
}

// MARK: - 统一采样中心

/// 全 App 唯一的系统采样中心：主窗口概览与菜单栏共用同一份快照、同一条采样循环。
///
/// 改造前的两条独立循环：
/// - OverviewViewModel：2 秒一次，在主线程同步读 IOKit / getifaddrs / 磁盘 / 历史 JSON；
/// - MenuBarMonitor：5 秒一次，同样在主线程再读一遍相同的指标。
/// 两者不仅重复读，读的还是同一条「贵」路径。现在采样本体在 `SystemSampler`
///（actor，后台执行器）里完成，主线程只接收一个不可变快照并赋值；
/// 采样频率按「谁需要更密」取最小值（概览页 2 秒），两处显示永远同一时刻的快照。
@MainActor
final class SharedSystemMonitor: ObservableObject {
    static let shared = SharedSystemMonitor()

    @Published private(set) var sample: SystemSample = .empty
    @Published private(set) var historySummary: HistorySummary = .empty
    @Published private(set) var trashBytes: Int64?

    private let sampler = SystemSampler()
    private let historyCache = HistorySummaryCache.shared

    private var loopTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var isSampling = false
    private var overviewActive = false
    private var lastTrendDay: Date?
    private var lastTrendRecordAt: Date?
    private var lastTrashProbeAt: Date?

    private init() {}

    /// 概览页出现 / 消失时调用：决定采样频率档位，并立刻补一次采样。
    func setOverviewActive(_ active: Bool) {
        guard overviewActive != active else { return }
        overviewActive = active
        refreshNow()
    }

    func start() {
        guard loopTask == nil else { return }
        if sample.disk == nil {
            // 首帧先给磁盘一次廉价同步读（一次 URLResourceValues，约 1ms），
            // 避免菜单栏 / 概览出现「读取中…」闪一下；其余指标由首次后台采样补齐。
            var seeded = sample
            seeded.disk = DiskService().snapshot()
            sample = seeded
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce()
                guard !Task.isCancelled else { return }
                let interval = self.currentInterval()
                let wake = Task {
                    _ = try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                self.wakeTask = wake
                await wake.value
                self.wakeTask = nil
            }
        }
    }

    /// 立即唤醒循环采样：进入概览、设置变更、手动刷新都走这里。
    func refreshNow() {
        guard loopTask != nil else {
            start()
            return
        }
        // 取消正在等待的 sleep，循环会立刻进入下一次采样；正在采样时无需重复排队。
        wakeTask?.cancel()
        wakeTask = nil
    }

    /// 设置里改了刷新间隔后重启节奏：不重建循环，只缩短当前等待。
    func restartLoop() {
        refreshNow()
    }

    private func sampleOnce() async {
        guard !isSampling else { return }
        isSampling = true
        let snapshot = await sampler.sample()
        apply(snapshot)
        isSampling = false
    }

    private func apply(_ snapshot: SystemSample) {
        sample = snapshot
        maybeRecordTrend(snapshot.disk)
        historySummary = historyCache.current()
        maybeProbeTrash()
    }

    /// 磁盘趋势写入：DiskTrendStore.record 是「解码全部点 → 替换当天点 → 编码写 UserDefaults」，
    /// 原来概览与菜单栏每 2~5 秒各调一次（每 tick 两次解码+编码+写盘）。
    /// 现在跨天必记一次，同一天最多每 30 分钟刷新当天数据点，兼顾趋势准确度与写入成本。
    private func maybeRecordTrend(_ disk: DiskSnapshot?) {
        guard let disk else { return }
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let dayChanged = lastTrendDay != today
        guard dayChanged || now.timeIntervalSince(lastTrendRecordAt ?? .distantPast) > 1800 else { return }
        lastTrendDay = today
        lastTrendRecordAt = now
        DiskTrendStore().record(disk, on: now)
    }

    /// 废纸篓体积变化慢，每 60 秒在后台统计一次；只读，不参与可清理估算。
    private func maybeProbeTrash() {
        let now = Date()
        guard now.timeIntervalSince(lastTrashProbeAt ?? .distantPast) > 60 else { return }
        lastTrashProbeAt = now
        // 递归枚举 ~/.Trash 放到后台线程；detached 任务不捕获 self，
        // 只把 Int64 结果带回主线程赋值（避免在并发闭包里持有 MainActor 对象）。
        let probe = Task.detached(priority: .utility) { TrashSizeProbe().size() }
        Task { [weak self] in
            let size = await probe.value
            self?.trashBytes = size
        }
    }

    /// 采样间隔：取各处需求里最密的那个。
    private func currentInterval() -> TimeInterval {
        let base = ScanSettings.menuBarRefreshInterval()
        if overviewActive {
            // 概览页要连续曲线：默认 2 秒；用户把菜单栏设得更快时跟随设置。
            // 窗口最小化 / 关闭时退到 10 秒，避免后台空转（与原概览循环一致）。
            return isMainWindowVisible ? min(base, 2) : 10
        }
        if isMainWindowVisible {
            return base
        }
        // 主窗口与概览都不可见时降频到 2.5 倍（上限 60 秒）。
        return min(60, max(10, base * 2.5))
    }

    /// 主窗口是否可见。窗口关闭 / 最小化时降低采样频率。
    private var isMainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !$0.isMiniaturized }
    }
}

// MARK: - 菜单栏监控（共享采样器的轻量适配器）

/// 菜单栏常驻监控：磁盘、内存、CPU、网络、电池与最近一次扫描结果。
///
/// 这里不再自己采样，只是 `SharedSystemMonitor` 的展示适配器：
/// - 数据来源统一：主窗口与菜单栏看到的是同一时刻的快照，两个数字不会对不上；
/// - 暂停时冻结在按下暂停那一刻的快照，面板数字不再继续跳；
/// - 对外保留原有属性 / 方法（refresh / restartLoop / style / isPaused 等），
///   调用方（SettingsView、RootView、MenuBarPanel）无需改动。
@MainActor
final class MenuBarMonitor: ObservableObject {
    @Published private(set) var style: MenuBarDisplayStyle = .iconAndPercent
    @Published var isPaused = false

    private let shared = SharedSystemMonitor.shared
    private var cancellables: Set<AnyCancellable> = []
    private var frozenSample: SystemSample?
    private var frozenHistory: HistorySummary?

    init() {
        style = ScanSettings.menuBarStyle()
        bind()
        shared.start()
    }

    private var currentSample: SystemSample {
        isPaused ? (frozenSample ?? shared.sample) : shared.sample
    }

    private var currentHistory: HistorySummary {
        isPaused ? (frozenHistory ?? shared.historySummary) : shared.historySummary
    }

    var disk: DiskSnapshot? { currentSample.disk }
    var memory: MemorySnapshot? { currentSample.memory }
    var cpuUsage: Double { currentSample.cpuUsage }
    var cpuHistory: [Double] { currentSample.cpuHistory }
    var network: NetworkRate { currentSample.network }
    var battery: BatterySnapshot { currentSample.battery }
    var lastScanBytes: Int64 { currentHistory.lastScanEntry?.bytes ?? 0 }
    var lastScanDate: Date? { currentHistory.lastScanEntry?.date }

    var percentText: String {
        guard let disk = disk else { return "—" }
        return ByteFormatter.percent(disk.usedFraction)
    }

    var diskHeadline: String {
        guard let disk = disk else { return "读取中…" }
        return ByteFormatter.string(disk.usedBytes)
    }

    var diskCaption: String {
        guard let disk = disk else { return "" }
        return "共 \(ByteFormatter.string(disk.totalBytes)) · 可用 \(ByteFormatter.string(disk.availableBytes))"
    }

    var lastScanText: String? {
        guard lastScanBytes > 0 else { return nil }
        return ByteFormatter.string(lastScanBytes)
    }

    /// 兼容原有调用方（设置页、RootView 刷新）：只唤醒共享采样器，读不再阻塞主线程。
    func refresh() {
        style = ScanSettings.menuBarStyle()
        if isPaused {
            // 暂停状态下的「刷新」只更新冻结值，不恢复自动刷新（保持原语义）。
            frozenSample = shared.sample
            frozenHistory = shared.historySummary
        }
        shared.refreshNow()
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            frozenSample = shared.sample
            frozenHistory = shared.historySummary
        } else {
            frozenSample = nil
            frozenHistory = nil
            shared.refreshNow()
        }
    }

    func restartLoop() {
        shared.restartLoop()
    }

    /// 把共享采样器的变化转发成自己的 objectWillChange：
    /// 面板订阅的是 monitor，所以共享快照一到就要重绘。
    private func bind() {
        shared.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}

// MARK: - 状态栏文字

struct MenuBarLabel: View {
    @ObservedObject var monitor: MenuBarMonitor

    var body: some View {
        HStack(spacing: 3) {
            if monitor.style != .percent {
                Image(nsImage: BrandAssets.menuBarIcon)
                    .renderingMode(.template)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            if monitor.style != .icon {
                Text(monitor.percentText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("磁盘已用 \(monitor.percentText)")
    }
}

// MARK: - 展开面板
//
// 菜单栏面板是同一套 M2 语言的紧凑版：更小的留白与字号，
// 但表面、强调色、数字字体与状态语义完全一致。

struct MenuBarPanel: View {
    @ObservedObject var monitor: MenuBarMonitor
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: DesignSpec.space2) {
                HStack(alignment: .firstTextBaseline, spacing: DesignSpec.space1 + 2) {
                    M2Eyebrow(text: "已用")
                    M2Number(text: monitor.diskHeadline, size: 21, weight: .medium)
                    Spacer(minLength: DesignSpec.space2)
                    M2Number(text: monitor.percentText, size: 11, weight: .medium,
                             color: M2.ink, unitColor: M2.ink)
                }
                M2ContinuousMeter(
                    used: monitor.disk?.usedFraction ?? 0,
                    cleanable: cleanableFraction,
                    height: 7
                )
                HStack(spacing: DesignSpec.space1) {
                    Text("共 \(ByteFormatter.string(monitor.disk?.totalBytes ?? 0))")
                    Text("·")
                    Text("可用 \(ByteFormatter.string(monitor.disk?.availableBytes ?? 0))")
                    Spacer(minLength: DesignSpec.space2)
                    if let volume = monitor.disk?.volumeName {
                        Text(volume)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(M2Font.body(9.5))
                .foregroundStyle(M2.secondary)
            }
            .padding(.top, DesignSpec.space2 + 2)

            Hairline().padding(.vertical, DesignSpec.space3)

            metricGrid

            Hairline().padding(.vertical, DesignSpec.space3)

            scanSummary

            Hairline().padding(.vertical, DesignSpec.space3)

            actions
        }
        .padding(DesignSpec.space3 + 2)
        .frame(width: 300)
        .background(M2.bg)
    }

    private var cleanableFraction: Double {
        guard let disk = monitor.disk, disk.totalBytes > 0 else { return 0 }
        return min(monitor.disk?.usedFraction ?? 0,
                   Double(monitor.lastScanBytes) / Double(disk.totalBytes))
    }

    private var header: some View {
        HStack(spacing: DesignSpec.space2) {
            BrandMark(size: 22)
            Text("O")
                .font(M2Font.serif(14))
                .foregroundStyle(M2.text)
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(M2.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("立即刷新")
            .accessibilityLabel("立即刷新")
            Button {
                monitor.togglePause()
            } label: {
                Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(monitor.isPaused ? M2.warning : M2.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(monitor.isPaused ? "恢复刷新" : "暂停刷新")
            .accessibilityLabel(monitor.isPaused ? "恢复刷新" : "暂停刷新")
        }
    }

    private var metricGrid: some View {
        VStack(spacing: DesignSpec.space2) {
            metricRow(title: "处理器",
                      value: ByteFormatter.percent(monitor.cpuUsage),
                      detail: "\(ProcessInfo.processInfo.processorCount) 核")
            metricRow(title: "内存",
                      value: ByteFormatter.percent(monitor.memory?.usedFraction ?? 0),
                      detail: ByteFormatter.string(monitor.memory?.usedBytes ?? 0))
            metricRow(title: "网络",
                      value: rateText(monitor.network.downBytesPerSecond),
                      detail: "↑ \(rateText(monitor.network.upBytesPerSecond))")
            metricRow(title: "电池",
                      value: monitor.battery.isPresent
                        ? ByteFormatter.percent(monitor.battery.chargeFraction) : "—",
                      detail: monitor.battery.isPresent ? monitor.battery.statusText : "台式机")
        }
    }

    private func metricRow(title: String, value: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpec.space2) {
            Text(title)
                .font(M2Font.body(9.5))
                .foregroundStyle(M2.tertiary)
                .frame(width: 44, alignment: .leading)
            Spacer(minLength: DesignSpec.space1)
            Text(detail)
                .font(M2Font.mono(9))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
            M2Number(text: value, size: 10.5, weight: .medium, unitColor: M2.tertiary)
                .frame(width: 62, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)，\(detail)")
    }

    private var scanSummary: some View {
        HStack(alignment: .center, spacing: DesignSpec.space2) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(M2.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.lastScanText.map { "上次扫描：\($0) 可清理" } ?? "还没有扫描记录")
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                Text(monitor.isPaused ? "自动刷新已暂停" : "数据每 \(Int(ScanSettings.menuBarRefreshInterval())) 秒刷新")
                    .font(M2Font.body(9))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignSpec.space1)
            if let date = monitor.lastScanDate {
                Text(Self.scanTime.string(from: date))
                    .font(M2Font.mono(9))
                    .foregroundStyle(M2.tertiary)
            }
        }
    }

    private static let scanTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private var actions: some View {
        VStack(spacing: DesignSpec.space2) {
            HStack(spacing: DesignSpec.space2) {
                Button {
                    openMainWindow()
                    coordinator.requestQuickScan()
                } label: {
                    Label(coordinator.isScanning ? "扫描中" : "扫描",
                          systemImage: coordinator.isScanning ? "hourglass" : "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(M2PrimaryButtonStyle(compact: true))
                .disabled(coordinator.isScanning)

                Button {
                    openMainWindow()
                } label: {
                    Label("主窗口", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }

            HStack(spacing: DesignSpec.space4) {
                Button("设置") {
                    coordinator.show(.system, systemTab: .settings)
                    openMainWindow()
                }
                .buttonStyle(M2LinkButtonStyle())

                Button("权限") {
                    coordinator.show(.system, systemTab: .permissions)
                    openMainWindow()
                }
                .buttonStyle(M2LinkButtonStyle())

                Button("概览") {
                    coordinator.show(.overview)
                    openMainWindow()
                }
                .buttonStyle(M2LinkButtonStyle())

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(M2LinkButtonStyle())
            }
            .padding(.top, DesignSpec.space1)
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        AppWindowBridge.shared.present = { openWindow(id: "main") }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        ByteFormatter.string(Int64(bytesPerSecond)) + "/s"
    }
}
