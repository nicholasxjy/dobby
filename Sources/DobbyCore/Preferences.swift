import Foundation

/// Which readouts appear next to the menu bar icon.
public struct MenuBarItems: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let cpu = MenuBarItems(rawValue: 1 << 0)
    public static let memory = MenuBarItems(rawValue: 1 << 1)
    public static let ports = MenuBarItems(rawValue: 1 << 2)
    public static let all: MenuBarItems = [.cpu, .memory, .ports]
}

/// How often the open panel samples processes and the graphs take a point.
public enum RefreshInterval: Int, CaseIterable, Sendable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    public var seconds: Int { rawValue }
}

/// Settings beyond appearance, menu bar stats and launch at login, each with its own default.
public struct PreferencesStore {
    public static let menuBarItemsKey = "menuBarItems"
    public static let flagsNewNetworkPortsKey = "flagNewNetworkPorts"
    public static let refreshIntervalKey = "refreshInterval"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var menuBarItems: MenuBarItems {
        get {
            guard defaults.object(forKey: Self.menuBarItemsKey) != nil else { return .all }
            return MenuBarItems(rawValue: defaults.integer(forKey: Self.menuBarItemsKey)).intersection(.all)
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.menuBarItemsKey) }
    }

    public var flagsNewNetworkPorts: Bool {
        get { defaults.bool(forKey: Self.flagsNewNetworkPortsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.flagsNewNetworkPortsKey) }
    }

    public var refreshInterval: RefreshInterval {
        get { RefreshInterval(rawValue: defaults.integer(forKey: Self.refreshIntervalKey)) ?? .twoSeconds }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.refreshIntervalKey) }
    }
}
