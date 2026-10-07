import AppKit
import DobbyCore
import Observation

/// The app-wide appearance. Applied through NSApp.appearance so the menu bar panel's material follows it too.
@MainActor
@Observable
final class ThemeSettings {
    static let shared = ThemeSettings()

    var theme: AppTheme {
        didSet {
            if persists { store.theme = theme }
            apply()
        }
    }
    /// Off for snapshot rendering, so previews don't overwrite the user's choice.
    @ObservationIgnored var persists = true
    @ObservationIgnored private let store = ThemeStore()

    private init() {
        theme = store.theme
    }

    func apply() {
        NSApp?.appearance = theme.appearance
    }
}

extension AppTheme {
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
