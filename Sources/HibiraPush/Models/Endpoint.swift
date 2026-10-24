import Foundation

/// The base URL the SDK sends device and reporting requests to.
///
/// Resolved in this order: `PushNotifications.shared.setEndpoint(_:)`,
/// the `HibiraPushEndpoint` key in the app's Info.plist (or its pre-rename
/// name `HikibiPushEndpoint`), then `defaultURL`.
struct Endpoint {
    static let defaultURL = "https://ws.hibira.io"
    static let infoPlistKey = "HibiraPushEndpoint"
    static let legacyInfoPlistKey = "HikibiPushEndpoint"

    private static let queue = DispatchQueue(label: "io.hibira.push.endpointQueue")
    private static var override: String?

    static var current: String {
        if let value = queue.sync(execute: { override }) {
            return value
        }
        for key in [infoPlistKey, legacyInfoPlistKey] {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               let normalized = normalize(value) {
                return normalized
            }
        }
        return defaultURL
    }

    static func set(_ endpoint: String?) {
        let normalized = endpoint.flatMap(normalize)
        queue.sync { override = normalized }
    }

    /// Trims whitespace and trailing slashes; returns nil for an empty value.
    static func normalize(_ endpoint: String) -> String? {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }
}
