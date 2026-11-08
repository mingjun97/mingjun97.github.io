import Foundation

// The data model mirrors the web app's `cashline.v1` localStorage JSON, so a
// backup exported from the web version imports here unchanged (and vice
// versa). Fields added for the native app — like `link` — are optional and
// ignored by the web app.

/// Rounds to whole cents, the way every amount in the web app is stored.
@inlinable public func cents(_ x: Double) -> Double { (x * 100).rounded() / 100 }

/// Where a record came from when it was created by a bank sync rather than
/// typed in. `nil` on a record means it is manual.
public struct ExternalLink: Codable, Hashable, Sendable {
    /// e.g. "plaid"
    public var provider: String
    /// The provider's connection (Plaid "item") this record belongs to.
    public var itemId: String
    /// The provider's id for the account / liability / recurring stream.
    public var externalId: String
    public var institution: String?
    public var mask: String?
    public var lastSynced: Date?
    /// When the bank reported the synced balance (nil = unknown).
    public var balanceAsOf: Date?
    /// True when the balance was read live from the bank rather than a cached copy.
    public var balanceIsLive: Bool?

    public init(provider: String, itemId: String, externalId: String, institution: String? = nil, mask: String? = nil,
                lastSynced: Date? = nil, balanceAsOf: Date? = nil, balanceIsLive: Bool? = nil) {
        self.provider = provider; self.itemId = itemId; self.externalId = externalId
        self.institution = institution; self.mask = mask; self.lastSynced = lastSynced
        self.balanceAsOf = balanceAsOf; self.balanceIsLive = balanceIsLive
    }
}

// MARK: - Account

/// A checking account that bills are paid from and deposits land in.
public struct Account: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var balance: Double
    public var link: ExternalLink?

    public init(id: String = newID(), name: String, balance: Double, link: ExternalLink? = nil) {
        self.id = id; self.name = name; self.balance = balance; self.link = link
    }
}

// MARK: - Bill

public enum BillKind: String, Codable, Sendable, CaseIterable {
    case card, utility

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BillKind(rawValue: raw) ?? .utility
    }
}

public enum AutopayMode: String, Codable, Sendable, CaseIterable {
    /// Pays the statement balance.
    case full
    /// Pays `autopayAmount` every cycle regardless of the statement.
    case fixed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AutopayMode(rawValue: raw) ?? .full
    }
}

/// A monthly obligation: a credit card or a utility / other bill.
public struct Bill: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: BillKind
    /// Current statement amount due.
    public var amount: Double
    /// Day of month it's due (1...31, clamped to short months).
    public var dueDay: Int
    /// The checking account it's paid from.
    public var accountId: String?
    public var autopay: Bool
    public var autopayMode: AutopayMode
    public var autopayAmount: Double
    /// `yyyy-MM` of the latest cycle that's been paid.
    public var lastPaidCycle: String?
    /// Charges posted to the next statement; folds into `amount` once the
    /// current due date passes.
    public var pending: Double
    /// `yyyy-MM` of the latest due date whose pending charges were folded in.
    public var lastRolledCycle: String?
    /// An id from `BillIcon`; nil = suggest from the name.
    public var icon: String?
    public var link: ExternalLink?

    public init(id: String = newID(), name: String, kind: BillKind, amount: Double, dueDay: Int,
                accountId: String?, autopay: Bool, autopayMode: AutopayMode = .full, autopayAmount: Double = 0,
                lastPaidCycle: String? = nil, pending: Double = 0, lastRolledCycle: String? = nil,
                icon: String? = nil, link: ExternalLink? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.amount = amount; self.dueDay = dueDay
        self.accountId = accountId; self.autopay = autopay; self.autopayMode = autopayMode
        self.autopayAmount = autopayAmount; self.lastPaidCycle = lastPaidCycle; self.pending = pending
        self.lastRolledCycle = lastRolledCycle; self.icon = icon; self.link = link
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, amount, dueDay, accountId, autopay, autopayMode, autopayAmount
        case lastPaidCycle, pending, lastRolledCycle, icon, link
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? newID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Bill"
        kind = try c.decodeIfPresent(BillKind.self, forKey: .kind) ?? .utility
        amount = c.lenientDouble(.amount) ?? 0
        dueDay = min(31, max(1, c.lenientInt(.dueDay) ?? 1))
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        autopay = try c.decodeIfPresent(Bool.self, forKey: .autopay) ?? false
        autopayMode = try c.decodeIfPresent(AutopayMode.self, forKey: .autopayMode) ?? .full
        autopayAmount = c.lenientDouble(.autopayAmount) ?? 0
        lastPaidCycle = try c.decodeIfPresent(String.self, forKey: .lastPaidCycle)
        pending = c.lenientDouble(.pending) ?? 0
        lastRolledCycle = try c.decodeIfPresent(String.self, forKey: .lastRolledCycle)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        link = try c.decodeIfPresent(ExternalLink.self, forKey: .link)
    }

    /// What autopay drafts each cycle.
    public var autopayDraft: Double { autopay && autopayMode == .fixed ? autopayAmount : amount }
    /// What actually leaves the account for this bill's next occurrence.
    public var outflow: Double { autopay ? autopayDraft : amount }
    public var iconID: String { icon.flatMap { BillIcon.all[$0] != nil ? $0 : nil } ?? BillIcon.suggest(name: name, kind: kind) }
}

// MARK: - Deposit

public enum DepositType: String, Codable, Sendable { case oneoff, payroll }

public enum Cadence: String, Codable, Sendable, CaseIterable {
    case weekly, biweekly, semimonthly, monthly

    public var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .semimonthly: return "Twice a month"
        case .monthly: return "Monthly"
        }
    }
}

