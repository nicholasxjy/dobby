import Foundation

public enum AppTheme: String, CaseIterable, Sendable {
    case system, light, dark
}

/// Persists the appearance choice; anything unrecognized means "follow the system".
public struct ThemeStore {
    public static let key = "appTheme"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var theme: AppTheme {
        get { defaults.string(forKey: Self.key).flatMap(AppTheme.init(rawValue:)) ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
