import Foundation

/// 大小格式化（1024 进制，输出稳定可测）。
public enum ByteFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 例：0 -> "0 B"，1024 -> "1 KB"，1536 -> "1.5 KB"，1_073_741_824 -> "1 GB"。
    public static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        }
        let text = String(format: "%.1f", value)
        let trimmed = text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        return "\(trimmed) \(units[unitIndex])"
    }

    /// 精确到字节的写法，用于确认弹窗展示。
    public static func detailed(_ bytes: Int64) -> String {
        let text = string(bytes)
        if bytes > 0 { return "\(text)（\(bytes.formatted()) 字节）" }
        return text
    }

    public static func percent(_ fraction: Double) -> String {
        let value = min(1, max(0, fraction)) * 100
        return String(format: "%.0f%%", value)
    }

    /// 网络速率：例 "1.2 MB/s"。
    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0.5 else { return "0 B/s" }
        return string(Int64(bytesPerSecond.rounded())) + "/s"
    }
}
