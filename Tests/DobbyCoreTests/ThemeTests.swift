import Foundation
import Testing
@testable import DobbyCore

@Suite struct ThemeStoreTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "dobby.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func defaultsToFollowingTheSystem() {
        withDefaults { #expect(ThemeStore(defaults: $0).theme == .system) }
    }

    @Test func persistsTheChosenTheme() {
        withDefaults { defaults in
            ThemeStore(defaults: defaults).theme = .dark
            #expect(ThemeStore(defaults: defaults).theme == .dark)
            ThemeStore(defaults: defaults).theme = .light
            #expect(ThemeStore(defaults: defaults).theme == .light)
        }
    }

    @Test func unknownStoredValueFallsBackToSystem() {
        withDefaults { defaults in
            defaults.set("sepia", forKey: ThemeStore.key)
            #expect(ThemeStore(defaults: defaults).theme == .system)
        }
    }
}
