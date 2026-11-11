import Foundation

/// Translates a user-facing string that is not shown through a SwiftUI text view
/// (alerts, status messages, window titles). English is the base language;
/// translations live in Resources/<language>.lproj/Localizable.strings.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}
