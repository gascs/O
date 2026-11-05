import MoleLiteCore
import SwiftUI

/// 系统 › 权限：逐项列表 + 用途 + 判定依据 + 操作按钮。
struct PermissionsView: View {
    @ObservedObject var permissions: PermissionCenter

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpec.sectionSpacing) {
                    VStack(spacing: 0) {
                        ForEach(permissions.capabilities) { capability in
                            CapabilityRow(capability: capability,
                                          action: action(for: capability))
                            if capability.id != permissions.capabilities.last?.id {
                                Hairline().padding(.leading, DesignSpec.space3)
                            }
                        }
                    }
                    .panel(padding: 0)

                    VStack(alignment: .leading, spacing: DesignSpec.space2) {
                        M2SectionTitle(title: "说明")
                        Text("所有状态都来自实际读取，不是推断。「无法判定」表示探针条件不满足（例如路径不存在），不会被当成已授权。")
                            .font(M2Font.body(11))
                            .foregroundStyle(M2.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("没有完全磁盘访问也可以正常使用：邮件、Safari 等受保护位置会标注「受限」，扫描结果可能偏少。系统若要求重启应用才能生效，可点上方「重新启动 O」。")
                            .font(M2Font.body(11))
                            .foregroundStyle(M2.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.horizontal, DesignSpec.pagePadding)
                .padding(.top, DesignSpec.sectionSpacing)
                .padding(.bottom, DesignSpec.space6)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: DesignSpec.space2) {
            StatusDot(color: permissions.allGranted ? M2.secondary : M2.warning, size: 6)
            Text(permissions.allGranted ? "四项能力均已授权" : "\(permissions.restrictedCapabilities.count) 项未授权或无法判定")
                .font(M2Font.body(11.5, .medium))
                .foregroundStyle(M2.text)
            Text("检查于 \(Self.time.string(from: permissions.lastCheckedAt))")
                .font(M2Font.mono(9.5))
                .foregroundStyle(M2.tertiary)
            Spacer(minLength: DesignSpec.space2)
            if permissions.allGranted {
                Button("重新检测") { permissions.refresh() }
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
                Button("打开完全磁盘访问设置") { permissions.openSettings() }
                    .buttonStyle(M2PrimaryButtonStyle(compact: true))
                Button("重新启动 O") { permissions.restartApp() }
                    .buttonStyle(M2LinkButtonStyle())
            } else {
                // 受限态动作统一走橙色语义，不出现墨蓝，避免看起来像「正常可用」。
                Button("重新检测") { permissions.refresh() }
                    .buttonStyle(M2WarningButtonStyle(compact: true))
                Button("打开完全磁盘访问设置") { permissions.openSettings() }
                    .buttonStyle(M2WarningButtonStyle(compact: true, emphasized: true))
                Button("重新启动 O") { permissions.restartApp() }
                    .buttonStyle(M2LinkButtonStyle(tint: M2.warning))
            }
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space2 + 2)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func action(for capability: PermissionCapability) -> (() -> Void)? {
        switch capability.id {
        case "fda":
            return { permissions.openSettings() }
        case "loginItem":
            return { permissions.openLoginItemSettings() }
        default:
            return nil
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
