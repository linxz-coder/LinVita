import Foundation

@main
struct StikDebugLinkTests {
    static func main() {
        precondition(StikDebugLink.enableJITURL(bundleIdentifier: nil) == nil)
        precondition(StikDebugLink.enableJITURL(bundleIdentifier: "") == nil)
        for identifier in [
            "online.linxz.LinVita",
            "online.linxz.LinVita.TESTTEAM01",
            "test.bundle&script-name=wrong.js"
        ] {
            guard let url = StikDebugLink.enableJITURL(bundleIdentifier: identifier),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let items = parts.queryItems else {
                fatalError("Missing JIT URL")
            }
            precondition(parts.scheme == "stikdebug" && parts.host == "enable-jit")
            precondition(items.count == 2)
            precondition(items.first { $0.name == "bundle-id" }?.value == identifier)
            precondition(items.first { $0.name == "script-name" }?.value == "universal.js")
        }
        print("StikDebug URL tests passed: signed bundle ID, Universal selection, escaping, missing ID")
    }
}
