import Foundation
import Observation
import SwiftUI

/// How the app itself should be lit. Separate from the terminal theme slots
/// (`TerminalThemeSettings`), which pick a palette *per* appearance — this
/// picks which appearance is in force in the first place.
enum AppAppearanceOption: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// nil hands the decision back to iOS, which is the default.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// AirBuild's ten accent choices, persisted as their hex value by `@AppStorage`.
enum AppAccentColor: String, CaseIterable, Identifiable, Sendable {
    static let defaultsKey = "app-accent-color"
    static let defaultRawValue = "#3b9bff"

    case blue = "#3b9bff"
    case purple = "#bf5af2"
    case pink = "#ff375f"
    case red = "#ff453a"
    case orange = "#ff9f0a"
    case yellow = "#d4a20a"
    case green = "#30d158"
    case cyan = "#40c8e0"
    case indigo = "#5e5ce6"
    case gray = "#48484a"

    var id: String { rawValue }
    var color: Color { Self.color(for: rawValue) }

    static func color(for rawValue: String) -> Color {
        let value = UInt64(rawValue.dropFirst(), radix: 16) ?? 0x3b9bff
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }
}

/// The app-wide light/dark override, applied once at the root view. Everything
/// downstream — including the terminal surfaces, which resolve their theme
/// against `\.colorScheme` — follows from that single `preferredColorScheme`.
@MainActor
@Observable
final class AppAppearanceSettings {
    private static let defaultsKey = "app-appearance"

    private(set) var selection: AppAppearanceOption
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(AppAppearanceOption.init(rawValue:)) ?? .system
    }

    var preferredColorScheme: ColorScheme? { selection.preferredColorScheme }

    func select(_ option: AppAppearanceOption) {
        guard option != selection else { return }
        selection = option
        defaults.set(option.rawValue, forKey: Self.defaultsKey)
    }
}
