import MoleLiteCore
import SwiftUI

/// 规则页：预设、规则清单、受保护清单与预计空间。
struct RulesView: View {
    @ObservedObject var model: RulesViewModel
    @ObservedObject var estimates: RuleEstimateStore
    var goClean: () -> Void

    @State private var newProtectedPath = ""
    @State private var pendingToggle: CleanupRule?
    @State private var showCautionConfirm = false
    @State private var pendingPreset: RulePreset?

    var body: some View {
        VStack(spacing: 0) {
            PageHeaderBar(title: "清理规则", subtitle: headerSubtitle) {
                HStack(spacing: DesignSpec.space2) {
                    menu
                    Button {
                        model.editingRule = CleanupRule(name: "", category: .userCaches,
                                                        path: "~/Library/Caches", grade: .safe)
                    } label: {
                        Text("新增规则")
                    }
                    .buttonStyle(M2PrimaryButtonStyle(compact: true))
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpec.sectionSpacing) {
                    safetyNotice
                    presetPanel
                    rulesPanel
                    protectedPanel
                }
                .padding(.horizontal, DesignSpec.pagePadding)
                .padding(.vertical, DesignSpec.sectionSpacing)
            }
            .scrollIndicators(.never)
        }
        .background(M2.bg)
        .sheet(item: $model.editingRule) { rule in
            RuleEditorSheet(model: model, rule: rule)
        }
        .alert("提示", isPresented: $model.showingMessage) {
            Button("好") { model.showingMessage = false }
        } message: {
            Text(model.message ?? "")
        }
        .confirmationDialog("启用谨慎级规则？",
                            isPresented: $showCautionConfirm,
                            titleVisibility: .visible) {
            Button("启用", role: .destructive) {
                if let rule = pendingToggle {
                    model.toggle(rule, enabled: true)
                }
                pendingToggle = nil
            }
            Button("取消", role: .cancel) { pendingToggle = nil }
        } message: {
            Text(pendingToggle.map { "「\($0.name)」会清理 \(model.displayPath($0.path)) 中符合条件的内容。清理后只能从废纸篓恢复。" } ?? "")
        }
        .confirmationDialog("套用激进预设？",
                            isPresented: Binding(get: { pendingPreset != nil },
                                                 set: { if !$0 { pendingPreset = nil } }),
                            titleVisibility: .visible) {
            Button("套用并启用谨慎级规则", role: .destructive) {
                if let preset = pendingPreset { model.applyPreset(preset) }
                pendingPreset = nil
            }
            Button("取消", role: .cancel) { pendingPreset = nil }
        } message: {
            Text("激进预设包含个人文件、iOS 备份与容器数据，全部为谨慎级，扫描后仍需逐项确认。")
        }
        // 导入模式选择：文件选好后询问「合并 / 替换」。
        .confirmationDialog("导入 \(model.pendingImportFileName ?? "")",
                            isPresented: Binding(get: { model.pendingImportFileName != nil },
                                                 set: { if !$0 { model.cancelImport() } }),
                            titleVisibility: .visible) {
            Button("合并到现有规则") { model.applyImport(mode: .merge) }
            Button("替换全部规则", role: .destructive) { model.applyImport(mode: .replace) }
            Button("取消", role: .cancel) { model.cancelImport() }
        } message: {
            Text("合并：保留现有规则，同路径的条目自动跳过。替换：用文件内容整套替换当前规则与保护清单。非法规则都会被跳过并在结果中说明原因。")
        }
    }

    // MARK: - 页头

    private var headerSubtitle: String {
        let preset = model.configuration.appliedPreset?.title ?? "自定义"
        return "\(preset)预设 · \(model.enabledCount) 条启用 · \(model.cautionCount) 条谨慎"
    }

    private var menu: some View {
        Menu {
            ForEach(RulePreset.allCases) { preset in
                Button("套用「\(preset.title)」预设") {
                    if preset == .aggressive {
                        pendingPreset = preset
                    } else {
                        model.applyPreset(preset)
                    }
                }
            }
            Divider()
            Button("重新估算预计空间") { model.scanEstimates() }
            Button("导入 JSON…") { model.importJSON() }
            Button("导出 JSON…") { model.exportJSON() }
            Divider()
            Button("恢复默认规则") { model.resetRules() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("更多规则操作")
    }

    // MARK: - 说明

    private var safetyNotice: some View {
        M2Notice(kind: .info,
                 title: "规则只决定扫描范围，不绕过安全边界",
                 message: "所有条目仍逐条经过 PathSafety 与符号链接校验；清理只移入废纸篓，不调用 shell，不静默提权。系统目录 /Library、/System、/usr 始终只读。") {
            Button("去清理页", action: goClean)
                .buttonStyle(M2LinkButtonStyle())
        }
    }

    // MARK: - 预设

    private var presetPanel: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space3) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSpec.space2) {
                M2SectionTitle(title: "预设", detail: "一键套用，之后仍可逐条编辑")
                Spacer(minLength: DesignSpec.space2)
                estimateStatus
            }

