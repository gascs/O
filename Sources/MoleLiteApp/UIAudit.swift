import AppKit
import ApplicationServices
import MoleLiteCore
import SwiftUI

/// 扫描性能基准：在临时目录里造 N 个小文件，测量扫描耗时与主线程最大停顿。
/// 主线程用 20ms 心跳检测停顿；扫描全程在后台线程，进度按 100ms 合并。
enum UIScanBenchmark {
    final class Heartbeat: @unchecked Sendable {
        var maximumGap: TimeInterval = 0
        var last = Date()
        var ticks = 0
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @MainActor
    static func runIfNeeded() {
        guard UIAudit.benchmarkEnabled else { return }
        let index = CommandLine.arguments.firstIndex(of: "--scan-benchmark") ?? 0
        let fileCount = CommandLine.arguments.count > index + 1
            ? (Int(CommandLine.arguments[index + 1]) ?? 20_000) : 20_000

        Task { @MainActor in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("O-Benchmark-\(UUID().uuidString)")
            let caches = root.appendingPathComponent("Library/Caches")
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

            let startedSetup = Date()
            let folders = 40
            let perFolder = max(1, fileCount / folders)
            // 造文件放在后台线程，避免把建文件的时间算进主线程停顿。
            await Task.detached(priority: .utility) {
                let payload = Data(repeating: 0x2A, count: 1024)
                for folder in 0..<folders {
                    let directory = caches.appendingPathComponent("app-\(folder)")
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for file in 0..<perFolder {
                        FileManager.default.createFile(
                            atPath: directory.appendingPathComponent("f-\(file).bin").path,
                            contents: payload
                        )
                    }
                }
            }.value
            let totalFiles = folders * perFolder

            // 等首屏布局与初始数据加载结束，再开始测量，避免把启动开销算进扫描。
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            let heartbeat = Heartbeat()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                let now = Date()
                let gap = now.timeIntervalSince(heartbeat.last)
                heartbeat.maximumGap = max(heartbeat.maximumGap, gap)
                heartbeat.last = now
                heartbeat.ticks += 1
            }

            let scanner = Scanner(homeDirectory: root, settings: ScanSettings(includeHiddenItems: false))
            // 基准只统计扫描阶段，跳过建文件与计时器冷启动。
            heartbeat.last = Date()
            heartbeat.maximumGap = 0
            let started = Date()
            let updates = Counter()
            let report = try? await scanner.scan(categories: [.userCaches]) { _ in
                updates.increment()
            }
            let elapsed = Date().timeIntervalSince(started)
            timer.invalidate()

            let lines = [
                "benchmark files=\(totalFiles) setup=\(String(format: "%.2f", Date().timeIntervalSince(startedSetup)))s",
                "scan duration=\(String(format: "%.3f", elapsed))s items=\(report?.scannedItemCount ?? 0)",
                "raw progress callbacks=\(updates.count)",
                "main-thread max stall=\(String(format: "%.1f", heartbeat.maximumGap * 1000))ms ticks=\(heartbeat.ticks)"
            ]
            print(lines.joined(separator: "\n"))
            try? FileManager.default.removeItem(at: root)
            NSApplication.shared.terminate(nil)
        }
    }
}

/// 隐藏的界面自检模式，用于验证真实页面在 M2 下「文字是否真的渲染出来」。
///
/// 用法：`O.app/Contents/MacOS/O --ui-audit [输出目录]`
/// - 全部页面：浅色 / 深色，1280×800 整窗（含原生标题栏与工具栏），强制 2x 像素
/// - 全部页面：浅色 / 深色，860×600 最小整窗
/// - 首次引导、菜单栏面板、五种状态总览，各浅 / 深两套
/// - 同时导出辅助功能树，统计空标签与零尺寸节点
enum UIAudit {
    static var isEnabled: Bool { CommandLine.arguments.contains("--ui-audit") }

    /// 扫描性能基准模式：`--scan-benchmark [文件数]`
    static var benchmarkEnabled: Bool { CommandLine.arguments.contains("--scan-benchmark") }

    private struct PageSpec {
        let name: String
        let title: String
        let section: AppSection
        var spaceTab: SpaceTab?
        var systemTab: SystemTab?
    }

