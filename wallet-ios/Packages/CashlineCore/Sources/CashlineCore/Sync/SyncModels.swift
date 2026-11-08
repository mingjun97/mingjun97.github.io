import Foundation

// Provider-neutral shapes for data pulled from a bank aggregator. They follow
// Plaid's products closely (Accounts/Balance, Liabilities, Recurring
// Transactions) but nothing here depends on Plaid, so another aggregator can
// fill them too. The Cashline backend returns a `SyncSnapshot` as JSON with
// snake_case keys — see docs/BACKEND.md.

/// One bank connection (a Plaid "item").
public struct LinkedItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var institutionName: String?
    /// e.g. "ok", "login_required" (user must re-authenticate via Link update mode).
    public var status: String
    public var lastSyncedAt: Date?

    public init(id: String, provider: String = "plaid", institutionName: String? = nil, status: String = "ok", lastSyncedAt: Date? = nil) {
        self.id = id; self.provider = provider; self.institutionName = institutionName
        self.status = status; self.lastSyncedAt = lastSyncedAt
    }

    public var needsReauth: Bool { status != "ok" }
}

public enum ExternalAccountType: String, Codable, Sendable {
    case depository, credit, loan, investment, other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExternalAccountType(rawValue: raw) ?? .other
    }
}

/// An account at the bank. Depository accounts become Cashline accounts;
/// credit accounts become credit-card bills.
public struct ExternalAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var itemId: String
    public var name: String
    public var officialName: String?
    public var mask: String?
    public var type: ExternalAccountType
    public var subtype: String?
    public var currentBalance: Double?
    public var availableBalance: Double?
    public var isoCurrencyCode: String?
    /// "realtime" when read live from the bank, "cached" for the aggregator's stored copy.
    public var balanceSource: String?
    /// When the bank reported this balance, if known.
    public var balanceUpdatedAt: Date?

    public init(id: String, itemId: String, name: String, officialName: String? = nil, mask: String? = nil,
                type: ExternalAccountType, subtype: String? = nil, currentBalance: Double? = nil,
                availableBalance: Double? = nil, isoCurrencyCode: String? = "USD",
                balanceSource: String? = nil, balanceUpdatedAt: Date? = nil) {
        self.id = id; self.itemId = itemId; self.name = name; self.officialName = officialName; self.mask = mask
        self.type = type; self.subtype = subtype; self.currentBalance = currentBalance
        self.availableBalance = availableBalance; self.isoCurrencyCode = isoCurrencyCode
        self.balanceSource = balanceSource; self.balanceUpdatedAt = balanceUpdatedAt
    }

    public var isLiveBalance: Bool { balanceSource == "realtime" }
}

/// Statement data for a credit account (Plaid Liabilities → `credit`).
public struct ExternalCreditLiability: Codable, Hashable, Sendable {
    public var accountId: String
    public var lastStatementBalance: Double?
    public var lastStatementIssueDate: Day?
    public var minimumPaymentAmount: Double?
    public var nextPaymentDueDate: Day?
    public var lastPaymentAmount: Double?
    public var lastPaymentDate: Day?
    public var isOverdue: Bool?

    public init(accountId: String, lastStatementBalance: Double? = nil, lastStatementIssueDate: Day? = nil,
                minimumPaymentAmount: Double? = nil, nextPaymentDueDate: Day? = nil,
                lastPaymentAmount: Double? = nil, lastPaymentDate: Day? = nil, isOverdue: Bool? = nil) {
        self.accountId = accountId; self.lastStatementBalance = lastStatementBalance
        self.lastStatementIssueDate = lastStatementIssueDate; self.minimumPaymentAmount = minimumPaymentAmount
        self.nextPaymentDueDate = nextPaymentDueDate; self.lastPaymentAmount = lastPaymentAmount
        self.lastPaymentDate = lastPaymentDate; self.isOverdue = isOverdue
    }
}

public enum StreamFrequency: String, Codable, Sendable {
    case weekly = "WEEKLY", biweekly = "BIWEEKLY", semiMonthly = "SEMI_MONTHLY", monthly = "MONTHLY", unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StreamFrequency(rawValue: raw.uppercased()) ?? .unknown
    }

    var cadence: Cadence? {
        switch self {
        case .weekly: return .weekly
        case .biweekly: return .biweekly
        case .semiMonthly: return .semimonthly
        case .monthly: return .monthly
        case .unknown: return nil
        }
    }
}

/// A recurring incoming stream, like payroll (Plaid Recurring Transactions → `inflow_streams`).
public struct ExternalRecurringInflow: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var accountId: String
    public var description: String
    public var merchantName: String?
    /// Positive amount per occurrence.
    public var averageAmount: Double
    public var lastAmount: Double?
    public var frequency: StreamFrequency
    public var lastDate: Day?
    public var predictedNextDate: Day?
    public var isActive: Bool

    public init(id: String, accountId: String, description: String, merchantName: String? = nil, averageAmount: Double,
                lastAmount: Double? = nil, frequency: StreamFrequency, lastDate: Day? = nil,
                predictedNextDate: Day? = nil, isActive: Bool = true) {
        self.id = id; self.accountId = accountId; self.description = description; self.merchantName = merchantName
        self.averageAmount = averageAmount; self.lastAmount = lastAmount; self.frequency = frequency
        self.lastDate = lastDate; self.predictedNextDate = predictedNextDate; self.isActive = isActive
    }
}

/// Everything the backend knows about the user's linked institutions.
public struct SyncSnapshot: Codable, Hashable, Sendable {
    public var items: [LinkedItem]
    public var accounts: [ExternalAccount]
    public var creditLiabilities: [ExternalCreditLiability]
    public var recurringInflows: [ExternalRecurringInflow]
    public var syncedAt: Date

    public init(items: [LinkedItem] = [], accounts: [ExternalAccount] = [], creditLiabilities: [ExternalCreditLiability] = [],
                recurringInflows: [ExternalRecurringInflow] = [], syncedAt: Date = Date()) {
        self.items = items; self.accounts = accounts; self.creditLiabilities = creditLiabilities
        self.recurringInflows = recurringInflows; self.syncedAt = syncedAt
    }

    enum CodingKeys: String, CodingKey { case items, accounts, creditLiabilities, recurringInflows, syncedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([LinkedItem].self, forKey: .items) ?? []
        accounts = try c.decodeIfPresent([ExternalAccount].self, forKey: .accounts) ?? []
        creditLiabilities = try c.decodeIfPresent([ExternalCreditLiability].self, forKey: .creditLiabilities) ?? []
        recurringInflows = try c.decodeIfPresent([ExternalRecurringInflow].self, forKey: .recurringInflows) ?? []
        syncedAt = try c.decodeIfPresent(Date.self, forKey: .syncedAt) ?? Date()
    }
}
