import Foundation

/// 进度合并器：后台回调可能很密集，这里只保留最新值，并按固定间隔刷新一次。
///
/// 典型用法：
/// ```swift
/// if coalescer.submit(snapshot) { scheduleFlush(after: 0.1) }
/// // 定时器到点后
/// if let latest = coalescer.flush() { progress = latest }
/// ```
/// 决策逻辑与计时无关，便于自检覆盖。
public struct ProgressCoalescer<Value> {
    private var pending: Value?
    private var isScheduled = false

    public init() {}

    /// 收到新进度。返回 `true` 表示需要安排一次延迟刷新；已有待刷新任务时返回 `false`。
    @discardableResult
    public mutating func submit(_ value: Value) -> Bool {
        pending = value
        guard !isScheduled else { return false }
        isScheduled = true
        return true
    }

    /// 取出最新值并结束本次刷新窗口。没有新值或不在刷新窗口中时返回 nil。
    public mutating func flush() -> Value? {
        guard isScheduled else { return nil }
        isScheduled = false
        defer { pending = nil }
        return pending
    }

    public var hasPending: Bool { isScheduled }

    public mutating func reset() {
        pending = nil
        isScheduled = false
    }

    /// 建议的合并窗口：0.15 秒。
    ///
    /// 依据：60 FPS 一帧约 16ms，0.15s 内最多积压约 9 帧；进度条与数字每秒更新
    /// 6~7 次已经足够连续，而主线程的 body 重算次数从「每个扫描回调一次」降到
    /// 「每秒最多 7 次」。大文件扫描时回调可能每秒上百次，这样主线程省下的时间
    /// 直接还给列表绘制，滚动掉帧明显减少。
    ///
    /// （泛型类型不允许 static stored property，所以写成计算属性。）
    public static var recommendedInterval: TimeInterval { 0.15 }
}

/// 有界 Top-N 收集器：单遍筛选出排序最靠前的 N 个元素。
///
/// 为什么需要：大文件 / 重复文件的结果可能上千条，而界面只展示前 N 条。
/// 原实现先把全部结果收集成数组、再全量 `sorted()`（O(n·log n)，峰值内存也按全量算），
/// 大结果集时会在主线程上明显卡一下。这里用「大小为 N 的最小堆」：
/// 每个元素最多与堆顶比较一次，插入 O(log N)，整体 O(n·log N)，内存固定 O(N)。
/// 最后只在收尾时排序一次（O(N·log N)）输出。
///
/// 堆顶刻意是「当前保留元素里最差的」——新元素比它好才替换，否则直接丢弃。
public struct BoundedTopN<Element> {
    private let limit: Int
    /// 返回 true 表示 lhs 应排在 rhs 之前（更优）。
    private let isBetter: (Element, Element) -> Bool
    private var heap: [Element] = []

    /// 实际到达的元素总数（不受 limit 截断影响，用于「共 N 项」计数）。
    public private(set) var totalCount = 0

    public init(limit: Int, by isBetter: @escaping (Element, Element) -> Bool) {
        self.limit = max(1, limit)
        self.isBetter = isBetter
    }

    public var count: Int { heap.count }

    public mutating func insert(_ element: Element) {
        totalCount += 1
        if heap.count < limit {
            heap.append(element)
            siftUp(from: heap.count - 1)
        } else if let worst = heap.first, isBetter(element, worst) {
            heap[0] = element
            siftDown(from: 0)
        }
    }

    /// 按「更优在前」输出。只会调用一次全排序。
    public func ranked() -> [Element] {
        heap.sorted(by: isBetter)
    }

    /// 最小堆上浮：父节点比子节点更优时交换（保证堆顶是最差的）。
    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isBetter(heap[parent], heap[child]) else { break }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    /// 最小堆下沉：在子节点里挑出更差的那个，与父节点比较后交换。
    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            guard left < heap.count else { return }
            var worse = left
            if right < heap.count, isBetter(heap[worse], heap[right]) {
                worse = right
            }
            guard isBetter(heap[parent], heap[worse]) else { return }
            heap.swapAt(parent, worse)
            parent = worse
        }
    }
}