    private static let pages: [PageSpec] = [
        PageSpec(name: "01-home", title: "首页", section: .overview),
        PageSpec(name: "02-clean", title: "清理", section: .clean),
        PageSpec(name: "03-space-files", title: "空间 · 大文件", section: .space, spaceTab: .files),
        PageSpec(name: "04-space-duplicates", title: "空间 · 重复文件", section: .space, spaceTab: .duplicates),
        PageSpec(name: "05-apps", title: "应用", section: .apps),
        PageSpec(name: "06-system-launchitems", title: "系统 · 启动项", section: .system, systemTab: .launchItems),
        PageSpec(name: "07-system-permissions", title: "系统 · 权限", section: .system, systemTab: .permissions),
        PageSpec(name: "08-system-settings", title: "系统 · 设置", section: .system, systemTab: .settings),
        PageSpec(name: "09-rules", title: "规则", section: .rules)
    ]

    private static let designNotes: [String] = [
        "design-notes (M2):",
        "surface=暖纸 #F5F4ED / 暖黑 #171613；窗口底、顶部导航、面板三层由 1px 细线分隔，无阴影",
        "accent=墨蓝 #144A74（深色 #8FB9DC），唯一强调色，只用于可清理 / 选中 / 可操作",
        "semantics=橙色仅用于受限/谨慎；红色仅用于失败；绿色仅用于「确认正常」，受限状态不使用绿色或墨蓝",
        "type=衬线标题 27/15/13；正文 SF Pro 13/11.5/10；数字等宽 tabular，单位小一号并降为三级灰",
        "spacing=4pt 网格；页边 26；分组 18；行内 8；行高 32 / 表格 38；容器圆角 8 / 控件 6",
        "disk-meter=连续三段（已用暖灰 / 可清理墨蓝 / 空闲轨道），无分段缝隙",
        "layout=首页顶栏导航 + 内容；设备信息双列，实时状态四格（CPU 折线 / 内存分段 / 磁盘环 / 网络速率）",
        "navigation=顶部六项（首页 · 清理 · 空间 · 应用 · 系统 · 规则），⌘1–⌘6，860 宽不换行；窗口标题与工具栏主操作保留",
        "home-data=芯片 / 核心 / 内存 / GPU / 屏幕 / 序列号末四位 · 版本 / 构建 / 运行时长 / 启动磁盘 / 电源 / 热压力 / 本地 IP",
        "rules=预设（保守 / 标准 / 激进）· 规则增删改停 · 受保护清单 · JSON 导入导出 · 预计可释放与命中数",
        "states=空 / 扫描中 / 有结果 / 受限 / 错误 五套组件共用同一字阶与留白，见 11-states",
        "removed=M1 终端风格板、空间地图 / 分层容量条、系统蓝、统一卡片网格；磁盘环形仅用于首页实时状态",
        "limitations=辅助功能树在应用位于后台时可能只返回根节点，此时列坐标与文字截断均以 2x PNG 目检为准；悬停态取决于当时鼠标位置",
        "restricted=12–14 为整页受限态，由 auditForceRestricted 强制注入未授权分支；常规页截图先选择「仍然扫描可见范围」"
    ]

