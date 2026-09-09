import Foundation

/// Shared localization for SwiftUI, AppKit, and core errors.
/// Bundle selection follows macOS language preferences, including per-app overrides.
public enum L10n {
    // Packaged apps store resources in Contents/Resources. SwiftPM's generated
    // accessor may instead look beside the executable or in the build directory.
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "DevWatch_DevWatchCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    public static func text(_ key: String, _ arguments: String...) -> String {
        text(key, arguments: arguments, bundle: resourceBundle)
    }

    static func text(_ key: String, arguments: [String], bundle: Bundle) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
