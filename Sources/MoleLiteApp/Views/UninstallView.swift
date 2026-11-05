import AppKit
import MoleLiteCore
import SwiftUI

/// 应用：卸载与残留。M2 表格：图标 / 名称 / 版本 / 体积 / 残留 / Finder。
struct UninstallView: View {
    @ObservedObject var model: UninstallViewModel

    @ObservedObject private var permissions = PermissionCenter.shared
    @ObservedObject private var coordinator = AppCoordinator.shared

    /// 未授权时整页受限：应用本体仍可列出，但容器与受保护残留扫不到。
    private var showsRestrictedPage: Bool {
        if coordinator.auditForceRestricted { return true }
        return permissions.snapshot.fullDiskAccessStatus == .denied && !coordinator.allowLimitedScan
    }

    private enum Sort: String, CaseIterable, Identifiable {
        case name
        case size
        var id: String { rawValue }
        var title: String { self == .name ? "按名称" : "按体积" }
    }

    @State private var sort: Sort = .name

    private var apps: [AppBundle] {
        switch sort {
        case .name:
            return model.filteredApps.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .size:
            return model.filteredApps.sorted { $0.byteSize > $1.byteSize }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsRestrictedPage {
                restrictedPage
            } else {
                summaryBar
                content
                footer
            }
        }
        .background(M2.bg)
        .tint(M2.ink)
        .task(id: showsRestrictedPage) {
            // 回到本页时不要重复全量读取：已有列表直接展示，工具栏的「重新载入」才强制刷新。
            // 受限整页生效时先不读，用户选择「继续」解除拦截后再载入。
            if !showsRestrictedPage && model.apps.isEmpty { model.load() }
        }
        .sheet(isPresented: $model.showingConfirm) {
            ConfirmUninstallSheet(
                apps: model.selectedApps,
                leftovers: model.selectedLeftovers,
                totalBytes: model.selectedBytes,
                onConfirm: {
                    model.showingConfirm = false
                    Task { await model.uninstallSelected() }
                },
                onCancel: { model.showingConfirm = false }
            )
        }
        .alert("卸载结果", isPresented: $model.showingResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.resultMessage)
        }
    }

    // MARK: - 受限整页

    private var restrictedPage: some View {
        M2RestrictedPage(
            title: "受限：未获得完全磁盘访问",
            summary: "没有完全磁盘访问时，只能列出「应用程序」文件夹里的应用本体；应用容器与受保护目录里的关联残留扫不到，卸载后可能留下孤儿文件。",
            misses: [
                "~/Library/Containers 与 Group Containers 中的应用残留",
                "~/Library/Application Support 中受保护的应用数据",
                "邮件、Safari 等受保护应用产生的缓存与附件"
            ],
            scopeNote: "继续后只统计应用本体，残留列会显示为「无」，不代表真的没有残留。",
            onAuthorize: { permissions.openSettings() },
            onRecheck: { permissions.refresh() },
            onContinue: {
                coordinator.allowLimitedScan = true
                if model.apps.isEmpty { model.load() }
            }
        )
    }

    // MARK: - 头部

    private var header: some View {
        PageHeaderBar(
            title: "应用",
            // 受限时不要显示残留总量：那会与「残留扫不到」自相矛盾。
            subtitle: showsRestrictedPage
                ? "未授权 · 仅列出应用本体，残留未扫描"
                : "共 \(model.apps.count) 个应用 · 关联残留 \(ByteFormatter.string(model.totalLeftoverBytes))"
        ) {
            HStack(spacing: DesignSpec.space3) {
                if !model.searchText.isEmpty {
                    Text("筛选「\(model.searchText)」")
                        .font(M2Font.body(10))
                        .foregroundStyle(M2.secondary)
                        .lineLimit(1)
                    Button("清除") { model.searchText = "" }
                        .buttonStyle(M2LinkButtonStyle())
                }
            }
        }
    }

    private var summaryBar: some View {
        HStack(spacing: DesignSpec.space5) {
            summaryItem("应用数量", "\(model.apps.count) 个")
            summaryItem("应用体积", ByteFormatter.string(model.totalByteCount))
            summaryItem("关联残留", ByteFormatter.string(model.totalLeftoverBytes))
            Spacer(minLength: DesignSpec.space2)
            Picker("", selection: $sort) {
                ForEach(Sort.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(M2.ink)
            .fixedSize()
            Text("勾选应用会同时勾选其残留，可逐项取消")
                .font(M2Font.body(9.5))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func summaryItem(_ title: String, _ value: String) -> some View {
        HStack(spacing: DesignSpec.space1 + 2) {
            Text(title)
                .font(M2Font.body(9.5))
                .foregroundStyle(M2.tertiary)
            M2Number(text: value, size: 11, weight: .medium, unitColor: M2.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.apps.isEmpty {
            ScrollView {
                M2ScanningState(title: "正在读取应用", detail: "应用程序文件夹", fraction: 0, rows: 6)
                    .padding(DesignSpec.pagePadding)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if model.filteredApps.isEmpty {
            VStack(spacing: DesignSpec.space3) {
                if let banner = model.banner {
                    M2Notice(kind: M2NoticeKind.infer(banner), title: banner)
                        .padding(.horizontal, DesignSpec.pagePadding)
                        .padding(.top, DesignSpec.space3)
                }
                EmptyState(
                    icon: "app.dashed",
                    title: model.searchText.isEmpty ? "没有可显示的应用" : "没有匹配的应用",
                    message: model.banner ?? (model.searchText.isEmpty
                        ? "请确认「应用程序」文件夹可读取。"
                        : "换个关键词，或清除筛选。"),
                    actionTitle: model.searchText.isEmpty ? "重新读取" : "清除筛选",
                    action: {
                        if model.searchText.isEmpty { model.load() } else { model.searchText = "" }
                    }
                )
                .frame(maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let banner = model.banner {
                        M2Notice(kind: M2NoticeKind.infer(banner), title: banner)
                            .padding(.bottom, DesignSpec.space2)
                    }
                    columnHeader
                    ForEach(apps) { app in
                        AppRow(app: app, model: model)
                        if app.id != apps.last?.id {
                            Hairline().padding(.leading, 64)
                        }
                    }
                }
                .padding(.horizontal, DesignSpec.pagePadding)
                .padding(.top, DesignSpec.space2)
                .padding(.bottom, DesignSpec.space5)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: DesignSpec.space2) {
            Color.clear.frame(width: 18)
            Color.clear.frame(width: 26)
            Text("应用").frame(maxWidth: .infinity, alignment: .leading)
            Text("版本").frame(width: 96, alignment: .leading)
            Text("体积").frame(width: 88, alignment: .trailing)
            Text("残留").frame(width: 96, alignment: .trailing)
            Color.clear.frame(width: 20)
        }
        .font(M2Font.mono(DesignSpec.sectionLabelSize, .medium))
        .tracking(0.4)
        .foregroundStyle(M2.tertiary)
        .padding(.vertical, DesignSpec.space2)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var footer: some View {
        HStack(spacing: DesignSpec.space3) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text("已选 \(model.selectedApps.count) 个应用 · \(model.selectedLeftovers.count) 项残留")
                        .font(M2Font.body(11))
                        .foregroundStyle(M2.text)
                    Text("·")
                        .foregroundStyle(M2.tertiary)
                    M2Number(text: ByteFormatter.string(model.selectedBytes), size: 11, weight: .medium, unitColor: M2.tertiary)
                }
                Text("应用与关联残留都会移入废纸篓，可恢复")
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.secondary)
            }
            if model.isWorking {
                Text("正在卸载…")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
            }
            Spacer()
            Button {
                model.showingConfirm = true
            } label: {
                Label("卸载并移入废纸篓", systemImage: "xmark.bin")
            }
            .buttonStyle(M2PrimaryButtonStyle())
            .disabled(model.selectedApps.isEmpty || model.isWorking)
            .help(model.selectedApps.isEmpty ? "先勾选应用" : "应用与残留都会移入废纸篓")
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct AppRow: View {
    let app: AppBundle
    @ObservedObject var model: UninstallViewModel

    private var isSelected: Bool { model.selectedAppIDs.contains(app.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpec.space2) {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in model.toggle(app: app) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(M2.ink)
                .frame(width: 18)
                .accessibilityLabel("选择 \(app.name)")

                AppIcon(url: app.url, size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(M2Font.body(11.5, .medium))
                        .foregroundStyle(M2.text)
                        .lineLimit(1)
                    Text(app.bundleIdentifier ?? "无 bundle identifier")
                        .font(M2Font.mono(9))
                        .foregroundStyle(M2.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(app.version.map { "v\($0)" } ?? "—")
                    .font(M2Font.mono(9.5))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)

                M2Number(text: ByteFormatter.string(app.byteSize), size: 11, weight: .medium, unitColor: M2.tertiary)
                    .frame(width: 88, alignment: .trailing)

                Group {
                    if app.leftoverBytes > 0 {
                        Text("\(app.leftovers.count) 项 · \(ByteFormatter.string(app.leftoverBytes))")
                            .font(M2Font.mono(9.5))
                            .foregroundStyle(M2.secondary)
                    } else {
                        Text("无")
                            .font(M2Font.body(9.5))
                            .foregroundStyle(M2.tertiary)
                    }
                }
                .lineLimit(1)
                .frame(width: 96, alignment: .trailing)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([app.url])
                } label: {
                    Image(systemName: "folder.magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(M2.tertiary)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .help("在 Finder 中显示")
                .accessibilityLabel("在 Finder 中显示 \(app.name)")
            }
            .frame(height: DesignSpec.tableRowHeight + 4)
            .hoverHighlight(cornerRadius: 4)

            if isSelected && !app.leftovers.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DesignSpec.space1) {
                        Text("关联残留")
                            .font(M2Font.body(10, .medium))
                            .foregroundStyle(M2.secondary)
                        M2Number(text: ByteFormatter.string(app.leftoverBytes), size: 9.5, weight: .medium, unitColor: M2.tertiary)
                    }
                    .padding(.bottom, DesignSpec.space1)

                    ForEach(app.leftovers) { leftover in
                        HStack(spacing: DesignSpec.space2) {
                            Toggle("", isOn: Binding(
                                get: { model.selectedLeftoverIDs.contains(leftover.id) },
                                set: { _ in model.toggle(leftover: leftover) }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .tint(M2.ink)
                            .frame(width: 18)

                            Image(systemName: leftover.kind.systemImage)
                                .font(.system(size: 10))
                                .foregroundStyle(M2.tertiary)
                                .frame(width: 14)

                            Text(leftover.kind.label)
                                .font(M2Font.mono(9))
                                .foregroundStyle(M2.tertiary)
                                .frame(width: 64, alignment: .leading)

                            Text(leftover.name)
                                .font(M2Font.body(10))
                                .foregroundStyle(M2.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: DesignSpec.space2)

                            M2Number(text: ByteFormatter.string(leftover.byteSize), size: 9.5, weight: .regular, unitColor: M2.tertiary)
                        }
                        .frame(height: 24)
                    }
                }
                .padding(.leading, 48)
                .padding(.bottom, DesignSpec.space2)
            }
        }
    }
}

// MARK: - 卸载确认

struct ConfirmUninstallSheet: View {
    let apps: [AppBundle]
    let leftovers: [LeftoverItem]
    let totalBytes: Int64
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var itemCount: Int { apps.count + leftovers.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space4) {
            HStack(spacing: DesignSpec.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(M2.secondary)
                Text("确认卸载")
                    .font(M2Font.serif(DesignSpec.sheetTitleSize))
                    .foregroundStyle(M2.text)
            }

            Text("将 \(apps.count) 个应用与 \(leftovers.count) 项关联残留移入废纸篓，共 \(ByteFormatter.string(totalBytes))。所有内容都可以从废纸篓恢复。")
                .font(M2Font.body(11.5))
                .foregroundStyle(M2.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpec.space3) {
                    ForEach(apps) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: DesignSpec.space2) {
                                AppIcon(url: app.url, size: 16)
                                Text(app.name)
                                    .font(M2Font.body(11.5, .medium))
                                    .foregroundStyle(M2.text)
                                Spacer()
                                M2Number(text: ByteFormatter.string(app.byteSize), size: 10, weight: .regular, unitColor: M2.tertiary)
                            }
                            Text(app.url.path)
                                .font(M2Font.mono(9.5))
                                .foregroundStyle(M2.secondary)
                                .textSelection(.enabled)

                            ForEach(leftovers.filter { leftoversFor(app: app).contains($0.id) }) { item in
                                HStack(spacing: DesignSpec.space2) {
                                    Text(item.kind.label)
                                        .font(M2Font.mono(9))
                                        .foregroundStyle(M2.tertiary)
                                        .frame(width: 60, alignment: .leading)
                                    Text(item.url.path)
                                        .font(M2Font.mono(9.5))
                                        .foregroundStyle(M2.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: DesignSpec.space1)
                                    M2Number(text: ByteFormatter.string(item.byteSize), size: 9.5, weight: .regular, unitColor: M2.tertiary)
                                }
                                .padding(.leading, DesignSpec.space4)
                            }
                        }
                    }

                    if !orphanLeftovers.isEmpty {
                        Hairline()
                        ForEach(orphanLeftovers) { item in
                            Text(item.url.path)
                                .font(M2Font.mono(9.5))
                                .foregroundStyle(M2.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSpec.space3)
            }
            .frame(maxHeight: 280)
            .background(M2.panel)
            .clipShape(RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                    .strokeBorder(M2.line, lineWidth: 1)
            }

            HStack(spacing: DesignSpec.space3) {
                Text("共 \(itemCount) 项 · \(ByteFormatter.string(totalBytes))")
                    .font(M2Font.mono(10))
                    .foregroundStyle(M2.secondary)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("移入废纸篓", action: onConfirm)
                    .buttonStyle(M2PrimaryButtonStyle(compact: true))
            }
        }
        .padding(DesignSpec.space6)
        .frame(width: 620)
        .background(M2.bg)
    }

    private var orphanLeftovers: [LeftoverItem] {
        leftovers.filter { item in
            !apps.contains { leftoversFor(app: $0).contains(item.id) }
        }
    }

    private func leftoversFor(app: AppBundle) -> Set<String> {
        Set(app.leftovers.map(\.id))
    }
}
