import AppKit
import MoleLiteCore
import SwiftUI

/// 系统 › 启动项：按作用域分组的只读 / 可编辑列表。
struct LaunchItemsView: View {
    @ObservedObject var model: LaunchItemsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .sheet(isPresented: $model.showingConfirm) {
            ConfirmCleanSheet(
                items: model.selectedItems.map {
                    ScanItem(url: $0.url, byteSize: FileSizeReader.allocatedSize(of: $0.url), isDirectory: false)
                },
                totalBytes: model.selectedItems.reduce(0) { $0 + FileSizeReader.allocatedSize(of: $1.url) },
                onConfirm: {
                    model.showingConfirm = false
                    Task { await model.trashSelected() }
                },
                onCancel: { model.showingConfirm = false }
            )
        }
        .alert("操作结果", isPresented: $model.showingResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.resultMessage)
        }
        .task { model.load() }
    }

    private var header: some View {
        HStack(spacing: DesignSpec.space3) {
            Picker("", selection: $model.scopeFilter) {
                Text("全部").tag(LaunchScope?.none)
                ForEach(LaunchScope.allCases) { scope in
                    Text(scope.title).tag(LaunchScope?.some(scope))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(M2.ink)
            .fixedSize()

            Text("用户级 \(model.editableCount) 项 · 系统级 \(model.systemCount) 项（只读）")
                .font(M2Font.body(9.5))
                .foregroundStyle(M2.tertiary)
                .lineLimit(1)

            if !model.searchText.isEmpty {
                Text("筛选「\(model.searchText)」")
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignSpec.space2)

            if model.isLoading {
                Text("正在读取…")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
            }
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func filtered(_ items: [LaunchItem]) -> [LaunchItem] {
        let keyword = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return items }
        return items.filter {
            $0.label.localizedCaseInsensitiveContains(keyword) ||
            ($0.program ?? $0.url.path).localizedCaseInsensitiveContains(keyword)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.items.isEmpty {
            ScrollView {
                M2ScanningState(title: "正在读取启动项", detail: "用户级与系统级代理目录", fraction: 0, rows: 5)
                    .padding(DesignSpec.pagePadding)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if model.items.isEmpty {
            VStack(spacing: DesignSpec.space3) {
                if let banner = model.banner {
                    M2Notice(kind: M2NoticeKind.infer(banner), title: banner)
                        .padding(.horizontal, DesignSpec.pagePadding)
                        .padding(.top, DesignSpec.space3)
                }
                EmptyState(
                    icon: "power",
                    title: "没有读取到启动项",
                    message: model.banner ?? "O 会读取 ~/Library/LaunchAgents、/Library/LaunchAgents 等目录。",
                    actionTitle: "重新读取",
                    action: { model.load() }
                )
                .frame(maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpec.sectionSpacing) {
                    if let note = model.loginNote {
                        Text(note)
                            .font(M2Font.body(10))
                            .foregroundStyle(M2.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    }

                    if let banner = model.banner {
                        M2Notice(kind: M2NoticeKind.infer(banner), title: banner)
                    }

                    ForEach(model.groupedItems) { group in
                        launchGroup(group)
                    }
                }
                .padding(.horizontal, DesignSpec.pagePadding)
                .padding(.top, DesignSpec.sectionSpacing)
                .padding(.bottom, DesignSpec.space5)
            }
        }
    }

    private func launchGroup(_ group: LaunchGroup) -> some View {
        VStack(alignment: .leading, spacing: DesignSpec.space2) {
            HStack(spacing: DesignSpec.space2) {
                Image(systemName: group.scope.systemImage)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(M2.secondary)
                Text(group.scope.title)
                    .font(M2Font.serif(13))
                    .foregroundStyle(M2.text)
                Text(group.scope.detail)
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
                Spacer(minLength: DesignSpec.space2)
                Text("\(filtered(group.items).count) 项")
                    .font(M2Font.mono(9))
                    .foregroundStyle(M2.tertiary)
                if !group.scope.isUserEditable {
                    Text("只读")
                        .font(M2Font.mono(9))
                        .foregroundStyle(M2.tertiary)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(M2.line, lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                if filtered(group.items).isEmpty {
                    Text("没有匹配的启动项。")
                        .font(M2Font.body(10))
                        .foregroundStyle(M2.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DesignSpec.space4)
                        .frame(height: 40)
                } else {
                    ForEach(filtered(group.items)) { item in
                        launchRow(item)
                        if item.id != filtered(group.items).last?.id {
                            Hairline().padding(.leading, 42)
                        }
                    }
                }
            }
            .panel(padding: 0)

            if !group.scope.isUserEditable {
                Text(group.scope == .loginItem
                     ? "系统登录项由 macOS 管理，此处只读。"
                     : "系统级启动项需要管理员权限，O 不会修改或提权。")
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.tertiary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func launchRow(_ item: LaunchItem) -> some View {
        HStack(spacing: DesignSpec.space2) {
            Toggle("", isOn: Binding(
                get: { model.selectedIDs.contains(item.id) },
                set: { _ in model.toggle(item) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .tint(M2.ink)
            .disabled(!item.scope.isUserEditable)
            .frame(width: 18)
            .accessibilityLabel("选择 \(item.label)")

            Image(systemName: item.isDisabled ? "pause.circle" : "power")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(item.isDisabled ? M2.tertiary : M2.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                Text(item.program ?? item.url.path)
                    .font(M2Font.mono(9))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DesignSpec.space2)

            Text(item.statusText)
                .font(M2Font.body(9.5))
                .foregroundStyle(item.isDisabled ? M2.tertiary : M2.secondary)
                .lineLimit(1)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "folder.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(M2.tertiary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在 Finder 中显示")
            .help("在 Finder 中显示")
        }
        .frame(height: DesignSpec.tableRowHeight + 2)
        .padding(.horizontal, DesignSpec.space4)
        .hoverHighlight(cornerRadius: 4)
    }

    private var footer: some View {
        HStack(spacing: DesignSpec.space3) {
            VStack(alignment: .leading, spacing: 1) {
                Text("已选 \(model.selectedItems.count) 项")
                    .font(M2Font.body(11))
                    .foregroundStyle(M2.text)
                Text("仅用户级启动项可移动，系统项只读")
                    .font(M2Font.body(9.5))
                    .foregroundStyle(M2.secondary)
            }
            if model.isWorking {
                Text("正在移动…")
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
            .disabled(model.selectedItems.isEmpty || model.isWorking)
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .top) { Hairline() }
    }
}
