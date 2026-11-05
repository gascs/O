import AppKit
import MoleLiteCore
import SwiftUI
import UniformTypeIdentifiers

/// 清理页：M2 表格式分类行（展开箭头 / 图标 / 名称 / 说明 / 大小 / 勾选）。
/// 五种状态（空 / 扫描中 / 有结果 / 受限 / 错误）都在同一套密度与字阶内成立。
struct ScannerView: View {
    @ObservedObject var model: ScanViewModel
    @ObservedObject var permissions: PermissionCenter
    var goSpace: () -> Void

    @State private var expandedCategories: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.report != nil && !model.isScanning {
                controlBar
            }

            if !permissions.hasFullDiskAccess {
                M2RestrictedState(
                    message: "受限：邮件、Safari 与部分应用容器读不到，扫描结果会偏少；清理仍只作用于可见项。",
                    onOpenSettings: { permissions.openSettings() },
                    onRecheck: { permissions.refresh() }
                )
                .padding(.horizontal, DesignSpec.pagePadding)
                .padding(.top, DesignSpec.space3)
            }

            if let banner = model.banner, !model.isScanning,
               !(!permissions.hasFullDiskAccess
                 && (M2NoticeKind.infer(banner) == .warning || banner.contains("部分目录不可访问"))) {
                M2Notice(kind: M2NoticeKind.infer(banner), title: banner)
                    .padding(.horizontal, DesignSpec.pagePadding)
                    .padding(.top, DesignSpec.space3)
            }

            content

