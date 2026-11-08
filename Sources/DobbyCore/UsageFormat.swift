import Foundation

public enum UsageFormat {
    public static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes < 1 << 20 { return "\(Int((value / 1024).rounded())) KB" }
        if bytes < 1 << 30 { return String(format: "%.1f MB", value / Double(1 << 20)) }
        return String(format: "%.2f GB", value / Double(1 << 30))
    }

    /// At most one decimal, for tight spots like tiles and legends: "512 KB", "138 MB", "42.7 GB".
    public static func compactBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes < 1 << 20 { return "\(Int((value / 1024).rounded())) KB" }
        if bytes < 1 << 30 { return "\(Int((value / Double(1 << 20)).rounded())) MB" }
        return String(format: "%.1f GB", value / Double(1 << 30))
    }

    /// Keep rates readable in narrow columns, including traffic below one kilobyte per second.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        if value < 1024 { return "\(Int(value.rounded())) B/s" }
        let units = ["KB/s", "MB/s", "GB/s", "TB/s"]
        var scaled = value / 1024
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 { scaled /= 1024; unit += 1 }
        return String(format: scaled < 10 ? "%.1f %@" : "%.0f %@", scaled, units[unit])
    }

    public static func percent(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }
}
