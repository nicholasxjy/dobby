import ServiceManagement

/// The part of SMAppService that launch-at-login needs, so it can be faked in tests.
public protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

public enum LaunchAtLoginState: Equatable, Sendable {
    case off, on
    /// Registered, but the user still has to allow it in System Settings › General › Login Items.
    case needsApproval
}

/// Starts Dobby at login via the main app's login item. macOS owns the setting (the user can also change it
/// in System Settings), so the state is always read back from the service rather than stored.
public struct LaunchAtLogin {
    private let service: LoginItemService

    public init(service: LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    public var state: LaunchAtLoginState {
        switch service.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    /// Registers or unregisters the login item and returns the resulting state.
    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginState {
        if enabled, state == .off {
            try service.register()
        } else if !enabled, state != .off {
            try service.unregister()
        }
        return state
    }
}
