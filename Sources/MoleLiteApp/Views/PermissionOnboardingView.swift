import MoleLiteCore
import SwiftUI

/// 首次启动引导：分四步，可随时跳过，不一次性倾泻大段说明。
/// 1. 为什么需要 → 2. 当前真实状态 → 3. 去授权 → 4. 清理规则。
struct PermissionOnboardingView: View {
    @ObservedObject var permissions: PermissionCenter
    var onClose: () -> Void

    @State private var step: Int

    private let steps = ["为什么需要", "当前状态", "去授权", "清理规则"]

    /// `initialStep` 只供渲染自检直接跳到某一页；正常使用从第 1 步开始。
    init(permissions: PermissionCenter, initialStep: Int = 0, onClose: @escaping () -> Void) {
        _permissions = ObservedObject(wrappedValue: permissions)
        self.onClose = onClose
        _step = State(initialValue: min(max(0, initialStep), 3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(DesignSpec.space5)
            Hairline()
            footer
        }
        // 第 2 步要放下四条能力行、第 4 步要放下四条规则说明，固定 430 会上下硬裁，因此按步骤给高度。
        .frame(width: 540, height: step == 1 || step == 3 ? 520 : 440)
        .background(M2.bg)
        .tint(M2.ink)
        .onAppear { permissions.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSpec.space3) {
            VStack(alignment: .leading, spacing: DesignSpec.space2) {
                Text("权限设置")
                    .font(M2Font.serif(DesignSpec.sheetTitleSize))
                    .foregroundStyle(M2.text)
                HStack(spacing: DesignSpec.space3) {
                    ForEach(steps.indices, id: \.self) { index in
                        HStack(spacing: DesignSpec.space1) {
                            Circle()
                                .fill(index == step ? M2.ink : M2.tertiary.opacity(0.55))
                                .frame(width: 5, height: 5)
                            Text(steps[index])
                                .font(M2Font.body(10))
                                .foregroundStyle(index == step ? M2.ink : M2.tertiary)
                        }
                    }
                }
            }
            Spacer()
            Button("跳过") {
                ScanSettings.markPermissionGuideCompleted()
                onClose()
            }
            .buttonStyle(M2LinkButtonStyle())
            .accessibilityLabel("跳过权限引导，稍后可在设置中重新打开")
        }
        .padding(.horizontal, DesignSpec.space5)
        .padding(.vertical, DesignSpec.space4)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            whyStep
        case 1:
            statusStep
        case 2:
            grantStep
        default:
            rulesStep
        }
    }

