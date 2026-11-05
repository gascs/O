import Foundation

/// 统一设计规范：界面、渲染自检与测试共用同一组常量。
///
/// 视觉基调（M2 · 暖纸 / 暖黑 + 墨蓝）：
/// - 表面分三层：窗口底（暖纸 / 暖黑）、侧栏（再暗一档）、内容面板（提亮一档）；
///   全部由 1px 细线分隔，不使用阴影，也不使用彩色底块。
/// - 唯一强调色是墨蓝，只用于「可清理 / 选中 / 可操作」；橙色只表示「受限 / 谨慎」，
///   红色只表示失败。受限状态绝不复用强调色或绿色。
/// - 字体三件套：衬线标题（New York）、SF Pro 正文、等宽 tabular 数字（单位降一级）。
/// - 间距 4pt 网格；页面左右 26，分组 18，行内 8；行高 32 / 表格 38。
/// - 圆角：容器 8，控件 6；不使用 20+ 的超大圆角。
/// - 动效：0.19s easeOut，无弹跳。
public enum DesignSpec {
    // MARK: 间距（4pt 网格）

    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 20
    public static let space6: CGFloat = 24
    public static let space7: CGFloat = 28
    public static let space8: CGFloat = 32

    /// 内容区左右留白（24–28）。
    public static let pagePadding: CGFloat = 26
    /// 分组间距（16–20）。
    public static let sectionSpacing: CGFloat = 18
    /// 行内间距（8）。
    public static let rowSpacing: CGFloat = 8
    /// 行内纵向留白。
    public static let rowVerticalPadding: CGFloat = 4

    // MARK: 字号阶梯（M2）

    /// 页面标题（衬线 27）。
    public static let pageTitleSize: CGFloat = 27
    /// 页面副标题（状态摘要，SF Pro 11.5）。
    public static let pageSubtitleSize: CGFloat = 11.5
    /// 区块标题（衬线 15）。
    public static let sectionTitleSize: CGFloat = 15
    /// 同级小标题（衬线 13）。
    public static let subSectionTitleSize: CGFloat = 13
    /// 正文 / 列表行。
    public static let bodySize: CGFloat = 13
    /// 次要说明。
    public static let captionSize: CGFloat = 11
    /// 页脚 / 状态栏。
    public static let microSize: CGFloat = 10.5
    /// 概览主数字（可用空间）。
    public static let displaySize: CGFloat = 44
    /// 次级关键数字。
    public static let numberSize: CGFloat = 24
    /// 摘要卡主数字。
    public static let cardNumberSize: CGFloat = 30
    /// 分组标签（等宽大写）。
    public static let sectionLabelSize: CGFloat = 9
    /// 弹窗标题。
    public static let sheetTitleSize: CGFloat = 18

    // MARK: 行高、圆角、分隔线

    /// 列表行高；表格式行取 38，两行说明不挤压。
    public static let rowHeight: CGFloat = 32
    public static let tableRowHeight: CGFloat = 38
    /// 容器圆角 8，控件圆角 6。
    public static let cardCornerRadius: CGFloat = 8
    public static let controlCornerRadius: CGFloat = 6
    /// 面板内边距。
    public static let cardPadding: CGFloat = 18
    /// 分隔线 1px。
    public static let separatorWidth: CGFloat = 1
    /// 底部状态栏高度。
    public static let statusBarHeight: CGFloat = 28
    /// 概览右侧摘要卡宽度。
    public static let summaryCardWidth: CGFloat = 300
    /// 概览在内容宽度不足此值时改为单列（860 宽下四格实时卡片仍有足够宽度，不截断数值）。
    public static let twoColumnMinWidth: CGFloat = 1020

    // MARK: 动效

    /// 交互反馈动画时长（0.19s，无弹跳）。
    public static let animationDuration: Double = 0.19
    /// 内容展开 / 收起。
    public static let expandDuration: Double = 0.18

    // MARK: 窗口

    /// 最小窗口尺寸：侧边栏 180 + 内容 660 = 860；整窗高 600（含标题栏 52），
    /// 因此 SwiftUI 内容区最小高度为 548。详情页都用 ScrollView，高度不足时滚动，不裁文字。
    public static let minimumWindowWidth: CGFloat = 860
    public static let windowChromeHeight: CGFloat = 52
    public static let minimumWindowContentHeight: CGFloat = 600 - windowChromeHeight
    public static let sidebarMinWidth: CGFloat = 180
    public static let sidebarIdealWidth: CGFloat = 208
    public static let sidebarMaxWidth: CGFloat = 280
    public static let detailMinWidth: CGFloat = 660

    // MARK: 颜色约束

    /// 唯一强调色数量约束：1 个强调色 + 2 个语义色（受限 / 失败）。
    public static let accentColorCount = 1
}
