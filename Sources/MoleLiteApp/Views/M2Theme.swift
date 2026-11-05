import AppKit
import MoleLiteCore
import SwiftUI

// MARK: - M2 主题：暖纸 / 暖黑 + 墨蓝
//
// 所有颜色都是动态色，跟随系统浅色 / 深色，不写死任何一套。
// 字体三件套：衬线标题、SF Pro 正文、等宽 tabular 数字。

enum M2 {
    // MARK: 颜色

    /// 窗口底：暖纸 / 暖黑。
    static let bg = dynamic(light: 0xF5F4ED, dark: 0x171613)
    /// 侧栏：比窗口底再暗一档。
    static let sidebar = dynamic(light: 0xEDEBE1, dark: 0x121110)
    /// 内容面板：比窗口底提亮一档。
    static let panel = dynamic(light: 0xFAF9F5, dark: 0x1F1E1A)
    /// 1px 细线。
    static let line = dynamic(light: 0xD8D5C8, dark: 0x35332D)
    /// 主文字。
    static let text = dynamic(light: 0x363433, dark: 0xF4F2EC)
    /// 次级文字。
    static let secondary = dynamic(light: 0x6B6A64, dark: 0xA8A49A)
    /// 三级文字 / 弱化单位。
    // 浅色 tertiary 在暖纸上只有约 3:1，9pt 等宽字会发灰；提到约 3.8:1，
    // 仍与 secondary 保持层级差，但表格里的位置/类型不再难读。
    static let tertiary = dynamic(light: 0x7A7568, dark: 0x8E8A80)
    /// 唯一强调色：墨蓝。
    static let ink = dynamic(light: 0x144A74, dark: 0x8FB9DC)
    /// 选中底：极浅墨蓝。
    static let inkSoft = dynamic(light: 0xECF3FA, dark: 0x24303A)
    /// 反白文字（墨蓝实心上的文字）。
    static let onInk = dynamic(light: 0xFFFFFF, dark: 0x141A20)
    /// 受限 / 谨慎。
    static let warning = dynamic(light: 0xA56A2A, dark: 0xD9A86A)
    static let warningSoft = dynamic(light: 0xF3E9D5, dark: 0x33291B)
    /// 正常 / 已授权。只用于「确认正常」，不用于强调。
    static let positive = dynamic(light: 0x3F6B4F, dark: 0x8FC7A2)
    /// 失败 / 错误。
    static let danger = dynamic(light: 0xA8453C, dark: 0xE0857A)
    static let dangerSoft = dynamic(light: 0xF6E2DE, dark: 0x3A2320)
    /// 轨道 / 空槽。
    static let track = dynamic(light: 0xE8E6DC, dark: 0x2B2A25)
    /// 磁盘「已用」段：中性暖灰，不和墨蓝抢焦点。
    static let used = dynamic(light: 0xB9B5A8, dark: 0x6E6A60)

    // MARK: 尺寸

    static let radiusCard = DesignSpec.cardCornerRadius
    static let radiusControl = DesignSpec.controlCornerRadius

    /// 分类占比的冷暖灰阶：只用同一种墨色的透明度，避免出现近似色脏灰。
    static func tone(_ index: Int) -> Color {
        let values: [Double] = [0.78, 0.56, 0.38, 0.24]
        return text.opacity(values[min(max(0, index), values.count - 1)])
    }

    static func grade(_ grade: SafetyGrade) -> Color {
        switch grade {
        case .safe: return positive
        case .suggested: return ink
        case .caution: return warning
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbHex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(srgbHex value: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - 字体

enum M2Font {
    /// 衬线标题（New York）。
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func body(_ size: CGFloat = DesignSpec.bodySize, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// 等宽数字；≥26pt 的大数字改用 SF Pro tabular，避免 SF Mono 的句点在整格居中产生空隙。
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: size >= 26 ? .default : .monospaced)
    }
}

// MARK: - 表面

extension View {
    /// M2 面板：面板底色 + 1px 细线，圆角 8，无阴影。
    func m2Surface(radius: CGFloat = M2.radiusCard, padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(M2.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(M2.line, lineWidth: DesignSpec.separatorWidth)
            )
    }

    /// 行悬停：只加一层极淡的墨色，不做阴影或放大。
    func m2Hover(cornerRadius: CGFloat = M2.radiusControl, enabled: Bool = true) -> some View {
        modifier(M2HoverModifier(cornerRadius: cornerRadius, enabled: enabled))
    }
}

private struct M2HoverModifier: ViewModifier {
    let cornerRadius: CGFloat
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(M2.text.opacity(hovering && enabled ? 0.045 : 0))
            )
            .onHover { hovering = enabled ? $0 : false }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - 细线与标题

struct M2Hairline: View {
    var color: Color = M2.line

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: DesignSpec.separatorWidth)
            .accessibilityHidden(true)
    }
}

/// 区块标题：衬线 15pt + 可选右侧说明。
struct M2SectionTitle: View {
    let title: String
    var detail: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpec.space2) {
            Text(title)
                .font(M2Font.serif(DesignSpec.sectionTitleSize))
                .foregroundStyle(M2.text)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignSpec.space2)
            if let trailing {
                Text(trailing)
                    .font(M2Font.mono(10))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 分组小标签：等宽大写，字距略开。
struct M2Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(M2Font.mono(DesignSpec.sectionLabelSize, .medium))
            .tracking(0.6)
            .foregroundStyle(M2.tertiary)
            .lineLimit(1)
    }
}

