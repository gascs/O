import Foundation

/// 扫描报告导出（纯函数，便于测试）。
public enum ScanReportExporter {
    /// CSV：每行一个条目，列依次为 分类 / 名称 / 路径 / 字节数 / 可读大小 / 是否目录 / 修改时间。
    public static func csv(_ report: ScanReport) -> String {
        var lines: [String] = ["分类,名称,路径,字节数,可读大小,是否目录,修改时间"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for result in report.results {
            for item in result.items {
                let fields: [String] = [
                    result.category.title,
                    item.name,
                    item.url.path,
                    String(item.byteSize),
                    ByteFormatter.string(item.byteSize),
                    item.isDirectory ? "是" : "否",
                    item.modifiedAt.map { formatter.string(from: $0) } ?? ""
                ]
                lines.append(fields.map(escape).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Markdown：概览 + 每个分类的明细表。
    public static func markdown(_ report: ScanReport, generatedAt: Date = Date()) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.locale = Locale(identifier: "zh_CN")

        var lines: [String] = []
        lines.append("# O 扫描报告")
        lines.append("")
        lines.append("- 生成时间：\(dateFormatter.string(from: generatedAt))")
        lines.append("- 扫描条目：\(report.scannedItemCount.formatted()) 项")
        lines.append(String(format: "- 扫描耗时：%.2f 秒", report.duration))
        lines.append("- 可清理总量：\(ByteFormatter.string(report.totalBytes))")
        lines.append("")

        for result in report.results {
            lines.append("## \(result.category.title)（\(ByteFormatter.string(result.totalBytes)) / \(result.items.count) 项）")
            lines.append("")
            if let message = result.message {
                lines.append("> \(message)")
                lines.append("")
            }
            guard !result.items.isEmpty else {
                lines.append("未发现可清理项目。")
                lines.append("")
                continue
            }
            lines.append("| 名称 | 大小 | 修改时间 | 路径 |")
            lines.append("| --- | --- | --- | --- |")
            for item in result.items {
                let date = item.modifiedAt.map { dateFormatter.string(from: $0) } ?? "—"
                lines.append("| \(cell(item.name)) | \(ByteFormatter.string(item.byteSize)) | \(date) | `\(cell(item.url.path))` |")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
