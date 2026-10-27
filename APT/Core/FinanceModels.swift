import Foundation

// 灵石账簿的数据结构。字段名与旧版 `finance_ledger_v1`（JSON）完全一致，可原样读写，不丢字段。
// 金额一律用整数“分”（澳分）。

struct FinanceTransaction: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var amountCents: Int
    var balanceCents: Int
    var description: String
    var account: String
    var currency: String = "AUD"
    var category: String
    var kind: String
    var needsReview: Bool
    var reason: String
    var note: String = ""
    var sourceLine: Int
    var classification: String = "automatic"
    var revision: Int = 0
    var importedAt: String?
    var sourceSha256: String?
    /// 用户标记为“不计入统计”（重复或与己无关的银行流水）。新版新增字段：为 nil 时不写入 JSON，与旧版逐字节一致。
    var ignored: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, date, description, account, currency, category, kind, reason, note, classification, revision, ignored
        case amountCents = "amount_cents", balanceCents = "balance_cents", needsReview = "needs_review"
        case sourceLine = "source_line", importedAt = "imported_at", sourceSha256 = "source_sha256"
    }

    var month: String { String(date.prefix(7)) }
    /// 手记（手动记账、随手记、飞剑传书）的交易：可改金额日期说明、可删除；银行导入的不行。
    var isManual: Bool { account == ManualExpense.account }
    var isIgnored: Bool { ignored == true }
    /// 待确认且仍计入统计（标为“不计入”的不再催你确认）
    var awaitingReview: Bool { needsReview && !isIgnored }
}

struct StatementPeriod: Codable, Hashable {
    var start: String
    var end: String
}

struct FinanceSource: Codable, Hashable {
    var sha256: String
    var account: String
    var rawCsv: String
    var importedAt: String
    var rows: Int
    var start: String?
    var end: String?
    var pendingIncluded: Bool?
    var statementPeriod: StatementPeriod?
    /// 这次导入后按“疑似与手记重复”删掉的手记（原样保存），撤销这次导入时一并放回。
    /// 新版新增字段：为 nil 时不写入 JSON，旧账本逐字节不变。
    var removedManual: [FinanceTransaction]? = nil

    enum CodingKeys: String, CodingKey {
        case sha256, account, rows, start, end
        case rawCsv = "raw_csv", importedAt = "imported_at", pendingIncluded = "pending_included", statementPeriod = "statement_period"
        case removedManual = "removed_manual"
    }

    /// 已证实覆盖的日期范围：确认过的银行导出范围优先，否则取首末交易日期。
    var range: (String, String)? {
        if let p = statementPeriod { return (p.start, p.end) }
        if let start, let end { return (start, end) }
        return nil
    }
}

struct MerchantRule: Codable, Hashable, Identifiable {
    var id: String
    var account: String
    var merchant: String
    var category: String
    var enabled: Bool
    var revision: Int
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, account, merchant, category, enabled, revision
        case createdAt = "created_at"
    }
}

struct MonthFacts: Codable, Hashable {
    var month: String
    var start: String
    var end: String
    var rowCount: Int
    var fullMonth: Bool
    var coverageConfirmed: Bool
    var accountCount: Int
    var spendCents: Int
    var refundCents: Int
    var netSpendCents: Int
    var debitCents: Int
    var excludedCents: Int
    var excludedCategories: [String: Int]
    var educationCents: Int
    var nonEducationCents: Int
    var categories: [String: Int]
    var needsReviewCount: Int

    enum CodingKeys: String, CodingKey {
        case month, start, end, categories
        case rowCount = "row_count", fullMonth = "full_month", coverageConfirmed = "coverage_confirmed"
        case accountCount = "account_count", spendCents = "spend_cents", refundCents = "refund_cents"
        case netSpendCents = "net_spend_cents", debitCents = "debit_cents", excludedCents = "excluded_cents"
        case excludedCategories = "excluded_categories", educationCents = "education_cents"
        case nonEducationCents = "non_education_cents", needsReviewCount = "needs_review_count"
    }
}

struct CategoryChange: Codable, Hashable {
    var category: String
    var currentCents: Int
    var previousCents: Int
    var changeCents: Int