    /// 第 4 步：把「规则」概念在第一次启动时讲清楚。
    private var rulesStep: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space4) {
            Text("清理由「规则」驱动：扫描只按你启用的规则去找，改规则立即生效。")
                .font(M2Font.body(12))
                .foregroundStyle(M2.text)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DesignSpec.space3) {
                reasonRow(icon: "slider.horizontal.3",
                          title: "三档预设",
                          detail: "保守 / 标准 / 激进，一键套用后仍可逐条编辑或停用。")
                reasonRow(icon: "square.and.pencil",
                          title: "自定义规则",
                          detail: "路径、最小年龄、最小体积、安全等级都可配置；同一配置内不允许重复路径。")
                reasonRow(icon: "shield",
                          title: "受保护清单",
                          detail: "加入的路径永不清理；系统路径与危险位置在保存前就会被拒绝并说明原因。")
                reasonRow(icon: "arrow.up.arrow.down.square",
                          title: "导入 / 导出 JSON",
                          detail: "规则可以备份或分享；导入时可选「合并到现有规则」或「替换全部」，非法条目自动跳过。")
            }
            Text("之后在「规则」页随时调整；无论怎么配置，所有清理都只移入废纸篓。")
                .font(M2Font.body(10))
                .foregroundStyle(M2.secondary)
        }
    }

    private var whyStep: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space4) {
            Text("O 只读取磁盘信息并清理缓存，不会上传或删除你的文件。")
                .font(M2Font.body(12))
                .foregroundStyle(M2.text)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DesignSpec.space3) {
                reasonRow(icon: "internaldrive",
                          title: "统计与清理",
                          detail: "读取缓存、日志、废纸篓，把可以安全释放的空间列出来。")
                reasonRow(icon: "lock.shield",
                          title: "完全磁盘访问（可选）",
                          detail: "没有它也能用，只是邮件、Safari 等受保护位置扫不到。")
                reasonRow(icon: "power",
                          title: "登录启动（可选）",
                          detail: "需要时在系统设置里开启，不需要就保持关闭。")
            }
            Text("随时可以跳过；之后在「系统 › 权限」里重新打开这份引导。")
                .font(M2Font.body(10))
                .foregroundStyle(M2.secondary)
        }
    }

    private func reasonRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpec.space3) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(M2.secondary)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(M2Font.body(11.5, .medium))
                    .foregroundStyle(M2.text)
                Text(detail)
                    .font(M2Font.body(10.5))
                    .foregroundStyle(M2.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusStep: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space3) {
            HStack {
                Text("以下结果来自刚刚的真实探测，不是推断。")
                    .font(M2Font.body(11))
                    .foregroundStyle(M2.text)
                Spacer()
                Button("重新检测") { permissions.refresh() }
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }
            VStack(spacing: 0) {
                ForEach(permissions.capabilities) { capability in
                    CapabilityRow(capability: capability, compact: true)
                    if capability.id != permissions.capabilities.last?.id {
                        Hairline()
                    }
                }
            }
            .panel(padding: 0)

            Text("「无法判定」表示探针条件不满足，不会被当成已授权。")
                .font(M2Font.body(10))
                .foregroundStyle(M2.secondary)
        }
    }

    private var grantStep: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space4) {
            Text("按需打开下面两项；授权后切回 O 会自动重新检测。")
                .font(M2Font.body(11))
                .foregroundStyle(M2.text)
            HStack(spacing: DesignSpec.space2) {
                Button("打开完全磁盘访问设置") {
                    permissions.openSettings()
                }
                .buttonStyle(M2PrimaryButtonStyle(compact: true))
                Button("打开登录项设置") {
                    permissions.openLoginItemSettings()
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
                Spacer()
                Button("重新检测") { permissions.refresh() }
                    .buttonStyle(M2LinkButtonStyle())
            }

            VStack(alignment: .leading, spacing: DesignSpec.space2) {
                Text("回来后如果状态仍未变化，通常是系统需要重启应用才能生效。")
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
                Button("重新启动 O") {
                    permissions.restartApp()
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }

            HStack(spacing: DesignSpec.space2) {
                StatusDot(color: permissions.hasFullDiskAccess ? M2.secondary : M2.warning, size: 6)
                Text("完全磁盘访问：\(permissions.snapshot.fullDiskAccessStatus.title)")
                    .font(M2Font.body(11))
                    .foregroundStyle(permissions.hasFullDiskAccess ? M2.text : M2.warning)
                Spacer()
            }
            .padding(.top, DesignSpec.space2)

            Text("没有授权也能继续：受限功能会标注「受限」并说明扫不到的内容。")
                .font(M2Font.body(10))
                .foregroundStyle(M2.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: DesignSpec.space2) {
            if step > 0 {
                Button("上一步") {
                    withAnimation(.easeOut(duration: DesignSpec.animationDuration)) {
                        step -= 1
                    }
                }
                .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }
            Spacer()
            Text("第 \(step + 1) / \(steps.count) 步")
                .font(M2Font.mono(9))
                .foregroundStyle(M2.tertiary)
            if step < steps.count - 1 {
                Button("下一步") {
                    withAnimation(.easeOut(duration: DesignSpec.animationDuration)) {
                        step += 1
                    }
                }
                .buttonStyle(M2PrimaryButtonStyle(compact: true))
            } else {
                Button("完成") {
                    ScanSettings.markPermissionGuideCompleted()
                    onClose()
                }
                .buttonStyle(M2PrimaryButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, DesignSpec.space5)
        .padding(.vertical, DesignSpec.space3)
    }
}

/// 单条能力行：名称 + 状态 + 依据 + 操作。
struct CapabilityRow: View {
    let capability: PermissionCapability
    var compact = false
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: DesignSpec.space3) {
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title)
                    .font(M2Font.body(11.5, .medium))
                    .foregroundStyle(M2.text)
                Text(capability.purpose)
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
                    // 引导 sheet 只有 540 宽，单行会硬截断；允许两行并保留全文提示。
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(capability.purpose)
                Text(capability.basis)
                    .font(M2Font.mono(9))
                    // 探测依据是可核对的信息，不能淡到看不清；浅色下 tertiary 只有约 3:1。
                    .foregroundStyle(M2.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(capability.basis)
            }

            Spacer(minLength: DesignSpec.space3)

            HStack(spacing: DesignSpec.space1 + 2) {
                StatusDot(color: statusColor, size: 5)
                Text(capability.status.title)
                    .font(M2Font.body(10, .medium))
                    .foregroundStyle(capability.status == .denied ? M2.warning : M2.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            if let action, capability.status != .granted {
                // 未授权行内的动作使用橙色，避免与「正常可用」的墨蓝混淆。
                Button("去授权", action: action)
                    .buttonStyle(M2WarningButtonStyle(compact: true))
                    .frame(minWidth: 52)
            } else {
                Color.clear.frame(width: 52, height: 1)
            }
        }
        .padding(.horizontal, DesignSpec.space4)
        .padding(.vertical, compact ? DesignSpec.space2 : DesignSpec.space3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(capability.title)，\(capability.status.title)，\(capability.basis)")
    }

    private var statusColor: Color {
        switch capability.status {
        case .granted: return M2.secondary
        case .denied: return M2.warning
        case .undetermined: return M2.tertiary
        }
    }
}

/// 授权成功后的轻提示，4 秒自动收起。
struct GrantedNotice: View {
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: DesignSpec.space2) {
            StatusDot(color: M2.positive, size: 6)
            Text("已获得完全磁盘访问，扫描范围已更新")
                .font(M2Font.body(11))
                .foregroundStyle(M2.text)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(M2.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, DesignSpec.space4)
        .padding(.vertical, DesignSpec.space2)
        .background(
            RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                .fill(M2.panel)
        )
        .overlay {
            RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                .strokeBorder(M2.line, lineWidth: 1)
        }
    }
}
