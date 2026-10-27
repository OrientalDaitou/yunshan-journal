import Foundation
import SwiftData

// 岁月长卷几处说法的运行时自检（fix-annals）：
// 1. 今天写过时，长卷其一“最长连续 / 动笔天数”、其七洞见、修行录卷中洞见卡（近 90 日）是同一个数，都数到今天；
// 2. 卷首灵石格：本月导到昨天时不挂“部分”；格里只写“较去年同期 +N%”，按几个整月比放进悬停；已过完又没导全的月份照旧挂“部分”。
// 统计口径本身（本月“至今”的判断、指定星期写“次”、心境小字）在 Tools/CoreCheck 里测；这里走真的取数与卷首格。

extension SelfTest {
    static func fixAnnalsChecks(_ check: (Bool, String) -> Void) throws {
        try fixAnnalsStreakChecks(check)
        fixAnnalsTileChecks(check)
    }

    // MARK: 1. 连续落笔：真库取数，三处同一个数

    private static func fixAnnalsStreakChecks(_ check: (Bool, String) -> Void) throws {
        let c = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: c)
        DataStore.save(c)
        let today = LocalDay.today()
        guard let period = AnnalsPeriod.make(.year(today.year), today: today) else { return check(false, "长卷连续落笔：今年的时段为空") }
        // 连着写到今天的 10 天（年初头几天只写今年的，免得这一段跨年：跨年时长卷其一只数段内、洞见照实写整段，本就不同）
        let first = max(period.first, today.adding(days: -9))
        for day in LocalDay.range(first, today) { c.insert(JournalEntry(kind: .diary, body: "fix-annals 自检", dateKey: day.key)) }
        // 更早隔开的一篇：不连上，动笔天数多 1（今年有这一天时）
        let earlier = first.adding(days: -5)
        c.insert(JournalEntry(kind: .note, body: "fix-annals 自检·更早", dateKey: earlier.key))
        DataStore.save(c)

        let report = AnnalsEngine.report(period, input: RecordCollector.input(context: c, from: period.first, to: period.last, today: today, text: true))
        let streak = report.insights.first { $0.kind == .writingStreak }
        let card = LongTermDigest.make(AIDigest.input(context: c, today: today, habits: nil), today: today).insights.first { $0.kind == .writingStreak }
        let count = first.days(to: today) + 1
        let writingDays = count + (earlier >= period.first ? 1 : 0)
        let expected = count >= InsightEngine.Rules.streakDays
            ? "最长连续落笔 \(count) 天（\(first.label(relativeTo: today))—\(today.label(relativeTo: today))），也是有记录以来最长的一次，至今仍在延续。" : nil
        check(report.writing?.longestRun?.count == count && report.writing?.longestRun?.last == today && report.writing?.writingDays == writingDays
              && streak?.text == expected && card?.text == expected && (expected == nil || streak?.basis == "依据 \(writingDays) 天的落笔"),
              "长卷连续落笔（真库）：今天写过时其一“最长连续 \(report.writing?.longestRun?.count ?? 0) 天、动笔 \(report.writing?.writingDays ?? 0) 天”、"
              + "其七与卷中洞见卡同一个数：\(streak?.text ?? "（不足 \(InsightEngine.Rules.streakDays) 天不出）")")
    }

    // MARK: 2. 卷首灵石格

    private static func fixAnnalsTileChecks(_ check: (Bool, String) -> Void) {
        let today = LocalDay(key: "2026-10-20")!
        var ledger = FinanceLedger()
        for (i, day) in LocalDay.range(LocalDay(key: "2025-01-01")!, today).enumerated() where day.day % 4 == 2 {
            ledger.transactions.append(FinanceTransaction(id: "fa-tile-\(i)", date: day.key, amountCents: -(1500 + i), balanceCents: 0,
                                                          description: "自检", account: "CBA", category: "餐饮与外卖", kind: "消费",
                                                          needsReview: false, reason: "", sourceLine: i))
        }
        func tile(_ ranges: [(String, String)]) -> AnnalsTileSpec? {
            var l = ledger
            l.sources = ranges.map { FinanceSource(sha256: "fa-tile\($0.0)", account: "CBA", rawCsv: "", importedAt: "", rows: 0, start: $0.0, end: $0.1,
                                                   statementPeriod: StatementPeriod(start: $0.0, end: $0.1)) }
            guard let period = AnnalsPeriod.make(.year(2026), today: today) else { return nil }
            let input = RecordInput(today: today, entries: [], history: [], habits: [], cultivation: CultivationConfig(), ledger: l)
            return AnnalsTileSpec.tiles(AnnalsEngine.report(period, input: input)).first { $0.label == "灵石" }
        }
        let current = tile([("2025-01-01", "2026-10-19")])
        check(current?.partial == false && current?.compare?.hasPrefix("较去年同期 ") == true && current?.compare?.contains("整月") == false
              && current?.compareHelp == "按 9 个已导全的整月比较（本月与没导全的月份不算）",
              "卷首灵石格：本月导到昨天时不挂“部分”，格里只写“\(current?.compare ?? "nil")”，按几个整月比放进悬停")
        let gap = tile([("2025-01-01", "2026-08-31"), ("2026-09-10", "2026-10-19")])
        check(gap?.partial == true && gap?.compareHelp == "按 8 个已导全的整月比较（本月与没导全的月份不算）",
              "卷首灵石格：已过完又没导全的 9 月照旧挂“部分”，比较少一个整月")
    }
}
