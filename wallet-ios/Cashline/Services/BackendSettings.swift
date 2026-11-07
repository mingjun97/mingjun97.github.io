import Foundation
import Security

/// How the app reaches a server for bank connections. Device-level settings,
/// kept in UserDefaults rather than in the (exportable) app state.
struct BackendSettings: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        /// No bank connections; everything is entered by hand (like the web app).
        case off
        /// Built-in fake bank, for trying the flow without a server.
        case demo
        /// A real Cashline backend (see docs/BACKEND.md).
        case server

        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .demo: return "Demo bank"
            case .server: return "Cashline server"
            }
        }
    }

    var mode: Mode = .off
    var serverURL: String = ""
    var lastSync: Date?

    private static let key = "cashline.backend"

    static func load() -> BackendSettings {
        let d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var s = BackendSettings()
        s.mode = (d["mode"] as? String).flatMap(Mode.init(rawValue:)) ?? .off
        s.serverURL = d["serverURL"] as? String ?? ""
        s.lastSync = d["lastSync"] as? Date
        return s
    }

    func save() {
        var d: [String: Any] = ["mode": mode.rawValue, "serverURL": serverURL]
        if let lastSync { d["lastSync"] = lastSync }
        UserDefaults.standard.set(d, forKey: Self.key)
    }
}

/// Holds the token that identifies this user to the Cashline server, in the
/// Keychain. How the token is obtained (Sign in with Apple, email link, …) is
/// up to the backend; call `set(_:)` once signed in.
actor AuthTokenStore {
    static let shared = AuthTokenStore()
    private let service = "cashline.backend.token"

    func token() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ token: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let token else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
