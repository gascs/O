import AppKit
import MoleLiteCore
import SwiftUI

/// 系统 › 设置：M2 分组面板（衬线组标题 + 行内控件），改动即时生效。
/// 不使用系统 Form/Grouped，以免与 M2 表面语言混用。
struct SettingsView: View {
    @ObservedObject var monitor: MenuBarMonitor
    @ObservedObject var permissions: PermissionCenter

    @AppStorage(ScanSettings.Keys.largeFileThresholdMB) private var thresholdMB = 100
    @AppStorage(ScanSettings.Keys.includeHiddenItems) private var includeHidden = false
    @AppStorage(ScanSettings.Keys.preselectRecommendedItems) private var preselectRecommended = true
    @AppStorage(ScanSettings.Keys.menuBarDisplay) private var menuBarDisplay = MenuBarDisplayStyle.iconAndPercent.rawValue
    @AppStorage(ScanSettings.Keys.menuBarRefreshSeconds) private var refreshSeconds = 5
    @AppStorage(ScanSettings.Keys.duplicateMinSizeMB) private var duplicateMinSizeMB = 1
    @AppStorage(ScanSettings.Keys.duplicateGroupLimit) private var duplicateGroupLimit = 200
    @AppStorage(AppBehaviorSettings.Keys.windowCloseBehavior) private var closeBehavior = WindowCloseBehavior.keepInMenuBar.rawValue

    @State private var duplicateRoots: [String] = ScanSettings.duplicateRootPaths()
    @State private var feedback: String?
    @State private var loginState: LoginItemState = .notRegistered
    @State private var loginBusy = false