            HStack(spacing: DesignSpec.space2) {
                ForEach(RulePreset.allCases) { preset in
                    presetCard(preset)
                }
            }
            .frame(height: 88)

            HStack(spacing: DesignSpec.space2) {
                Button("恢复默认规则") { model.resetRules() }
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
                Button(model.isEstimating ? "正在估算…" : "重新估算预计空间") {
                    if model.isEstimating { model.cancelEstimates() } else { model.scanEstimates() }
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
                Spacer(minLength: 0)
                Text("预计空间按当前规则扫描后回填，不代表一定能全部释放。")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
            }
        }
        .panel(padding: 16)
    }

    private func presetCard(_ preset: RulePreset) -> some View {
        let active = model.configuration.appliedPreset == preset
        return Button {
            if preset == .aggressive {
                pendingPreset = preset
            } else {
                model.applyPreset(preset)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DesignSpec.space1) {
                    Text(preset.title)
                        .font(M2Font.serif(14, .semibold))
                        .foregroundStyle(active ? M2.ink : M2.text)
                    if active {
                        Text("当前")
                            .font(M2Font.mono(8.5, .medium))
                            .foregroundStyle(M2.ink)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(M2.inkSoft))
                    }
                    Spacer(minLength: 0)
                }
                Text(preset.summary)
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(CleanupRuleCatalog.rules(for: preset).filter(\.isEnabled).count) 条规则")
                    .font(M2Font.mono(9))
                    .foregroundStyle(M2.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                .fill(active ? M2.inkSoft : M2.bg.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                .strokeBorder(active ? M2.ink.opacity(0.45) : M2.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("\(preset.title)预设：\(preset.summary)")
    }

    private var estimateStatus: some View {
        HStack(spacing: DesignSpec.space1) {
            if model.isEstimating {
                Text("估算中…")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
            } else if let date = estimates.scannedAt {
                Text("估算于 \(Self.timeFormatter.string(from: date))")
                    .font(M2Font.mono(9))
                    .foregroundStyle(M2.tertiary)
            } else if let error = estimates.lastError {
                Text(error)
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.warning)
                    .lineLimit(1)
            } else {
                Text("尚未估算")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.tertiary)
            }
        }
    }

    // MARK: - 规则清单

    private var rulesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                M2Eyebrow(text: "规则")
                Spacer(minLength: DesignSpec.space2)
                Text("预计可释放")
                    .font(M2Font.mono(8.5))
                    .foregroundStyle(M2.tertiary)
                    .frame(width: 84, alignment: .trailing)
                Text("命中")
                    .font(M2Font.mono(8.5))
                    .foregroundStyle(M2.tertiary)
                    .frame(width: 46, alignment: .trailing)
                Spacer().frame(width: 54)
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .overlay(alignment: .bottom) { Hairline() }

            ForEach(model.configuration.rules) { rule in
                ruleRow(rule)
                if rule.id != model.configuration.rules.last?.id {
                    Hairline().padding(.leading, 16)
                }
            }

            if model.configuration.rules.isEmpty {
                Text("规则为空。可在上方套用预设，或点击「新增规则」。")
                    .font(M2Font.body(11))
                    .foregroundStyle(M2.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .panel(padding: 0)
    }

    private func ruleRow(_ rule: CleanupRule) -> some View {
        HStack(alignment: .center, spacing: DesignSpec.space3) {
            M2Switch(isOn: Binding(
                get: { rule.isEnabled },
                set: { value in
                    if value, rule.grade == .caution {
                        pendingToggle = rule
                        showCautionConfirm = true
                    } else {
                        model.toggle(rule, enabled: value)
                    }
                }
            ))
            .accessibilityLabel("\(rule.name) 启用")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSpec.space2) {
                    Text(rule.name)
                        .font(M2Font.body(12, .medium))
                        .foregroundStyle(rule.isEnabled ? M2.text : M2.tertiary)
                        .lineLimit(1)
                    if rule.category.title != rule.name {
                        Text(rule.category.title)
                            .font(M2Font.mono(8.5))
                            .foregroundStyle(M2.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(M2.line, lineWidth: 1))
                    }
                    gradeTag(rule.grade)
                }
                Text("\(model.displayPath(rule.path)) · \(rule.conditionText) · \(rule.scanMode.title)")
                    .font(M2Font.mono(9.5))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DesignSpec.space2)

            estimateCell(rule)
            hitCell(rule)

            HStack(spacing: DesignSpec.space1) {
                Button {
                    model.editingRule = rule
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10.5))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(M2.secondary)
                .help("编辑规则")

                Button {
                    model.delete(rule)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(M2.secondary)
                .help("删除规则")
            }
            .frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(rule.isEnabled ? Color.clear : M2.text.opacity(0.025))
        .help(rule.note)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rule.name)，\(rule.grade.title)，\(model.displayPath(rule.path))")
    }

    private func estimateCell(_ rule: CleanupRule) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let bytes = estimates.bytes(for: rule.id), bytes > 0 {
                M2Number(text: ByteFormatter.string(bytes), size: 11, weight: .medium, unitColor: M2.tertiary)
            } else if let reason = estimates.skipReason(for: rule.id) {
                Text(reason)
                    .font(M2Font.body(9))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
            } else {
                Text(model.isEstimating ? "…" : "—")
                    .font(M2Font.mono(11))
                    .foregroundStyle(M2.tertiary)
            }
        }
        .frame(width: 84, alignment: .trailing)
    }

    private func hitCell(_ rule: CleanupRule) -> some View {
        Text(estimates.itemCount(for: rule.id).map { "\($0) 项" } ?? "—")
            .font(M2Font.mono(9.5))
            .foregroundStyle(M2.tertiary)
            .frame(width: 46, alignment: .trailing)
    }

    private func gradeTag(_ grade: SafetyGrade) -> some View {
        Text(grade.title)
            .font(M2Font.mono(8.5, .medium))
            .foregroundStyle(M2.grade(grade))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(M2.grade(grade).opacity(0.08)))
    }

    // MARK: - 受保护清单

    private var protectedPanel: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space3) {
            M2SectionTitle(title: "受保护清单",
                           detail: "清单中的路径永不进入扫描结果",
                           trailing: "\(model.configuration.protectedPaths.count) 项")

            HStack(spacing: DesignSpec.space2) {
                TextField("输入路径，例如 ~/Documents/合同", text: $newProtectedPath)
                    .textFieldStyle(.plain)
                    .font(M2Font.body(11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: M2.radiusControl).fill(M2.bg))
                    .overlay(RoundedRectangle(cornerRadius: M2.radiusControl)
                        .strokeBorder(M2.line, lineWidth: 1))
                Button("添加") {
                    if model.addProtectedPath(newProtectedPath) {
                        newProtectedPath = ""
                    }
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
                .disabled(newProtectedPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.configuration.protectedPaths.isEmpty {
                Text("尚未添加。受保护清单适合放重要文稿、正在进行的项目或应用目录。")
                    .font(M2Font.body(10.5))
                    .foregroundStyle(M2.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.configuration.protectedPaths, id: \.self) { path in
                        HStack(spacing: DesignSpec.space2) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 10))
                                .foregroundStyle(M2.secondary)
                            Text(model.displayPath(path))
                                .font(M2Font.mono(10))
                                .foregroundStyle(M2.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: DesignSpec.space2)
                            Button {
                                model.removeProtectedPath(path)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(M2.secondary)
                            .help("从保护清单移除")
                        }
                        .frame(height: 30)
                        if path != model.configuration.protectedPaths.last {
                            Hairline().padding(.leading, 18)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: M2.radiusControl).fill(M2.bg.opacity(0.55)))
            }

            M2Notice(kind: .warning,
                     title: "谨慎级规则需要二次确认",
                     message: "容器、备份、个人文件等规则在启用时会再次询问；清理前仍逐项选择，且只移入废纸篓。")
        }
        .panel(padding: 16)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 轻量开关

struct M2Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? M2.ink : M2.track)
                    .frame(width: 28, height: 16)
                Circle()
                    .fill(isOn ? M2.onInk : M2.panel)
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: isOn)
    }
}

