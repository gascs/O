import AppKit
import MoleLiteCore
import SwiftUI

/// 空间：大文件 / 重复文件两个子切换，层级不超过两层。
struct SpaceView: View {
    @ObservedObject var largeModel: LargeFilesViewModel
    @ObservedObject var duplicateModel: DuplicateViewModel
    let searchText: String

    @ObservedObject private var coordinator = AppCoordinator.shared

    private var tab: Binding<SpaceTab> {
        Binding(get: { coordinator.spaceTab }, set: { coordinator.spaceTab = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch coordinator.spaceTab {
            case .files:
                LargeFilesView(model: largeModel)
            case .duplicates:
                DuplicatesView(model: duplicateModel)
            }
        }
        .background(M2.bg)
        .tint(M2.ink)
        .onAppear {
            // 受限整页生效时不后台扫描，避免「页面说受限、后台却已扫完」的自相矛盾。
            let restricted = coordinator.auditForceRestricted
                || (PermissionCenter.shared.snapshot.fullDiskAccessStatus == .denied && !coordinator.allowLimitedScan)
            if !restricted && largeModel.items.isEmpty && !largeModel.isScanning {
                largeModel.startScan()
            }
        }
    }

    private var header: some View {
        PageHeaderBar(
            title: "空间",
            subtitle: coordinator.spaceTab == .files
                ? "超过阈值的文件 · 按名称、类型、时间与大小排序"
                : "按内容哈希识别重复文件 · 默认保留每组一份"
        ) {
            HStack(spacing: DesignSpec.space3) {
                M2Tabs(
                    items: SpaceTab.allCases.map { ($0, $0.title) },
                    selection: tab
                )

                if isScanning {
                    Button("取消") { cancel() }
                        .buttonStyle(M2SecondaryButtonStyle(compact: true))
                }
            }
        }
    }

    private var isScanning: Bool {
        coordinator.spaceTab == .files ? largeModel.isScanning : duplicateModel.isScanning
    }

    private func cancel() {
        if coordinator.spaceTab == .files {
            largeModel.cancel()
        } else {
            duplicateModel.cancel()
        }
    }
}

/// 空间 › 重复文件。
struct DuplicatesView: View {
    @ObservedObject var model: DuplicateViewModel

    @ObservedObject private var permissions = PermissionCenter.shared
    @ObservedObject private var coordinator = AppCoordinator.shared

