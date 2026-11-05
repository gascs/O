import AppKit
import MoleLiteCore
import SwiftUI

/// 菜单栏常驻监控：磁盘、内存、CPU、网络、电池与最近一次扫描结果。
@MainActor
final class MenuBarMonitor: ObservableObject {
    @Published private(set) var disk: DiskSnapshot?
    @Published private(set) var memory: MemorySnapshot?
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var network: NetworkRate = .zero
    @Published private(set) var battery: BatterySnapshot = .absent
    @Published private(set) var lastScanBytes: Int64 = 0
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var style: MenuBarDisplayStyle = .iconAndPercent
    @Published var isPaused = false

    private var networkSampler = NetworkSampler()
    private var lastCPUSample: CPUSample?
    private var loopTask: Task<Void, Never>?
    private var lastTrendDay: Date?
    private let diskService = DiskService()
    private let metrics = SystemMetricsService()
    private let batteryService = BatteryService()

    init() {
        style = ScanSettings.menuBarStyle()
        refresh()
        startLoop()
    }

    var percentText: String {
        guard let disk else { return "—" }
        return ByteFormatter.percent(disk.usedFraction)
    }

    var diskHeadline: String {
        guard let disk else { return "读取中…" }
        return ByteFormatter.string(disk.usedBytes)
    }

    var diskCaption: String {
        guard let disk else { return "" }
        return "共 \(ByteFormatter.string(disk.totalBytes)) · 可用 \(ByteFormatter.string(disk.availableBytes))"
    }

    var lastScanText: String? {
        guard lastScanBytes > 0 else { return nil }
        return ByteFormatter.string(lastScanBytes)
    }

    func refresh() {
        disk = diskService.snapshot()
        memory = metrics.memory()
        if let sample = metrics.cpuSample() {
            if let previous = lastCPUSample {
                let usage = sample.usage(since: previous)
                cpuUsage = usage
                cpuHistory.append(usage)
                if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }
            }
            lastCPUSample = sample
        }
        network = networkSampler.sample() ?? network
        battery = batteryService.snapshot()
        style = ScanSettings.menuBarStyle()

        let recent = HistoryStore().load().first { $0.kind == .scan }
        lastScanBytes = recent?.bytes ?? 0
        lastScanDate = recent?.date

        recordTrendIfNeeded()
    }

    private func recordTrendIfNeeded() {
        guard let disk else { return }
        let today = Calendar.current.startOfDay(for: Date())
        guard lastTrendDay != today else { return }
        lastTrendDay = today
        DiskTrendStore().record(disk)
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused { refresh() }
    }

    func restartLoop() {
        startLoop()
    }

    /// 主窗口是否可见。窗口关闭 / 最小化时降低菜单栏采样频率，避免无谓占用。
    private var isMainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !$0.isMiniaturized }
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let base = ScanSettings.menuBarRefreshInterval()
                // 主窗口不可见时把采样间隔拉长到 2.5 倍（上限 60 秒），与主窗口刷新完全解耦。
                let interval = self.isMainWindowVisible ? base : min(60, base * 2.5)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard !self.isPaused else { continue }
                self.refresh()
            }
        }
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
