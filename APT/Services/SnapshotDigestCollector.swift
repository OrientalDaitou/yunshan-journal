import Foundation
import SwiftData

// 快照「近况速览」的取数：把 Core/SnapshotDigest.swift 要的事实从缓存与几次小范围查询里取好。
// 不新增全量计算：修为与各习惯的统计读 CultivationModel 已缓存的那份（与侧栏境界卡、今日洞府同一份）；
// 消费取 SummaryCollector 已算好的 summary.finance / financeToDate；复盘、落笔按日期用 #Predicate 只取近几十天的；
// 目标很少，整表取。五年数据下这里合计约十毫秒级。

@MainActor
enum SnapshotDigestCollector {
    /// 全部目标（含已放弃的，函数里自己筛），按创建先后。createdDay / updatedDay 按应用的时区换算。
    /// 标题压成一行：速览、快照目标表、README 目标表都是一条一行
    static func goalFacts(_ context: ModelContext) -> [SnapshotDigest.GoalFact] {
        let zone = CourierService.timeZone
        let goals = (try? context.fetch(FetchDescriptor<Goal>(sortBy: [SortDescriptor(\.createdAt)])))
            ?? context.all(Goal.self).sorted { $0.createdAt < $1.createdAt }
        return goals.map { g in
            SnapshotDigest.GoalFact(title: CourierItem.oneLine(g.title).trimmingCharacters(in: .whitespaces), status: g.status,
                                    progress: g.progress, priority: g.priority, category: CourierItem.oneLine(g.category),
                                    targetDate: g.targetDate.flatMap { LocalDay(key: $0) },
                                    createdDay: LocalDay(date: g.createdAt, timeZone: zone),
                                    updatedDay: LocalDay(date: g.updatedAt, timeZone: zone))
        }
    }

    /// 速览的全部输入。model 由调用方先 refresh（快照刷新开头已做）；消费取 summary 里已算好的，都不重算。
    /// 自己只取这几样，一律 #Predicate，不整表取修行录：
    /// - 近 60 天的复盘（正文要全文：快照修行录里的已被截短），去掉“AI建议”；
    /// - 近 60 天一篇都没有时，再往前找最近一篇的日子；
    /// - 近 14 天的全部落笔；近 7 天没有落笔时，再找最近一篇的日子。
    static func input(context: ModelContext, today: LocalDay, summary: PlannerSummary,
                      goals: [SnapshotDigest.GoalFact], model: CultivationModel) -> SnapshotDigest.Input {
        let state = model.state
        let realm = SnapshotDigest.Realm(title: state.title, totalXP: state.totalXP, nextRealm: state.nextRealmName,
                                         toNext: state.xpToNext,
                                         last7: (0..<7).reduce(0) { $0 + (state.perDay[today.adding(days: -$1)] ?? 0) },
                                         enabled: model.config.enabled)
        let habits = model.rows.map { SnapshotDigest.HabitFact(title: CourierItem.oneLine($0.habit.title), stats: $0.stats) }

        let reviews = recentReviews(context, today: today)
        let lastReviewDay = reviews.first?.day ?? lastReview(context, before: reviewSince(today))
        let entries = recentEntries(context, today: today)
        let recentFrom = today.adding(days: -6)
        let lastEntryDay = entries.contains { $0.day >= recentFrom } ? entries.map(\.day).max() : lastEntry(context, today: today)

        return SnapshotDigest.Input(today: today, realm: realm, habits: habits, goals: goals, reviews: reviews,
                                    lastReviewDay: lastReviewDay, entries: entries, lastEntryDay: lastEntryDay,
                                    finance: summary.finance, financeToDate: summary.financeToDate)
    }

    // MARK: 小范围取数

    /// 复盘里由问道灵枢“存进修行录”的 AI 建议带这个标签：不算用户自己的复盘
    static let adviceTag = "AI建议"

    private static func reviewSince(_ today: LocalDay) -> LocalDay { today.adding(days: -(SnapshotDigest.reviewDays - 1)) }

    /// 近 60 天的复盘，新→旧（同一天按时刻、创建先后），去掉 AI 建议
    private static func recentReviews(_ context: ModelContext, today: LocalDay) -> [SnapshotDigest.ReviewFact] {
        let review = JournalKind.review.rawValue
        let since = reviewSince(today).key, todayKey = today.key
        let found = (try? context.fetch(FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.kind == review && $0.dateKey >= since && $0.dateKey <= todayKey }))) ?? []
        return found.filter { !$0.isDeleted && !$0.tags.contains(adviceTag) }
            .sorted { ($0.dateKey, $0.minute ?? -1, $0.createdAt) > ($1.dateKey, $1.minute ?? -1, $1.createdAt) }
            .map { SnapshotDigest.ReviewFact(day: $0.day, period: $0.period, title: $0.title, body: $0.body) }
    }

    /// since 之前最近一篇（不是 AI 建议的）复盘的日子；从没写过返回 nil。
    /// 只按日期倒序取几篇：连着几十篇都是 AI 建议的情况不会有，取不到时当作没写过
    private static func lastReview(_ context: ModelContext, before since: LocalDay) -> LocalDay? {
        let review = JournalKind.review.rawValue
        let sinceKey = since.key
        var descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.kind == review && $0.dateKey < sinceKey },
                                                       sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
        descriptor.fetchLimit = 20
        return ((try? context.fetch(descriptor)) ?? []).first { !$0.isDeleted && !$0.tags.contains(adviceTag) }?.day
    }

    /// 近 14 天（含今天）的全部落笔；写在未来日子的补记不算
    private static func recentEntries(_ context: ModelContext, today: LocalDay) -> [SnapshotDigest.EntryFact] {
        let since = today.adding(days: -13).key, todayKey = today.key
        let found = (try? context.fetch(FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.dateKey >= since && $0.dateKey <= todayKey }))) ?? []
        return found.filter { !$0.isDeleted }.map { SnapshotDigest.EntryFact(day: $0.day, kind: $0.kindValue, mood: $0.mood) }
    }

    /// 今天及以前最近一篇落笔的日子；一篇都没有返回 nil
    private static func lastEntry(_ context: ModelContext, today: LocalDay) -> LocalDay? {
        let todayKey = today.key
        var descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey <= todayKey },
                                                       sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor)) ?? []).first?.day
    }
}
