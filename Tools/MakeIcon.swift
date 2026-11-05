import AppKit

// 生成 O 的极简图标：单一几何圆环，去掉多层渐变、白色高光与内发光。
// 用法： makeicon <输出目录>
//   输出目录/AppIcon.iconset/…            —— 应用图标（10 个尺寸）
//   输出目录/MenuBarIconTemplate.png      —— 18×18 单色 template 图
//   输出目录/MenuBarIconTemplate@2x.png   —— 36×36 单色 template 图

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
let iconsetPath = (outputDirectory as NSString).appendingPathComponent("AppIcon.iconset")
try? fileManager.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

// MARK: - 应用图标

/// 真正的 squircle（超椭圆，n=5）路径，而不是普通圆角矩形。
func squirclePath(in rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let steps = 720
    let power = 2 / n

    for index in 0...steps {
        let t = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let cosValue = cos(t)
        let sinValue = sin(t)
        let x = a * copysign(1, cosValue) * pow(abs(cosValue), power)
        let y = b * copysign(1, sinValue) * pow(abs(sinValue), power)
        let point = NSPoint(x: cx + x, y: cy + y)
        if index == 0 {
            path.move(to: point)
        } else {
            path.line(to: point)
        }
    }
    path.close()
    return path
}

/// macOS Big Sur+ 图标网格：1024 画布中主体 824，squircle 超椭圆。
/// 设计＝应用首页的「磁盘占用环」：暖纸底（M2 #F5F4ED）+ 墨蓝 #144A74 占用弧（12 点起
/// 顺时针 72%）+ 暖灰 #D8D5C8 空闲轨道（剩余 28%）+ 暖黑 #141318 轴点，发丝边。
/// 无渐变、无高光、无内阴影；图标即应用的核心视觉，配色与 M2 完全一致。
func drawAppIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let bodyInset = size * 0.0978
    let bodyRect = NSRect(x: bodyInset, y: bodyInset,
                          width: size - bodyInset * 2, height: size - bodyInset * 2)
    let body = squirclePath(in: bodyRect)

    // M2 暖纸底色，不做渐变与高光。
    NSColor(srgbRed: 0xF5 / 255.0, green: 0xF4 / 255.0, blue: 0xED / 255.0, alpha: 1).setFill()
    body.fill()

    // 发丝边：让图标在浅色桌面上仍有清晰边界。
    let border = squirclePath(in: bodyRect.insetBy(dx: size * 0.0007, dy: size * 0.0007))
    border.lineWidth = max(1, size * 0.0012)
    NSColor(calibratedWhite: 0.0, alpha: 0.14).setStroke()
    border.stroke()

    // 占用环：直径 0.585、笔画 0.125，12 点起顺时针。
    let center = NSPoint(x: size / 2, y: size / 2)
    let ringRadius = size * 0.585 / 2
    let stroke = size * 0.125

    // 空闲轨道：剩余 28%（从 -168° 顺时针经左侧到 12 点）。
    // 比 M2 细线灰深一档：16px 下轨道仍可辨。
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: ringRadius,
                    startAngle: -168, endAngle: 90, clockwise: true)
    track.lineWidth = stroke
    track.lineCapStyle = .butt
    NSColor(srgbRed: 0xCB / 255.0, green: 0xC7 / 255.0, blue: 0xB6 / 255.0, alpha: 1).setStroke()
    track.stroke()

    // 墨蓝占用弧：12 点起顺时针 258°（≈72%），与首页环形图同一语义。
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: ringRadius,
                  startAngle: 90, endAngle: -168, clockwise: true)
    arc.lineWidth = stroke
    arc.lineCapStyle = .butt
    NSColor(srgbRed: 0x14 / 255.0, green: 0x4A / 255.0, blue: 0x74 / 255.0, alpha: 1).setStroke()
    arc.stroke()

    // 轴点：暖黑圆点落在环心；直径 15%，从属环形主体、16px 下仍是一个可辨认的深色中心。
    let dotRadius = size * 0.075
    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2))
    NSColor(srgbRed: 0x14 / 255.0, green: 0x13 / 255.0, blue: 0x18 / 255.0, alpha: 1).setFill()
    dot.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    guard let png = drawAppIcon(pixels: variant.pixels) else { continue }
    try? png.write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(variant.name))
}

// MARK: - 菜单栏 template 图标（单色 + 透明背景，由系统按外观自动着色）

func drawMenuBarIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    // 与 App 图标同一母题：占用弧 + 弱化轨道 + 轴点。
    // template 图支持透明度，轨道用 35% 黑，系统按菜单栏外观整体着色。
    let center = NSPoint(x: size / 2, y: size / 2)
    let radius = size * (1 - 0.16 * 2) / 2
    let stroke = size * 0.155

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius,
                    startAngle: -168, endAngle: 90, clockwise: true)
    track.lineWidth = stroke
    track.lineCapStyle = .butt
    NSColor.black.withAlphaComponent(0.35).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius,
                  startAngle: 90, endAngle: -168, clockwise: true)
    arc.lineWidth = stroke
    arc.lineCapStyle = .butt
    NSColor.black.setStroke()
    arc.stroke()

    let dotRadius = size * 0.09
    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2))
    NSColor.black.setFill()
    dot.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (name, pixels) in [("MenuBarIconTemplate.png", 18), ("MenuBarIconTemplate@2x.png", 36)] {
    guard let png = drawMenuBarIcon(pixels: pixels) else { continue }
    try? png.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name))
}

print("图标已生成：\(outputDirectory)")
