import Foundation

/// Somewhere to keep the app state. The app uses `JSONFileStore`; a future
/// backend-synced store can conform to the same protocol.
public protocol StateStore: Sendable {
    func load() throws -> AppState?
    func save(_ state: AppState) throws
}

/// Stores the state as one JSON file — the same shape as a web-app backup.
public struct JSONFileStore: StateStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `Application Support/Cashline/cashline.v1.json`
    public static func appDefault() throws -> JSONFileStore {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Cashline", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return JSONFileStore(url: dir.appendingPathComponent("cashline.v1.json"))
    }

    public func load() throws -> AppState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Backup.decode(Data(contentsOf: url))
    }

    public func save(_ state: AppState) throws {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try Backup.encode(state).write(to: url, options: options)
    }
}

/// In-memory store for previews and tests.
public final class MemoryStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppState?
    public init(_ state: AppState? = nil) { value = state }
    public func load() throws -> AppState? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ state: AppState) throws { lock.lock(); value = state; lock.unlock() }
}

/// Backup files, compatible with the web app's Export / Import.
public enum Backup {
    public enum BackupError: LocalizedError {
        case notABackup
        public var errorDescription: String? { "That file isn't a Cashline backup." }
    }

    public static func encode(_ state: AppState) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(state)
    }

    public static func decode(_ data: Data) throws -> AppState {
        // A backup must at least carry accounts and bills arrays.
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["accounts"] is [Any], obj["bills"] is [Any] else { throw BackupError.notABackup }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(AppState.self, from: data)
    }

    /// `cashline-backup-20261107-1430.json`
    public static func filename(now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        return String(format: "cashline-backup-%04d%02d%02d-%02d%02d.json", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }
}

extension AppState {
    /// Example accounts, bills and deposits to explore the app with.
    public static func sample(today t: Day) -> AppState {
        var s = AppState()
        let day = { (off: Int) in t.adding(days: off).day }
        let a1 = Account(name: "Chase Checking …4821", balance: 2350)
        let a2 = Account(name: "BofA Checking …1177", balance: 640)
        s.accounts = [a1, a2]

        func mk(_ name: String, _ kind: BillKind, _ amount: Double, _ dueDay: Int, _ acct: String, _ autopay: Bool,
                _ mode: AutopayMode = .full, _ apAmount: Double = 0) -> Bill {
            Bill(name: name, kind: kind, amount: amount, dueDay: dueDay, accountId: acct, autopay: autopay,
                 autopayMode: mode, autopayAmount: apAmount, lastPaidCycle: Engine.initialPaidCycle(dueDay: dueDay, today: t))
        }
        s.bills = [
            mk("Chase Sapphire", .card, 812.44, day(3), a1.id, true, .fixed, 250),
            mk("Amex Blue Cash", .card, 1240.10, day(9), a2.id, false),
            mk("Citi Double Cash", .card, 96.20, day(15), a1.id, true),
            mk("Discover it", .card, 430.00, day(21), a2.id, false),
            mk("PG&E Electric", .utility, 145.67, day(6), a1.id, true),
            mk("Water & Sewer", .utility, 78.30, day(12), a1.id, false),
            mk("Internet — Xfinity", .utility, 65.00, day(26), a2.id, true),
        ]
        // one bill starts overdue (2 days ago, unpaid) to show how alerts look
        let od = t.adding(days: -2)
        let prev = Day.clamped(year: od.year, monthIndex: od.monthIndex - 1, day: od.day)
        s.bills.append(Bill(name: "City Trash Service", kind: .utility, amount: 42.50, dueDay: od.day,
                            accountId: a1.id, autopay: false, lastPaidCycle: prev.cycleKey))
        s.deposits = [
            Deposit(name: "Payroll — Acme Corp", amount: 2150, accountId: a1.id, type: .payroll,
                    cadence: .biweekly, anchor: t.adding(days: 4).iso),
            Deposit(name: "eBay sale payout", amount: 310, accountId: a2.id, type: .oneoff, date: t.adding(days: 8).iso),
        ]
        let e = Engine(state: s, today: t)
        for i in s.bills.indices { s.bills[i].lastRolledCycle = e.lastPassedDueKey(s.bills[i]) }
        if let i = s.bills.firstIndex(where: { $0.name == "Citi Double Cash" }) { s.bills[i].pending = 58.40 }
        if let disc = s.bills.first(where: { $0.name == "Discover it" }) {
            let due = Engine(state: s, today: t).nextDue(disc)
            s.scheduled = [ScheduledPayment(billId: disc.id, name: disc.name, amount: disc.amount,
                                            date: t.adding(days: 5).iso, accountId: disc.accountId, cycle: due.key)]
        }
        return s
    }
}
