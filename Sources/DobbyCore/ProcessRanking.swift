import Foundation

public enum ProcessRanking {
    /// Filters by name, PID prefix or owning app, then sorts descending by `metric`.
    public static func ranked(_ items: [ProcessUsage], by metric: Metric, query: String) -> [ProcessUsage] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let filtered = needle.isEmpty ? items : items.filter { matches($0, needle) }
        return filtered.sorted { a, b in
            let (va, vb) = (value(of: a, metric), value(of: b, metric))
            if va != vb { return va > vb }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.pid < b.pid
        }
    }

    /// Keeps rows in their previous on-screen order so they don't jump under the pointer.
    /// Rows that disappeared are dropped; new rows are appended in the given order.
    public static func applyingFrozenOrder(_ items: [ProcessUsage], previousOrder: [pid_t]) -> [ProcessUsage] {
        let position = Dictionary(previousOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let known = items.filter { position[$0.pid] != nil }.sorted { position[$0.pid]! < position[$1.pid]! }
        let fresh = items.filter { position[$0.pid] == nil }
        return known + fresh
    }

    /// Full-width value for usage bars. The floor keeps an idle list from showing full bars.
    public static func barScale(for items: [ProcessUsage], metric: Metric) -> Double {
        let top = items.map { value(of: $0, metric) }.max() ?? 0
        switch metric {
        case .cpu: return max(top, 50)
        case .memory: return max(top, Double(1 << 30))
        }
    }

    public static func value(of item: ProcessUsage, _ metric: Metric) -> Double {
        switch metric {
        case .cpu: return item.cpuPercent
        case .memory: return Double(item.memoryBytes)
        }
    }

    private static func matches(_ item: ProcessUsage, _ needle: String) -> Bool {
        item.name.localizedCaseInsensitiveContains(needle)
            || String(item.pid).hasPrefix(needle)
            || (item.owningAppName?.localizedCaseInsensitiveContains(needle) ?? false)
            || (item.ownerName?.localizedCaseInsensitiveContains(needle) ?? false)
    }
}
