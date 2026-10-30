import SwiftUI

enum PKGTheme {
    private static var selectedTheme: String { UserDefaults.standard.string(forKey: "appTheme") ?? "charcoal" }

    static var background: Color {
        switch selectedTheme {
        case "black": return .black
        case "navy": return Color(red: 8/255, green: 16/255, blue: 30/255)
        case "light", "system": return Color(.systemBackground)
        default: return Color(red: 8/255, green: 16/255, blue: 30/255)
        }
    }

    static var surface: Color {
        switch selectedTheme {
        case "black": return Color(red: 18/255, green: 18/255, blue: 20/255)
        case "navy": return Color(red: 15/255, green: 27/255, blue: 45/255)
        case "light", "system": return Color(.secondarySystemGroupedBackground)
        default: return Color(red: 22/255, green: 28/255, blue: 38/255)
        }
    }

    static var elevatedSurface: Color {
        switch selectedTheme {
        case "black": return Color(red: 28/255, green: 28/255, blue: 31/255)
        case "navy": return Color(red: 22/255, green: 38/255, blue: 61/255)
        case "light", "system": return Color(.tertiarySystemGroupedBackground)
        default: return Color(red: 31/255, green: 39/255, blue: 52/255)
        }
    }

    static var preferredColorScheme: ColorScheme? {
        switch selectedTheme {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }
}
