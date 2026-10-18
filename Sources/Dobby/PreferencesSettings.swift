import DobbyCore
import Observation

/// Menu bar items, new-network-port flagging and the refresh interval, persisted as they change.
@MainActor
@Observable
final class PreferencesSettings {
    static let shared = PreferencesSettings()

    var menuBarItems: MenuBarItems {
        didSet { store.menuBarItems = menuBarItems }
    }
    var flagsNewNetworkPorts: Bool {
        didSet { store.flagsNewNetworkPorts = flagsNewNetworkPorts }
    }
    var refreshInterval: RefreshInterval {
        didSet { store.refreshInterval = refreshInterval }
    }
    @ObservationIgnored private let store = PreferencesStore()

    private init() {
        menuBarItems = store.menuBarItems
        flagsNewNetworkPorts = store.flagsNewNetworkPorts
        refreshInterval = store.refreshInterval
    }
}