    enum CodingKeys: String, CodingKey {
        case category
        case currentCents = "current_cents", previousCents = "previous_cents", changeCents = "change_cents"
    }
}

struct MonthComparison: Codable, Hashable {
    var previousMonth: String
    var spendChangeCents: Int
    var netChangeCents: Int
    var nonEducationChangeCents: Int
    var categories: [CategoryChange]

    enum CodingKeys: String, CodingKey {
        case categories
        case previousMonth = "previous_month", spendChangeCents = "spend_change_cents"
        case netChangeCents = "net_change_cents", nonEducationChangeCents = "non_education_change_cents"
    }
}

struct CategoryAmount: Codable, Hashable {
    var category: String
    var cents: Int
}

struct BudgetStatus: Codable, Hashable {
    var key: String
    var label: String
    var spentCents: Int
    var limitCents: Int?
    var remainingCents: Int?

    enum CodingKeys: String, CodingKey {
        case key, label
        case spentCents = "spent_cents", limitCents = "limit_cents", remainingCents = "remaining_cents"
    }
}

struct ServiceSignal: Codable, Hashable {
    var kind: String
    var text: String
    var changeCents: Int?

    enum CodingKeys: String, CodingKey {
        case kind, text
        case changeCents = "change_cents"
    }
}

struct ServiceCheck: Codable, Hashable {
    var key: String
    var label: String
    var preferenceKey: String
    var status: String
    var debitCents: Int
    var count: Int
    var previousCents: Int?
    var previousMonth: String?
    var signals: [ServiceSignal]

    enum CodingKeys: String, CodingKey {
        case key, label, status, count, signals
        case preferenceKey = "preference_key", debitCents = "debit_cents"
        case previousCents = "previous_cents", previousMonth = "previous_month"
    }
}

struct LargePurchase: Codable, Hashable {
    var date: String
    var merchant: String
    var category: String
    var cents: Int
}

/// 月度修习录（月报）。保存后即为当时账本的快照，不随后续修改而变。
struct MonthlyReport: Codable, Hashable, Identifiable {
    var id: String = ""
    var month: String
    var version: Int = 0
    var basisHash: String
    var summary: MonthFacts
    var comparison: MonthComparison?
    var topCategories: [CategoryAmount]
    var budgets: [BudgetStatus]
    var services: [ServiceCheck]
    var suggestions: [String]
    var largePurchases: [LargePurchase]
    var reflection: String = ""
    var generatedAt: String = ""
    /// 新版生成的月报标记为 "swift-1"；旧版导入的月报为 nil（其 basis_hash 由旧版算法得出，不参与“已过期”判断）。
    var engine: String?

    enum CodingKeys: String, CodingKey {
        case id, month, version, summary, comparison, budgets, services, suggestions, reflection, engine
        case basisHash = "basis_hash", topCategories = "top_categories", largePurchases = "large_purchases"
        case generatedAt = "generated_at"
    }
}

struct FinanceLedger: Codable {
    var schemaVersion = 1
    var transactions: [FinanceTransaction] = []
    var sources: [FinanceSource] = []
    var reviewPreferences: [String: String] = [:]
    var monthlyReports: [MonthlyReport] = []
    var merchantRules: [MerchantRule] = []
    var budgets: [String: [String: Int]] = [:]

    enum CodingKeys: String, CodingKey {
        case transactions, sources, budgets
        case schemaVersion = "schema_version", reviewPreferences = "review_preferences"
        case monthlyReports = "monthly_reports", merchantRules = "merchant_rules"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        transactions = try c.decodeIfPresent([FinanceTransaction].self, forKey: .transactions) ?? []
        sources = try c.decodeIfPresent([FinanceSource].self, forKey: .sources) ?? []
        reviewPreferences = try c.decodeIfPresent([String: String].self, forKey: .reviewPreferences) ?? [:]
        monthlyReports = try c.decodeIfPresent([MonthlyReport].self, forKey: .monthlyReports) ?? []
        merchantRules = try c.decodeIfPresent([MerchantRule].self, forKey: .merchantRules) ?? []
        budgets = try c.decodeIfPresent([String: [String: Int]].self, forKey: .budgets) ?? [:]
    }

    static func decode(_ data: Data) throws -> FinanceLedger {
        try JSONDecoder().decode(FinanceLedger.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