            Hairline()
            footer
        }
        .background(M2.bg)
        .tint(M2.ink)
        .sheet(isPresented: $model.showingConfirm) {
            ConfirmCleanSheet(
                items: model.selectedItems,
                totalBytes: model.selectedBytes,
                permanentlyDeletes: model.selectionIncludesTrash,
                onConfirm: {
                    model.showingConfirm = false
                    Task { await model.cleanSelected() }
                },
                onCancel: { model.showingConfirm = false }
            )
        }
        .alert("清理结果", isPresented: $model.showingResult) {
            if model.cleanHasPermissionIssue {
                Button("打开权限设置") { permissions.openSettings() }
            }
            if !model.failedItems.isEmpty {
                Button("重试失败项") {
                    Task { await model.retryFailed() }
                }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(model.resultMessage)
        }
    }

    // MARK: - 页头

    private var header: some View {
        PageHeaderBar(title: "清理", subtitle: headerSubtitle) {
            HStack(spacing: DesignSpec.space3) {
                Menu {
                    Button("导出 CSV") { export(.csv) }
                    Button("导出 Markdown") { export(.markdown) }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(M2Font.body(11))
                        .foregroundStyle(model.report == nil ? M2.tertiary : M2.ink)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.report == nil)
                .help("导出扫描报告")

                if model.isScanning {
                    Button("取消扫描") { model.cancelScan() }
                        .buttonStyle(M2SecondaryButtonStyle(compact: true))
                }
            }
        }
    }

    private var headerSubtitle: String {
        if model.isScanning { return "正在扫描，可随时取消；结果按分类逐步出现" }
        guard let report = model.report else { return "扫描缓存、日志、Xcode 与废纸篓；清理默认移入废纸篓" }
        return String(format: "上次扫描 %d 项 · 用时 %.1f 秒 · 清理默认移入废纸篓", report.scannedItemCount, report.duration)
    }

    // MARK: - 控制条

    private var controlBar: some View {
        HStack(spacing: DesignSpec.space4) {
            ForEach(model.recommendations) { group in
                HStack(spacing: DesignSpec.space1 + 2) {
                    StatusDot(color: M2.grade(group.grade), size: 5)
                    Text(group.grade.title)
                        .font(M2Font.body(10))
                        .foregroundStyle(M2.secondary)
                    M2Number(text: ByteFormatter.string(group.bytes), size: 10, weight: .medium, unitColor: M2.tertiary)
                }
                .help(group.grade.explanation)
            }
            if !model.searchText.isEmpty {
                HStack(spacing: DesignSpec.space2) {
                    Text("筛选「\(model.searchText)」")
                        .font(M2Font.body(10))
                        .foregroundStyle(M2.secondary)
                        .lineLimit(1)
                    Button("清除") { model.searchText = "" }
                        .buttonStyle(M2LinkButtonStyle())
                }
            }
            Spacer(minLength: DesignSpec.space2)
            Button("勾选建议项") { model.selectSuggested() }
                .buttonStyle(M2LinkButtonStyle())
                .disabled(model.report == nil)
            Button("清空选择") { model.clearSelection() }
                .buttonStyle(M2LinkButtonStyle())
                .disabled(model.selectedIDs.isEmpty)
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            ScrollView {
                M2ScanningState(
                    title: "正在扫描",
                    detail: scanningDetail,
                    fraction: model.progress.fraction,
                    currentPath: model.progress.currentPath,
                    rows: 6
                )
                .padding(DesignSpec.pagePadding)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if model.report == nil {
            EmptyState(
                icon: "trash",
                title: "准备开始扫描",
                message: "统计缓存、日志、Xcode 数据与废纸篓体积；清理默认移入废纸篓，废纸篓内容可显式永久删除。",
                actionTitle: "开始扫描",
                action: { model.startScan() }
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    tableHeader
                    if model.filteredCategoryCount == 0 {
                        Text(model.searchText.isEmpty ? "未发现可清理项目。" : "没有匹配「\(model.searchText)」的项目。")
                            .font(M2Font.body(11.5))
                            .foregroundStyle(M2.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, DesignSpec.space5)
                            .padding(.horizontal, DesignSpec.space3)
                    } else {
                        ForEach(ScanCategory.allCases.filter { category in
                            guard let result = model.result(for: category) else { return false }
                            return result.totalBytes > 0 || result.message != nil
                                || !model.filteredItems(in: result).isEmpty
                        }) { category in
                            CategoryTableRow(
                                category: category,
                                result: model.result(for: category),
                                model: model,
                                permissions: permissions,
                                isExpanded: expandedCategories.contains(category.rawValue),
                                toggleExpanded: {
                                    withAnimation(.easeOut(duration: DesignSpec.expandDuration)) {
                                        if expandedCategories.contains(category.rawValue) {
                                            expandedCategories.remove(category.rawValue)
                                        } else {
                                            expandedCategories.insert(category.rawValue)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    spaceFooterRow
                }
                .padding(.horizontal, DesignSpec.pagePadding)
                .padding(.top, DesignSpec.space2)
                .padding(.bottom, DesignSpec.space5)
            }
        }
    }

    private var scanningDetail: String {
        var parts: [String] = []
        if let category = model.progress.category { parts.append(category.title) }
        parts.append("已扫描 \(model.progress.itemsScanned) 项")
        if let remaining = model.remainingEstimate {
            parts.append(remaining.text)
        } else if let estimate = model.scanEstimate {
            parts.append("预计 \(estimate.text)")
        }
        return parts.joined(separator: " · ")
    }

    private var tableHeader: some View {
        HStack(spacing: DesignSpec.space2) {
            Color.clear.frame(width: 18)
            Color.clear.frame(width: 18)
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("说明").frame(width: 200, alignment: .leading)
            Text("大小").frame(width: 84, alignment: .trailing)
            Color.clear.frame(width: 18)
        }
        .font(M2Font.mono(DesignSpec.sectionLabelSize, .medium))
        .tracking(0.4)
        .foregroundStyle(M2.tertiary)
        .padding(.vertical, DesignSpec.space2)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var spaceFooterRow: some View {
        Button {
            goSpace()
        } label: {
            HStack(spacing: DesignSpec.space2) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(M2.secondary)
                Text("查看大文件与重复文件")
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.text)
                Text("按大小、类型与修改时间排序")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.tertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(M2.tertiary)
            }
            .frame(height: DesignSpec.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, DesignSpec.space3)
        .accessibilityLabel("查看大文件与重复文件")
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: DesignSpec.space3) {
            Text("清理仅移入废纸篓，可在废纸篓中恢复；废纸篓内的条目将永久删除，不可恢复")
                .font(M2Font.body(10))
                .foregroundStyle(M2.secondary)
                .lineLimit(1)
            if model.isCleaning {
                if model.cleanProgress.total > 0 {
                    M2ProgressMeter(
                        fraction: Double(model.cleanProgress.completed) / Double(max(1, model.cleanProgress.total)),
                        height: 3
                    )
                    .frame(width: 72)
                    Text("正在移动 \(model.cleanProgress.completed)/\(model.cleanProgress.total)")
                        .font(M2Font.mono(10))
                        .foregroundStyle(M2.secondary)
                } else {
                    Text("正在移动…")
                        .font(M2Font.body(10))
                        .foregroundStyle(M2.secondary)
                }
            }
            Spacer()
            Button("清理建议项") {
                model.selectSuggested()
                model.showingConfirm = true
            }
            .buttonStyle(M2SecondaryButtonStyle())
            .disabled(model.suggestedBytes == 0 || model.isScanning || model.isCleaning)
            .help(model.suggestedBytes == 0 ? "暂无可一键勾选的安全项" : "勾选安全与建议级别项目")

            Button {
                model.showingConfirm = true
            } label: {
                Label("移入废纸篓", systemImage: "trash")
            }
            .buttonStyle(M2PrimaryButtonStyle())
            .disabled(model.selectedItems.isEmpty || model.isScanning || model.isCleaning)
            .help(model.selectedItems.isEmpty ? "先勾选要清理的项目" : "移入废纸篓，可随时恢复")
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: - 导出

    private enum ExportFormat {
        case csv
        case markdown
    }

    private func export(_ format: ExportFormat) {
        guard let report = model.report else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format == .csv ? "O-扫描结果.csv" : "O-扫描结果.md"
        panel.allowedContentTypes = format == .csv
            ? [.commaSeparatedText]
            : [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .csv
            ? ScanReportExporter.csv(report)
            : ScanReportExporter.markdown(report)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.present(message: "导出失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 分类行

private struct CategoryTableRow: View {
    let category: ScanCategory
    let result: ScanCategoryResult?
    @ObservedObject var model: ScanViewModel
    @ObservedObject var permissions: PermissionCenter
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    @State private var showAll = false

    private var allItems: [ScanItem] {
        model.filteredItems(in: result ?? ScanCategoryResult(category: category))
    }

    private var visibleItems: [ScanItem] {
        showAll ? allItems : Array(allItems.prefix(8))
    }

    private var allSelected: Bool {
        !allItems.isEmpty && allItems.allSatisfy { model.selectedIDs.contains($0.id) }
    }

    private var hasRestriction: Bool {
        guard let message = result?.message else { return false }
        return message.contains("权限") || message.contains("读不到")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpec.space2) {
                Button(action: toggleExpanded) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(allItems.isEmpty ? M2.tertiary.opacity(0.5) : M2.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .disabled(allItems.isEmpty)
                .accessibilityLabel(isExpanded ? "收起 \(category.title)" : "展开 \(category.title)")

                Image(systemName: category.systemImage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(M2.secondary)
                    .frame(width: 18)

                Text(category.title)
                    .font(M2Font.body(12, .medium))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: DesignSpec.space2) {
                    HStack(spacing: 4) {
                        StatusDot(color: M2.grade(RecommendationEngine.baseGrade(for: category)), size: 4)
                        Text(RecommendationEngine.baseGrade(for: category).title)
                            .font(M2Font.body(9.5))
                            .foregroundStyle(M2.tertiary)
                            .lineLimit(1)
                    }
                    .help(RecommendationEngine.baseGrade(for: category).explanation)
                    Text(category.subtitle)
                        .font(M2Font.body(10))
                        .foregroundStyle(M2.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: 200, alignment: .leading)

                M2Number(text: ByteFormatter.string(result?.totalBytes ?? 0), size: DesignSpec.bodySize, weight: .medium, unitColor: M2.tertiary)
                    .frame(width: 84, alignment: .trailing)

                Toggle("", isOn: Binding(
                    get: { allSelected },
                    set: { selectAll($0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(M2.ink)
                .disabled(allItems.isEmpty)
                .frame(width: 18)
                .accessibilityLabel("全选 \(category.title)")
            }
            .frame(height: DesignSpec.tableRowHeight)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 4)
            .onTapGesture { if !allItems.isEmpty { toggleExpanded() } }

            if let message = result?.message {
                HStack(spacing: DesignSpec.space2) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(hasRestriction ? M2.warning : M2.tertiary)
                    Text(message)
                        .font(M2Font.body(10))
                        .foregroundStyle(hasRestriction ? M2.warning : M2.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasRestriction {
                        Button("去授权") { permissions.openSettings() }
                            .buttonStyle(M2LinkButtonStyle())
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 26)
                .padding(.vertical, DesignSpec.space1)
            }

            if isExpanded && !allItems.isEmpty {
                ForEach(visibleItems) { item in
                    ItemTableRow(item: item, model: model)
                }
                if allItems.count > 8 {
                    HStack {
                        Button(showAll ? "收起" : "显示全部 \(allItems.count) 项") {
                            withAnimation(.easeOut(duration: DesignSpec.expandDuration)) { showAll.toggle() }
                        }
                        .buttonStyle(M2LinkButtonStyle())
                        Spacer()
                    }
                    .padding(.leading, 26)
                    .padding(.vertical, DesignSpec.space1)
                }
            }

            Hairline()
        }
    }

    private func selectAll(_ selected: Bool) {
        model.setSelected(allItems.map(\.id), selected: selected)
    }
}

// MARK: - 条目行

private struct ItemTableRow: View {
    let item: ScanItem
    @ObservedObject var model: ScanViewModel

    @State private var showAllChildren = false

    private var isSelected: Bool { model.selectedIDs.contains(item.id) }
    private var children: [ScanItem] {
        showAllChildren ? item.children : Array(item.children.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpec.space2) {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { newValue in if newValue != isSelected { model.toggle(item.id) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(M2.ink)
                .frame(width: 18)
                .accessibilityLabel("选择 \(item.name)")

                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(M2.tertiary)
                    .frame(width: 18)

                Text(item.name)
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.url.path)

                HStack(spacing: DesignSpec.space1) {
                    Text(item.url.path)
                        .font(M2Font.mono(9.5))
                        .foregroundStyle(M2.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    } label: {
                        Image(systemName: "folder.magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(M2.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("在 Finder 中显示")
                    .accessibilityLabel("在 Finder 中显示 \(item.name)")
                }
                .frame(width: 200, alignment: .leading)

                M2Number(text: ByteFormatter.string(item.byteSize), size: 11, weight: .regular, unitColor: M2.tertiary)
                    .frame(width: 84, alignment: .trailing)

                Button {
                    withAnimation(.easeOut(duration: DesignSpec.expandDuration)) {
                        model.toggleExpanded(item.id)
                    }
                } label: {
                    Image(systemName: model.isExpanded(item.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(item.children.isEmpty ? M2.tertiary.opacity(0.45) : M2.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .disabled(item.children.isEmpty)
                .accessibilityLabel(model.isExpanded(item.id) ? "收起子项" : "展开子项")
            }
            .frame(height: DesignSpec.tableRowHeight - 4)
            .padding(.leading, 26)
            .hoverHighlight(cornerRadius: 4)

            if model.isExpanded(item.id) && !item.children.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        HStack(spacing: DesignSpec.space2) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9))
                                .foregroundStyle(M2.tertiary)
                                .frame(width: 14)
                            Text(child.name)
                                .font(M2Font.body(10))
                                .foregroundStyle(M2.secondary)
                                .lineLimit(1)
                            Spacer()
                            M2Number(text: ByteFormatter.string(child.byteSize), size: 10, weight: .regular, unitColor: M2.tertiary)
                        }
                        .frame(height: 24)
                    }
                    if item.children.count > 8 && !showAllChildren {
                        Button("显示全部 \(item.children.count) 项") { showAllChildren = true }
                            .buttonStyle(M2LinkButtonStyle())
                    }
                }
                .padding(.leading, 60)
                .padding(.bottom, DesignSpec.space1)
            }
        }
    }
}

// MARK: - 清理确认

struct ConfirmCleanSheet: View {
    let items: [ScanItem]
    let totalBytes: Int64
    /// 选中项是否包含废纸篓内容：这类条目会被永久删除，不可恢复。
    var permanentlyDeletes: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private struct ConfirmGroup: Identifiable {
        let id: String
        let items: [ScanItem]
    }

    private var grouped: [ConfirmGroup] {
        let dictionary = Dictionary(grouping: items) { $0.url.deletingLastPathComponent().path }
        return dictionary
            .map { ConfirmGroup(id: $0.key, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
    }

    private var estimate: DurationEstimate {
        DurationEstimator().cleanEstimate(items: items.count, bytes: totalBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space4) {
            HStack(spacing: DesignSpec.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(M2.secondary)
                Text(permanentlyDeletes ? "确认清理（含永久删除）" : "确认移入废纸篓")
                    .font(M2Font.serif(DesignSpec.sheetTitleSize))
                    .foregroundStyle(M2.text)
            }

            if permanentlyDeletes {
                Text("以下 \(items.count) 个项目共 \(ByteFormatter.string(totalBytes))：其中位于废纸篓的项目将被永久删除、不可恢复，其余项目移入废纸篓后仍可恢复。预计耗时 \(estimate.text)。")
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("永久删除无法撤销，请确认这些文件不再需要。")
                    .font(M2Font.body(11))
                    .foregroundStyle(M2.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("以下 \(items.count) 个项目共 \(ByteFormatter.string(totalBytes)) 将被移入废纸篓。移入后可随时从废纸篓恢复，O 不会执行永久删除。预计耗时 \(estimate.text)。")
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpec.space2) {
                    ForEach(grouped) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.id)
                                .font(M2Font.mono(9.5, .medium))
                                .foregroundStyle(M2.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ForEach(group.items.prefix(12)) { item in
                                HStack(spacing: DesignSpec.space2) {
                                    Text("•").foregroundStyle(M2.tertiary)
                                    Text(item.name)
                                        .font(M2Font.body(11))
                                        .foregroundStyle(M2.text)
                                        .lineLimit(1)
                                    Spacer(minLength: DesignSpec.space1)
                                    M2Number(text: ByteFormatter.string(item.byteSize), size: 10, weight: .regular, unitColor: M2.tertiary)
                                }
                            }
                            if group.items.count > 12 {
                                Text("其余 \(group.items.count - 12) 项…")
                                    .font(M2Font.body(10))
                                    .foregroundStyle(M2.tertiary)
                            }
                        }
                        .padding(.bottom, DesignSpec.space1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSpec.space3)
            }
            .frame(maxHeight: 260)
            .background(M2.panel)
            .clipShape(RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                    .strokeBorder(M2.line, lineWidth: 1)
            }

            HStack(spacing: DesignSpec.space3) {
                Text("共 \(ByteFormatter.string(totalBytes)) · \(items.count) 项")
                    .font(M2Font.mono(10))
                    .foregroundStyle(M2.secondary)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(permanentlyDeletes ? "永久删除" : "移入废纸篓", action: onConfirm)
                    .buttonStyle(M2PrimaryButtonStyle(compact: true))
            }
        }
        .padding(DesignSpec.space6)
        .frame(width: 600)
        .background(M2.bg)
    }
}
