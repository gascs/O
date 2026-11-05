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
}