// MARK: - 数字

/// 数字 + 弱化单位：等宽 tabular，单位小一号、用三级灰。
struct M2Number: View {
    let text: String
    var size: CGFloat
    var weight: Font.Weight = .regular
    var color: Color = M2.text
    var unitColor: Color = M2.secondary
    var unitRatio: CGFloat = 0.34

    private var parts: (value: String, unit: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        if pieces.count == 2 { return (pieces[0], pieces[1]) }
        if let percent = trimmed.firstIndex(of: "%") {
            return (String(trimmed[trimmed.startIndex..<percent]), "%")
        }
        return (trimmed, nil)
    }

    var body: some View {
        let parsed = parts
        let unitSize = parsed.unit == "%" ? max(9, size * 0.55) : max(9, size * unitRatio)
        HStack(alignment: .firstTextBaseline, spacing: parsed.unit == "%" ? 1 : 3) {
            Text(parsed.value)
                .font(M2Font.mono(size, weight))
                .monospacedDigit()
                .foregroundStyle(color)
            if let unit = parsed.unit {
                Text(unit)
                    .font(M2Font.mono(unitSize, .medium))
                    .foregroundStyle(unitColor)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - 容量条

/// 连续三段磁盘条：已用 / 其中可清理 / 空闲，无分段缝隙。
struct M2ContinuousMeter: View {
    /// 已用占总量的比例。
    let used: Double
    /// 可清理占总量的比例。
    let cleanable: Double
    var height: CGFloat = 10

    private var usedValue: Double { min(1, max(0, used)) }
    private var cleanValue: Double { min(usedValue, max(0, cleanable)) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usedWidth = CGFloat(usedValue) * width
            let cleanWidth = CGFloat(cleanValue) * width
            ZStack(alignment: .leading) {
                Capsule().fill(M2.track)
                Capsule()
                    .fill(M2.used)
                    .frame(width: usedWidth)
                Rectangle()
                    .fill(M2.ink)
                    .frame(width: max(0, cleanWidth), height: height)
                    .offset(x: max(0, usedWidth - cleanWidth))
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("磁盘已使用 \(Int((usedValue * 100).rounded()))%，其中可清理 \(Int((cleanValue * 100).rounded()))%")
    }
}

/// 单色细进度条：扫描 / 清理进度，与磁盘条同一语言。
struct M2ProgressMeter: View {
    let fraction: Double
    var height: CGFloat = 4
    var tint: Color = M2.ink

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(M2.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.2), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("进度 \(Int(min(1, max(0, fraction)) * 100))%")
    }
}

/// 分类占比的细线（图例用），比分段块更安静。
struct M2LineMeter: View {
    let fraction: Double
    var tint: Color = M2.text
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(M2.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(1, proxy.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - 分段切换

/// 页内二级切换：等宽细边容器 + 选中墨蓝浅底，替代系统灰色胶囊。
struct M2Tabs<Value: Hashable>: View {
    let items: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Button {
                    withAnimation(.easeOut(duration: DesignSpec.animationDuration)) {
                        selection = item.0
                    }
                } label: {
                    Text(item.1)
                        .font(M2Font.body(11, selection == item.0 ? .medium : .regular))
                        .foregroundStyle(selection == item.0 ? M2.ink : M2.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selection == item.0 ? M2.inkSoft : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.0 ? [.isSelected, .isButton] : [.isButton])
            }
        }
        .padding(2)
        .overlay(
            RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                .strokeBorder(M2.line, lineWidth: 1)
        )
        .fixedSize()
    }
}

// MARK: - 按钮

/// 主按钮：墨蓝实心，白 / 近黑文字。
struct M2PrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(M2Font.body(compact ? 11 : 12, .medium))
            .foregroundStyle(M2.onInk)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 30)
            .background(
                RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                    .fill(M2.ink.opacity(isEnabled ? 1 : 0.45))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(Rectangle())
    }
}

/// 次按钮：透明底 + 墨蓝描边。
struct M2SecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(M2Font.body(compact ? 11 : 12, .medium))
            .foregroundStyle(isEnabled ? M2.ink : M2.tertiary)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 30)
            .overlay(
                RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                    .strokeBorder(isEnabled ? M2.ink.opacity(0.55) : M2.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// 受限态按钮：橙色语义，不借用墨蓝（避免把「受限」看成正常可操作状态）。
/// `emphasized` 用浅橙底，作为受限提示里的主要动作；另一个保持描边。
struct M2WarningButtonStyle: ButtonStyle {
    var compact = false
    var emphasized = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(M2Font.body(compact ? 11 : 12, .medium))
            .foregroundStyle(isEnabled ? M2.warning : M2.tertiary)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 30)
            .background(
                RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                    .fill(emphasized ? M2.warningSoft : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                    .strokeBorder(isEnabled ? M2.warning.opacity(emphasized ? 0.6 : 0.45) : M2.line,
                                  lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// 工具条文字按钮：不描边，只用墨蓝文字。
struct M2LinkButtonStyle: ButtonStyle {
    var tint: Color = M2.ink
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(M2Font.body(11, .medium))
            .foregroundStyle(isEnabled ? tint : M2.tertiary)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - 状态提示

enum M2NoticeKind: Equatable {
    case info
    case warning
    case error

    var color: Color {
        switch self {
        case .info: return M2.tertiary
        case .warning: return M2.warning
        case .error: return M2.danger
        }
    }

    var background: Color {
        switch self {
        case .info: return M2.panel
        case .warning: return M2.warningSoft
        case .error: return M2.dangerSoft
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.shield"
        case .error: return "xmark.octagon"
        }
    }

    /// 只按文案归类，不推断系统状态。
    static func infer(_ message: String) -> M2NoticeKind {
        if message.contains("失败") || message.contains("错误") || message.contains("无法读取") {
            return .error
        }
        if message.contains("权限") || message.contains("受限") || message.contains("读不到") {
            return .warning
        }
        return .info
    }
}

/// 单行 / 双行提示条：左色条 + 图标 + 文案 + 操作。受限与错误从不使用绿色或墨蓝。
struct M2Notice<Actions: View>: View {
    let kind: M2NoticeKind
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        // 标题行右侧放操作，说明始终占满整行宽度；窄宽度下不会把中文挤成竖排单字。
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: DesignSpec.space2) {
                icon
                Text(title)
                    .font(M2Font.body(12, .medium))
                    .foregroundStyle(M2.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: DesignSpec.space2)
                HStack(spacing: DesignSpec.space2) { actions() }
                    .fixedSize()
            }
            if let message {
                Text(message)
                    .font(M2Font.body(10.5))
                    .foregroundStyle(M2.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, DesignSpec.space3)
        .padding(.vertical, DesignSpec.space2)
        .background(kind.background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(kind.color)
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                .strokeBorder(kind == .info ? M2.line : kind.color.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: kind.icon)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(kind.color)
            .frame(width: 16, height: 16)
    }
}

extension M2Notice where Actions == EmptyView {
    init(kind: M2NoticeKind, title: String, message: String? = nil) {
        self.init(kind: kind, title: title, message: message) { EmptyView() }
    }
}

// MARK: - 状态页

/// 空状态：同一套留白与字阶，不靠插画撑场面。
struct M2EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DesignSpec.space3) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(M2.tertiary)
                .frame(height: 30)

            VStack(spacing: DesignSpec.space1) {
                Text(title)
                    .font(M2Font.serif(17))
                    .foregroundStyle(M2.text)
                Text(message)
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(M2PrimaryButtonStyle(compact: true))
                    .padding(.top, DesignSpec.space1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, DesignSpec.space7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)。\(message)")
    }
}

/// 扫描中：明确的进度 + 三行静态骨架，不用转圈遮挡内容。
struct M2ScanningState: View {
    var title: String = "正在扫描"
    var detail: String?
    var fraction: Double = 0
    var currentPath: String?
    var rows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpec.space3) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSpec.space2) {
                Text(title)
                    .font(M2Font.serif(15))
                    .foregroundStyle(M2.text)
                if let detail {
                    Text(detail)
                        .font(M2Font.mono(10))
                        .foregroundStyle(M2.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DesignSpec.space2)
                Text("\(Int(min(1, max(0, fraction)) * 100))%")
                    .font(M2Font.mono(10, .medium))
                    .foregroundStyle(M2.ink)
                    .monospacedDigit()
            }

            M2ProgressMeter(fraction: fraction, height: 4)

            if let currentPath {
                Text(currentPath)
                    .font(M2Font.mono(9.5))
                    .foregroundStyle(M2.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(spacing: DesignSpec.space2) {
                ForEach(0..<rows, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                        .fill(M2.text.opacity(0.045))
                        .frame(height: 30)
                }
            }
            .padding(.top, DesignSpec.space1)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(Int(fraction * 100))%")
    }
}

/// 错误状态：从不用绿色或墨蓝，重试是唯一主动作。
struct M2ErrorState: View {
    let title: String
    let message: String
    var retryTitle: String = "重试"
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: DesignSpec.space3) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(M2.danger)
                .frame(height: 28)
            VStack(spacing: DesignSpec.space1) {
                Text(title)
                    .font(M2Font.serif(17))
                    .foregroundStyle(M2.text)
                Text(message)
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let retry {
                Button(retryTitle, action: retry)
                    .buttonStyle(M2SecondaryButtonStyle(compact: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, DesignSpec.space7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)。\(message)")
    }
}

/// 受限状态：橙色语义，明确写清「少扫了什么」，不伪装成正常。
struct M2RestrictedState: View {
    let title: String = "部分目录受限"
    let message: String
    var onOpenSettings: (() -> Void)?
    var onRecheck: (() -> Void)?

    var body: some View {
        M2Notice(kind: .warning, title: title, message: message) {
            if let onRecheck {
                Button("重新检测", action: onRecheck)
                    .buttonStyle(M2WarningButtonStyle(compact: true))
            }
            if let onOpenSettings {
                Button("打开设置", action: onOpenSettings)
                    .buttonStyle(M2WarningButtonStyle(compact: true, emphasized: true))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// 整页受限：未授权时替换整个页面内容，明确列出「扫不到什么」，
/// 并提供「去授权」入口与「仍然扫描可见范围」的退路。
/// 所有动作使用橙色语义，不出现墨蓝或绿色。
struct M2RestrictedPage: View {
    let title: String
    let summary: String
    let misses: [String]
    var scopeNote: String?
    var onAuthorize: () -> Void
    var onRecheck: () -> Void
    var onContinue: (() -> Void)?
    var continueTitle: String = "仍然扫描可见范围"

    var body: some View {
        VStack(spacing: DesignSpec.space5) {
            VStack(spacing: DesignSpec.space2) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(M2.warning)
                    .frame(height: 32)

                Text(title)
                    .font(M2Font.serif(19))
                    .foregroundStyle(M2.text)
                    .multilineTextAlignment(.center)

                Text(summary)
                    .font(M2Font.body(11.5))
                    .foregroundStyle(M2.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DesignSpec.space2) {
                M2Eyebrow(text: "扫不到的内容")
                ForEach(misses, id: \.self) { line in
                    HStack(alignment: .top, spacing: DesignSpec.space2) {
                        Rectangle()
                            .fill(M2.warning.opacity(0.5))
                            .frame(width: 2, height: 11)
                            .padding(.top, 3)
                        Text(line)
                            .font(M2Font.body(11))
                            .foregroundStyle(M2.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(DesignSpec.space4)
            .m2Surface(radius: M2.radiusControl)
            .overlay(
                RoundedRectangle(cornerRadius: M2.radiusControl, style: .continuous)
                    .strokeBorder(M2.warning.opacity(0.32), lineWidth: 1)
            )

            HStack(spacing: DesignSpec.space2) {
                if let onContinue {
                    Button(continueTitle, action: onContinue)
                        .buttonStyle(M2LinkButtonStyle(tint: M2.secondary))
                }
                Button("重新检测", action: onRecheck)
                    .buttonStyle(M2WarningButtonStyle(compact: true))
                Button("去授权", action: onAuthorize)
                    .buttonStyle(M2WarningButtonStyle(compact: true, emphasized: true))
            }

            if let scopeNote {
                Text(scopeNote)
                    .font(M2Font.body(10))
                    .foregroundStyle(M2.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignSpec.pagePadding)
        .padding(.vertical, DesignSpec.space6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)。\(summary)")
    }
}