    private static var outputDirectory: URL {
        if let index = CommandLine.arguments.firstIndex(of: "--ui-audit"),
           CommandLine.arguments.count > index + 1 {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("O-UIAudit")
    }

    @MainActor
    static func runIfNeeded() {
        guard isEnabled else { return }
        let directory = outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 审计需要窗口在前台：AX 树与「窗口可见」判定都依赖应用处于活动状态。
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 600_000_000)
            var report: [String] = []
            report.append("axTrusted=\(AXIsProcessTrusted())")
            report.append("fullDiskAccess=\(PermissionCenter.shared.snapshot.fullDiskAccessStatus.rawValue)")

            guard let window = mainWindow() else {
                report.append("找不到主窗口")
                try? report.joined(separator: "\n").write(to: directory.appendingPathComponent("summary.txt"),
                                                         atomically: true, encoding: .utf8)
                NSApplication.shared.terminate(nil)
                return
            }
            window.makeKeyAndOrderFront(nil)

            // 触发一次真实快速扫描，让清理页与空间页有可对照的数据。
            NotificationCenter.default.post(name: .moleLiteQuickScan, object: nil)
            try? await Task.sleep(nanoseconds: 12_000_000_000)

            let standardSize = NSSize(width: 1280, height: 800)

            // 受限整页先拍：此时空间页尚未扫描、应用尚未载入，页脚计数为 0，
            // 不会出现「页面说受限、页脚却仍显示 5 个大文件」的自相矛盾。
            AppCoordinator.shared.allowLimitedScan = false
            AppCoordinator.shared.auditForceRestricted = true
            for (appearanceName, appearanceNameValue) in [("light", NSAppearance.Name.aqua),
                                                          ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearanceNameValue)
                window.setFrame(NSRect(origin: window.frame.origin, size: standardSize), display: true)
                try? await Task.sleep(nanoseconds: 600_000_000)

                let restrictedPages: [(name: String, section: AppSection, spaceTab: SpaceTab?)] = [
                    ("12-restricted-space-files", .space, .files),
                    ("13-restricted-space-duplicates", .space, .duplicates),
                    ("14-restricted-apps", .apps, nil)
                ]
                for page in restrictedPages {
                    AppCoordinator.shared.section = page.section
                    if let spaceTab = page.spaceTab { AppCoordinator.shared.spaceTab = spaceTab }
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    window.contentView?.needsLayout = true
                    window.displayIfNeeded()
                    guard let image = render2x(window: window) else {
                        report.append("[\(page.name)-\(appearanceName)] 渲染失败")
                        continue
                    }
                    let url = directory.appendingPathComponent("\(page.name)-\(appearanceName).png")
                    try? image.write(to: url)
                    report.append("[\(page.name)-\(appearanceName)] png=\(url.lastPathComponent) frame=\(Int(window.frame.width))x\(Int(window.frame.height))")
                }
            }
            AppCoordinator.shared.auditForceRestricted = false

            // 常规页截图模拟用户点「仍然扫描可见范围」；未授权本身仍真实存在。
            AppCoordinator.shared.allowLimitedScan = true

            // 预读应用列表：浅色 / 深色两套截图看到同一份已加载数据。
            AppCoordinator.shared.section = .apps
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            for (appearanceName, appearanceNameValue) in [("light", NSAppearance.Name.aqua),
                                                          ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearanceNameValue)
                window.setFrame(NSRect(origin: window.frame.origin, size: standardSize), display: true)
                try? await Task.sleep(nanoseconds: 600_000_000)

                for page in pages {
                    apply(page)
                    focus(window)
                    // 重复页默认不扫描，会停在空态；轻色这一轮用 AX 真实点一次「开始查找」，
                    // 让分组结果有图可核对（不注入任何假数据）。深色轮沿用同一份结果。
                    if page.spaceTab == .duplicates && appearanceName == "light" {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        let pressed = axPressButton(titled: "开始查找", in: window)
                        report.append("[duplicates-scan] pressed=\(pressed)")
                        if pressed {
                            var finished = false
                            for _ in 0..<20 {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                if !axContains(text: "正在查找", in: window) {
                                    finished = true
                                    break
                                }
                            }
                            report.append("[duplicates-scan] finished=\(finished)")
                        }
                    }
                    // 规则页：真实触发一次预计空间估算，等扫描回填后截图。
                    // 直接走应用内通知而非 AX 点击，辅助功能树在后台可能不完整。
                    if page.section == .rules && appearanceName == "light" {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        NotificationCenter.default.post(name: .oAuditEstimateRules, object: nil)
                        report.append("[rules-estimate] triggered=true")
                        var finished = false
                        for _ in 0..<60 {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if RuleEstimateStore.shared.scannedAt != nil && !RuleEstimateStore.shared.isScanning {
                                finished = true
                                break
                            }
                        }
                        report.append("[rules-estimate] finished=\(finished) outcomes=\(RuleEstimateStore.shared.outcomes.count)")
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                    // 空间页会真实扫描磁盘，给它更长的稳定时间；首页多留 9s 让 CPU 折线累积多个采样点；其余页面 1.2s 足够布局落定。
                    let settle: UInt64
                    if page.section == .space {
                        settle = 4_000_000_000
                    } else if page.section == .overview {
                        settle = 9_000_000_000
                    } else {
                        settle = 1_200_000_000
                    }
                    try? await Task.sleep(nanoseconds: settle)
                    window.contentView?.needsLayout = true
                    window.displayIfNeeded()

                    guard let image = render2x(window: window) else {
                        report.append("[\(page.name)-\(appearanceName)] 渲染失败")
                        continue
                    }
                    let url = directory.appendingPathComponent("\(page.name)-\(appearanceName).png")
                    try? image.write(to: url)
                    report.append("[\(page.name)-\(appearanceName)] png=\(url.lastPathComponent) frame=\(Int(window.frame.width))x\(Int(window.frame.height)) pixels=\(Int(window.frame.width * 2))x\(Int(window.frame.height * 2))")

                    if appearanceName == "light" {
                        let stats = accessibilityStats(window: window,
                                                       dumpTo: directory.appendingPathComponent("\(page.name)-ax.txt"))
                        report.append("[\(page.name)] axNodes=\(stats.total) textNodes=\(stats.text) emptyText=\(stats.empty) zeroSize=\(stats.zero) narrow=\(stats.narrow)")
                    }
                }
            }

