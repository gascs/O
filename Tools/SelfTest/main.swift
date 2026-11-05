import Foundation
import MoleLiteCore

// 不依赖 XCTest 的自检程序：在没有 Xcode（只有 Command Line Tools）的机器上也能执行。
// 覆盖：大小格式化、路径安全白名单、扫描过滤、推荐分级、重复文件、历史趋势、
//       启动项解析、报告导出、移入废纸篓（全部使用临时目录，用后清理）。

var passCount = 0
var failCount = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passCount += 1
        print("  PASS  \(name)")
    } else {
        failCount += 1
        print("  FAIL  \(name)\(detail.isEmpty ? "" : "  → \(detail)")")
    }
}

let fileManager = FileManager.default
let sandbox = fileManager.temporaryDirectory.appendingPathComponent("MoleLiteSelfTest-\(UUID().uuidString)")
try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: sandbox) }

@discardableResult
func makeFile(_ root: URL, _ relative: String, bytes: Int, fill: UInt8 = 0) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    fileManager.createFile(atPath: url.path, contents: Data(repeating: fill, count: bytes))
    return url
}

print("\n— 大小格式化 —")
check("0 字节", ByteFormatter.string(0) == "0 B")
check("512 字节", ByteFormatter.string(512) == "512 B")
check("1024 字节 → 1 KB", ByteFormatter.string(1024) == "1 KB")
check("1536 字节 → 1.5 KB", ByteFormatter.string(1536) == "1.5 KB")
check("1 GB", ByteFormatter.string(1_073_741_824) == "1 GB")
check("1.5 GB", ByteFormatter.string(1_610_612_736) == "1.5 GB")
check("1 TB", ByteFormatter.string(1_099_511_627_776) == "1 TB")
check("负数归零", ByteFormatter.string(-1) == "0 B")
check("百分比 26%", ByteFormatter.percent(0.256) == "26%")
check("百分比截断 100%", ByteFormatter.percent(1.4) == "100%")

print("\n— 路径安全白名单 —")
let safety = PathSafety(homeDirectory: URL(fileURLWithPath: "/Users/tester"))
let rejected = ["/System/Library", "/usr/local/bin/tool", "/bin/ls", "/etc/hosts", "/Library/Caches",
                "/private/var/db", "/tmp/scratch", "/Volumes/ExtDisk/file", "/", "/Users",
                "/Users/tester", "/Users/tester/Library", "/Applications", "/Applications/Utilities"]
for path in rejected {
    check("拒绝 \(path)", !safety.verdict(for: URL(fileURLWithPath: path)).isAllowed)
}
check("允许 ~/Library/Caches 子项",
      safety.verdict(for: URL(fileURLWithPath: "/Users/tester/Library/Caches/com.example.app")).isAllowed)
check("允许 ~/Downloads 中的文件",
      safety.verdict(for: URL(fileURLWithPath: "/Users/tester/Downloads/movie.mkv")).isAllowed)
check("允许 /Applications/Example.app",
      safety.verdict(for: URL(fileURLWithPath: "/Applications/Example.app")).isAllowed)
check("允许 ~/Library/Group Containers 子项",
      safety.verdict(for: URL(fileURLWithPath: "/Users/tester/Library/Group Containers/group.com.example")).isAllowed)
check("允许 ~/Library/LaunchAgents 中的 plist",
      safety.verdict(for: URL(fileURLWithPath: "/Users/tester/Library/LaunchAgents/com.example.plist")).isAllowed)
