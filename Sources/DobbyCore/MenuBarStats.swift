import Foundation

/// The compact CPU / memory / ports readout shown next to the menu bar icon.
public struct MenuBarSummary: Equatable, Sendable, CustomStringConvertible {
    public static let placeholder = "–"

    public let cpu: String
    public let memory: String
    public let ports: String
    /// Full wording for the tooltip and VoiceOver.
    public let description: String

    /// `cpu` is the busy fraction (0...1) of all cores; nil values haven't been sampled yet.
    public init(cpu: Double?, memory: MemoryStats?, portCount: Int?) {
        let memoryFraction = memory.flatMap { $0.totalBytes > 0 ? Double($0.usedBytes) / Double($0.totalBytes) : nil }
        self.cpu = cpu.map(Self.percent) ?? Self.placeholder
        self.memory = memoryFraction.map(Self.percent) ?? Self.placeholder
        self.ports = portCount.map(String.init) ?? Self.placeholder

        var memoryDetail = self.memory
        if let memory, memoryFraction != nil {
            memoryDetail += " (\(UsageFormat.bytes(memory.usedBytes)) of \(UsageFormat.bytes(memory.totalBytes)))"
        }
        let portsDetail = portCount.map { "\($0) \($0 == 1 ? "port" : "ports")" } ?? "Ports \(Self.placeholder)"
        description = "CPU \(self.cpu) · Memory \(memoryDetail) · \(portsDetail)"
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

/// Persists whether the readout is shown; off by default.
public struct MenuBarStatsStore {
    public static let key = "showMenuBarStats"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