            // 最小窗口：全部页面各来一套，确认 860×600 下不裁字、不溢出。
            for (appearanceName, appearanceNameValue) in [("light", NSAppearance.Name.aqua),
                                                          ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearanceNameValue)
                window.setFrame(NSRect(origin: window.frame.origin,
                                       size: NSSize(width: DesignSpec.minimumWindowWidth,
                                                    height: 600)), display: true)
                try? await Task.sleep(nanoseconds: 600_000_000)

                for page in pages {
                    apply(page)
                    focus(window)
                    let settle: UInt64
                    if page.section == .space {
                        settle = 2_500_000_000
                    } else if page.section == .overview {
                        settle = 3_000_000_000
                    } else {
                        settle = 2_000_000_000
                    }
                    try? await Task.sleep(nanoseconds: settle)
                    window.contentView?.needsLayout = true
                    window.displayIfNeeded()
                    guard let image = render2x(window: window) else {
                        report.append("[min-\(page.name)-\(appearanceName)] 渲染失败")
                        continue
                    }
                    let url = directory.appendingPathComponent("min-\(page.name)-\(appearanceName).png")
                    try? image.write(to: url)
                    let contentSize = window.contentLayoutRect.size
                    report.append("[min-\(page.name)-\(appearanceName)] content=\(Int(contentSize.width))x\(Int(contentSize.height))")
                }