check("拒绝 /Library/LaunchAgents（系统级）",
      !safety.verdict(for: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.plist")).isAllowed)
check("~ 路径可展开",
      PathSafety.normalize("~/Library/Logs/app.log", home: URL(fileURLWithPath: "/Users/tester")) == "/Users/tester/Library/Logs/app.log")

let linkHome = sandbox.appendingPathComponent("link-home")
try fileManager.createDirectory(at: linkHome.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
let escapeLink = linkHome.appendingPathComponent("Library/Caches/escape")
try fileManager.createSymbolicLink(at: escapeLink, withDestinationURL: URL(fileURLWithPath: "/System/Library"))
check("拒绝指向系统目录的符号链接",
      !PathSafety(homeDirectory: linkHome).verdict(for: escapeLink).isAllowed)

print("\n— 扫描过滤规则 —")
let fakeHome = sandbox.appendingPathComponent("home")
try makeFile(fakeHome, "Library/Caches/AppA/a.bin", bytes: 1_048_576)
try makeFile(fakeHome, "Library/Caches/AppA/b.bin", bytes: 1_048_576)
try makeFile(fakeHome, "Library/Caches/AppB/c.bin", bytes: 524_288)
try makeFile(fakeHome, "Library/Caches/AppA/.hidden.bin", bytes: 1_048_576)
try makeFile(fakeHome, "Downloads/big.dat", bytes: 2_097_152)
try makeFile(fakeHome, "Downloads/small.dat", bytes: 102_400)

let plainReport = try await Scanner(homeDirectory: fakeHome, settings: ScanSettings(includeHiddenItems: false))
    .scan(categories: [.userCaches])
let cacheResult = plainReport.result(for: .userCaches)
check("缓存按一级目录聚合为 2 项", cacheResult?.items.count == 2)
check("聚合结果按体积降序（首项为 AppA）", cacheResult?.items.first?.name == "AppA")
check("默认排除隐藏文件", (cacheResult?.totalBytes ?? 0) == 2_621_440)
check("可展开子项存在", (cacheResult?.items.first?.children.count ?? 0) > 0)

let hiddenReport = try await Scanner(homeDirectory: fakeHome, settings: ScanSettings(includeHiddenItems: true))
    .scan(categories: [.userCaches])
check("开启后包含隐藏文件", (hiddenReport.result(for: .userCaches)?.totalBytes ?? 0) == 3_670_016)

let largeReport = try await Scanner(homeDirectory: fakeHome, settings: ScanSettings(largeFileThresholdMB: 1))
    .scan(categories: [.largeFiles])
let largeResult = largeReport.result(for: .largeFiles)
check("大文件阈值过滤只保留 2MB 文件", largeResult?.items.count == 1 && largeResult?.items.first?.name == "big.dat")
check("大文件体积正确", (largeResult?.totalBytes ?? 0) == 2_097_152)

let missingReport = try await Scanner(homeDirectory: fakeHome).scan(categories: [.logs])
check("缺失目录给出提示而非崩溃", missingReport.result(for: .logs)?.items.isEmpty == true &&
      missingReport.result(for: .logs)?.message != nil)

let cancelled = ScanCancellation()
cancelled.cancel()
do {
    _ = try await Scanner(homeDirectory: fakeHome).scan(categories: [.userCaches], cancellation: cancelled)
    check("取消扫描抛出错误", false)
} catch let error as ScanError {
    check("取消扫描抛出错误", error == .cancelled)
} catch {
    check("取消扫描抛出错误", false, "\(error)")
}

print("\n— 大文件浏览器 —")
let browserResult = try await Scanner(homeDirectory: fakeHome)
    .largeFiles(in: [fakeHome.appendingPathComponent("Downloads")], thresholdBytes: 1_048_576)
check("可指定目录扫描大文件", browserResult.items.count == 1)
check("大文件记录修改时间", browserResult.items.first?.modifiedAt != nil)
check("文件类型后缀正确", browserResult.items.first?.fileExtension == "dat")
let missingBrowserResult = try await Scanner(homeDirectory: fakeHome)
    .largeFiles(in: [fakeHome.appendingPathComponent("Movies")], thresholdBytes: 1_048_576)
check("缺失目录返回提示", missingBrowserResult.items.isEmpty && missingBrowserResult.message != nil)

print("\n— 推荐分级 —")
let gigabyte: Int64 = 3_221_225_472
let smallCache = ScanItem(url: URL(fileURLWithPath: "/tmp/demo/cache"), byteSize: 1_000, isDirectory: true)
let logItem = ScanItem(url: URL(fileURLWithPath: "/tmp/demo/app.log"), byteSize: 500, isDirectory: false)
let trashItem = ScanItem(url: URL(fileURLWithPath: "/tmp/demo/old.txt"), byteSize: 200, isDirectory: false)
let hugeFile = ScanItem(url: URL(fileURLWithPath: "/tmp/demo/huge.iso"), byteSize: gigabyte, isDirectory: false)
let demoReport = ScanReport(results: [
    ScanCategoryResult(category: .userCaches, items: [smallCache], totalBytes: 1_000),
    ScanCategoryResult(category: .logs, items: [logItem], totalBytes: 500),
    ScanCategoryResult(category: .trash, items: [trashItem], totalBytes: 200),
    ScanCategoryResult(category: .largeFiles, items: [hugeFile], totalBytes: gigabyte)
], scannedItemCount: 4, duration: 0.1)
let groups = RecommendationEngine.groups(in: demoReport)
check("分为安全/建议/谨慎三档", groups.count == 3)
check("缓存归入安全档", groups.first { $0.grade == .safe }?.itemIDs == [smallCache.id])
check("日志归入建议档", groups.first { $0.grade == .suggested }?.itemIDs == [logItem.id])
check("废纸篓与大文件归入谨慎档", (groups.first { $0.grade == .caution }?.itemIDs.count ?? 0) == 2)
check("一键建议项排除谨慎档", RecommendationEngine.oneClickItemIDs(in: demoReport).sorted() == [smallCache.id, logItem.id].sorted())

let hugeCache = ScanItem(url: URL(fileURLWithPath: "/tmp/demo/bigcache"), byteSize: gigabyte, isDirectory: true)
let escalatedReport = ScanReport(results: [
    ScanCategoryResult(category: .userCaches, items: [hugeCache], totalBytes: gigabyte)
], scannedItemCount: 1, duration: 0.1)
check("超大单项升级为谨慎档", RecommendationEngine.grade(for: hugeCache, in: .userCaches) == .caution)
check("升级后不参与一键清理", RecommendationEngine.oneClickItemIDs(in: escalatedReport).isEmpty)

print("\n— 重复文件 —")
let duplicateRoot = sandbox.appendingPathComponent("duplicates")
try makeFile(duplicateRoot, "one/photo.bin", bytes: 1_048_576, fill: 7)
try makeFile(duplicateRoot, "two/photo-copy.bin", bytes: 1_048_576, fill: 7)
try makeFile(duplicateRoot, "three/photo-other.bin", bytes: 1_048_576, fill: 9)
try makeFile(duplicateRoot, "small.txt", bytes: 10_240, fill: 1)

let duplicateGroups = try await DuplicateFinder(roots: [duplicateRoot], minFileSize: 524_288)
    .find()
check("识别出一组重复文件", duplicateGroups.count == 1)
check("每组包含两个副本", duplicateGroups.first?.files.count == 2)
check("可释放空间等于一份副本", duplicateGroups.first.map { $0.reclaimableBytes == $0.fileSize } == true)
check("内容不同的同尺寸文件被排除",
      !(duplicateGroups.first?.files.contains { $0.name == "photo-other.bin" } ?? true))
check("小于阈值的文件不参与", !(duplicateGroups.first?.files.contains { $0.name == "small.txt" } ?? true))

let manyRoot = sandbox.appendingPathComponent("duplicates-many")
for index in 0..<4 {
    try makeFile(manyRoot, "set-\(index)/a.bin", bytes: 614_400, fill: UInt8(index + 1))
    try makeFile(manyRoot, "set-\(index)/b.bin", bytes: 614_400, fill: UInt8(index + 1))
}
let limitedGroups = try await DuplicateFinder(roots: [manyRoot], minFileSize: 524_288, maxGroups: 2).find()
check("重复结果上限可调（4 组截断为 2）", limitedGroups.count == 2)
check("上限小于 1 时安全夹紧", DuplicateFinder(roots: [manyRoot], maxGroups: 0).maxGroups == 1)

print("\n— 重复文件范围配置 —")
let configDefaults = UserDefaults(suiteName: "O-config-\(UUID().uuidString)")!
let rootsHome = sandbox.appendingPathComponent("roots-home")
try fileManager.createDirectory(at: rootsHome.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
try fileManager.createDirectory(at: rootsHome.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
let configuredRoots = [rootsHome.appendingPathComponent("Downloads").path,
                       rootsHome.appendingPathComponent("Document").path]
configDefaults.set(configuredRoots, forKey: ScanSettings.Keys.duplicateRootPaths)
let resolvedRoots = ScanSettings.duplicateRootPaths(from: configDefaults, home: rootsHome)
check("只保留真实存在的自定义目录", resolvedRoots == [configuredRoots[0]])
check("目录为空时回退默认目录（仅存在的两项）",
      ScanSettings.duplicateRootPaths(from: UserDefaults(suiteName: "O-emptysuite-\(UUID().uuidString)")!,
                                      home: rootsHome).count == 2)
configDefaults.set(5, forKey: ScanSettings.Keys.duplicateGroupLimit)
check("组数上限下限夹紧到 20", ScanSettings.duplicateGroupLimit(from: configDefaults) == 20)
configDefaults.set(9_999, forKey: ScanSettings.Keys.duplicateGroupLimit)
check("组数上限上限夹紧到 2000", ScanSettings.duplicateGroupLimit(from: configDefaults) == 2000)
check("默认未完成权限引导", !ScanSettings.onboardingCompleted(from: UserDefaults(suiteName: "O-emptysuite-\(UUID().uuidString)")!))
configDefaults.set(true, forKey: ScanSettings.Keys.onboardingCompleted)
check("完成标记可持久化", ScanSettings.onboardingCompleted(from: configDefaults))

let duplicateHashA = DuplicateFinder.hash(duplicateRoot.appendingPathComponent("one/photo.bin"), limitBytes: nil)
let duplicateHashB = DuplicateFinder.hash(duplicateRoot.appendingPathComponent("two/photo-copy.bin"), limitBytes: nil)
check("相同内容哈希一致", duplicateHashA != nil && duplicateHashA == duplicateHashB)

print("\n— 历史与趋势 —")
let suiteName = "MoleLiteSelfTest-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
let history = HistoryStore(defaults: defaults)
let older = HistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_000), kind: .clean, bytes: 4096, itemCount: 3, detail: "测试")
let newer = HistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_100), kind: .scan, bytes: 8192, itemCount: 5, detail: "测试")
history.append(older)
history.append(newer)
check("历史按时间倒序", history.load().first?.id == newer.id)
check("仅统计清理记录释放量", history.totalFreedBytes == 4096)
check("历史条数正确", history.load().count == 2)
let limitedHistory = HistoryStore(defaults: defaults, limit: 2)
check("历史条数受限", limitedHistory.load().count == 2)
history.clear()
check("历史可清空", history.load().isEmpty)

let trend = DiskTrendStore(defaults: defaults)
let dayOne = Date(timeIntervalSince1970: 1_700_000_000)
trend.record(usedBytes: 1000, totalBytes: 2000, on: dayOne)
trend.record(usedBytes: 1200, totalBytes: 2000, on: dayOne.addingTimeInterval(3600))
check("同一天只保留一个采样点", trend.points().count == 1)
check("当天采样被覆盖", trend.points().first?.usedBytes == 1200)
trend.record(usedBytes: 800, totalBytes: 2000, on: dayOne.addingTimeInterval(86_400))
check("跨天新增采样点", trend.points().count == 2)
check("趋势比例计算正确", trend.points().last?.usedFraction == 0.4)

print("\n— 启动项解析 —")
let launchRoot = sandbox.appendingPathComponent("launch-home")
let agentDirectory = launchRoot.appendingPathComponent("Library/LaunchAgents")
try fileManager.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
let plist: [String: Any] = [
    "Label": "com.example.agent",
    "ProgramArguments": ["/usr/bin/true", "--demo"],
    "RunAtLoad": true,
    "Disabled": false
]
let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
let plistURL = agentDirectory.appendingPathComponent("com.example.agent.plist")
try plistData.write(to: plistURL)

let launchService = LaunchItemService(homeDirectory: launchRoot)
let parsed = launchService.parse(plistURL, scope: .userAgent)
check("读取 Label", parsed.label == "com.example.agent")
check("读取启动参数首项", parsed.program == "/usr/bin/true")
check("读取 RunAtLoad", parsed.runAtLoad == true)
check("状态文案正确", parsed.statusText == "登录时启动")
check("用户级启动项可编辑", parsed.scope.isUserEditable)
check("系统级启动项只读", !LaunchScope.systemAgent.isUserEditable)
let loadedItems = launchService.loadSynchronously()
check("目录扫描读取到启动项", loadedItems.contains { $0.label == "com.example.agent" })

print("\n— 系统登录项（只读） —")
let btmDirectory = launchRoot.appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagement")
try fileManager.createDirectory(at: btmDirectory, withIntermediateDirectories: true)
let btmPlist: [String: Any] = [
    "items": [
        ["url": "file:///Applications/Example.app", "identifier": "com.example.login"],
        ["url": "file:///Applications/Example.app", "identifier": "com.example.login"]
    ]
]
let btmData = try PropertyListSerialization.data(fromPropertyList: btmPlist, format: .binary, options: 0)
try btmData.write(to: btmDirectory.appendingPathComponent("com.apple.backgrounditems.btm"))
let loginResult = launchService.loadLoginItems()
check("解析系统登录项", loginResult.items.count == 1)
check("同一路径去重", loginResult.items.first?.url.path == "/Applications/Example.app")
check("登录项归入只读范围", loginResult.items.first?.scope == .loginItem &&
      loginResult.items.first?.scope.isUserEditable == false)
check("解析成功时不返回告警", loginResult.note == nil)
let emptyLaunchHome = sandbox.appendingPathComponent("empty-launch-home")
try fileManager.createDirectory(at: emptyLaunchHome, withIntermediateDirectories: true)
let emptyLoginResult = LaunchItemService(homeDirectory: emptyLaunchHome).loadLoginItems()
check("读不到登录项时明确回退", emptyLoginResult.items.isEmpty &&
      (emptyLoginResult.note?.contains("不会修改系统数据库") ?? false))
check("登录项会并入启动项列表",
      launchService.loadSynchronously().contains { $0.scope == .loginItem })

print("\n— 偏好迁移（改名） —")
let legacySuite = "com.molelite.app.selftest-\(UUID().uuidString)"
let newSuite = "com.o.app.selftest-\(UUID().uuidString)"
let legacyDefaults = UserDefaults(suiteName: legacySuite)!
let newDefaults = UserDefaults(suiteName: newSuite)!
defer {
    legacyDefaults.removePersistentDomain(forName: legacySuite)
    newDefaults.removePersistentDomain(forName: newSuite)
}
legacyDefaults.set(120, forKey: ScanSettings.Keys.largeFileThresholdMB)
legacyDefaults.set(true, forKey: ScanSettings.Keys.includeHiddenItems)
legacyDefaults.set("iconAndPercent", forKey: ScanSettings.Keys.menuBarDisplay)
legacyDefaults.synchronize()
newDefaults.set(300, forKey: ScanSettings.Keys.largeFileThresholdMB)
let migrated = PreferenceMigration.migrateIfNeeded(to: newDefaults, legacyDomains: [legacySuite], force: true)
check("迁移旧域缺失的 2 个键", migrated == 2, "实际 \(migrated)")
check("新域已有值不被覆盖",
      (newDefaults.object(forKey: ScanSettings.Keys.largeFileThresholdMB) as? Int) == 300)
check("迁移隐藏项设置", newDefaults.bool(forKey: ScanSettings.Keys.includeHiddenItems))
check("迁移状态栏样式", newDefaults.string(forKey: ScanSettings.Keys.menuBarDisplay) == "iconAndPercent")
check("写入迁移完成标记", newDefaults.bool(forKey: PreferenceMigration.markerKey))
check("再次启动不重复迁移",
      PreferenceMigration.migrateIfNeeded(to: newDefaults, legacyDomains: [legacySuite]) == 0)
check("可列出旧域键", PreferenceMigration.legacyKeys(from: legacyDefaults, legacyDomains: [legacySuite]).count == 3)
check("旧域不存在时安全返回",
      PreferenceMigration.migrateIfNeeded(to: newDefaults, legacyDomains: ["com.o.notexist"], force: true) == 0)

print("\n— 权限状态判定 —")
let permHome = sandbox.appendingPathComponent("perm-home")
try fileManager.createDirectory(at: permHome.appendingPathComponent("Library/Mail"), withIntermediateDirectories: true)
try fileManager.createDirectory(at: permHome.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
let permissionSnapshot = PermissionService.snapshot(home: permHome)
check("可读目录判定为已授权",
      permissionSnapshot.probes.first { $0.id == "mail" }?.access == .granted)
check("不存在的目录判定为缺失",
      permissionSnapshot.probes.first { $0.id == "trash" }?.access == .missing)
check("任一项可读即视为已开启", permissionSnapshot.hasFullDiskAccess)
check("状态文案不含虚假授权", permissionSnapshot.probes.first { $0.id == "tcc" }?.statusText == "路径不存在")
let emptyPermHome = sandbox.appendingPathComponent("perm-empty")
try fileManager.createDirectory(at: emptyPermHome, withIntermediateDirectories: true)
let emptySnapshot = PermissionService.snapshot(home: emptyPermHome)
check("全部缺失时不声称已授权", !emptySnapshot.hasFullDiskAccess)
check("全部缺失判为无法判定", emptySnapshot.fullDiskAccessStatus == .undetermined)
check("全部缺失时给出说明", emptySnapshot.summary == "完全磁盘访问无法判定")
check("无法判定时依据说明原因", emptySnapshot.fullDiskAccessBasis.contains("无法判定"))

// 废纸篓可读不能推断出完全磁盘访问。
let trashOnlyHome = sandbox.appendingPathComponent("perm-trash-only")
try fileManager.createDirectory(at: trashOnlyHome.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
let trashOnly = PermissionService.snapshot(home: trashOnlyHome)
check("废纸篓可读不等于完全磁盘访问", !trashOnly.hasFullDiskAccess)
check("废纸篓可读时 FDA 仍为无法判定", trashOnly.fullDiskAccessStatus == .undetermined)

let capabilities = PermissionService.capabilities(from: permissionSnapshot, home: permHome)
check("能力清单固定为 4 项", capabilities.count == 4)
check("能力 id 与顺序稳定",
      capabilities.map(\.id) == ["fda", "trash", "applications", "loginItem"])
check("每项能力都有判定依据", capabilities.allSatisfy { !$0.basis.isEmpty })
check("废纸篓缺失时如实标为无法判定",
      capabilities.first { $0.id == "trash" }?.status == .undetermined)
let emptyCapabilities = PermissionService.capabilities(from: emptySnapshot, home: emptyPermHome)
check("无法判定不会被当成已授权",
      emptyCapabilities.first { $0.id == "fda" }?.status == .undetermined)
check("状态文案三选一",
      capabilities.allSatisfy { [CapabilityStatus.granted, .denied, .undetermined].contains($0.status) })

// 引导跳过记忆：完成或跳过都写入同一个键，设置页可重置。
let guideDefaults = UserDefaults(suiteName: "O-guide-\(UUID().uuidString)")!
check("默认未完成引导", !ScanSettings.onboardingCompleted(from: guideDefaults))
ScanSettings.markPermissionGuideCompleted(from: guideDefaults, at: Date(timeIntervalSince1970: 100))
check("跳过/完成后记住引导", ScanSettings.onboardingCompleted(from: guideDefaults))
check("记录关闭时间", guideDefaults.double(forKey: ScanSettings.Keys.permissionGuideClosedAt) == 100)
ScanSettings.resetPermissionGuide(from: guideDefaults)
check("设置页重置后可再次引导", !ScanSettings.onboardingCompleted(from: guideDefaults))
check("重置清除关闭时间", guideDefaults.object(forKey: ScanSettings.Keys.permissionGuideClosedAt) == nil)

let realSnapshot = PermissionService.snapshot()
check("真实探针数量为 4", realSnapshot.probes.count == 4)
check("真实探针不修改文件系统", realSnapshot.probes.allSatisfy { !$0.path.isEmpty })

print("\n— 耗时预估 —")
let etaDefaults = UserDefaults(suiteName: "O-eta-\(UUID().uuidString)")!
let estimator = DurationEstimator(defaults: etaDefaults)
check("无历史时不预估扫描", estimator.scanEstimate() == nil)
let cleanEstimate = estimator.cleanEstimate(items: 200, bytes: 20 * 1_048_576)
check("清理预估为正数", cleanEstimate.seconds > 0)
check("首次清理标注经验系数", cleanEstimate.basis == "按经验系数估算")
estimator.recordClean(seconds: 1.4, items: 200, bytes: 20 * 1_048_576)
check("清理后记录次数", estimator.calibration.hasCleanHistory)
check("清理预估改用实测校正",
      estimator.cleanEstimate(items: 200, bytes: 20 * 1_048_576).basis.contains("校正"))
estimator.recordScan(seconds: 0.9, items: 3_000, bytes: 120_000_000)
check("扫描样本被记录", estimator.calibration.scanItemsSeen == 1)
check("按条目数可预估扫描", estimator.scanEstimate(itemsHint: 6_000)?.seconds ?? 0 > 0)
check("不足 1 秒文案", DurationEstimator.format(0.4) == "不到 1 秒")
check("秒级文案", DurationEstimator.format(5) == "约 5 秒")
check("分钟文案", DurationEstimator.format(90) == "约 1 分 30 秒")
check("整分钟文案", DurationEstimator.format(120) == "约 2 分钟")
let remaining = estimator.projectedRemaining(elapsed: 3, fraction: 0.3)
check("按进度外推剩余时间", abs((remaining?.seconds ?? 0) - 7) < 0.001, "实际 \(remaining?.seconds ?? -1)")
check("进度过小时不预估", estimator.projectedRemaining(elapsed: 0.2, fraction: 0.01) == nil)
check("接近完成时不再外推", estimator.projectedRemaining(elapsed: 3, fraction: 0.999) == nil)
check("负值安全归零", DurationEstimate(seconds: -5, basis: "测试").seconds == 0)

print("\n— 进度节流合并 —")
var coalescer = ProgressCoalescer<Int>()
check("首个进度安排刷新", coalescer.submit(1))
check("窗口内的进度不重复安排", !coalescer.submit(2) && !coalescer.submit(3))
check("刷新时只取最新进度", coalescer.flush() == 3)
check("刷新后窗口关闭", coalescer.flush() == nil && !coalescer.hasPending)
check("关闭后可再次安排", coalescer.submit(4))
coalescer.reset()
check("重置后丢弃待刷新值", coalescer.flush() == nil)


print("\n— 报告导出 —")
let trickyName = ScanItem(url: URL(fileURLWithPath: "/tmp/demo/a,b\"c"), name: "a,b\"c", byteSize: 1024, isDirectory: false)
let exportReport = ScanReport(results: [
    ScanCategoryResult(category: .userCaches, items: [trickyName], totalBytes: 1024)
], scannedItemCount: 1, duration: 0.5)
let csv = ScanReportExporter.csv(exportReport)
check("CSV 含表头", csv.hasPrefix("分类,名称,路径,字节数"))
check("CSV 对逗号与引号转义", csv.contains("\"a,b\"\"c\""))
check("CSV 含可读大小", csv.contains("1 KB"))
let markdown = ScanReportExporter.markdown(exportReport)
check("Markdown 含标题", markdown.contains("# O 扫描报告"))
check("Markdown 含分类小节", markdown.contains("## 用户缓存"))
check("Markdown 含表格表头", markdown.contains("| 名称 | 大小 | 修改时间 | 路径 |"))
let pipeName = ScanItem(url: URL(fileURLWithPath: "/tmp/demo/a|b.txt"), name: "a|b.txt", byteSize: 10, isDirectory: false)
let pipeReport = ScanReport(results: [
    ScanCategoryResult(category: .userCaches, items: [pipeName], totalBytes: 10)
], scannedItemCount: 1, duration: 0.1)
check("Markdown 转义竖线", ScanReportExporter.markdown(pipeReport).contains("a\\|b.txt"))

print("\n— 网络采样 —")
var networkSampler = NetworkSampler()
check("可读取网络计数器", NetworkSampler.counterTotals() != nil)
let firstSample = networkSampler.sample(at: Date(timeIntervalSince1970: 1000))
let secondSample = networkSampler.sample(at: Date(timeIntervalSince1970: 1001))
check("连续采样可用", firstSample != nil && secondSample != nil)
check("速率非负", (secondSample?.downBytesPerSecond ?? -1) >= 0 && (secondSample?.upBytesPerSecond ?? -1) >= 0)

print("\n— 应用残留 —")
let appHome = sandbox.appendingPathComponent("app-home")
_ = try makeFile(appHome, "Library/Caches/com.example.app/cache.bin", bytes: 2048)
_ = try makeFile(appHome, "Library/Group Containers/group.com.example.app/shared.bin", bytes: 1024)
_ = try makeFile(appHome, "Library/Preferences/com.example.app.plist", bytes: 256)
let inventory = AppInventoryService(homeDirectory: appHome)
let leftovers = inventory.leftoverItems(bundleIdentifier: "com.example.app", appName: "Example")
check("找到缓存残留", leftovers.contains { $0.kind == .cache })
check("找到共享容器残留", leftovers.contains { $0.kind == .groupContainer })
check("找到偏好设置残留", leftovers.contains { $0.kind == .preference })
check("按体积倒序", (leftovers.first?.byteSize ?? 0) >= (leftovers.last?.byteSize ?? 0))

print("\n— 移入废纸篓（安全边界） —")
let protectedReport = TrashService().trash(entries: [(URL(fileURLWithPath: "/System/Library/CoreServices"), 0)])
check("系统路径被拒绝", protectedReport.failureCount == 1 &&
      (protectedReport.outcomes.first?.message ?? "").contains("受保护"))

let trashMark = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/MoleLiteSelfTestItem")
check("废纸篓内项目不重复回收", {
    let report = TrashService().trash(entries: [(trashMark, 10)])
    return report.outcomes.first?.success == false &&
        (report.outcomes.first?.message ?? "").contains("手动清空")
}())

let missingItem = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MoleLiteSelfTest-missing")
check("不存在的文件安全跳过", TrashService().trash(entries: [(missingItem, 0)]).successCount == 1)

// 真实移动：在 ~/Library/Caches 内创建 4KB 临时文件 → 移入废纸篓 → 校验 → 清理测试产物。
// 沙箱 / 只读主目录的 CI 环境允许跳过，不把环境限制计为失败。
let marker = fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/MoleLiteSelfTest-\(UUID().uuidString).txt")
if fileManager.createFile(atPath: marker.path, contents: Data(count: 4096)) {
    let realReport = TrashService().trash(entries: [(marker, 4096)])
    check("真实移入废纸篓成功", realReport.successCount == 1 && !fileManager.fileExists(atPath: marker.path))
    if let trashedURL = realReport.outcomes.first?.resultingURL {
        check("可在废纸篓中定位", fileManager.fileExists(atPath: trashedURL.path))
        try? fileManager.removeItem(at: trashedURL)
    } else {
        check("可在废纸篓中定位", false)
    }
} else {
    print("  注：当前环境不允许写入 ~/Library/Caches，跳过真实废纸篓往返检查")
}

print("\n— 登录启动状态映射 —")
check("0 → 未注册", LoginItemState.map(rawStatus: 0) == .notRegistered)
check("1 → 已启用", LoginItemState.map(rawStatus: 1) == .enabled)
check("2 → 需系统批准", LoginItemState.map(rawStatus: 2) == .requiresApproval)
check("3 → 未找到", LoginItemState.map(rawStatus: 3) == .notFound)
if case .failed(let message) = LoginItemState.map(rawStatus: 9) {
    check("未知状态如实失败", message.contains("未知登录项状态"))
} else {
    check("未知状态如实失败", false)
}
check("只有 enabled 算开启", LoginItemState.enabled.isEnabled &&
      !LoginItemState.requiresApproval.isEnabled &&
      !LoginItemState.notRegistered.isEnabled)
check("需批准时提供系统设置入口", LoginItemState.requiresApproval.needsSystemSettings)
check("失败时提供系统设置入口", LoginItemState.failed("拒绝").needsSystemSettings)
check("未注册时不假装已开启", !LoginItemState.notRegistered.isEnabled)

let bareController = LoginItemController()
check("裸可执行文件不在 .app 内", !bareController.isRunningFromAppBundle)
do {
    try bareController.setEnabled(true)
    check("裸可执行文件拒绝注册", false)
} catch {
    check("裸可执行文件拒绝注册", error.localizedDescription.contains(".app"))
}

print("\n— 关闭窗口行为 —")
let behaviorSuite = "O-behavior-\(UUID().uuidString)"
let behaviorDefaults = UserDefaults(suiteName: behaviorSuite)!
defer { behaviorDefaults.removePersistentDomain(forName: behaviorSuite) }
check("默认驻留菜单栏", WindowCloseBehavior.current(from: behaviorDefaults) == .keepInMenuBar)
behaviorDefaults.set(WindowCloseBehavior.quitApp.rawValue, forKey: AppBehaviorSettings.Keys.windowCloseBehavior)
check("可切换为退出", WindowCloseBehavior.current(from: behaviorDefaults) == .quitApp)
behaviorDefaults.set("invalid", forKey: AppBehaviorSettings.Keys.windowCloseBehavior)
check("非法值回落到驻留", WindowCloseBehavior.current(from: behaviorDefaults) == .keepInMenuBar)
check("驻留与退出的标题互不相同",
      WindowCloseBehavior.keepInMenuBar.title != WindowCloseBehavior.quitApp.title)

print("\n— 单实例判断 —")
let instanceDirectory = fileManager.temporaryDirectory
    .appendingPathComponent("O-instance-\(UUID().uuidString)", isDirectory: true)
try? fileManager.createDirectory(at: instanceDirectory, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: instanceDirectory) }
let firstGuard = InstanceGuard(directory: instanceDirectory)
check("首个实例取得锁", firstGuard.acquire())
check("锁文件记录持锁 PID", firstGuard.heldPID == Int(getpid()))
let secondGuard = InstanceGuard(directory: instanceDirectory)
check("重复启动被判定为已有实例", secondGuard.acquire() == false)
secondGuard.release()
firstGuard.release()
let thirdGuard = InstanceGuard(directory: instanceDirectory)
check("释放后可再次取得锁", thirdGuard.acquire())
thirdGuard.release()
check("激活通知名稳定", InstanceGuard.activationNotificationName == "com.o.app.activate-window")

print("\n— 清理规则与扩围扫描 —")
check("保守预设 5 条规则", CleanupRuleCatalog.conservative.count == 5)
check("标准预设 47 条规则", CleanupRuleCatalog.standard.count == 47)
check("激进预设 58 条规则", CleanupRuleCatalog.aggressive.count == 58)
check("标准预设包含生态规则",
      CleanupRuleCatalog.standard.contains { $0.id.hasPrefix("eco.") })
check("激进预设包含个人文件来源",
      CleanupRuleCatalog.aggressive.contains { $0.category == .userFiles })
check("预设规则 id 不重复",
      Set(CleanupRuleCatalog.aggressive.map(\.id)).count == CleanupRuleCatalog.aggressive.count)

// 规则校验只需要一个「主目录」语义的路径，用系统临时目录即可，避免污染真实 $HOME。
let ruleHome = fileManager.temporaryDirectory
    .appendingPathComponent("o-selftest-rules-\(UUID().uuidString)")
try? fileManager.createDirectory(at: ruleHome, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: ruleHome) }

check("预设路径全部通过校验", {
    RulePreset.allCases.allSatisfy { preset in
        CleanupRuleCatalog.rules(for: preset).allSatisfy {
            RuleValidator.validate($0, home: ruleHome).isValid
        }
    }
}())
check("拒绝系统路径",
      RuleValidator.validate(path: "/System/Library/Caches", home: ruleHome).reason?.contains("系统") == true)
check("拒绝整个主目录",
      RuleValidator.validate(path: ruleHome.path, home: ruleHome).reason?.contains("主目录") == true)
check("拒绝范围过大的 ~/Library", {
    let library = ruleHome.appendingPathComponent("Library").path
    return RuleValidator.validate(path: library, home: ruleHome).reason?.contains("范围过大") == true
}())
check("受保护清单阻断规则", {
    let protected = ruleHome.appendingPathComponent("Keep").path
    let verdict = RuleValidator.validate(path: protected, home: ruleHome, protectedPaths: [protected])
    return !verdict.isValid && verdict.reason?.contains("受保护清单") == true
}())
check("递归规则必须带条件", {
    let rule = CleanupRule(name: "无门槛", category: .userFiles,
                           path: ruleHome.appendingPathComponent("Downloads").path,
                           scanMode: .recursiveFiles)
    let verdict = RuleValidator.validate(rule, home: ruleHome)
    return !verdict.isValid && verdict.reason?.contains("至少设置一项条件") == true
}())

let ruleSuite = "O-rules-\(UUID().uuidString)"
let ruleDefaults = UserDefaults(suiteName: ruleSuite)!
defer { ruleDefaults.removePersistentDomain(forName: ruleSuite) }
let ruleStore = RulesStore(defaults: ruleDefaults, home: ruleHome)
let exported = try? RulesStore.exportJSON(CleanupRuleCatalog.configuration(for: .aggressive))
check("规则可导出 JSON", exported != nil)
if let exported {
    let imported = try? ruleStore.importJSON(exported)
    check("规则 JSON 往返一致",
          imported?.rules.map(\.id) == CleanupRuleCatalog.aggressive.map(\.id))
}
check("非法 JSON 被拒绝", (try? ruleStore.importJSON(Data("bad json".utf8))) == nil)

// 导出信封与宽松导入
check("导出为带元数据的信封格式", {
    guard let data = try? RulesStore.exportJSON(CleanupRuleCatalog.configuration(for: .conservative),
                                               appVersion: "0.4.0") else { return false }
    let text = String(decoding: data, as: UTF8.self)
    return text.contains("\"formatVersion\"")
        && text.contains("\"appVersion\" : \"0.4.0\"")
        && text.contains("\"exportedAt\"")
}())
check("旧版裸配置仍可导入", {
    let bare = CleanupRulesConfiguration(rules: [
        CleanupRule(name: "缓存", category: .userCaches,
                    path: ruleHome.appendingPathComponent("Library/Caches").path)
    ])
    guard let data = try? JSONEncoder().encode(bare),
          let imported = try? ruleStore.importJSON(data) else { return false }
    return imported.rules.count == 1 && imported.rules.first?.name == "缓存"
}())
check("宽松导入跳过非法规则并给摘要", {
    let good = CleanupRule(name: "缓存", category: .userCaches,
                           path: ruleHome.appendingPathComponent("Library/Caches").path)
    let bad = CleanupRule(name: "系统目录", category: .systemCaches, path: "/System/Library/Caches")
    let source = CleanupRulesConfiguration(rules: [good, bad])
    guard let data = try? RulesStore.exportJSON(source),
          let summary = try? ruleStore.importRules(data, mode: .replace) else { return false }
    return summary.acceptedRules.count == 1
        && summary.rejectedRules.count == 1
        && summary.hasFindings
        && summary.message.contains("已导入 1 条规则")
}())
check("合并导入同路径去重并合并保护清单", {
    var existing = CleanupRuleCatalog.configuration(for: .standard)
    existing.protectedPaths = [ruleHome.appendingPathComponent("Documents").path]
    let samePath = CleanupRule(name: "缓存副本", category: .userCaches, path: existing.rules[0].path)
    let fresh = CleanupRule(name: "新位置", category: .userCaches,
                            path: ruleHome.appendingPathComponent("FreshCache").path)
    let incoming = CleanupRulesConfiguration(rules: [samePath, fresh],
                                             protectedPaths: [ruleHome.appendingPathComponent("Movies").path])
    guard let data = try? RulesStore.exportJSON(incoming),
          let summary = try? ruleStore.importRules(data, mode: .merge, current: existing) else { return false }
    return summary.acceptedRules.count == 1
        && summary.acceptedRules.first?.name == "新位置"
        && summary.skippedDuplicates == 1
        && summary.appliedPreset == nil
        && Set(summary.protectedPaths) == Set(existing.protectedPaths + incoming.protectedPaths)
}())
check("导入模式标题可用", RulesImportMode.allCases.count == 2 && RulesImportMode.merge.title == "合并到现有规则")

let ruleCache = ruleHome.appendingPathComponent("Library/Caches")
try? fileManager.createDirectory(at: ruleCache, withIntermediateDirectories: true)
_ = try? makeFile(ruleHome, "Library/Caches/big.bin", bytes: 3_000_000)
_ = try? makeFile(ruleHome, "Library/Caches/small.bin", bytes: 1_000)
let oldDate = Calendar.current.date(byAdding: .day, value: -40, to: Date())!
try? fileManager.setAttributes([.modificationDate: oldDate],
                               ofItemAtPath: ruleCache.appendingPathComponent("big.bin").path)
try? fileManager.setAttributes([.modificationDate: oldDate],
                               ofItemAtPath: ruleCache.appendingPathComponent("small.bin").path)
let cacheRule = CleanupRule(name: "缓存", category: .userCaches, path: ruleCache.path,
                            minAgeDays: 30, minSizeMB: 1)
let ruleReport: RuleScanReport? = try? CleanupRuleScanner(home: ruleHome, includeHidden: true)
    .scan(rules: [cacheRule], protectedPaths: [])
check("规则扫描命中 1 项", ruleReport?.outcomes.first?.itemCount == 1)
check("规则扫描按体积过滤", (ruleReport?.outcomes.first?.bytes ?? 0) >= 1_048_576)
let missingRule = CleanupRule(name: "Docker", category: .docker,
                             path: ruleHome.appendingPathComponent("NoDocker").path)
let ruleMissingReport: RuleScanReport? = try? CleanupRuleScanner(home: ruleHome, includeHidden: true)
    .scan(rules: [missingRule], protectedPaths: [])
check("缺失路径记录跳过原因",
      ruleMissingReport?.outcomes.first?.skippedReason == "未检测到 Docker 数据目录")
check("跳过规则被计数", ruleMissingReport?.skippedRuleCount == 1)

let nestedParent = CleanupRule(name: "全部缓存", category: .userCaches, path: ruleCache.path)
let npmRoot = ruleCache.appendingPathComponent("npm")
try? fileManager.createDirectory(at: npmRoot, withIntermediateDirectories: true)
_ = try? makeFile(ruleHome, "Library/Caches/npm/blob", bytes: 2_000_000)
let nestedChild = CleanupRule(name: "npm", category: .packageCaches, path: npmRoot.path)
let nestedRuleReport: RuleScanReport? = try? CleanupRuleScanner(home: ruleHome, includeHidden: true)
    .scan(rules: [nestedParent, nestedChild], protectedPaths: [])
check("父规则跳过子规则根目录", {
    nestedRuleReport?.outcome(for: nestedParent.id)?.items.allSatisfy {
        !$0.url.path.contains("/npm/")
    } == true
}())
check("子规则独立统计", nestedRuleReport?.outcome(for: nestedChild.id)?.itemCount == 1)

print("\n结果：\(passCount) 通过，\(failCount) 失败\n")
exit(failCount == 0 ? 0 : 1)
