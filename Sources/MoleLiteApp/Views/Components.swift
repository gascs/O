import AppKit
import MoleLiteCore
import SwiftUI

// MARK: - 设计规范（M2）
//
// 视觉语言：暖纸 / 暖黑表面、墨蓝强调、衬线标题 + SF Pro 正文 + 等宽 tabular 数字。
// - 唯一强调色：墨蓝；橙色只用于「受限 / 谨慎」，红色只用于失败，绿色只用于「确认正常」。
// - 表面：窗口底 / 侧栏 / 面板三层，1px 细线分隔，无阴影。
// - 圆角：容器 8，控件 6；不使用 20+ 的超大圆角。
// - 图标统一 SF Symbols，同一 weight，不使用彩色图标块。
// - 数字全部 tabular；单位小一号并降为三级灰。

// MARK: - 表面与交互

extension View {
    /// 容器表面：面板底色 + 1px 细线，圆角 8，无阴影。
    func panel(padding: CGFloat = DesignSpec.cardPadding, radius: CGFloat = DesignSpec.cardCornerRadius) -> some View {
        m2Surface(radius: radius, padding: padding)
    }

    func hoverHighlight(cornerRadius: CGFloat = DesignSpec.controlCornerRadius) -> some View {
        m2Hover(cornerRadius: cornerRadius)
    }
}

/// 1px 细线。
struct Hairline: View {
    var body: some View {
        M2Hairline()
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

// MARK: - 页头与布局

/// 统一页头：衬线 27pt 标题 + 状态摘要副标题 + 右侧控件，底部 1px 细线。
struct PageHeaderBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: DesignSpec.space4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(M2Font.serif(DesignSpec.pageTitleSize))
                    .foregroundStyle(M2.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(M2Font.body(DesignSpec.pageSubtitleSize))
                    .foregroundStyle(M2.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DesignSpec.space3)
            trailing()
                .fixedSize()
        }
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
    }
}

extension PageHeaderBar where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 空状态：统一实现，保留旧名以免调用点重复改造。
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        M2EmptyState(icon: icon, title: title, message: message,
                     actionTitle: actionTitle, action: action)
    }
}

struct AppIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// 文件类型图标（按后缀粗略映射）。
enum FileIcon {
    static func systemImage(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "mov", "mkv", "avi": return "film"
        case "zip", "rar", "7z", "dmg", "pkg": return "archivebox"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "mp3", "wav", "aac", "flac": return "waveform"
        case "app": return "app"
        case "xcodeproj", "xcworkspace", "swift": return "hammer"
        case "文件夹": return "folder"
        default: return "doc"
        }
    }
}

// MARK: - 品牌

enum BrandAssets {
    static let menuBarIcon: NSImage = makeMenuBarIcon()

    private static func makeMenuBarIcon() -> NSImage {
        if let image = NSImage(named: "MenuBarIconTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        // 未打包时的兜底：运行时画同样比例的圆环。
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.9, dy: 2.9))
            ring.lineWidth = 2.8
            NSColor.black.setStroke()
            ring.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum AppInfo {
    static let displayName = "O"
    static let version = "0.4.0"
    static let bundleIdentifier = "com.o.app"
    static let tagline = "磁盘清理与系统维护"
}

/// 应用内品牌标识：与 App 图标同一母题——面板底 + 1px 细线 +
/// 「磁盘占用环」（墨蓝 72% 占用弧 + 暖灰轨道 + 暖黑轴点），无渐变高光。
struct BrandMark: View {
    var size: CGFloat = 34

    private var ringDiameter: CGFloat { size * 0.58 }
    private var strokeWidth: CGFloat { size * 0.125 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(M2.panel)
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .strokeBorder(M2.line, lineWidth: 1)

            ZStack {
                // 空闲轨道：剩余 28%。
                Circle()
                    .trim(from: 0.72, to: 1)
                    .stroke(M2.line, lineWidth: strokeWidth)
                    .frame(width: ringDiameter, height: ringDiameter)
                // 墨蓝占用弧：12 点起顺时针 72%，与 App 图标一致。
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(M2.ink, lineWidth: strokeWidth)
                    .frame(width: ringDiameter, height: ringDiameter)
                // 轴点。
                Circle()
                    .fill(M2.text)
                    .frame(width: size * 0.15, height: size * 0.15)
            }
            // Circle.trim 的 0 位在 3 点钟方向，转 -90° 让弧从 12 点起顺时针。
            .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - 权限提示

/// 非阻塞的受限提示：橙色语义，明确写清少扫了什么。
struct PermissionBanner: View {
    var message: String = "部分受保护目录无法读取，相关统计可能不完整。"
    var compact = false
    var onOpenSettings: () -> Void
    var onRecheck: () -> Void

    var body: some View {
        M2RestrictedState(
            message: compact ? "受限：部分目录读不到，统计会偏少。" : message,
            onOpenSettings: onOpenSettings,
            onRecheck: onRecheck
        )
    }
}