                // 最小窗口整窗基准图：860×600（含标题栏）2x，用于核对整体是否挤压。
                AppCoordinator.shared.section = .overview
                try? await Task.sleep(nanoseconds: 900_000_000)
                window.contentView?.needsLayout = true
                window.displayIfNeeded()
                if let image = render2x(window: window) {
                    let url = directory.appendingPathComponent("min-window-\(appearanceName).png")
                    try? image.write(to: url)
                    report.append("[min-window-\(appearanceName)] png=min-window-\(appearanceName).png frame=\(Int(window.frame.width))x\(Int(window.frame.height)) content=\(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))")
                }
            }

            NSApp.appearance = NSAppearance(named: .aqua)
            AppCoordinator.shared.section = .overview

            // 首次引导：第 1–4 步（第 4 步为「清理规则」介绍），离屏渲染，浅 / 深各一套。
            for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
                for stepIndex in 0..<4 {
                    let hosting = NSHostingView(rootView: PermissionOnboardingView(
                        permissions: PermissionCenter.shared,
                        initialStep: stepIndex,
                        onClose: {}
                    ))
                    let sheetHeight: CGFloat = stepIndex == 1 || stepIndex == 3 ? 520 : 440
                    hosting.frame = NSRect(x: 0, y: 0, width: 540, height: sheetHeight)
                    hosting.appearance = NSAppearance(named: appearance)
                    hosting.layoutSubtreeIfNeeded()
                    if let data = render2x(view: hosting) {
                        let fileName = "09-onboarding-step\(stepIndex + 1)-\(name).png"
                        try? data.write(to: directory.appendingPathComponent(fileName))
                        report.append("[09-onboarding-step\(stepIndex + 1)-\(name)] png=\(fileName) pixels=\(Int(540 * 2))x\(Int(sheetHeight * 2))")
                    }
                }
            }

            // 菜单栏面板：同一语言的紧凑版，300 宽。
            let menuMonitor = MenuBarMonitor()
            for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
                let hosting = NSHostingView(rootView: MenuBarPanel(
                    monitor: menuMonitor,
                    coordinator: AppCoordinator.shared
                ))
                hosting.appearance = NSAppearance(named: appearance)
                let fitted = hosting.fittingSize
                hosting.frame = NSRect(x: 0, y: 0, width: 300, height: max(320, fitted.height))
                hosting.layoutSubtreeIfNeeded()
                if let data = render2x(view: hosting) {
                    try? data.write(to: directory.appendingPathComponent("10-menubar-\(name).png"))
                    report.append("[10-menubar-\(name)] png=10-menubar-\(name).png size=300x\(Int(hosting.frame.height))")
                }
            }

            // 五种状态总览：空 / 扫描中 / 有结果 / 受限 / 错误。
            for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
                let hosting = NSHostingView(rootView: M2StateGallery())
                hosting.frame = NSRect(x: 0, y: 0, width: 1120, height: 620)
                hosting.appearance = NSAppearance(named: appearance)
                hosting.layoutSubtreeIfNeeded()
                if let data = render2x(view: hosting) {
                    try? data.write(to: directory.appendingPathComponent("11-states-\(name).png"))
                    report.append("[11-states-\(name)] png=11-states-\(name).png pixels=2240x1240")
                }
            }

            report.append("")
            report.append(contentsOf: designNotes)
            report.append("")
            report.append("note=只在离屏模型上执行扫描与选择；未修改用户偏好，未执行任何真实清理。")

            let content = report.joined(separator: "\n")
            try? content.write(to: directory.appendingPathComponent("summary.txt"),
                               atomically: true, encoding: .utf8)
            print(content)
            NSApplication.shared.terminate(nil)
        }
    }

    @MainActor
    private static func apply(_ page: PageSpec) {
        AppCoordinator.shared.section = page.section
        if let spaceTab = page.spaceTab { AppCoordinator.shared.spaceTab = spaceTab }
        if let systemTab = page.systemTab { AppCoordinator.shared.systemTab = systemTab }
    }

    /// 审计期间保持应用与窗口在前台：后台状态下 SwiftUI 会降频，AX 树也可能不完整。
    @MainActor
    private static func focus(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !$0.isMiniaturized && $0.contentView != nil }
    }

    /// 强制 2x：自建 2 倍像素的 rep，再绘制整窗（含标题栏）或独立视图。
    @MainActor
    private static func render2x(window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        return render2x(view: view)
    }

    @MainActor
    private static func render2x(view: NSView) -> Data? {
        let bounds = view.bounds
        guard bounds.width > 10, bounds.height > 10 else { return nil }
        let scale = 2

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * CGFloat(scale)),
            pixelsHigh: Int(bounds.height * CGFloat(scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]), png.count > 4096 {
                return png
            }
        }

        // 备用：把 layer 树画进 2x 离屏上下文。
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width * CGFloat(scale)),
            height: Int(bounds.height * CGFloat(scale)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        guard let layer = view.layer else { return nil }
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private struct Stats {
        var total = 0
        var text = 0
        var empty = 0
        var zero = 0
        var narrow = 0
    }

    /// AX 通道不可用时的退路：直接读进程内的 NSAccessibility 树，不依赖辅助功能授权。
    private static func viewAccessibilityStats(window: NSWindow, dumpTo url: URL) -> Stats {
        var stats = Stats()
        var lines: [String] = []
        guard let root = window.contentView else {
            try? "找不到 contentView".write(to: url, atomically: true, encoding: .utf8)
            return stats
        }
        var visited = Set<UInt>()

        func walk(_ object: Any, depth: Int) {
            guard depth < 30 else { return }
            let reference = object as AnyObject
            let key = UInt(bitPattern: ObjectIdentifier(reference))
            guard visited.insert(key).inserted else { return }
            stats.total += 1

            let element = reference as? NSAccessibilityProtocol
            let role = element?.accessibilityRole()?.rawValue ?? String(describing: type(of: reference))
            let label = element?.accessibilityLabel() ?? ""
            let value = element?.accessibilityValue().map { "\($0)" } ?? ""
            let frame = element?.accessibilityFrame() ?? .zero
            let text = [label, value].first { !$0.isEmpty } ?? ""
            let isTextRole = role == "AXStaticText" || role == "AXButton" || role == "AXHeading"

            if isTextRole {
                stats.text += 1
                if text.isEmpty { stats.empty += 1 }
                if !text.isEmpty && frame.width < 10 { stats.narrow += 1 }
                if frame.width < 1 || frame.height < 1 { stats.zero += 1 }
            }
            if isTextRole || !text.isEmpty {
                lines.append("\(String(repeating: "  ", count: depth))\(role) frame=\(fmt(frame)) text=\"\(text)\"")
            } else {
                lines.append("\(String(repeating: "  ", count: depth))\(role) frame=\(fmt(frame))")
            }

            let children = NSAccessibility.unignoredChildren(from: [reference])
            if !children.isEmpty {
                for child in children { walk(child, depth: depth + 1) }
            } else if let view = reference as? NSView {
                for subview in view.subviews { walk(subview, depth: depth + 1) }
            }
        }

        walk(root, depth: 0)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return stats
    }

    /// 只在主窗口做一次 AX 遍历；`visit` 返回 true 表示提前结束。
    @discardableResult
    private static func axVisit(in window: NSWindow, _ visit: (AXUIElement) -> Bool) -> Bool {
        let application = AXUIElementCreateApplication(getpid())
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], !windows.isEmpty else { return false }

        var visited = Set<CFHashCode>()
        var stopped = false

        func walk(_ element: AXUIElement, depth: Int) {
            if stopped || depth > 26 { return }
            let key = CFHash(element)
            guard visited.insert(key).inserted else { return }
            if visit(element) { stopped = true; return }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                for child in children { walk(child, depth: depth + 1) }
            }
        }

        let preferred = windows.first { copyString($0, kAXTitleAttribute) == window.title } ?? windows[0]
        walk(preferred, depth: 0)
        return stopped
    }

    /// 模拟用户点击一个 AX 按钮（用于重复页的「开始查找」），不伪造数据。
    private static func axPressButton(titled label: String, in window: NSWindow) -> Bool {
        axVisit(in: window) { element in
            guard copyString(element, kAXRoleAttribute) == "AXButton" else { return false }
            let texts = [copyString(element, kAXTitleAttribute),
                         copyString(element, kAXValueAttribute),
                         copyString(element, kAXDescriptionAttribute)].compactMap { $0 }
            guard texts.contains(label) else { return false }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
    }

    private static func axContains(text needle: String, in window: NSWindow) -> Bool {
        axVisit(in: window) { element in
            let role = copyString(element, kAXRoleAttribute) ?? ""
            guard role == "AXStaticText" || role == "AXButton" else { return false }
            let texts = [copyString(element, kAXTitleAttribute),
                         copyString(element, kAXValueAttribute),
                         copyString(element, kAXDescriptionAttribute)].compactMap { $0 }
            return texts.contains { $0.contains(needle) }
        }
    }

    private static func accessibilityStats(window: NSWindow, dumpTo url: URL) -> Stats {
        var stats = Stats()
        var lines: [String] = []

        let application = AXUIElementCreateApplication(getpid())
        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowValue)
        guard windowResult == .success, let rawWindows = windowValue as? [AXUIElement] else {
            lines.append("AX windows 读取失败：\(windowResult.rawValue)（通常是未授予辅助功能权限）")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return viewAccessibilityStats(window: window, dumpTo: url)
        }
        // 未授权辅助功能时，kAXWindows 偶尔会退化成应用元素本身；只保留真正的窗口，避免递归成环。
        var windows = rawWindows.filter { copyString($0, kAXRoleAttribute) == "AXWindow" }
        if windows.isEmpty {
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                windows = children.filter { copyString($0, kAXRoleAttribute) == "AXWindow" }
            }
        }
        guard !windows.isEmpty else {
            lines.append("AX windows 未返回 AXWindow（只拿到 \(rawWindows.count) 个元素，role=\(rawWindows.first.map { copyString($0, kAXRoleAttribute) ?? "?" } ?? "nil")）")
            lines.append("改用进程内 NSView 辅助功能树：")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return viewAccessibilityStats(window: window, dumpTo: url)
        }

        var visited = Set<CFHashCode>()
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 26 else { return }
            let key = CFHash(element)
            guard visited.insert(key).inserted else { return }
            stats.total += 1

            let role = copyString(element, kAXRoleAttribute) ?? "?"
            let title = copyString(element, kAXTitleAttribute) ?? ""
            let value = copyString(element, kAXValueAttribute) ?? ""
            let description = copyString(element, kAXDescriptionAttribute) ?? ""
            let frame = copyFrame(element)

            if role == "AXStaticText" || role == "AXButton" || role == "AXHeading" {
                stats.text += 1
                let text = [title, value, description].first { !$0.isEmpty } ?? ""
                if text.isEmpty { stats.empty += 1 }
                if !text.isEmpty && frame.width < 10 { stats.narrow += 1 }
                if frame.width < 1 || frame.height < 1 { stats.zero += 1 }
                lines.append("\(String(repeating: "  ", count: depth))\(role) frame=\(fmt(frame)) text=\"\(text)\"")
            } else if role != "AXGroup" && role != "AXUnknown" {
                lines.append("\(String(repeating: "  ", count: depth))\(role) frame=\(fmt(frame))")
            }

            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                for child in children { walk(child, depth: depth + 1) }
            }
        }

        for window in windows { walk(window, depth: 0) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return stats
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyFrame(_ element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var origin = CGPoint.zero
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
           let raw = positionValue, CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgPoint, &origin)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let raw = sizeValue, CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    private static func fmt(_ rect: CGRect) -> String {
        "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}

// MARK: - 五种状态总览（仅用于渲染自检，不进入运行时界面）

struct M2StateGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpec.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("M2 状态规范")
                    .font(M2Font.serif(24))
                    .foregroundStyle(M2.text)
                Text("空 / 扫描中 / 有结果 / 受限 / 错误")
                    .font(M2Font.body(11))
                    .foregroundStyle(M2.secondary)
                Spacer()
                Text("每个页面复用同一组组件")
                    .font(M2Font.mono(9))
                    .foregroundStyle(M2.tertiary)
            }

            HStack(alignment: .top, spacing: DesignSpec.space4) {
                stateCard("空状态") {
                    M2EmptyState(
                        icon: "internaldrive",
                        title: "准备开始扫描",
                        message: "统计缓存、日志与废纸篓体积；清理只移入废纸篓。",
                        actionTitle: "开始扫描",
                        action: {}
                    )
                }
                stateCard("扫描中") {
                    M2ScanningState(
                        title: "正在扫描",
                        detail: "用户缓存 · 已扫描 2,140 项",
                        fraction: 0.42,
                        currentPath: "~/Library/Caches/com.apple.Safari",
                        rows: 3
                    )
                    .padding(DesignSpec.space3)
                }
            }

            HStack(alignment: .top, spacing: DesignSpec.space4) {
                stateCard("有结果") {
                    VStack(spacing: 0) {
                        resultRow("系统缓存", "2.4 GB", selected: true)
                        Hairline()
                        resultRow("用户日志", "812 MB", selected: true)
                        Hairline()
                        resultRow("Xcode 派生数据", "3.1 GB", selected: false)
                    }
                    .padding(.horizontal, DesignSpec.space3)
                }
                stateCard("受限（未授权）") {
                    VStack(alignment: .leading, spacing: DesignSpec.space2) {
                        M2RestrictedState(
                            message: "受限：邮件、Safari 与部分应用容器读不到，结果会偏少。",
                            onOpenSettings: {},
                            onRecheck: {}
                        )
                        Text("橙色语义，绝不复用墨蓝或绿色")
                            .font(M2Font.mono(9))
                            .foregroundStyle(M2.tertiary)
                    }
                    .padding(DesignSpec.space3)
                }
                stateCard("错误") {
                    M2ErrorState(
                        title: "读取磁盘失败",
                        message: "无法读取卷信息，请稍后重试。",
                        retry: {}
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DesignSpec.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(M2.bg)
    }

    private func stateCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignSpec.space2) {
            M2Eyebrow(text: title)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .panel(padding: DesignSpec.space3)
    }

    private func resultRow(_ name: String, _ size: String, selected: Bool) -> some View {
        HStack(spacing: DesignSpec.space2) {
            Toggle("", isOn: .constant(selected))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(M2.ink)
            Text(name)
                .font(M2Font.body(11))
                .foregroundStyle(M2.text)
            Spacer()
            M2Number(text: size, size: 11, weight: .medium, unitColor: M2.tertiary)
        }
        .frame(height: 34)
    }
}
