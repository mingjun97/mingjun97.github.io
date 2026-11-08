import XCTest
@testable import CashlineCore

/// Talks to a running wallet-server (started with `node scripts/dev-fake.ts`)
/// to check the app and server agree on the JSON contract. Skipped unless
/// CASHLINE_TEST_SERVER is set, e.g. CASHLINE_TEST_SERVER=http://127.0.0.1:8787
final class ServerContractTests: XCTestCase {
    func testFullFlowAgainstServer() async throws {
        guard let raw = ProcessInfo.processInfo.environment["CASHLINE_TEST_SERVER"], let base = URL(string: raw) else {
            throw XCTSkip("CASHLINE_TEST_SERVER not set")
        }
        let api = HTTPCashlineBackend(baseURL: base, authToken: { "dev-token-0123456789abcdef0123" })
        let linkToken = try await api.createLinkToken(updateItemId: nil)
        XCTAssertFalse(linkToken.isEmpty)
        let item = try await api.exchangePublicToken("public-sandbox-ok", institutionName: "First Platypus Bank")
        XCTAssertEqual(item.institutionName, "First Platypus Bank")

        let cached = try await api.fetchSnapshot(liveBalances: false)
        XCTAssertEqual(cached.accounts.first { $0.type == .depository }?.availableBalance, 100)
        XCTAssertFalse(cached.accounts.first { $0.type == .depository }!.isLiveBalance)

        let live = try await api.fetchSnapshot(liveBalances: true)
        let chk = try XCTUnwrap(live.accounts.first { $0.type == .depository })
        XCTAssertTrue(chk.isLiveBalance)
        XCTAssertEqual(chk.availableBalance, 1234.56)
        XCTAssertNotNil(chk.balanceUpdatedAt)
        XCTAssertEqual(live.creditLiabilities.first?.nextPaymentDueDate?.iso, "2026-11-20")
        XCTAssertEqual(live.recurringInflows.first?.frequency, .biweekly)

        var state = AppState()
        let report = SyncMerger.merge(live, into: &state, today: Day(iso: "2026-11-08")!)
        XCTAssertEqual(report.accountsAdded, 1)
        XCTAssertEqual(state.accounts[0].balance, 1234.56)
        XCTAssertEqual(state.accounts[0].link?.balanceIsLive, true)

        do {
            _ = try await HTTPCashlineBackend(baseURL: base, authToken: { "wrong-token-wrong-token-wrong" }).fetchSnapshot(liveBalances: false)
            XCTFail("expected 401")
        } catch let BackendError.http(status, message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "Missing or invalid access token.")
        }
        try await api.removeItem(id: item.id)
        let after = try await api.fetchSnapshot(liveBalances: false)
        XCTAssertTrue(after.items.isEmpty)
    }
}
