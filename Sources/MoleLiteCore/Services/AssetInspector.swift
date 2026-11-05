import Foundation

/// 图标资源尺寸校验：直接解析 PNG 头部的 IHDR，不依赖 AppKit。
public enum AssetInspector {
    public struct PNGSize: Equatable, Sendable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public static func pngSize(at url: URL) -> PNGSize? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24 else { return nil }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(header.prefix(8)) == signature else { return nil }
        let width = Int(header[16]) << 24 | Int(header[17]) << 16 | Int(header[18]) << 8 | Int(header[19])
        let height = Int(header[20]) << 24 | Int(header[21]) << 16 | Int(header[22]) << 8 | Int(header[23])
        guard width > 0, height > 0 else { return nil }
        return PNGSize(width: width, height: height)
    }

    /// App 图标期望的尺寸表（文件名 → 像素边长）。
    public static let expectedAppIconFiles: [(name: String, pixels: Int)] = [
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

    /// 校验 iconset 目录，返回不匹配的文件说明；空数组表示全部合格。
    public static func validateIconset(at directory: URL) -> [String] {
        var issues: [String] = []
        for expected in expectedAppIconFiles {
            let url = directory.appendingPathComponent(expected.name)
            guard let size = pngSize(at: url) else {
                issues.append("\(expected.name) 缺失或不是有效 PNG")
                continue
            }
            if size.width != expected.pixels || size.height != expected.pixels {
                issues.append("\(expected.name) 尺寸为 \(size.width)×\(size.height)，应为 \(expected.pixels)×\(expected.pixels)")
            }
        }
        return issues
    }
}
