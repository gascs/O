import Foundation

/// 智能推荐：按「安全 / 建议 / 谨慎」给扫描结果分级。
public enum RecommendationEngine {
    /// 单个条目超过该体积时自动升级为「谨慎」，避免误删大文件。
    public static let itemCautionThreshold: Int64 = 2 * 1024 * 1024 * 1024

    public static func baseGrade(for category: ScanCategory) -> SafetyGrade {
        switch category {
        case .userCaches, .xcode, .diagnostics, .developer, .packageCaches, .systemCaches:
            return .safe
        case .logs, .appLeftovers: return .suggested
        case .trash, .largeFiles, .docker, .backups, .mailAttachments, .userFiles:
            return .caution
        }
    }

    public static func grade(for item: ScanItem, in category: ScanCategory) -> SafetyGrade {
        let base = baseGrade(for: category)
        if base != .caution && item.byteSize >= itemCautionThreshold { return .caution }
        return base
    }

    /// 把一次扫描结果聚合为三档建议。
    public static func groups(in report: ScanReport) -> [RecommendationGroup] {
        var buckets: [SafetyGrade: (ids: [String], bytes: Int64, categories: Set<ScanCategory>)] = [:]

        for result in report.results {
            for item in result.items {
                let grade = grade(for: item, in: result.category)
                var bucket = buckets[grade] ?? ([], 0, [])
                bucket.ids.append(item.id)
                bucket.bytes += item.byteSize
                bucket.categories.insert(result.category)
                buckets[grade] = bucket
            }
        }

        return SafetyGrade.allCases.compactMap { grade in
            guard let bucket = buckets[grade], !bucket.ids.isEmpty else { return nil }
            let categories = ScanCategory.allCases.filter { bucket.categories.contains($0) }
            return RecommendationGroup(
                grade: grade,
                itemIDs: bucket.ids,
                bytes: bucket.bytes,
                categories: categories,
                note: grade.explanation
            )
        }
    }

    /// 「一键清理建议项」选择的条目：安全 + 建议，且排除废纸篓与大文件。
    public static func oneClickGroups(in report: ScanReport) -> [RecommendationGroup] {
        groups(in: report).filter { $0.grade.isOneClickEligible }
    }

    public static func oneClickItemIDs(in report: ScanReport) -> [String] {
        oneClickGroups(in: report).flatMap(\.itemIDs)
    }
}
