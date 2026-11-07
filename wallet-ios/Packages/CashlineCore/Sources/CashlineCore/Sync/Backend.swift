import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Cashline server. Plaid's secret and access tokens must never live on
/// the phone, so the app talks to this backend, which talks to Plaid.
///
/// Flow for linking a bank:
/// 1. `createLinkToken()` → open Plaid Link on the device with it.
/// 2. Link returns a `public_token` → `exchangePublicToken(...)`; the server
///    swaps it for an access token and stores it.
/// 3. `fetchSnapshot()` whenever the app wants fresh data; merge it with
///    `SyncMerger`.
public protocol CashlineBackend: Sendable {
    func createLinkToken(updateItemId: String?) async throws -> String
    func exchangePublicToken(_ publicToken: String, institutionName: String?) async throws -> LinkedItem
    func fetchSnapshot() async throws -> SyncSnapshot
    func removeItem(id: String) async throws
}

public enum BackendError: LocalizedError, Equatable {
    case notConfigured
    case http(status: Int, message: String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "No server is set up for bank connections."
        case let .http(status, message): return message ?? "The server returned an error (\(status))."
        case .invalidResponse: return "The server sent something unexpected."
        }
    }
}

/// Talks to the REST API described in docs/BACKEND.md.
public struct HTTPCashlineBackend: CashlineBackend {
    public var baseURL: URL
    /// Returns the bearer token identifying the user (e.g. from Sign in with Apple
    /// exchanged with your server). nil sends no Authorization header.
    public var authToken: @Sendable () async -> String?
    var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared, authToken: @escaping @Sendable () async -> String? = { nil }) {
        self.baseURL = baseURL; self.session = session; self.authToken = authToken
    }

    public func createLinkToken(updateItemId: String?) async throws -> String {
        struct Body: Encodable { var updateItemId: String?; var platform = "ios" }
        struct Reply: Decodable { var linkToken: String }
        let r: Reply = try await send("POST", "v1/plaid/link-token", body: Body(updateItemId: updateItemId))
        return r.linkToken
    }

    public func exchangePublicToken(_ publicToken: String, institutionName: String?) async throws -> LinkedItem {
        struct Body: Encodable { var publicToken: String; var institutionName: String? }
        return try await send("POST", "v1/plaid/items", body: Body(publicToken: publicToken, institutionName: institutionName))
    }

    public func fetchSnapshot() async throws -> SyncSnapshot {
        try await send("GET", "v1/sync", body: Optional<String>.none)
    }

    public func removeItem(id: String) async throws {
        let _: Empty = try await send("DELETE", "v1/plaid/items/\(id)", body: Optional<String>.none)
    }

    private struct Empty: Decodable {}
    private struct ErrorReply: Decodable { var error: String?; var message: String? }

    private func send<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B?) async throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await authToken() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            let enc = JSONEncoder()
            enc.keyEncodingStrategy = .convertToSnakeCase
            req.httpBody = try enc.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.cashlineData(for: req)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        let dec = JSONDecoder.cashlineAPI
        guard (200..<300).contains(http.statusCode) else {
            let e = try? dec.decode(ErrorReply.self, from: data)
            throw BackendError.http(status: http.statusCode, message: e?.message ?? e?.error)
        }
        if R.self == Empty.self { return Empty() as! R }
        do { return try dec.decode(R.self, from: data) } catch { throw BackendError.invalidResponse }
    }
}

extension JSONDecoder {
    /// snake_case keys, ISO-8601 timestamps, `yyyy-MM-dd` dates.
    public static var cashlineAPI: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }
}

extension URLSession {
    /// `data(for:)` that also works on Linux Foundation.
    func cashlineData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error) }
                else if let data, let response { cont.resume(returning: (data, response)) }
                else { cont.resume(throwing: BackendError.invalidResponse) }
            }.resume()
        }
    }
}