// MARK: - 规则编辑

struct RuleEditorSheet: View {
    @ObservedObject var model: RulesViewModel
    let rule: CleanupRule

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var category: ScanCategory
    @State private var path: String
    @State private var ageText: String
    @State private var sizeText: String
    @State private var grade: SafetyGrade
    @State private var scanMode: RuleScanMode
    @State private var note: String
    @State private var enabled: Bool
    @State private var errorText: String?

    init(model: RulesViewModel, rule: CleanupRule) {
        self.model = model
        self.rule = rule
        _name = State(initialValue: rule.name)
        _category = State(initialValue: rule.category)
        _path = State(initialValue: rule.path)
        _ageText = State(initialValue: "\(rule.minAgeDays)")
        _sizeText = State(initialValue: "\(rule.minSizeMB)")
        _grade = State(initialValue: rule.grade)
        _scanMode = State(initialValue: rule.scanMode)
        _note = State(initialValue: rule.note)
        _enabled = State(initialValue: rule.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(rule.name.isEmpty && model.configuration.rule(id: rule.id) == nil ? "新增规则" : "编辑规则")
                    .font(M2Font.serif(DesignSpec.sheetTitleSize))
                    .foregroundStyle(M2.text)
                Spacer()
                Text("保存前会经过 PathSafety 校验")
                    .font(M2Font.mono(9))
                    .foregroundStyle(M2.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpec.space3) {
                    fieldRow("名称") {
                        TextField("例如：Xcode 派生数据", text: $name)
                            .textFieldStyle(.plain)
                            .font(M2Font.body(12))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: M2.radiusControl).fill(M2.bg))
                            .overlay(RoundedRectangle(cornerRadius: M2.radiusControl).strokeBorder(M2.line, lineWidth: 1))
                    }

                    fieldRow("类别") {
                        Picker("", selection: $category) {
                            ForEach(ScanCategory.allCases) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)
                    }

                    fieldRow("路径") {
                        TextField("~/Library/Caches", text: $path)
                            .textFieldStyle(.plain)
                            .font(M2Font.mono(11))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: M2.radiusControl).fill(M2.bg))
                            .overlay(RoundedRectangle(cornerRadius: M2.radiusControl).strokeBorder(M2.line, lineWidth: 1))
                    }

                    HStack(spacing: DesignSpec.space4) {
                        fieldRow("最小年龄（天）") {
                            numberField($ageText)
                        }
                        fieldRow("最小体积（MB）") {
                            numberField($sizeText)
                        }
                    }

                    fieldRow("扫描方式") {
                        M2Tabs(items: RuleScanMode.allCases.map { ($0, $0.title) }, selection: $scanMode)
                    }

                    fieldRow("安全等级") {
                        HStack(spacing: DesignSpec.space2) {
                            ForEach(SafetyGrade.allCases) { value in
                                Button {
                                    grade = value
                                } label: {
                                    Text(value.title)
                                        .font(M2Font.body(10.5, grade == value ? .medium : .regular))
                                        .foregroundStyle(grade == value ? M2.grade(value) : M2.secondary)
                                        .padding(.horizontal, 10)
                                        .frame(height: 24)
                                        .background(RoundedRectangle(cornerRadius: 4)
                                            .fill(grade == value ? M2.grade(value).opacity(0.1) : Color.clear))
                                        .overlay(RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(grade == value ? M2.grade(value).opacity(0.45) : M2.line, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    fieldRow("说明") {
                        TextEditor(text: $note)
                            .font(M2Font.body(11))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 64)
                            .background(RoundedRectangle(cornerRadius: M2.radiusControl).fill(M2.bg))
                            .overlay(RoundedRectangle(cornerRadius: M2.radiusControl).strokeBorder(M2.line, lineWidth: 1))
                    }

                    HStack(spacing: DesignSpec.space2) {
                        M2Switch(isOn: $enabled)
                        Text("启用此规则")
                            .font(M2Font.body(11.5))
                            .foregroundStyle(M2.text)
                        Spacer()
                        if grade == .caution {
                            Text("谨慎级：启用与清理前都会二次确认")
                                .font(M2Font.body(10))
                                .foregroundStyle(M2.warning)
                        }
                    }

                    if let errorText {
                        M2Notice(kind: .error, title: "无法保存", message: errorText)
                    }
                }
                .padding(24)
            }

            Hairline()

            HStack(spacing: DesignSpec.space2) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
                Button("保存") { save() }
                    .buttonStyle(M2PrimaryButtonStyle(compact: true))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(M2.bg)
        }
        .frame(width: 560, height: 560)
        .background(M2.panel)
    }

    private func save() {
        var updated = rule
        updated.name = name
        updated.category = category
        updated.path = path
        updated.minAgeDays = Int(ageText) ?? 0
        updated.minSizeMB = Int(sizeText) ?? 0
        updated.grade = grade
        updated.scanMode = scanMode
        updated.note = note
        updated.isEnabled = enabled
        if model.upsert(updated) {
            dismiss()
        } else {
            errorText = model.message
        }
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            M2Eyebrow(text: label)
            content()
        }
    }

    private func numberField(_ text: Binding<String>) -> some View {
        TextField("0", text: text)
            .textFieldStyle(.plain)
            .font(M2Font.mono(11))
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 8)
            .frame(width: 92, height: 26)
            .background(RoundedRectangle(cornerRadius: M2.radiusControl).fill(M2.bg))
            .overlay(RoundedRectangle(cornerRadius: M2.radiusControl).strokeBorder(M2.line, lineWidth: 1))
    }
}
