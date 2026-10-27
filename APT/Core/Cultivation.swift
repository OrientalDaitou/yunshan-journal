import Foundation

/// 修仙进度配置，默认值与旧版 `V2_DEFAULTS.cultivation` 一致。
struct CultivationConfig: Codable, Equatable {
    var realms: [String] = CultivationConfig.defaultRealms
    var thresholds: [Int] = CultivationConfig.defaultThresholds
    var dailyCap: Int = 150
    var enabled: Bool = true

    static let defaultRealms = ["炼气", "筑基", "金丹", "元婴", "化神", "炼虚", "合体", "大乘", "渡劫"]
    static let defaultThresholds = [0, 100, 350, 800, 1600, 3000, 5000, 8000, 12000]

    /// 名称与阈值数量不一致或阈值不递增时，回退到默认值，避免界面崩溃。
    var sanitized: CultivationConfig {
        var copy = self
        let ascending = zip(thresholds, thresholds.dropFirst()).allSatisfy { $0 < $1 }
        if realms.isEmpty || realms.count != thresholds.count || thresholds.first != 0 || !ascending {
            copy.realms = Self.defaultRealms
            copy.thresholds = Self.defaultThresholds
        }
        copy.dailyCap = max(10, dailyCap)
        return copy
    }
}

/// 一条修为来源。kind 用于同日递减：同一天同一类第 6 次起修为减半，第 11 次起再减。
struct XPSource {
    var day: LocalDay
    var kind: String
    var amount: Int
}

struct CultivationState: Equatable {
    var totalXP: Int
    var todayXP: Int
    var realmIndex: Int
    var realmName: String
    var stage: String
    var progress: Double
    var currentThreshold: Int
    var nextThreshold: Int?
    var nextRealmName: String?
    var perDay: [LocalDay: Int]

    var xpToNext: Int? { nextThreshold.map { max(0, $0 - totalXP) } }
    var title: String { "\(realmName) · \(stage)" }

    static let empty = CultivationState(totalXP: 0, todayXP: 0, realmIndex: 0, realmName: CultivationConfig.defaultRealms[0],
                                        stage: "初期", progress: 0, currentThreshold: 0, nextThreshold: 100,
                                        nextRealmName: CultivationConfig.defaultRealms[1], perDay: [:])
}

enum CultivationEngine {
    static let habitXP = 10
    static let perfectDayXP = 20
    static let stages = ["初期", "中期", "后期", "圆满"]

    static let rulesDescription = """
    · 每完成一次习惯打卡：+\(habitXP) 修为
    · 当天所有“每天 / 指定星期”的习惯全部完成：额外 +\(perfectDayXP)（功课圆满）
    · 归档的习惯从归档那天起不再计入圆满；习惯创建之前的日子补了卡才计入，没补不算漏做
    · 改数量目标不改写历史：之前的打卡按当时的目标判定是否达标，新目标从改的当天起生效
    · 修行录落笔：日记 +5、灵感 +3、复盘 +15
    · 同一天同类来源第 6 次起递减，每日修为有上限（防止刷修为）
    · 修为由打卡记录实时计算：取消打卡会同步扣回，不会凭空累积
    """

    static func compute(sources: [XPSource], config rawConfig: CultivationConfig, today: LocalDay) -> CultivationState {
        let config = rawConfig.sanitized
        var perDay: [LocalDay: Int] = [:]
        if config.enabled {
            // 按（日期, 类别）排序后，同一天、同一类别的来源必然相邻：顺序扫一遍就能数出“第几次”和当天累计，
            // 不必为每条来源拼字符串键（修为每次重绘都会重算，这里是热点）。
            let ordered = sources.filter { $0.day <= today }.sorted {
                $0.day.jdn != $1.day.jdn ? $0.day.jdn < $1.day.jdn : $0.kind < $1.kind
            }
            var day: LocalDay?
            var kind = ""
            var count = 0
            var dayTotal = 0
            for source in ordered {
                if source.day != day {
                    if let day { perDay[day] = dayTotal }
                    day = source.day
                    kind = source.kind
                    count = 0
                    dayTotal = 0
                } else if source.kind != kind {
                    kind = source.kind
                    count = 0
                }
                let amount = max(1, source.amount / (1 + count / 5))
                count += 1
                dayTotal += max(0, min(amount, config.dailyCap - dayTotal))
            }
            if let day { perDay[day] = dayTotal }
        }
        let total = perDay.values.reduce(0, +)
        return state(for: total, today: perDay[today] ?? 0, perDay: perDay, config: config)
    }

    /// 最高境界没有下一道门槛：从进入起再积 finalRealmSpan 修为走完初期 → 圆满，满了即“大圆满”。
    static let finalRealmSpan = 5000

    static func state(for total: Int, today: Int = 0, perDay: [LocalDay: Int] = [:], config rawConfig: CultivationConfig) -> CultivationState {
        let config = rawConfig.sanitized
        let index = config.thresholds.lastIndex { total >= $0 } ?? 0
        let lower = config.thresholds[index]
        let isLast = index == config.thresholds.count - 1
        let upper = isLast ? nil : config.thresholds[index + 1]
        let progress = Double(total - lower) / Double(max(1, (upper ?? lower + finalRealmSpan) - lower))
        let stage = isLast && total >= lower + finalRealmSpan ? "大圆满" : stages[max(0, min(3, Int(progress * 4)))]
        return CultivationState(totalXP: total, todayXP: today, realmIndex: index, realmName: config.realms[index],
                                stage: stage, progress: min(1, max(0, progress)), currentThreshold: lower,
                                nextThreshold: upper, nextRealmName: isLast ? nil : config.realms[index + 1],
                                perDay: perDay)
    }

