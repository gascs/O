import MoleLiteCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var menuBarMonitor: MenuBarMonitor
    @ObservedObject private var coordinator = AppCoordinator.shared
    @Environment(\.openWindow) private var openWindow

    @StateObject private var overviewModel = OverviewViewModel()
    @StateObject private var scanModel = ScanViewModel()
    @StateObject private var uninstallModel = UninstallViewModel()
    @StateObject private var largeFilesModel = LargeFilesViewModel()
    @StateObject private var duplicateModel = DuplicateViewModel()
    @StateObject private var launchModel = LaunchItemsViewModel()
    @StateObject private var rulesModel = RulesViewModel()
    @ObservedObject private var ruleEstimates = RuleEstimateStore.shared
    @ObservedObject private var permissions = PermissionCenter.shared

    @State private var handledQuickScanToken = 0
    @State private var showOnboarding = !UIAudit.isEnabled && !ScanSettings.onboardingCompleted()
    @State private var showGrantedNotice = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topNavigation
            detail
                .frame(minWidth: DesignSpec.detailMinWidth,
                       maxWidth: .infinity, maxHeight: .infinity)
            StatusBarView(
                section: coordinator.section,
                scanModel: scanModel,
                overviewModel: overviewModel,
                largeModel: largeFilesModel,
                duplicateModel: duplicateModel,
                uninstallModel: uninstallModel,
                rulesModel: rulesModel,
                permissions: permissions
            )
        }
        .background(M2.bg)
        // 页面切换不做整页交叉淡入：快速连按 ⌘1–⌘6 时旧页面层可能与新页面叠影。
        // 动效只保留导航下划线（navItem）与横幅的短过渡。
        .navigationTitle("O")
        .frame(minWidth: DesignSpec.minimumWindowWidth,
               minHeight: DesignSpec.minimumWindowContentHeight)
        .tint(M2.ink)
        .sheet(isPresented: $showOnboarding) {
            PermissionOnboardingView(permissions: permissions) {
                showOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        .toolbar { toolbarContent }
        .overlay(alignment: .top) {
            if showGrantedNotice {
                GrantedNotice(onClose: dismissGrantedNotice)
                    .padding(.top, DesignSpec.space2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            // 注册单一窗口入口：菜单栏、Dock 与单实例激活都复用它。
            AppWindowBridge.shared.present = { openWindow(id: "main") }
            handleQuickScanIfNeeded()
            syncSearch()
        }
        .onChange(of: coordinator.quickScanToken) { _ in handleQuickScanIfNeeded() }
        .onChange(of: scanModel.isScanning) { value in
            coordinator.isScanning = value
        }
        .onChange(of: coordinator.section) { _ in syncSearch() }
        .onChange(of: coordinator.searchText) { _ in syncSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .moleLiteRefresh)) { _ in
            refreshCurrentSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .moleLiteSelectSection)) { note in
            if let raw = note.object as? String, let section = AppSection(rawValue: raw) {
                coordinator.section = section
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .moleLiteQuickScan)) { _ in
            coordinator.requestQuickScan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .oCleanSelected)) { _ in
            coordinator.section = .clean
            Task { await scanModel.cleanSelected() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .oExportReport)) { _ in
            exportReport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .oFocusSearch)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .oShowPermissionGuide)) { _ in
            ScanSettings.resetPermissionGuide()
            showOnboarding = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .oAuditEstimateRules)) { _ in
            rulesModel.scanEstimates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .oPermissionGranted)) { _ in
            // 授权成功后自动补充扫描能力：重新估算可清理空间并刷新当前页。
            overviewModel.estimateCleanable()
            refreshCurrentSection()
            showGrantedNotice = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                dismissGrantedNotice()
            }
        }
    }

    // MARK: - 顶部导航
    //
    // 六个页面平铺在窗口顶部；每项固定宽度、单行显示，860 宽下不换行。
    // 品牌名由窗口标题栏（navigationTitle）承载，这里不再重复展示。
    private var topNavigation: some View {
        HStack(spacing: DesignSpec.space2) {
            ForEach(AppSection.allCases) { section in
                navItem(section)
            }

            Spacer(minLength: DesignSpec.space2)

            HStack(spacing: 4) {
                if !permissions.allGranted {
                    StatusDot(color: M2.warning, size: 5)
                }
                Text(permissions.allGranted ? "仅移入废纸篓" : "部分受限")
                    .font(M2Font.mono(9))
                    .foregroundStyle(permissions.allGranted ? M2.tertiary : M2.warning)
                    .lineLimit(1)
            }
            .help(permissions.allGranted ? "所有清理动作只移入废纸篓" : "部分受保护目录无法读取")
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(M2.bg)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func navItem(_ section: AppSection) -> some View {
        let selected = coordinator.section == section
        return Button {
            coordinator.show(section)
        } label: {
            Text(section.title)
                .font(M2Font.body(12, selected ? .medium : .regular))
                .foregroundStyle(selected ? M2.ink : M2.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 11)
                .padding(.bottom, 7)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? M2.ink : Color.clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: DesignSpec.animationDuration), value: selected)
        .help("\(section.title)（⌘\(section.shortcutNumber)）")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityLabel(section.title)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: DesignSpec.space2) {
                searchField

                Button {
                    refreshCurrentSection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(M2.secondary)
                .help("刷新当前页面（⌘R）")
                .accessibilityLabel("刷新当前页面")

                Button(primaryActionTitle) {
                    performPrimaryAction()
                }
                .buttonStyle(M2PrimaryButtonStyle())
                .disabled(primaryActionDisabled)
                .help(primaryActionTitle)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DesignSpec.space1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(M2.tertiary)
            TextField("搜索当前页面", text: $coordinator.searchText)
                .textFieldStyle(.plain)
                .font(M2Font.body(11))
                .focused($searchFocused)
                .frame(width: 150)
                .accessibilityLabel("搜索当前页面")
            if !coordinator.searchText.isEmpty {
                Button {
                    coordinator.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(M2.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                .fill(M2.panel)
        )
        .overlay {
            RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                .strokeBorder(M2.line, lineWidth: 1)
        }
    }

    private var primaryActionTitle: String {
        switch coordinator.section {
        case .overview: return "扫描"
        case .clean: return scanModel.isScanning ? "扫描中" : "开始扫描"
        case .space: return coordinator.spaceTab == .files ? "重新扫描" : "查找重复"
        case .apps: return uninstallModel.isLoading ? "载入中" : "重新载入"
        case .system: return "重新检测"
        case .rules: return rulesModel.isEstimating ? "估算中" : "估算"
        }
    }

    private var primaryActionDisabled: Bool {
        switch coordinator.section {
        case .clean: return scanModel.isScanning || scanModel.isCleaning
        case .space: return coordinator.spaceTab == .files ? largeFilesModel.isScanning : duplicateModel.isScanning
        case .apps: return uninstallModel.isLoading || uninstallModel.isWorking
        case .rules: return rulesModel.isEstimating
        case .overview, .system: return false
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detail: some View {
        switch coordinator.section {
        case .overview:
            OverviewView(
                model: overviewModel,
                permissions: permissions,
                goScan: { coordinator.requestQuickScan() },
                goSpace: { coordinator.show(.space) },
                goPermission: { coordinator.show(.system, systemTab: .permissions) }
            )
        case .clean:
            ScannerView(
                model: scanModel,
                permissions: permissions,
                goSpace: { coordinator.show(.space, spaceTab: .files) }
            )
        case .space:
            SpaceView(
                largeModel: largeFilesModel,
                duplicateModel: duplicateModel,
                searchText: coordinator.searchText
            )
        case .apps:
            UninstallView(model: uninstallModel)
        case .system:
            SystemView(monitor: menuBarMonitor, permissions: permissions, launchModel: launchModel)
        case .rules:
            RulesView(model: rulesModel, estimates: ruleEstimates,
                      goClean: { coordinator.show(.clean) })
        }
    }

    // MARK: - 快捷行为

    private func dismissGrantedNotice() {
        withAnimation(.easeOut(duration: DesignSpec.animationDuration)) {
            showGrantedNotice = false
        }
        permissions.dismissGrantedNotice()
    }

    private func syncSearch() {
        // 各页各自持有过滤状态；工具栏是统一入口。
        scanModel.searchText = coordinator.searchText
        uninstallModel.searchText = coordinator.searchText
        largeFilesModel.searchText = coordinator.searchText
        duplicateModel.searchText = coordinator.searchText
        launchModel.searchText = coordinator.searchText
    }

    private func handleQuickScanIfNeeded() {
        guard coordinator.quickScanToken != handledQuickScanToken else { return }
        handledQuickScanToken = coordinator.quickScanToken
        coordinator.section = .clean
        scanModel.startScan(categories: [.userCaches, .logs, .xcode])
    }

    private func performPrimaryAction() {
        switch coordinator.section {
        case .overview:
            coordinator.requestQuickScan()
        case .clean:
            scanModel.startScan()
        case .space:
            if coordinator.spaceTab == .files {
                largeFilesModel.startScan()
            } else {
                duplicateModel.startScan()
            }
        case .apps:
            uninstallModel.load()
        case .system:
            permissions.refresh()
            launchModel.load()
        case .rules:
            rulesModel.scanEstimates()
        }
    }

    private func refreshCurrentSection() {
        switch coordinator.section {
        case .overview:
            overviewModel.refresh()
            overviewModel.estimateCleanable()
            permissions.refresh()
        case .clean:
            scanModel.startScan()
        case .space:
            if coordinator.spaceTab == .files {
                largeFilesModel.startScan()
            } else {
                duplicateModel.startScan()
            }
        case .apps:
            uninstallModel.load()
        case .system:
            permissions.refresh()
            launchModel.load()
            menuBarMonitor.refresh()
        case .rules:
            rulesModel.reload()
            rulesModel.scanEstimates()
        }
    }

    /// 文件菜单「导出报告」：导出当前扫描结果为 Markdown。
    private func exportReport() {
        guard let report = scanModel.report else {
            scanModel.present(message: "还没有扫描结果可导出，请先在「清理」页扫描。")
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "O-扫描结果.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ScanReportExporter.markdown(report).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            scanModel.present(message: "导出失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 状态栏

private struct StatusBarView: View {
    let section: AppSection
    @ObservedObject var scanModel: ScanViewModel
    @ObservedObject var overviewModel: OverviewViewModel
    @ObservedObject var largeModel: LargeFilesViewModel
    @ObservedObject var duplicateModel: DuplicateViewModel
    @ObservedObject var uninstallModel: UninstallViewModel
    @ObservedObject var rulesModel: RulesViewModel
    @ObservedObject var permissions: PermissionCenter

    var body: some View {
        HStack(spacing: DesignSpec.space2) {
            Group {
                if scanModel.isScanning {
                    M2ProgressMeter(fraction: scanModel.progress.fraction, height: 3)
                        .frame(width: 76)
                    HStack(spacing: 3) {
                        Text("扫描中")
                        Text("\(scanModel.progress.itemsScanned)")
                            .font(M2Font.mono(DesignSpec.microSize, .medium))
                            .foregroundStyle(M2.secondary)
                        Text("项 · \(Int(scanModel.progress.fraction * 100))%")
                    }
                } else {
                    if !permissions.allGranted {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(M2.warning)
                    }
                    Text(leadingText)
                }
            }
            .font(M2Font.body(DesignSpec.microSize))
            .foregroundStyle(M2.secondary)
            .lineLimit(1)

            Spacer(minLength: DesignSpec.space2)

            Text(trailingText)
                .font(M2Font.mono(9))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .frame(height: DesignSpec.statusBarHeight)
        .background(M2.bg)
        .overlay(alignment: .top) { Hairline() }
    }

    private var leadingText: String {
        switch section {
        case .overview:
            if let disk = overviewModel.disk {
                return "可用 \(ByteFormatter.string(disk.availableBytes)) / 共 \(ByteFormatter.string(disk.totalBytes)) · 2 秒采样"
            }
            return "正在读取磁盘信息"
        case .clean:
            let count = scanModel.report?.results.reduce(0) { $0 + $1.items.count } ?? 0
            return "已选 \(scanModel.selectedIDs.count) 项 · \(ByteFormatter.string(scanModel.selectedBytes)) · 共 \(count) 项"
        case .space:
            if duplicateModel.isScanning { return "已检查 \(duplicateModel.scannedFiles) 个文件" }
            if largeModel.isScanning { return "正在查找大文件" }
            return "大文件 \(largeModel.items.count) 项 · 重复 \(duplicateModel.groups.count) 组"
        case .apps:
            return "共 \(uninstallModel.apps.count) 个应用 · 已选 \(uninstallModel.selectedAppIDs.count) 个"
        case .system:
            return "权限检查于 \(Self.timeFormatter.string(from: permissions.lastCheckedAt))"
        case .rules:
            return "\(rulesModel.enabledCount) 条规则启用 · \(rulesModel.configuration.protectedPaths.count) 项受保护"
        }
    }

    private var trailingText: String {
        if section == .rules {
            if rulesModel.isEstimating { return "正在按当前规则估算" }
            if let date = RuleEstimateStore.shared.scannedAt {
                return "预计空间估算于 \(Self.timeFormatter.string(from: date))"
            }
            return "尚未估算预计空间"
        }
        if let entry = overviewModel.lastScanEntry {
            return "上次扫描 \(Self.timeFormatter.string(from: entry.date)) · \(entry.itemCount) 项"
        }
        return permissions.allGranted ? "尚未扫描" : "部分内容受权限限制"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
