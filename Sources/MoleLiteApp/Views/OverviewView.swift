import MoleLiteCore
import SwiftUI

/// 首页：设备信息、系统状态、四项实时图表与可清理建议。
/// 窗口变窄时自动改为单列，最小窗口 860 下不挤压、不裁字。
struct OverviewView: View {
    @ObservedObject var model: OverviewViewModel
    @ObservedObject var permissions: PermissionCenter
    var goScan: () -> Void
    var goSpace: () -> Void
    var goPermission: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeaderBar(title: "首页", subtitle: headerSubtitle)

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        Color.clear
                            .frame(height: 0)
                            .id("overview-top")
                        if model.disk == nil && model.estimateMessage == nil {
                            M2EmptyState(
                                icon: "internaldrive",
                                title: "正在读取磁盘信息",
                                message: "首次读取通常不到一秒。"
                            )
                            .frame(minHeight: max(240, geo.size.height - 40))
                        } else {
                            content(twoColumn: geo.size.width >= DesignSpec.twoColumnMinWidth)
                                .padding(.horizontal, DesignSpec.pagePadding)
                                .padding(.top, DesignSpec.sectionSpacing)
                                .padding(.bottom, DesignSpec.space6)
                        }
                    }
                    .onAppear {
                        // 切换页面时重置到顶部，避免沿用上一页的滚动位置。
                        proxy.scrollTo("overview-top", anchor: .top)
                    }
                }
            }
        }
        .background(M2.bg)
        .onAppear {
            model.start()
            model.estimateCleanable()
            permissions.refresh()
        }
        .onDisappear {
            model.stop()
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private func content(twoColumn: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignSpec.sectionSpacing) {
            if !permissions.allGranted {
                M2RestrictedState(
                    message: "邮件、Safari 等受保护位置读不到，统计可能偏少；不影响继续清理可见部分。",
                    onOpenSettings: goPermission,
                    onRecheck: { permissions.refresh() }
                )
            }

            hero

            if twoColumn {
                HStack(alignment: .top, spacing: DesignSpec.sectionSpacing) {
                    VStack(alignment: .leading, spacing: DesignSpec.sectionSpacing) {
                        livePanel
                        devicePanel
                        suggestions
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    summaryRail
                        .frame(width: DesignSpec.summaryCardWidth)
                }
            } else {
                VStack(alignment: .leading, spacing: DesignSpec.sectionSpacing) {
                    summaryRail
                    livePanel
                    devicePanel
                    suggestions
                }
            }
        }
    }

    // MARK: - 页头

    private var headerSubtitle: String {
        guard let disk = model.disk else { return "设备与实时状态 · 正在读取磁盘信息" }
        return "设备与实时状态 · \(statusTitle) · 可用 \(ByteFormatter.string(disk.availableBytes))"
    }

    private var statusTitle: String {
        guard let disk = model.disk else { return "正在读取磁盘信息" }
        if disk.availableFraction < 0.1 { return "磁盘空间紧张" }
        if disk.availableFraction < 0.2 { return "磁盘空间偏紧" }
        return "磁盘空间充足"
    }

    // MARK: - 焦点区

    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space4) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSpec.space5) {
                VStack(alignment: .leading, spacing: 2) {
                    M2Eyebrow(text: "可用空间")
                    M2Number(
                        text: model.disk.map { ByteFormatter.string($0.availableBytes) } ?? "—",
                        size: DesignSpec.displaySize,
                        weight: .medium
                    )
                    Text(usedCaption)
                        .font(M2Font.body(DesignSpec.captionSize))
                        .foregroundStyle(M2.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignSpec.space4)

                VStack(alignment: .trailing, spacing: 2) {
                    M2Eyebrow(text: "已用")
                    M2Number(
                        text: model.disk.map { ByteFormatter.percent($0.usedFraction) } ?? "—",
                        size: DesignSpec.numberSize,
                        weight: .medium,
                        color: M2.text,
                        unitColor: M2.tertiary
                    )
                }
            }

            VStack(alignment: .leading, spacing: DesignSpec.space2) {
                M2ContinuousMeter(
                    used: model.disk?.usedFraction ?? 0,
                    cleanable: cleanableFraction,
                    height: 12
                )
                HStack(spacing: DesignSpec.space5) {
                    meterLegend("已用", value: model.disk.map { ByteFormatter.string($0.usedBytes) } ?? "—", color: M2.used)
                    meterLegend("可清理", value: model.cleanableBytes.map(ByteFormatter.string) ?? "—", color: M2.ink)
                    meterLegend("可用", value: model.disk.map { ByteFormatter.string($0.availableBytes) } ?? "—", color: M2.track)
                    Spacer(minLength: 0)
                }
            }
        }
        .panel(padding: 20)
        .accessibilityElement(children: .contain)
    }

    private var cleanableFraction: Double {
        guard let disk = model.disk, disk.totalBytes > 0, let cleanable = model.cleanableBytes else { return 0 }
        return min(1, Double(cleanable) / Double(disk.totalBytes))
    }

    private var usedCaption: String {
        guard let disk = model.disk else { return "" }
        return "共 \(ByteFormatter.string(disk.totalBytes)) · 空闲 \(ByteFormatter.percent(disk.availableFraction))"
    }

    private func meterLegend(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: DesignSpec.space1 + 2) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 3)
            Text(label)
                .font(M2Font.body(DesignSpec.captionSize))
                .foregroundStyle(M2.secondary)
            M2Number(text: value, size: DesignSpec.captionSize, weight: .medium, color: M2.text, unitColor: M2.tertiary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: - 摘要卡

    private var summaryRail: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space4) {
            VStack(alignment: .leading, spacing: 2) {
                M2Eyebrow(text: "本次可清理")
                M2Number(
                    text: model.cleanableBytes.map(ByteFormatter.string) ?? "—",
                    size: DesignSpec.cardNumberSize,
                    weight: .medium,
                    color: M2.ink
                )
                Text(summaryCaption)
                    .font(M2Font.body(DesignSpec.captionSize))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: DesignSpec.space2) {
                Button {
                    goScan()
                } label: {
                    Text("开始扫描").frame(maxWidth: .infinity)
                }
                .buttonStyle(M2PrimaryButtonStyle())

                Button {
                    goSpace()
                } label: {
                    Text("查看空间明细").frame(maxWidth: .infinity)
                }
                .buttonStyle(M2SecondaryButtonStyle())
            }

            Hairline()

            VStack(spacing: 0) {
                summaryRow("可用占比", model.disk.map { ByteFormatter.percent($0.availableFraction) } ?? "—")
                summaryRow("累计释放", ByteFormatter.string(model.totalFreedBytes))
                summaryRow("上次扫描", model.lastScanEntry.map { Self.timeFormatter.string(from: $0.date) } ?? "尚未扫描")
            }

            if !model.categoryBreakdown.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: DesignSpec.space2) {
                    M2Eyebrow(text: "扫描范围")
                    ForEach(scopeRows, id: \.0) { row in
                        HStack(spacing: DesignSpec.space2) {
                            Text(row.0)
                                .font(M2Font.body(DesignSpec.captionSize))
                                .foregroundStyle(M2.secondary)
                                .lineLimit(1)
                            Spacer(minLength: DesignSpec.space1)
                            M2Number(text: ByteFormatter.string(row.1), size: DesignSpec.captionSize, weight: .medium, unitColor: M2.tertiary)
                        }
                    }
                }
            }
        }
        .panel(padding: 18)
        .accessibilityElement(children: .contain)
    }

    private var recommendationCount: Int {
        model.recommendations.count
    }

    private var summaryCaption: String {
        if model.cleanableBytes != nil {
            return "\(recommendationCount) 组建议 · 清理仅移入废纸篓"
        }
        return model.isEstimating ? "正在估算…" : "扫描后显示可清理空间"
    }

    private var scopeRows: [(String, Int64)] {
        let order: [ScanCategory] = [.userCaches, .logs, .xcode, .trash]
        return order.compactMap { category in
            guard let bytes = model.categoryBreakdown[category], bytes > 0 else { return nil }
            return (category.title, bytes)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: DesignSpec.space2) {
            Text(label)
                .font(M2Font.body(DesignSpec.captionSize))
                .foregroundStyle(M2.secondary)
            Spacer(minLength: DesignSpec.space1)
            M2Number(text: value, size: DesignSpec.captionSize, weight: .medium, unitColor: M2.tertiary)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: - 建议清单

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space2) {
            M2SectionTitle(
                title: "建议动作",
                detail: "按安全等级分组，清理仅移入废纸篓"
            )
            .padding(.leading, 2)

            VStack(spacing: 0) {
                if model.isEstimating && model.recommendations.isEmpty {
                    M2ScanningState(title: "正在估算可清理空间", detail: "缓存 · 日志 · Xcode · 废纸篓", fraction: 0, rows: 3)
                        .padding(16)
                } else if let message = model.estimateMessage {
                    M2ErrorState(title: "估算失败", message: message, retry: { model.estimateCleanable() })
                        .frame(minHeight: 160)
                } else if model.recommendations.isEmpty {
                    emptySuggestions
                } else {
                    ForEach(model.recommendations) { group in
                        suggestionRow(group)
                        if group.id != model.recommendations.last?.id {
                            Hairline().padding(.leading, 18)
                        }
                    }
                }
            }
            .panel(padding: 0)
        }
    }

    private func suggestionRow(_ group: RecommendationGroup) -> some View {
        HStack(alignment: .center, spacing: DesignSpec.space3) {
            StatusDot(color: M2.grade(group.grade), size: 6)
                .frame(width: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.categories.map(\.title).joined(separator: " · "))
                    .font(M2Font.body(12, .medium))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                Text(group.note)
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignSpec.space2)

            Text(group.grade.title)
                .font(M2Font.mono(9))
                .foregroundStyle(group.grade == .caution ? M2.warning : M2.tertiary)
                .frame(width: 30, alignment: .trailing)

            M2Number(text: ByteFormatter.string(group.bytes), size: DesignSpec.bodySize, weight: .medium, unitColor: M2.tertiary)
                .frame(width: 82, alignment: .trailing)

            Group {
                if group.grade == .caution {
                    Text("需逐项确认")
                        .font(M2Font.body(9.5))
                        .foregroundStyle(M2.tertiary)
                        .frame(width: 62, alignment: .trailing)
                } else {
                    Button("清理", action: goScan)
                        .buttonStyle(M2LinkButtonStyle())
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
        .frame(height: 54)
        .padding(.horizontal, DesignSpec.space4)
        .hoverHighlight(cornerRadius: 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.grade.title)，\(group.categories.map(\.title).joined(separator: "、"))，\(group.note)，\(ByteFormatter.string(group.bytes))")
    }

    private var emptySuggestions: some View {
        VStack(spacing: DesignSpec.space2) {
            M2EmptyState(
                icon: "checkmark.circle",
                title: "暂时没有可安全清理的内容",
                message: "扫描缓存、日志与废纸篓后，这里会按安全等级列出建议。",
                actionTitle: "重新扫描",
                action: goScan
            )
            .frame(minHeight: 150)
        }
    }

    // MARK: - 设备信息

    private var devicePanel: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space2) {
            M2SectionTitle(title: "设备", detail: "全部来自系统 API，读不到即标记不可用",
                           trailing: model.hardware?.modelIdentifier)
            Hairline()
            HStack(alignment: .top, spacing: DesignSpec.space4) {
                VStack(alignment: .leading, spacing: DesignSpec.space2) {
                    M2Eyebrow(text: "硬件")
                    LazyVGrid(columns: infoColumns, alignment: .leading, spacing: DesignSpec.space2) {
                        ForEach(hardwareRows, id: \.0) { row in
                            infoCell(row.0, row.1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(M2.line)
                    .frame(width: DesignSpec.separatorWidth)

                VStack(alignment: .leading, spacing: DesignSpec.space2) {
                    M2Eyebrow(text: "系统")
                    LazyVGrid(columns: infoColumns, alignment: .leading, spacing: DesignSpec.space2) {
                        ForEach(systemRows, id: \.0) { row in
                            infoCell(row.0, row.1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panel(padding: 14)
        .help("「不可用」表示该系统 API 在当前环境未返回数据；应用不会用估算值填充。序列号仅显示末四位。")
    }

    private var infoColumns: [GridItem] {
        [GridItem(.flexible(minimum: 100), spacing: DesignSpec.space3),
         GridItem(.flexible(minimum: 100), spacing: DesignSpec.space3)]
    }

    private var hardwareRows: [(String, String)] {
        let hardware = model.hardware
        return [
            ("芯片", hardware?.chipName ?? "不可用"),
            ("核心", hardware?.coreSummary ?? "不可用"),
            ("内存", hardware.map { ByteFormatter.string($0.memoryBytes) } ?? "不可用"),
            ("GPU", hardware?.gpuName ?? "不可用（Metal 未返回设备）"),
            ("屏幕", model.screenSummary ?? "不可用"),
            ("标识", hardware?.serialSuffix.map { "序列号末四位 \($0)" } ?? "不可用")
        ]
    }

    private var systemRows: [(String, String)] {
        guard let info = model.systemInfo else {
            return [("系统", "正在读取"), ("运行时长", "正在读取"), ("启动磁盘", "正在读取")]
        }
        return [
            ("版本", "\(info.osVersion) · \(info.buildNumber ?? "构建号不可用")"),
            ("运行时长", Self.uptimeText(info.uptime)),
            ("启动磁盘", info.bootVolume.map { "可用 \(ByteFormatter.string($0.availableBytes)) / 共 \(ByteFormatter.string($0.totalBytes))" } ?? "不可用"),
            ("电源", batteryText(info.battery)),
            ("热压力", info.thermalState.isEmpty ? "不可用" : info.thermalState),
            ("网络", networkText(info.networkInterfaces))
        ]
    }

    private func batteryText(_ battery: BatteryDetail) -> String {
        guard battery.isPresent else { return "无电池（台式机）" }
        var parts = [battery.statusText]
        if let health = battery.healthPercent {
            parts.append("健康 \(health)%")
        } else {
            parts.append("健康不可用")
        }
        if let cycle = battery.cycleCount {
            parts.append("循环 \(cycle) 次")
        } else {
            parts.append("循环数不可用")
        }
        return parts.joined(separator: " · ")
    }

    private func networkText(_ interfaces: [NetworkInterfaceInfo]) -> String {
        guard let first = interfaces.first else { return "不可用（未连接网络）" }
        let extra = interfaces.count > 1 ? " +\(interfaces.count - 1)" : ""
        return "\(first.name) · \(first.address)\(extra)"
    }

    private func infoCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(M2Font.body(8.5))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
            Text(value)
                .font(M2Font.mono(9.5))
                .foregroundStyle(value.hasPrefix("不可用") ? M2.tertiary : M2.text)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .help(value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: - 实时状态

    private var livePanel: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space2) {
            M2SectionTitle(title: "实时状态",
                           detail: "2 秒采样，窗口不可见时降频",
                           trailing: model.isSamplingFast ? "采样中" : "已降频")
                .padding(.horizontal, 2)

            HStack(alignment: .top, spacing: 0) {
                cpuTile
                liveDivider
                memoryTile
                liveDivider
                diskTile
                liveDivider
                networkTile
            }
            .padding(16)
            .panel(padding: 0)
        }
    }

    private var liveDivider: some View {
        Rectangle()
            .fill(M2.line)
            .frame(width: DesignSpec.separatorWidth)
            .padding(.vertical, 2)
            .padding(.horizontal, DesignSpec.space3)
    }

    private var cpuTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                M2Eyebrow(text: "CPU")
                Spacer(minLength: 4)
                M2Number(text: ByteFormatter.percent(model.cpuUsage), size: 12, weight: .medium)
            }
            M2Sparkline(values: model.cpuHistory, height: 34, tint: M2.ink)
            Text("\(model.processorCount) 核 · 最近 \(max(1, model.cpuHistory.count)) 次")
                .font(M2Font.body(8.5))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CPU 占用 \(ByteFormatter.percent(model.cpuUsage))")
    }

    private var memoryTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                M2Eyebrow(text: "内存")
                Spacer(minLength: 4)
                M2Number(text: model.memory.map { ByteFormatter.percent($0.usedFraction) } ?? "—",
                         size: 12, weight: .medium)
            }
            memoryBar
            HStack(spacing: DesignSpec.space2) {
                legendDot("常驻", M2.ink)
                legendDot("压缩", M2.ink.opacity(0.55))
                legendDot("其它", M2.used)
                legendDot("空闲", M2.track)
            }
            Text(model.memory.map {
                "已用 \(ByteFormatter.string($0.usedBytes)) / \(ByteFormatter.string($0.totalBytes))"
            } ?? "不可用")
                .font(M2Font.mono(8.5))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(memoryAccessibility)
    }

    private var memoryBar: some View {
        GeometryReader { proxy in
            let total = max(1, Double(model.memory?.totalBytes ?? 0))
            let wired = Double(model.memory?.wiredBytes ?? 0) / total
            let compressed = Double(model.memory?.compressedBytes ?? 0) / total
            let used = Double(model.memory?.usedBytes ?? 0) / total
            let other = max(0, used - wired - compressed)
            HStack(spacing: 0) {
                Rectangle().fill(M2.ink).frame(width: proxy.size.width * wired)
                Rectangle().fill(M2.ink.opacity(0.55)).frame(width: proxy.size.width * compressed)
                Rectangle().fill(M2.used).frame(width: proxy.size.width * other)
                Rectangle().fill(M2.track)
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private var memoryAccessibility: String {
        guard let memory = model.memory else { return "内存不可用" }
        return "内存已用 \(ByteFormatter.percent(memory.usedFraction))，常驻 \(ByteFormatter.string(memory.wiredBytes))，压缩 \(ByteFormatter.string(memory.compressedBytes))"
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 6, height: 3)
            Text(label)
                .font(M2Font.body(8))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
        }
    }

    private var diskTile: some View {
        HStack(alignment: .center, spacing: DesignSpec.space3) {
            ZStack {
                Circle()
                    .strokeBorder(M2.track, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: model.disk?.usedFraction ?? 0)
                    .stroke(M2.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(model.disk.map { ByteFormatter.percent($0.usedFraction) } ?? "—")
                    .font(M2Font.mono(10.5, .medium))
                    .foregroundStyle(M2.text)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                M2Eyebrow(text: "磁盘")
                Text(model.disk.map { "可用 \(ByteFormatter.string($0.availableBytes))" } ?? "不可用")
                    .font(M2Font.mono(9.5))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(model.disk.map { "共 \(ByteFormatter.string($0.totalBytes))" } ?? "")
                    .font(M2Font.mono(8.5))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("磁盘已用 \(model.disk.map { ByteFormatter.percent($0.usedFraction) } ?? "不可用")")
    }

    private var networkTile: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                M2Eyebrow(text: "网络")
                Spacer(minLength: 4)
                Text(model.systemInfo?.networkInterfaces.first?.name ?? "—")
                    .font(M2Font.mono(8.5))
                    .foregroundStyle(M2.tertiary)
            }
            rateRow("↓", value: model.network.downBytesPerSecond, color: M2.ink)
            rateRow("↑", value: model.network.upBytesPerSecond, color: M2.secondary)
            Text(model.systemInfo?.networkInterfaces.first.map { "本地 IP \($0.address)" } ?? "无本地接口")
                .font(M2Font.mono(8.5))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("网络下行 \(ByteFormatter.rate(model.network.downBytesPerSecond))，上行 \(ByteFormatter.rate(model.network.upBytesPerSecond))")
    }

    private func rateRow(_ arrow: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(arrow)
                .font(M2Font.mono(10))
                .foregroundStyle(M2.tertiary)
            M2Number(text: ByteFormatter.rate(value), size: 11, weight: .medium, color: color, unitColor: M2.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private static func uptimeText(_ uptime: TimeInterval) -> String {
        let totalMinutes = Int(uptime) / 60
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days) 天 \(hours) 小时 \(minutes) 分" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - CPU 折线

/// 极简折线：1px 网格 + 墨蓝细线 + 极浅面积，无坐标轴文字。
private struct M2Sparkline: View {
    let values: [Double]
    var height: CGFloat = 34
    var tint: Color = M2.ink

    var body: some View {
        Canvas { context, size in
            for index in 1..<3 {
                let y = size.height * CGFloat(index) / 3
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(grid, with: .color(M2.line), lineWidth: 1)
            }

            guard values.count > 1 else {
                var flat = Path()
                flat.move(to: CGPoint(x: 0, y: size.height * 0.94))
                flat.addLine(to: CGPoint(x: size.width, y: size.height * 0.94))
                context.stroke(flat, with: .color(tint.opacity(0.35)), lineWidth: 1)
                return
            }

            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            var area = Path()
            for (index, value) in values.enumerated() {
                let clamped = min(1, max(0, value))
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: size.height - CGFloat(clamped) * (size.height - 2) - 1)
                if index == 0 {
                    line.move(to: point)
                    area.move(to: CGPoint(x: point.x, y: size.height))
                    area.addLine(to: point)
                } else {
                    line.addLine(to: point)
                    area.addLine(to: point)
                }
            }
            area.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.06)))
            context.stroke(line, with: .color(tint), lineWidth: 1.3)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
