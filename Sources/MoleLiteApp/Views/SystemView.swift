import MoleLiteCore
import SwiftUI

/// 系统：启动项 / 权限 / 设置 三个子页，导航只有两层。
struct SystemView: View {
    @ObservedObject var monitor: MenuBarMonitor
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var launchModel: LaunchItemsViewModel

    @ObservedObject private var coordinator = AppCoordinator.shared

    private var tab: Binding<SystemTab> {
        Binding(get: { coordinator.systemTab }, set: { coordinator.systemTab = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeaderBar(title: "系统", subtitle: "启动项、权限与偏好设置") {
                M2Tabs(
                    items: SystemTab.allCases.map { ($0, $0.title) },
                    selection: tab
                )
            }

            switch coordinator.systemTab {
            case .launchItems:
                LaunchItemsView(model: launchModel)
            case .permissions:
                PermissionsView(permissions: permissions)
            case .settings:
                SettingsView(monitor: monitor, permissions: permissions)
            }
        }
        .background(M2.bg)
        .tint(M2.ink)
    }
}
