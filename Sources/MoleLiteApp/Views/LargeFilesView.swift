import AppKit
import MoleLiteCore
import SwiftUI

/// 空间 › 大文件：M2 自定义表格（列对齐、等宽 tabular 数字、行内勾选），
/// 保留下拉目录、阈值、多选与右键操作。
struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesViewModel

    @ObservedObject private var permissions = PermissionCenter.shared
    @ObservedObject private var coordinator = AppCoordinator.shared

    /// 未授权且用户没有选择继续时，整页替换为受限说明，而不是只挂一条横幅。
    private var showsRestrictedPage: Bool {
        if coordinator.auditForceRestricted { return true }
        return permissions.snapshot.fullDiskAccessStatus == .denied && !coordinator.allowLimitedScan
    }

    private enum SortKey {
        case name, location, type, modified, size
    }

    @State private var sortKey: SortKey = .size
    @State private var descending = true

    private var items: [ScanItem] {
        let filtered = model.filteredItems
        return filtered.sorted { lhs, rhs in
            let result: Bool
            switch sortKey {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .location:
                result = lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
            case .type:
                result = lhs.fileExtension.localizedStandardCompare(rhs.fileExtension) == .orderedAscending
            case .modified:
                result = (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
            case .size:
                result = lhs.byteSize < rhs.byteSize
            }
            return descending ? !result : result
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsRestrictedPage {
                restrictedPage
            } else {
                toolbar
                content
                footer
            }
        }
        .sheet(isPresented: $model.showingConfirm) {
            ConfirmCleanSheet(
                items: model.selectedItems,
                totalBytes: model.selectedBytes,
                onConfirm: {
                    model.showingConfirm = false
                    Task { await model.trashSelected() }
                },
                onCancel: { model.showingConfirm = false }
            )
        }
        .alert("清理结果", isPresented: $model.showingResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.resultMessage)
        }
    }

    // MARK: - 受限整页

    private var restrictedPage: some View {
        M2RestrictedPage(
            title: "受限：未获得完全磁盘访问",
            summary: "没有完全磁盘访问时，O 只能扫描下载、文档、桌面等普通目录；受保护位置里的大文件不会出现在结果里，体积统计会偏少。",
            misses: [
                "~/Library/Caches 与其他应用容器中的大文件",
                "邮件附件与 Safari 的下载缓存",
                "其他受保护目录中的数据文件"
            ],
            scopeNote: "当前阈值 \(model.thresholdMB) MB · 目录 \(shortPath(model.rootPath))。授权后回来会自动重新检测。",
            onAuthorize: { permissions.openSettings() },
            onRecheck: { permissions.refresh() },
            onContinue: {
                coordinator.allowLimitedScan = true
                if model.items.isEmpty && !model.isScanning { model.startScan() }
            }
        )
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: DesignSpec.space3) {
            Menu {
                ForEach(model.availableRoots) { item in
                    Button(item.title) { model.changeRoot(item.url) }
                }
                Divider()
                Button("选择文件夹…") { pickFolder() }
            } label: {
                Label(shortPath(model.rootPath), systemImage: "folder")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 200)

            Stepper(value: $model.thresholdMB, in: 10...5000, step: 50) {
                Text("阈值 \(model.thresholdMB) MB")
                    .font(M2Font.mono(10))
                    .foregroundStyle(M2.secondary)
            }
            .fixedSize()

            if model.isScanning {
                Text("正在查找…")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
            } else if !model.items.isEmpty {
                HStack(spacing: 3) {
                    Text("\(model.items.count) 项")
                        .font(M2Font.mono(10))
                        .foregroundStyle(M2.secondary)
                    Text("·")
                        .foregroundStyle(M2.tertiary)
                    M2Number(text: ByteFormatter.string(model.totalBytes), size: 10, weight: .medium, unitColor: M2.tertiary)
                }
            }

            Spacer(minLength: DesignSpec.space2)

            if !model.searchText.isEmpty {
                Text("筛选「\(model.searchText)」")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(1)
            }

            Button("全选") { model.selectAll() }
                .buttonStyle(M2LinkButtonStyle())
                .disabled(items.isEmpty)
            Button("清空") { model.clearSelection() }
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
                    title: "正在查找大文件",
                    detail: "阈值 \(model.thresholdMB) MB · \(shortPath(model.rootPath))",
                    fraction: 0,
                    currentPath: nil,
                    rows: 7
                )
                .padding(DesignSpec.pagePadding)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if model.items.isEmpty {
            VStack(spacing: DesignSpec.space3) {
                if let message = model.message, message.contains("失败") || message.contains("错误") {
                    M2Notice(kind: M2NoticeKind.infer(message), title: message)
                        .padding(.horizontal, DesignSpec.pagePadding)
                        .padding(.top, DesignSpec.space3)
                }
                EmptyState(
                    icon: "externaldrive",
                    title: "没有找到大文件",
                    message: model.message ?? "调整阈值或切换目录后重试。",
                    actionTitle: "开始扫描",
                    action: { model.startScan() }
                )
                .frame(maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    tableHeader
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, DesignSpec.pagePadding)
                .padding(.bottom, DesignSpec.space5)
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: DesignSpec.space2) {
            Color.clear.frame(width: 18)
            headerButton("名称", key: .name, alignment: .leading)
                .frame(maxWidth: .infinity)
            headerButton("位置", key: .location, alignment: .leading)
                .frame(width: 132)
            headerButton("类型", key: .type, alignment: .leading)
                .frame(width: 52)
            headerButton("修改时间", key: .modified, alignment: .leading)
                .frame(width: 108)
            headerButton("大小", key: .size, alignment: .trailing)
                .frame(width: 76)
        }
        .padding(.vertical, DesignSpec.space2)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func headerButton(_ title: String, key: SortKey, alignment: Alignment) -> some View {
        Button {
            if sortKey == key {
                descending.toggle()
            } else {
                sortKey = key
                descending = key == .size || key == .modified
            }
        } label: {
            HStack(spacing: 2) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                if sortKey == key {
                    Image(systemName: descending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 7, weight: .semibold))
                }
                if alignment != .trailing { Spacer(minLength: 0) }
            }
            .font(M2Font.mono(DesignSpec.sectionLabelSize, .medium))
            .tracking(0.4)
            .foregroundStyle(sortKey == key ? M2.secondary : M2.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("按\(title)排序")
    }

    private func row(_ item: ScanItem) -> some View {
        HStack(spacing: DesignSpec.space2) {
            Toggle("", isOn: Binding(
                get: { model.selectedIDs.contains(item.id) },
                set: { newValue in
                    var ids = model.selectedIDs
                    if newValue { ids.insert(item.id) } else { ids.remove(item.id) }
                    model.setSelection(ids)
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .tint(M2.ink)
            .frame(width: 18)
            .accessibilityLabel("选择 \(item.name)")

            HStack(spacing: DesignSpec.space2) {
                Image(systemName: FileIcon.systemImage(for: item.fileExtension))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(M2.tertiary)
                    .frame(width: 14)
                Text(item.name)
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                    .help(item.url.path)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            Text(shortPath(item.url.deletingLastPathComponent().path))
                .font(M2Font.mono(9.5))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 132, alignment: .leading)
                .help(item.url.path)

            Text(item.fileExtension.isEmpty ? "—" : item.fileExtension)
                .font(M2Font.body(9.5))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
                .frame(width: 52, alignment: .leading)

            Text(Self.dateText(item.modifiedAt))
                .font(M2Font.mono(9.5))
                .foregroundStyle(M2.secondary)
                .lineLimit(1)
                .frame(width: 108, alignment: .leading)

            M2Number(text: ByteFormatter.string(item.byteSize), size: 11, weight: .medium, unitColor: M2.tertiary)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(height: DesignSpec.tableRowHeight - 4)
        .hoverHighlight(cornerRadius: 4)
        .contextMenu {
            Button("在 Finder 中显示") { reveal([item.id]) }
            Button("移入废纸篓") {
                model.setSelection([item.id])
                model.showingConfirm = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name)，\(ByteFormatter.string(item.byteSize))")
    }

    private var footer: some View {
        HStack(spacing: DesignSpec.space3) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text("已选 \(model.selectedItems.count) 项")
                        .font(M2Font.body(11))
                        .foregroundStyle(M2.text)
                    Text("·")
                        .foregroundStyle(M2.tertiary)
                    M2Number(text: ByteFormatter.string(model.selectedBytes), size: 11, weight: .medium, unitColor: M2.tertiary)
                }
                Text("仅移入废纸篓，可在废纸篓中恢复")
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.secondary)
            }
            if model.isCleaning {
                Text("正在移入废纸篓…")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
            }
            Spacer()
            Button {
                model.showingConfirm = true
            } label: {
                Label("移入废纸篓", systemImage: "trash")
            }
            .buttonStyle(M2PrimaryButtonStyle())
            .disabled(model.selectedItems.isEmpty || model.isCleaning)
            .help(model.selectedItems.isEmpty ? "先选择文件" : "移入废纸篓，可恢复")
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: - 辅助

    private func reveal(_ ids: Set<String>) {
        let urls = model.items.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择要扫描大文件的目录"
        if panel.runModal() == .OK, let url = panel.url {
            model.changeRoot(url)
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
