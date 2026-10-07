import ServiceManagement
import Testing
@testable import DobbyCore

/// Stands in for SMAppService.mainApp, which only works from an installed app bundle.
private final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status
    /// What a successful register() leaves behind; macOS may hold new items for approval.
    var statusAfterRegister: SMAppService.Status = .enabled
    var error: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let error { throw error }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCalls += 1
        if let error { throw error }
        status = .notRegistered
    }
}

private struct Failure: Error {}

@Suite struct LaunchAtLoginTests {
    @Test func mapsServiceStatus() {
        #expect(LaunchAtLogin(service: FakeLoginItem(status: .notRegistered)).state == .off)
        #expect(LaunchAtLogin(service: FakeLoginItem(status: .notFound)).state == .off)
        #expect(LaunchAtLogin(service: FakeLoginItem(status: .enabled)).state == .on)
        #expect(LaunchAtLogin(service: FakeLoginItem(status: .requiresApproval)).state == .needsApproval)
    }

    @Test func enablingRegisters() throws {
        let service = FakeLoginItem(status: .notRegistered)
        #expect(try LaunchAtLogin(service: service).setEnabled(true) == .on)
        #expect(service.registerCalls == 1)
    }

    @Test func enablingReportsPendingApproval() throws {
        let service = FakeLoginItem(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        #expect(try LaunchAtLogin(service: service).setEnabled(true) == .needsApproval)
    }

    @Test func disablingUnregistersEvenWhilePendingApproval() throws {
        let service = FakeLoginItem(status: .requiresApproval)
        #expect(try LaunchAtLogin(service: service).setEnabled(false) == .off)
        #expect(service.unregisterCalls == 1)
    }

    @Test func doesNothingWhenAlreadyInTheRequestedState() throws {
        let on = FakeLoginItem(status: .enabled)
        #expect(try LaunchAtLogin(service: on).setEnabled(true) == .on)
        let off = FakeLoginItem(status: .notRegistered)
        #expect(try LaunchAtLogin(service: off).setEnabled(false) == .off)
        #expect(on.registerCalls + off.unregisterCalls == 0)
    }

    @Test func propagatesServiceErrors() {
        let service = FakeLoginItem(status: .notRegistered)
        service.error = Failure()
        #expect(throws: Failure.self) { try LaunchAtLogin(service: service).setEnabled(true) }
        #expect(LaunchAtLogin(service: service).state == .off)
    }
}
