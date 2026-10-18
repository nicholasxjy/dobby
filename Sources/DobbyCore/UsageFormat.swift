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

    public static func percent(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }
}