    private var showsRestrictedPage: Bool {
        if coordinator.auditForceRestricted { return true }
        return permissions.snapshot.fullDiskAccessStatus == .denied && !coordinator.allowLimitedScan
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
                items: model.selectedFiles.map {
                    ScanItem(url: $0.url, byteSize: $0.byteSize, isDirectory: false)
                },
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

    private var restrictedPage: some View {
        M2RestrictedPage(
            title: "受限：未获得完全磁盘访问",
            summary: "没有完全磁盘访问时，重复文件只能在下载、文档、桌面等普通目录里比对；受保护位置里的副本不会出现在结果里。",
            misses: [
                "~/Library 下的重复副本与缓存导出文件",
                "应用容器（Containers / Group Containers）中的重复数据",
                "邮件附件与 Safari 的下载副本"
            ],
            scopeNote: "当前范围 \(model.rootsDescription) · 最小 \(model.minSizeMB) MB。授权后回来会自动重新检测。",
            onAuthorize: { permissions.openSettings() },
            onRecheck: { permissions.refresh() },
            onContinue: {
                coordinator.allowLimitedScan = true
                if model.groups.isEmpty && !model.isScanning { model.startScan() }
            }
        )
    }

    private var toolbar: some View {
        HStack(spacing: DesignSpec.space3) {
            Stepper(value: $model.minSizeMB, in: 1...200, step: 1) {
                Text("最小 \(model.minSizeMB) MB")
                    .font(M2Font.mono(10))
                    .foregroundStyle(M2.secondary)
            }
            .fixedSize()

            Text("范围：\(model.rootsDescription)")
                .font(M2Font.body(10))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("在「系统 › 设置」里可增删查找目录与结果上限")

            Spacer(minLength: DesignSpec.space2)

            if model.isScanning {
                Text("已检查 \(model.scannedFiles) 个文件 · 正在比对")
                    .font(M2Font.mono(10))
                    .foregroundStyle(M2.secondary)
            } else if !model.groups.isEmpty {
                Text("\(model.groups.count) 组 · 可释放 \(ByteFormatter.string(model.reclaimableBytes))")
                    .font(M2Font.mono(10))
                    .foregroundStyle(M2.secondary)
            }
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .bottom) { Hairline() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            ScrollView {
                M2ScanningState(
                    title: "正在比对重复文件",
                    detail: "已检查 \(model.scannedFiles) 个文件",
                    fraction: 0,
                    currentPath: nil,
                    rows: 5
                )
                .padding(DesignSpec.pagePadding)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if model.groups.isEmpty {
            VStack(spacing: DesignSpec.space3) {
                if let message = model.message, message.contains("失败") || message.contains("错误") {
                    M2Notice(kind: M2NoticeKind.infer(message), title: message)
                        .padding(.horizontal, DesignSpec.pagePadding)
                        .padding(.top, DesignSpec.space3)
                }
                EmptyState(
                    icon: "doc.on.doc",
                    title: "没有发现重复文件",
                    message: model.message ?? "可在「系统 › 设置」里调整查找目录与结果上限。",
                    actionTitle: "开始查找",
                    action: { model.startScan() }
                )
                .frame(maxHeight: .infinity)
            }
        } else if model.filteredGroups.isEmpty {
            EmptyState(
                icon: "magnifyingglass",
                title: "没有匹配的重复文件",
                message: "当前筛选「\(model.searchText)」没有结果。",
                actionTitle: "清除筛选",
                action: { model.searchText = "" }
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filteredGroups) { group in
                        groupHeader(group)
                        ForEach(group.files) { file in
                            fileRow(file, keep: file.id == group.files.first?.id)
                        }
                        Hairline()
                    }
                }
                .padding(.horizontal, DesignSpec.pagePadding)
                .padding(.bottom, DesignSpec.space5)
            }
        }
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack(spacing: DesignSpec.space2) {
            Text("\(group.files.count) 个相同文件")
                .font(M2Font.body(12, .medium))
                .foregroundStyle(M2.text)
            M2Number(text: ByteFormatter.string(group.reclaimableBytes), size: 10, weight: .medium, unitColor: M2.tertiary)
            Text("每个 \(ByteFormatter.string(group.fileSize))")
                .font(M2Font.body(10))
                .foregroundStyle(M2.tertiary)
            Spacer()
            Button("勾选副本") { model.toggleGroup(group) }
                .buttonStyle(M2LinkButtonStyle())
        }
        .frame(height: DesignSpec.rowHeight)
        .padding(.top, DesignSpec.space2)
    }

    private func fileRow(_ file: DuplicateFile, keep: Bool) -> some View {
        HStack(spacing: DesignSpec.space2) {
            Toggle("", isOn: Binding(
                get: { model.selectedIDs.contains(file.id) },
                set: { _ in model.toggle(file) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .tint(M2.ink)
            .frame(width: 18)
            .accessibilityLabel("选择 \(file.name)")

            Text(keep ? "保留" : "待清理")
                .font(M2Font.mono(9))
                .foregroundStyle(keep ? M2.secondary : M2.ink)
                .frame(width: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                Text(file.url.deletingLastPathComponent().path)
                    .font(M2Font.mono(9.5))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DesignSpec.space2)

            Text(LargeFilesView.dateText(file.modifiedAt))
                .font(M2Font.mono(9.5))
                .foregroundStyle(M2.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "folder.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(M2.tertiary)
            }
            .buttonStyle(.plain)
            .help("在 Finder 中显示")
        }
        .frame(height: DesignSpec.tableRowHeight - 4)
        .hoverHighlight(cornerRadius: 4)
    }

    private var footer: some View {
        HStack(spacing: DesignSpec.space3) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text("已选 \(model.selectedFiles.count) 项")
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
            Button("清空选择") { model.clearSelection() }
                .buttonStyle(M2SecondaryButtonStyle())
                .disabled(model.selectedIDs.isEmpty)
            Button {
                model.showingConfirm = true
            } label: {
                Label("移入废纸篓", systemImage: "trash")
            }
            .buttonStyle(M2PrimaryButtonStyle())
            .disabled(model.selectedFiles.isEmpty || model.isCleaning)
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .top) { Hairline() }
    }
}
