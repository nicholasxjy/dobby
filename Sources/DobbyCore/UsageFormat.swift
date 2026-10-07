import Foundation

public enum UsageFormat {
    public static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes < 1 << 20 { return "\(Int((value / 1024).rounded())) KB" }
        if bytes < 1 << 30 { return String(format: "%.1f MB", value / Double(1 << 20)) }
        return String(format: "%.2f GB", value / Double(1 << 30))
    }

    public static func percent(_ percent: Double) -> String {
        String(format: "%.1f%%", percent)
    }
}