    /// 修行录落笔的修为来源（未来日期不计）。
    static func journalSources(_ items: [(day: LocalDay, kind: JournalKind)], today: LocalDay) -> [XPSource] {
        items.filter { $0.day <= today }.map { XPSource(day: $0.day, kind: "journal-" + $0.kind.rawValue, amount: $0.kind.xp) }
    }

    /// 某习惯在 day 这天是否计入“功课圆满”的应做数（achieved：这天是否已达标）。应做数与完成数都用它判断，口径一致：
    /// - 只看“每天 / 指定星期”且当天应做的习惯；
    /// - 已归档：有归档日的，只在归档日之前计入；旧数据没有归档日，完全不计（与原来一致）；
    /// - 创建日之前：补了卡就照常计入，没做不算漏——新建习惯把开始日期设在过去，不会抹掉过去已得的圆满。
    static func countsTowardPerfectDay(_ spec: HabitSpec, archived: Bool, on day: LocalDay, achieved: @autoclosure () -> Bool) -> Bool {
        guard spec.frequency != .weekly, spec.isScheduled(day) else { return false }
        if archived {
            guard let archivedDay = spec.archivedDay, day < archivedDay else { return false }
        }
        if let createdDay = spec.createdDay, day < createdDay, !achieved() { return false }
        return true
    }

    /// 某一天是否“功课圆满”（与 sources 的判定完全相同）。habits 传全部习惯（含已归档的，由这里按归档日过滤）。
    /// 当天没有任何应做的“每天 / 指定星期”习惯时为 false。
    static func isPerfectDay(_ day: LocalDay, habits: [(spec: HabitSpec, logs: [HabitLogValue], archived: Bool)]) -> Bool {
        var scheduled = 0, achieved = 0
        for habit in habits {
            // 与 HabitStats 相同：同一天有多条记录时以最后一条为准。
            let ok = habit.spec.achieved(habit.logs.last { $0.day == day })
            guard countsTowardPerfectDay(habit.spec, archived: habit.archived, on: day, achieved: ok) else { continue }
            scheduled += 1
            if ok { achieved += 1 }
        }
        return scheduled > 0 && achieved == scheduled
    }

    /// 由习惯与打卡记录生成修为来源。
    static func sources(habits: [(spec: HabitSpec, logs: [HabitLogValue], archived: Bool)], today: LocalDay) -> [XPSource] {
        sources(habits: habits, stats: habits.map { HabitStats(spec: $0.spec, logs: $0.logs, today: today) }, today: today)
    }

    /// 同上，每个习惯的统计已由调用方算好（修为模型按习惯缓存了统计，不必再建一遍）。
    /// stats 与 habits 一一对应，且是用同一个 today 算的。
    static func sources(habits: [(spec: HabitSpec, logs: [HabitLogValue], archived: Bool)], stats allStats: [HabitStats],
                        today: LocalDay) -> [XPSource] {
        var result: [XPSource] = []
        var achievedByDay: [LocalDay: Int] = [:]
        for (habit, stats) in zip(habits, allStats) {
            for day in stats.logs.keys where day <= today && stats.isAchieved(day) {
                result.append(XPSource(day: day, kind: "habit", amount: habitXP))
                if countsTowardPerfectDay(habit.spec, archived: habit.archived, on: day, achieved: true) {
                    achievedByDay[day, default: 0] += 1
                }
            }
        }
        // “功课圆满”只看有打卡记录的日子，不为没有记录的历史日期逐日扫描。
        // 每周 N 次、以及没有归档日的已归档习惯任何一天都不计，先筛掉。
        let candidates = zip(habits, allStats).filter { habit, _ in
            habit.spec.frequency != .weekly && (!habit.archived || habit.spec.archivedDay != nil)
        }
        for (day, achieved) in achievedByDay {
            var scheduled = 0
            for (habit, stats) in candidates
            where countsTowardPerfectDay(habit.spec, archived: habit.archived, on: day, achieved: stats.isAchieved(day)) {
                scheduled += 1
            }
            if scheduled > 0, achieved == scheduled {
                result.append(XPSource(day: day, kind: "perfect", amount: perfectDayXP))
            }
        }
        return result
    }

    /// 某一天的修为（与全量计算里的 perDay[day] 相同）。同日递减、每日上限、功课圆满都只看这一天的来源，
    /// 所以只用这一天的打卡与落笔就能算出：落笔、删除、撤销删除只改动一天，总修为的变化就是这一天修为的变化。
    /// habits 传全部习惯（含已归档的）；logs、journal 可以只传这一天的，别的日子在这里也会被滤掉。
    static func dayXP(_ day: LocalDay, habits: [(spec: HabitSpec, logs: [HabitLogValue], archived: Bool)],
                      journal: [(day: LocalDay, kind: JournalKind)], config: CultivationConfig, today: LocalDay) -> Int {
        guard day <= today else { return 0 }
        let inputs = habits.map { (spec: $0.spec, logs: $0.logs.filter { $0.day == day }, archived: $0.archived) }
        let sources = sources(habits: inputs, today: today) + journalSources(journal.filter { $0.day == day }, today: today)
        return compute(sources: sources, config: config, today: today).perDay[day] ?? 0
    }
}
