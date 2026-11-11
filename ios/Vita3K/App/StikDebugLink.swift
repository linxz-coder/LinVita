import Foundation

enum StikDebugLink {
    /// Use the installed bundle ID: sideload signing can add a team suffix.
    static func enableJITURL(bundleIdentifier: String?) -> URL? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleIdentifier),
            URLQueryItem(name: "script-name", value: "universal.js")
        ]
        return components.url
    }
}
