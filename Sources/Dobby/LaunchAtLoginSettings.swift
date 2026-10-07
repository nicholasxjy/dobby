import DobbyCore
import Observation
import ServiceManagement

/// The Launch at Login toggle. Only works from the bundled Dobby.app; under `swift run` registering fails with a notice.
@MainActor
@Observable
final class LaunchAtLoginSettings {
    static let shared = LaunchAtLoginSettings()

    private(set) var state: LaunchAtLoginState
    @ObservationIgnored private let launchAtLogin = LaunchAtLogin()

    private init() {
        state = launchAtLogin.state
    }

    /// Re-reads the state, since it can also be changed in System Settings while Dobby runs.
    func refresh() {
        state = launchAtLogin.state
    }

    /// Applies the toggle and returns a notice worth showing, if any.
    func setEnabled(_ enabled: Bool) -> (text: String, isError: Bool)? {
        do {
            state = try launchAtLogin.setEnabled(enabled)
        } catch {
            refresh()
            return ("Couldn't turn \(enabled ? "on" : "off") launch at login (\(error.localizedDescription))", true)
        }
        guard state == .needsApproval else { return nil }
        SMAppService.openSystemSettingsLoginItems()
        return ("Allow Dobby in System Settings › General › Login Items", false)
    }
}