/// Expected incoming money: a one-time payout or recurring payroll.
public struct Deposit: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var amount: Double
    public var accountId: String?
    public var type: DepositType
    /// One-off: expected date (`yyyy-MM-dd`).
    public var date: String?
    /// Payroll cadence.
    public var cadence: Cadence?
    /// Weekly / biweekly: any real payday (`yyyy-MM-dd`), used as the anchor.
    public var anchor: String?
    /// Monthly: the day. Semimonthly: the first payday.
    public var day1: Int?
    /// Semimonthly: the second payday (31 = last day of month).
    public var day2: Int?
    public var link: ExternalLink?

    public init(id: String = newID(), name: String, amount: Double, accountId: String?, type: DepositType,
                date: String? = nil, cadence: Cadence? = nil, anchor: String? = nil,
                day1: Int? = nil, day2: Int? = nil, link: ExternalLink? = nil) {
        self.id = id; self.name = name; self.amount = amount; self.accountId = accountId; self.type = type
        self.date = date; self.cadence = cadence; self.anchor = anchor; self.day1 = day1; self.day2 = day2
        self.link = link
    }

    enum CodingKeys: String, CodingKey { case id, name, amount, accountId, type, date, cadence, anchor, day1, day2, link }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? newID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Deposit"
        amount = c.lenientDouble(.amount) ?? 0
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        type = (try? c.decodeIfPresent(DepositType.self, forKey: .type)) ?? .oneoff
        date = try c.decodeIfPresent(String.self, forKey: .date)
        cadence = try? c.decodeIfPresent(Cadence.self, forKey: .cadence)
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor)
        day1 = c.lenientInt(.day1)
        day2 = c.lenientInt(.day2)
        link = try c.decodeIfPresent(ExternalLink.self, forKey: .link)
    }
}

// MARK: - Payments

/// A payment that has been recorded (history).
public struct Payment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var billId: String
    public var name: String
    public var amount: Double
    public var date: String
    public var accountId: String?
    public var cycle: String
    public var wasScheduled: Bool?

    public init(id: String = newID(), billId: String, name: String, amount: Double, date: String,
                accountId: String?, cycle: String, wasScheduled: Bool? = nil) {
        self.id = id; self.billId = billId; self.name = name; self.amount = amount; self.date = date
        self.accountId = accountId; self.cycle = cycle; self.wasScheduled = wasScheduled
    }
}

/// A payment held until a future date. It covers its bill's cycle right away
/// but only debits the account when the date arrives.
public struct ScheduledPayment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var billId: String
    public var name: String
    public var amount: Double
    public var date: String
    public var accountId: String?
    public var cycle: String

    public init(id: String = newID(), billId: String, name: String, amount: Double, date: String, accountId: String?, cycle: String) {
        self.id = id; self.billId = billId; self.name = name; self.amount = amount; self.date = date
        self.accountId = accountId; self.cycle = cycle
    }

    public var day: Day? { Day(iso: date) }
}

// MARK: - Settings & state

public struct Settings: Codable, Hashable, Sendable {
    /// Manual-pay bills raise an alert this many days ahead.
    public var leadDays: Int = 5
    /// Local notifications for reminders (key kept as `browserNotif` for web compatibility).
    public var notificationsEnabled: Bool = false
    /// Adjust account balances when a bill is paid or a deposit received.
    public var deductOnPaid: Bool = true
    /// Web-only (Drive backup timestamp, ms). Preserved round-trip.
    public var lastDriveBackup: Double?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case leadDays, notificationsEnabled = "browserNotif", deductOnPaid, lastDriveBackup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leadDays = min(30, max(0, c.lenientInt(.leadDays) ?? 5))
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        deductOnPaid = try c.decodeIfPresent(Bool.self, forKey: .deductOnPaid) ?? true
        lastDriveBackup = c.lenientDouble(.lastDriveBackup)
    }
}

/// Everything Cashline stores.
public struct AppState: Codable, Hashable, Sendable {
    public var accounts: [Account] = []
    public var bills: [Bill] = []
    public var deposits: [Deposit] = []
    public var payments: [Payment] = []
    public var scheduled: [ScheduledPayment] = []
    public var settings = Settings()
    /// Web-only notification bookkeeping. Preserved round-trip.
    public var notified: [String: Double] = [:]
    /// Bank connections from the last sync (native app only).
    public var linkedItems: [LinkedItem] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case accounts, bills, deposits, payments, scheduled, settings, notified, linkedItems }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        bills = try c.decodeIfPresent([Bill].self, forKey: .bills) ?? []
        deposits = try c.decodeIfPresent([Deposit].self, forKey: .deposits) ?? []
        payments = try c.decodeIfPresent([Payment].self, forKey: .payments) ?? []
        scheduled = try c.decodeIfPresent([ScheduledPayment].self, forKey: .scheduled) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        notified = (try? c.decodeIfPresent([String: Double].self, forKey: .notified)) ?? [:]
        linkedItems = (try? c.decodeIfPresent([LinkedItem].self, forKey: .linkedItems)) ?? []
    }

    public var isEmpty: Bool { accounts.isEmpty && bills.isEmpty && deposits.isEmpty }

    public func account(_ id: String?) -> Account? { id.flatMap { id in accounts.first { $0.id == id } } }
    public func accountName(_ id: String?) -> String { account(id)?.name ?? "No account" }
    public func bill(_ id: String?) -> Bill? { id.flatMap { id in bills.first { $0.id == id } } }
}

public func newID() -> String { UUID().uuidString.lowercased() }

// The web app stores numbers loosely (an input's value can end up as a
// string), so decode amounts and days from either form.
extension KeyedDecodingContainer {
    func lenientDouble(_ key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }
}
