import UIKit
#if canImport(LinkKit)
import LinkKit
#endif

struct PlaidLinkResult {
    var publicToken: String
    var institutionName: String?
}

enum PlaidLinkError: LocalizedError {
    case sdkMissing
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .sdkMissing:
            return "Plaid Link isn't part of this build yet. Add the LinkKit package (see wallet-ios/README.md) or use Demo bank in Settings."
        case let .couldNotStart(why):
            return "Couldn't open Plaid Link: \(why)"
        }
    }
}

/// Presents Plaid Link and returns the public token to hand to the backend.
///
/// The Plaid SDK is optional: add the `LinkKit` Swift package
/// (https://github.com/plaid/plaid-link-ios-spm) to the app target and this
/// file switches to the real flow automatically. Without it, only the Demo
/// bank works.
@MainActor
enum PlaidLinkPresenter {
    #if canImport(LinkKit)
    /// Plaid's handler must stay alive while Link is on screen.
    private static var handler: Handler?
    #endif

    /// Returns nil when the person closes Link without connecting.
    static func open(linkToken: String) async throws -> PlaidLinkResult? {
        #if canImport(LinkKit)
        guard let presenter = topViewController() else { throw PlaidLinkError.couldNotStart("no window") }
        return try await withCheckedThrowingContinuation { cont in
            var config = LinkTokenConfiguration(token: linkToken) { success in
                cont.resume(returning: PlaidLinkResult(publicToken: success.publicToken,
                                                       institutionName: success.metadata.institution.name))
                handler = nil
            }
            config.onExit = { exit in
                if let error = exit.error {
                    cont.resume(throwing: PlaidLinkError.couldNotStart(error.localizedDescription))
                } else {
                    cont.resume(returning: nil)
                }
                handler = nil
            }
            switch Plaid.create(config) {
            case let .success(h):
                handler = h
                h.open(presentUsing: .viewController(presenter))
            case let .failure(error):
                cont.resume(throwing: PlaidLinkError.couldNotStart(error.localizedDescription))
            }
        }
        #else
        throw PlaidLinkError.sdkMissing
        #endif
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