    private let loginController = LoginItemController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpec.sectionSpacing) {
                permissionSection
                loginSection
                windowSection
                scanSection
                duplicateSection
                menuBarSection
                shortcutSection
                safetySection
                historySection
                aboutSection
            }
            .padding(.horizontal, DesignSpec.pagePadding)
            .padding(.top, DesignSpec.sectionSpacing)
            .padding(.bottom, DesignSpec.space6)
        }
        .task { refreshLoginState() }
    }

    // MARK: - 分组骨架

    private func settingsSection<Content: View>(
        _ title: String,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpec.space2) {
            M2SectionTitle(title: title)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                content()
            }
            .panel(padding: 0)
            if let caption {
                Text(caption)
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func settingRow<Control: View>(
        title: String,
        detail: String,
        showDivider: Bool = true,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DesignSpec.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(M2Font.body(11.5, .medium))
                        .foregroundStyle(M2.text)
                    Text(detail)
                        .font(M2Font.body(9.5))
                        .foregroundStyle(M2.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DesignSpec.space3)
                control()
                    .fixedSize()
            }
            .padding(.horizontal, DesignSpec.space4)
            .padding(.vertical, DesignSpec.space2 + 2)
            .frame(minHeight: 50)

            if showDivider { Hairline().padding(.leading, DesignSpec.space4) }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 权限

    private var permissionSection: some View {
        settingsSection("权限", caption: "状态与「系统 › 权限」共用同一次真实探测，不推断。") {
            settingRow(title: "权限引导",
                       detail: "重新查看分步引导，检查完全磁盘访问与登录项状态") {
                Button("重新打开引导") {
                    NotificationCenter.default.post(name: .oShowPermissionGuide, object: nil)
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }

            ForEach(permissions.capabilities) { capability in
                CapabilityRow(capability: capability) {
                    if capability.id.contains("login") {
                        permissions.openLoginItemSettings()
                    } else {
                        permissions.openSettings()
                    }
                }
                if capability.id != permissions.capabilities.last?.id {
                    Hairline()
                }
            }
        }
    }

    // MARK: - 登录时启动

    private var loginSection: some View {
        settingsSection(
            "登录时启动",
            caption: "状态来自 SMAppService.mainApp 的真实返回值。应用不在「应用程序」文件夹或为 ad-hoc 签名时，系统可能拒绝注册；失败会显示系统原文，不会标为已启用。"
        ) {
            settingRow(title: "登录时自动打开 O",
                       detail: "通过 SMAppService 注册主应用，登录后自动启动",
                       showDivider: loginState.needsSystemSettings || feedback != nil) {
                Toggle("", isOn: Binding(
                    get: { loginState.isEnabled },
                    set: { updateLogin($0) }
                ))
                .toggleStyle(.switch)
                .tint(M2.ink)
                .labelsHidden()
                .disabled(loginBusy)
            }

            HStack(spacing: DesignSpec.space2) {
                Image(systemName: loginStatusIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(loginStatusColor)
                Text(loginState.title)
                    .font(M2Font.body(10, .medium))
                    .foregroundStyle(M2.text)
                Text(loginState.detail)
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(2)
                Spacer(minLength: DesignSpec.space2)
                if loginBusy {
                    Text("处理中…")
                        .font(M2Font.body(9.5))
                        .foregroundStyle(M2.tertiary)
                }
            }
            .padding(.horizontal, DesignSpec.space4)
            .padding(.bottom, DesignSpec.space2)

            HStack(spacing: DesignSpec.space3) {
                Button("重新检测") { refreshLoginState() }
                    .buttonStyle(M2LinkButtonStyle())
                Button("打开登录项设置") { loginController.openSystemSettings() }
                    .buttonStyle(M2LinkButtonStyle())
                if loginState.needsSystemSettings {
                    Text("需要系统设置批准后才能生效")
                        .font(M2Font.body(9.5))
                        .foregroundStyle(M2.warning)
                }
                Spacer()
            }
            .padding(.horizontal, DesignSpec.space4)
            .padding(.bottom, DesignSpec.space2)

            if let feedback {
                M2Notice(kind: .info, title: feedback)
                    .padding(.horizontal, DesignSpec.space3)
                    .padding(.bottom, DesignSpec.space3)
            }
        }
    }

    private var loginStatusIcon: String {
        switch loginState {
        case .enabled: return "checkmark.circle"
        case .requiresApproval: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon"
        default: return "circle.dashed"
        }
    }

    private var loginStatusColor: Color {
        switch loginState {
        case .enabled: return M2.secondary
        case .failed: return M2.danger
        default: return M2.warning
        }
    }

    private func refreshLoginState() {
        loginState = loginController.currentState()
    }

    private func updateLogin(_ enabled: Bool) {
        loginBusy = true
        defer { loginBusy = false }
        do {
            try loginController.setEnabled(enabled)
            loginState = loginController.currentState()
            if enabled && !loginState.isEnabled {
                feedback = "系统返回：\(loginState.title)。\(loginState.detail)"
            } else {
                feedback = enabled ? "已注册登录项" : "已注销登录项"
            }
        } catch {
            loginState = .failed(error.localizedDescription)
            feedback = "系统返回：\(error.localizedDescription)"
        }
    }

    // MARK: - 窗口

    private var windowSection: some View {
        settingsSection("窗口") {
            settingRow(title: "关闭窗口时",
                       detail: WindowCloseBehavior(rawValue: closeBehavior)?.detail
                           ?? WindowCloseBehavior.keepInMenuBar.detail,
                       showDivider: false) {
                M2Tabs(
                    items: WindowCloseBehavior.allCases.map { ($0.rawValue, $0.title) },
                    selection: $closeBehavior
                )
            }
        }
    }

    // MARK: - 扫描偏好

    private var scanSection: some View {
        settingsSection("扫描偏好") {
            settingRow(title: "大文件阈值",
                       detail: "超过该体积的文件会出现在「空间 › 大文件」结果中") {
                Stepper(value: $thresholdMB, in: 10...5000, step: 50) {
                    Text("\(thresholdMB) MB")
                        .font(M2Font.mono(10))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .fixedSize()
            }
            settingRow(title: "包含隐藏文件",
                       detail: "扫描缓存与日志时一并统计以「.」开头的项目") {
                Toggle("", isOn: $includeHidden).labelsHidden().tint(M2.ink)
            }
            settingRow(title: "默认勾选建议项",
                       detail: "扫描完成后自动勾选缓存、日志与 Xcode 项目",
                       showDivider: false) {
                Toggle("", isOn: $preselectRecommended).labelsHidden().tint(M2.ink)
            }
        }
    }

    // MARK: - 重复文件

    private var duplicateSection: some View {
        settingsSection("大文件与重复文件") {
            settingRow(title: "重复文件最小体积",
                       detail: "小于该体积的文件不参与查重") {
                Stepper(value: $duplicateMinSizeMB, in: 1...200, step: 1) {
                    Text("\(duplicateMinSizeMB) MB")
                        .font(M2Font.mono(10))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                .fixedSize()
            }
            settingRow(title: "返回的重复组上限",
                       detail: "超出部分不列出，避免列表过长") {
                Stepper(value: $duplicateGroupLimit, in: 20...2000, step: 20) {
                    Text("\(duplicateGroupLimit) 组")
                        .font(M2Font.mono(10))
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: DesignSpec.space2) {
                HStack {
                    Text("查找目录")
                        .font(M2Font.body(11.5, .medium))
                        .foregroundStyle(M2.text)
                    Spacer()
                    Button {
                        addDuplicateRoot()
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
                }
                Text("只在这些目录里查找重复文件，默认下载 / 文档 / 桌面。")
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.secondary)

                if duplicateRoots.isEmpty {
                    Text("尚未选择目录，使用默认目录。")
                        .font(M2Font.body(10))
                        .foregroundStyle(M2.tertiary)
                } else {
                    ForEach(duplicateRoots, id: \.self) { path in
                        HStack(spacing: DesignSpec.space2) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                                .foregroundStyle(M2.tertiary)
                            Text(displayPath(path))
                                .font(M2Font.mono(9.5))
                                .foregroundStyle(M2.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: DesignSpec.space2)
                            Button {
                                removeDuplicateRoot(path)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(M2.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("移除该目录")
                        }
                        .frame(height: 24)
                    }
                }
            }
            .padding(.horizontal, DesignSpec.space4)
            .padding(.vertical, DesignSpec.space3)
        }
    }

    // MARK: - 菜单栏

    private var menuBarSection: some View {
        settingsSection("菜单栏") {
            settingRow(title: "状态栏显示",
                       detail: "控制菜单栏图标旁是否显示磁盘百分比") {
                M2Tabs(
                    items: MenuBarDisplayStyle.allCases.map { ($0.rawValue, $0.title) },
                    selection: $menuBarDisplay
                )
            }
            settingRow(title: "刷新间隔",
                       detail: "菜单栏面板读取磁盘、内存、CPU 与网络的频率") {
                Stepper(value: $refreshSeconds, in: 1...60, step: 1) {
                    Text("\(refreshSeconds) 秒")
                        .font(M2Font.mono(10))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                .fixedSize()
            }
            settingRow(title: "立即刷新",
                       detail: "手动更新一次菜单栏与概览数据",
                       showDivider: false) {
                Button("刷新") { monitor.refresh() }
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }
        }
        .onChange(of: menuBarDisplay) { _ in monitor.refresh() }
        .onChange(of: refreshSeconds) { _ in monitor.restartLoop() }
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        settingsSection("快捷键") {
            ForEach(shortcutRows.indices, id: \.self) { index in
                let row = shortcutRows[index]
                HStack(spacing: DesignSpec.space3) {
                    Text(row.0)
                        .font(M2Font.mono(10, .medium))
                        .foregroundStyle(M2.ink)
                        .frame(width: 76, alignment: .leading)
                    Text(row.1)
                        .font(M2Font.body(11))
                        .foregroundStyle(M2.text)
                    Spacer()
                }
                .padding(.horizontal, DesignSpec.space4)
                .frame(height: 30)
                if index < shortcutRows.count - 1 {
                    Hairline().padding(.leading, DesignSpec.space4)
                }
            }
        }
    }

    private var shortcutRows: [(String, String)] {
        [("⌘R", "刷新当前页面"),
         ("⌘F", "聚焦搜索框"),
         ("⌘,", "打开设置"),
         ("⌘1 … ⌘5", "概览 / 清理 / 空间 / 应用 / 系统"),
         ("⌘⇧R", "立即扫描")]
    }

    // MARK: - 安全边界

    private var safetySection: some View {
        settingsSection("安全边界") {
            VStack(alignment: .leading, spacing: DesignSpec.space2) {
                bullet("所有清理只调用「移入废纸篓」，可从废纸篓恢复，不做永久删除。")
                bullet("对 /System、/usr、/bin、/Library 等系统路径一律拒绝。")
                bullet("不执行 sudo，也不尝试提升权限；权限不足时如实提示。")
                bullet("崩溃报告、共享容器等残留仅在用户目录内查找。")
                bullet("启动项只读展示，不调用 launchctl，也不修改系统登录项数据库。")
            }
            .padding(.horizontal, DesignSpec.space4)
            .padding(.vertical, DesignSpec.space3)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpec.space2) {
            Text("—")
                .font(M2Font.mono(9))
                .foregroundStyle(M2.tertiary)
                .frame(width: 10, alignment: .leading)
            Text(text)
                .font(M2Font.body(10))
                .foregroundStyle(M2.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        settingsSection("历史与趋势") {
            settingRow(title: "累计已释放", detail: "来自本地清理记录，不会上传") {
                M2Number(text: ByteFormatter.string(HistoryStore().totalFreedBytes), size: 11, weight: .medium, unitColor: M2.tertiary)
            }
            settingRow(title: "清理历史", detail: "删除所有本地扫描与清理记录") {
                Button("清空") {
                    HistoryStore().clear()
                    feedback = "历史记录已清空"
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }
            settingRow(title: "耗时预估模型", detail: "用实测数据校正扫描与清理的耗时估算",
                       showDivider: false) {
                Button("重置") {
                    DurationEstimator().reset()
                    feedback = "耗时预估已重置为经验值"
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        settingsSection("关于") {
            HStack(spacing: DesignSpec.space3) {
                BrandMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("O \(AppInfo.version)")
                        .font(M2Font.serif(16))
                        .foregroundStyle(M2.text)
                    Text(AppInfo.tagline)
                        .font(M2Font.body(11))
                        .foregroundStyle(M2.secondary)
                    Text("本地运行 · 无网络上传 · 仅移入废纸篓")
                        .font(M2Font.body(9.5))
                        .foregroundStyle(M2.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, DesignSpec.space4)
            .padding(.vertical, DesignSpec.space3)
        }
    }

    // MARK: - 行为

    private func displayPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func addDuplicateRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择要在其中查找重复文件的目录"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !duplicateRoots.contains(url.path) {
            duplicateRoots.append(url.path)
        }
        persistDuplicateRoots()
    }

    private func removeDuplicateRoot(_ path: String) {
        duplicateRoots.removeAll { $0 == path }
        persistDuplicateRoots()
    }

    private func persistDuplicateRoots() {
        UserDefaults.standard.set(duplicateRoots, forKey: ScanSettings.Keys.duplicateRootPaths)
    }
}
