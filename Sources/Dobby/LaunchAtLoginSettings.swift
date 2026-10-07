import DobbyCore
import Observation
import ServiceManagement

/// The 开机启动 toggle. Only works from the bundled Dobby.app; under `swift run` registering fails with a notice.
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
            return ("无法\(enabled ? "开启" : "关闭")开机启动（\(error.localizedDescription)）", true)
        }
        guard state == .needsApproval else { return nil }
        SMAppService.openSystemSettingsLoginItems()
        return ("请在「系统设置 › 通用 › 登录项」中允许 Dobby", false)
    }
}
