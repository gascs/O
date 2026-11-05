import CryptoKit
import Foundation

/// 重复文件查找：按「大小 → 首块哈希 → 全文分块哈希」三级筛选，避免全盘读取。
/// 仅读取文件内容用于计算哈希，不做任何修改。
public struct DuplicateFinder: Sendable {
    public let roots: [URL]
    public let minFileSize: Int64
    public let maxCandidates: Int
    /// 返回的重复组上限，避免一次给出上千组难以处理的结果。
    public let maxGroups: Int

    public init(roots: [URL], minFileSize: Int64 = 1_048_576, maxCandidates: Int = 3000,
                maxGroups: Int = 300) {
        self.roots = roots
        self.minFileSize = max(1, minFileSize)
        self.maxCandidates = max(1, maxCandidates)
        self.maxGroups = max(1, maxGroups)
    }

    public func find(cancellation: ScanCancellation = ScanCancellation(),
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> [DuplicateGroup] {
        let roots = self.roots
        let minFileSize = self.minFileSize
        let maxCandidates = self.maxCandidates
        let maxGroups = self.maxGroups

        return try await Task.detached(priority: .userInitiated) {
            try Self.scan(roots: roots, minFileSize: minFileSize,
                          maxCandidates: maxCandidates,
                          cancellation: cancellation, progress: progress,
                          maxGroups: maxGroups)
        }.value
    }

    /// 同步实现，便于自检直接调用。
    public static func scan(roots: [URL], minFileSize: Int64, maxCandidates: Int,
                            cancellation: ScanCancellation,
                            progress: @escaping @Sendable (Int) -> Void,
                            maxGroups: Int = 300) throws -> [DuplicateGroup] {
        var bySize: [Int64: [DuplicateFile]] = [:]
        var scanned = 0

        // 目录为空或候选项很少时，循环体内的节流检查不会执行，这里先检查一次。
        try cancellation.check()

        for root in roots {
            let options: [FileManager.DirectoryEnumerationOptions] = [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                             .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                             .fileSizeKey, .contentModificationDateKey],
                options: FileManager.DirectoryEnumerationOptions(options),
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if scanned % 256 == 0 {
                    try cancellation.check()
                    progress(scanned)
                }
                guard let values = try? fileURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
                    .contentModificationDateKey
                ]) else { continue }
                if values.isDirectory == true || values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true else { continue }
                let size = FileSizeReader.allocatedSize(values)
                guard size >= minFileSize else { continue }
                scanned += 1
                if scanned > maxCandidates { break }
                bySize[size, default: []].append(DuplicateFile(
                    url: fileURL,
                    byteSize: size,
                    modifiedAt: values.contentModificationDate
                ))
            }
        }

        let candidates = bySize.filter { $0.value.count > 1 }
        guard !candidates.isEmpty else { return [] }

        var groups: [DuplicateGroup] = []
        for (size, files) in candidates {
            try cancellation.check()
            // 第一级：只哈希前 32 KB，快速排除大小相同但内容不同的文件。
            var byQuickHash: [[DuplicateFile]] = []
            var buckets: [String: [DuplicateFile]] = [:]
            for file in files {
                guard let key = hash(file.url, limitBytes: 32 * 1024) else { continue }
                buckets[key, default: []].append(file)
            }
            byQuickHash = Array(buckets.values.filter { $0.count > 1 })

            for sameQuick in byQuickHash {
                // 第二级：整文件分块 SHA-256。
                var fullBuckets: [String: [DuplicateFile]] = [:]
                for file in sameQuick {
                    try cancellation.check()
                    guard let key = hash(file.url, limitBytes: nil) else { continue }
                    fullBuckets[key, default: []].append(file)
                }
                for (digest, sameFiles) in fullBuckets where sameFiles.count > 1 {
                    let sorted = sameFiles.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
                    groups.append(DuplicateGroup(id: "\(size)-\(digest.prefix(16))",
                                                 files: sorted, fileSize: size))
                }
            }
        }

        progress(scanned)
        let sortedGroups = groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        return Array(sortedGroups.prefix(max(1, maxGroups)))
    }

    /// 计算文件哈希。`limitBytes` 不为 nil 时只读取前若干字节。
    public static func hash(_ url: URL, limitBytes: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limitBytes ?? Int.max

        while remaining > 0 {
            let size = min(1_048_576, remaining)
            guard let data = try? handle.read(upToCount: size), !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
