// 无需 Xcode 的核心逻辑自检：swiftc APT/Core/*.swift Tools/CoreCheck/main.swift -o corecheck && ./corecheck [旧版数据库路径]
import Foundation

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print(ok ? "✓ \(message)" : "✗ \(message)")
    if !ok { failures += 1 }
}

/// 固定种子的随机数（splitmix64），对照测试每次结果相同、可复现。
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var rng = SeededRandom(state: 20261014)
func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &rng)] }

typealias HabitInput = (spec: HabitSpec, logs: [HabitLogValue], archived: Bool)

// MARK: 改动前的实现（原样保留，只用于对照：新实现在相同输入下必须给出相同结果）

func referenceOccurrences(_ rule: RecurrenceRule, from first: LocalDay, to last: LocalDay) -> [RecurrenceRule.Occurrence] {
    guard first <= last else { return [] }
    var candidates = Set<LocalDay>()
    let lower = max(first.adding(days: -62), rule.start)
    var upper = last.adding(days: 62)
    if let repeatUntil = rule.repeatUntil { upper = min(upper, repeatUntil) }
    if rule.kind == .none {
        candidates.insert(rule.start)
    } else if lower <= upper {
        candidates.formUnion(LocalDay.range(lower, upper))
    }
    for key in rule.overrides.keys { if let d = LocalDay(key: key) { candidates.insert(d) } }
    var result: [RecurrenceRule.Occurrence] = []
    for day in candidates.sorted() where !rule.excluded.contains(day.key) && rule.matches(day) {
        let patch = rule.overrides[day.key]
        let scheduled = patch?.date.flatMap(LocalDay.init(key:)) ?? day
        guard scheduled >= first, scheduled <= last else { continue }
        result.append(.init(sourceDay: day, scheduledDay: scheduled, isOverride: patch != nil))
    }
    return result
}

func referencePerDay(_ sources: [XPSource], config rawConfig: CultivationConfig, today: LocalDay) -> [LocalDay: Int] {
    let config = rawConfig.sanitized
    var perDay: [LocalDay: Int] = [:]
    guard config.enabled else { return perDay }
    var counts: [String: Int] = [:]
    for source in sources.filter({ $0.day <= today }).sorted(by: { ($0.day, $0.kind) < ($1.day, $1.kind) }) {
        let key = source.day.key + "|" + source.kind
        let count = counts[key, default: 0]
        counts[key] = count + 1
        let amount = max(1, source.amount / (1 + count / 5))
        let rewarded = max(0, min(amount, config.dailyCap - perDay[source.day, default: 0]))
        perDay[source.day, default: 0] += rewarded
    }
    return perDay
}

/// 改动前的修为来源：没有归档日、创建日、打卡当时目标的概念。
func referenceSources(habits: [HabitInput], today: LocalDay) -> [XPSource] {
    var result: [XPSource] = []
    var achievedByDay: [LocalDay: Int] = [:]
    for habit in habits {
        let stats = HabitStats(spec: habit.spec, logs: habit.logs, today: today)
        for day in stats.logs.keys where day <= today && stats.isAchieved(day) {
            result.append(XPSource(day: day, kind: "habit", amount: CultivationEngine.habitXP))
            if !habit.archived, habit.spec.frequency != .weekly, habit.spec.isScheduled(day) {
                achievedByDay[day, default: 0] += 1
            }
        }
    }
    let daily = habits.filter { !$0.archived && $0.spec.frequency != .weekly }
    for (day, achieved) in achievedByDay {
        let scheduled = daily.filter { $0.spec.isScheduled(day) }.count
        if scheduled > 0, achieved == scheduled {
            result.append(XPSource(day: day, kind: "perfect", amount: CultivationEngine.perfectDayXP))
        }
    }
    return result
}

func sourceSignature(_ sources: [XPSource]) -> [String] { sources.map { "\($0.day.key)|\($0.kind)|\($0.amount)" }.sorted() }

// LocalDay
let d = LocalDay(key: "2026-10-13")!
check(d.key == "2026-10-13" && d.weekdayIndex == 1, "LocalDay 解析与星期（2026-10-13 为周二）")
check(LocalDay(key: "2026-02-30") == nil, "LocalDay 拒绝不存在的日期")
check(ClockTime.minutes(from: "24:00", allowEndOfDay: true) == 1440 && ClockTime.minutes(from: "24:00") == nil
      && ClockTime.minutes(from: "24:0") == nil && ClockTime.minutes(from: "24:30", allowEndOfDay: true) == nil,
      "“24:00” 只在结束时间里有效")
check((try? CourierParser.parse(Data(#"{"type":"event","title":"a","start":"21:00","end":"24:00"}"#.utf8))) != nil,
      "传书日程可以结束于 24:00")
check((try? CourierParser.parse(Data(#"{"type":"event","title":"a","start":"24:00"}"#.utf8))) == nil
      && (try? CourierParser.parse(Data(#"{"type":"event","title":"a","start":"24:0"}"#.utf8))) == nil
      && (try? CourierParser.parse(Data(#"{"type":"diary","body":"a","time":"24:00"}"#.utf8))) == nil,
      "传书的开始时间 / 日记时刻拒绝 24:00")
check(LocalDay(key: "2024-02-28")!.adding(days: 1).key == "2024-02-29", "闰年加一天")
check(d.mondayOfWeek.key == "2026-10-12", "周一锚点")

// Recurrence：旧版“导师1v1 meeting”每 2 周、周一、至 11-02
let biweekly = RecurrenceRule(start: LocalDay(key: "2026-10-05")!, kind: .weekly, interval: 2, weekdays: [],
                              repeatUntil: LocalDay(key: "2026-11-02"))
let occ = biweekly.occurrences(from: LocalDay(key: "2026-10-01")!, to: LocalDay(key: "2026-11-30")!).map(\.scheduledDay.key)
check(occ == ["2026-10-05", "2026-10-19", "2026-11-02"], "隔周重复 + 截止日期：\(occ)")
var skip = RecurrenceRule(start: LocalDay(key: "2026-09-28")!, kind: .weekly)
skip.excluded = ["2026-10-05"]
skip.stopBefore = LocalDay(key: "2026-10-19")
let skipOcc = skip.occurrences(from: LocalDay(key: "2026-09-28")!, to: LocalDay(key: "2026-10-31")!).map(\.scheduledDay.key)
check(skipOcc == ["2026-09-28", "2026-10-12"], "跳过某次 + 从某日停止：\(skipOcc)")
var moved = RecurrenceRule(start: LocalDay(key: "2026-09-28")!, kind: .daily, interval: 3)
moved.overrides = ["2026-10-01": OccurrencePatch(date: "2026-10-02")]
let movedOcc = moved.occurrences(from: LocalDay(key: "2026-09-28")!, to: LocalDay(key: "2026-10-04")!).map(\.scheduledDay.key)
check(movedOcc == ["2026-09-28", "2026-10-02", "2026-10-04"], "每 3 天 + 单次改期：\(movedOcc)")
let custom = RecurrenceRule(start: LocalDay(key: "2026-10-12")!, kind: .custom, weekdays: [0, 2, 4])
check(custom.occurrences(from: d, to: d.adding(days: 6)).count == 3, "指定星期（一三五）")
var farMove = RecurrenceRule(start: LocalDay(key: "2026-09-07")!, kind: .weekly)
farMove.overrides = ["2026-09-07": OccurrencePatch(date: "2026-12-25"), "2026-09-14": OccurrencePatch(title: "只改标题")]
let farOcc = farMove.occurrences(from: LocalDay(key: "2026-12-21")!, to: LocalDay(key: "2026-12-27")!)
check(farOcc.map(\.scheduledDay.key) == ["2026-12-25", "2026-12-21"] && farOcc.first?.sourceDay.key == "2026-09-07",
      "单次改期挪到很远的日子也能展开：\(farOcc.map(\.scheduledDay.key))")

// Recurrence：随机规则与改动前的实现逐项对照（含跳过、停止、截止、单次改期、非规范的日期键）
let recurrenceBase = LocalDay(key: "2026-10-01")!
/// 能被 LocalDay(key:) 解析、却不是规范写法的日期键（例如 "2026-10-+5"）：旧实现按字符串比较，这种键不算数。
func nonCanonical(_ day: LocalDay) -> String { String(day.key.dropLast(2)) + "+" + String(day.key.suffix(1)) }
var recurrenceMismatch: [String] = []
for _ in 0..<4000 {
    var rule = RecurrenceRule(start: recurrenceBase.adding(days: Int.random(in: -40...40, using: &rng)), kind: pick(RecurrenceKind.allCases),
                              interval: Int.random(in: 0...3, using: &rng),
                              weekdays: (0...6).filter { _ in chance(0.3) })
    if chance(0.3) { rule.repeatUntil = rule.start.adding(days: Int.random(in: -5...90, using: &rng)) }
    if chance(0.3) { rule.stopBefore = rule.start.adding(days: Int.random(in: -5...90, using: &rng)) }
    for _ in 0..<Int.random(in: 0...4, using: &rng) { rule.excluded.insert(rule.start.adding(days: Int.random(in: 0...70, using: &rng)).key) }
    if chance(0.2) { rule.excluded.insert(nonCanonical(rule.start.adding(days: Int.random(in: 0...20, using: &rng)))) }
    for _ in 0..<Int.random(in: 0...4, using: &rng) {
        let source = rule.start.adding(days: Int.random(in: -3...80, using: &rng))
        var key = source.key
        if chance(0.15) { key = nonCanonical(source) } else if chance(0.05) { key = "坏键" }
        let date: String? = chance(0.3) ? nil : (chance(0.1) ? "2026-02-30" : source.adding(days: Int.random(in: -90...90, using: &rng)).key)
        rule.overrides[key] = OccurrencePatch(title: chance(0.5) ? "改" : nil, date: date)
    }
    let first = recurrenceBase.adding(days: Int.random(in: -60...60, using: &rng))
    let last = first.adding(days: Int.random(in: -2...70, using: &rng))
    let new = rule.occurrences(from: first, to: last)
    let old = referenceOccurrences(rule, from: first, to: last)
    if new != old, recurrenceMismatch.count < 3 { recurrenceMismatch.append("\(rule) \(first)…\(last)：新 \(new.count) 旧 \(old.count)") }
}
check(recurrenceMismatch.isEmpty, "重复规则展开与改动前完全一致（4000 组随机规则）" + (recurrenceMismatch.isEmpty ? "" : "：\(recurrenceMismatch)"))

// 日程时长：按真实规则（隔周、跳过某次、单次改期的时间）展开，再折成每周平均（与 SummaryCollector 共用 ScheduleHours）
let hoursMonday = LocalDay(key: "2026-10-12")!
let tutoring = RecurrenceRule(start: hoursMonday, kind: .weekly, interval: 2)
var research = RecurrenceRule(start: hoursMonday.adding(days: 1), kind: .weekly)
research.excluded = [hoursMonday.adding(days: 8).key]
research.overrides = [hoursMonday.adding(days: 15).key: OccurrencePatch(start_time: "09:00", end_time: "12:00")]
var budgetItems: [(category: String, start: Int?, end: Int?)] = []
for _ in tutoring.occurrences(from: hoursMonday, to: hoursMonday.adding(days: 27)) { budgetItems.append(("Tutoring", 10 * 60, 12 * 60)) }
for o in research.occurrences(from: hoursMonday, to: hoursMonday.adding(days: 27)) {
    let patch = research.overrides[o.sourceDay.key]
    budgetItems.append(("Research", patch?.start_time.flatMap { ClockTime.minutes(from: $0) } ?? 9 * 60,
                        patch?.end_time.flatMap { ClockTime.minutes(from: $0, allowEndOfDay: true) } ?? 10 * 60 + 30))
}
let budget = ScheduleHours.weeklyAverage(budgetItems, days: 28).map { "\($0.category) \($0.hoursPerWeek)" }
check(budget == ["Research 1.5", "Tutoring 1.0"], "日程每周平均时长（隔周、跳过一次、改期延长一次）：\(budget)")

// Habits
let today = LocalDay(key: "2026-10-13")!
let spec = HabitSpec(frequency: .daily, startDay: today.adding(days: -9))
let logs = (1...5).map { HabitLogValue(day: today.adding(days: -$0), completed: true, quantity: nil) }
let stats = HabitStats(spec: spec, logs: logs, today: today)
check(stats.streak.count == 5, "每日习惯连续 5 天（今天未打卡不算断）：\(stats.streak)")
check(stats.completionRate(days: 7) == 5.0 / 6.0, "近 7 天完成率排除今天：\(stats.completionRate(days: 7) ?? -1)")
let weekly = HabitSpec(frequency: .weekly, targetPerWeek: 2, startDay: today.adding(days: -30))
let wlogs = [today.adding(days: -7), today.adding(days: -8), today.adding(days: -1)].map { HabitLogValue(day: $0, completed: true, quantity: nil) }
let wstats = HabitStats(spec: weekly, logs: wlogs, today: today)
check(wstats.streak.count == 1 && wstats.streak.unit == "周", "每周 2 次：本周未满不算断，上周达标：\(wstats.streak)")
let qty = HabitSpec(frequency: .daily, targetValue: 30, startDay: today)
check(!qty.achieved(HabitLogValue(day: today, completed: true, quantity: 20)) && qty.achieved(HabitLogValue(day: today, completed: true, quantity: 30)), "数量目标决定是否达成")
let qty45 = HabitSpec(frequency: .daily, targetValue: 45, startDay: today)
check(qty45.achieved(HabitLogValue(day: today, completed: true, quantity: 30, target: 30))
      && !qty45.achieved(HabitLogValue(day: today, completed: true, quantity: 30)),
      "按打卡当时的目标判定（当时 30、现在 45 → 达标）；没记当时目标的沿用当前目标")
check(qty45.achieved(HabitLogValue(day: today, completed: true, quantity: nil, target: 0))
      && !qty45.achieved(HabitLogValue(day: today, completed: false, quantity: nil, target: 0)),
      "当时没有数量目标（记为 0）的打卡只看是否完成")

// 每周 N 次：近 7 / 30 天的窗口开头截到半周时，按整周是否达标折算（今天 2026-10-14 周三）
let weekToday = LocalDay(key: "2026-10-14")!
let weekStart = LocalDay(key: "2026-06-01")!
let twicePerWeek = HabitSpec(frequency: .weekly, targetPerWeek: 2, startDay: weekStart)
func weekdayLogs(_ weekdays: Set<Int>) -> [HabitLogValue] {
    LocalDay.range(weekStart, weekToday).filter { weekdays.contains($0.weekdayIndex) }.map { HabitLogValue(day: $0, completed: true, quantity: nil) }
}
for (label, weekdays) in [("周一、二", Set([0, 1])), ("周六、日", Set([5, 6])), ("周一、四", Set([0, 3]))] {
    let stats = HabitStats(spec: twicePerWeek, logs: weekdayLogs(weekdays), today: weekToday)
    let r7 = stats.completionRate(days: 7) ?? -1, r30 = stats.completionRate(days: 30) ?? -1
    check(abs(r7 - 1) < 1e-9 && abs(r30 - 1) < 1e-9, "每周 2 次、每周\(label)打卡：近 7 天 \(r7)、近 30 天 \(r30)（都应为 100%）")
}
let onceOnly = HabitStats(spec: twicePerWeek, logs: weekdayLogs([0]), today: weekToday)
let onceRate = onceOnly.completionRate(days: 30) ?? -1
check(onceRate > 0.5 && onceRate < 0.6, "每周 2 次但每周只做 1 次：近 30 天 \(onceRate)（约一半，本周未完不计罚）")
check(onceOnly.weeklyTrend(weeks: 4).dropLast().allSatisfy { $0.rate == 0.5 }, "整周趋势不受影响：\(onceOnly.weeklyTrend(weeks: 4).map(\.rate))")
// 窗口结尾截在过去某周的周中（月度复盘 9 月 1–30 日，月末是周三；事后复盘截至上周三 10-07 的近 7 天）：同样按整周折算
let septemberFirst = LocalDay(key: "2026-09-01")!, septemberLast = LocalDay(key: "2026-09-30")!
let lastWednesday = LocalDay(key: "2026-10-07")!
for (label, weekdays) in [("周一、二", Set([0, 1])), ("周六、日", Set([5, 6])), ("周一、四", Set([0, 3]))] {
    let stats = HabitStats(spec: twicePerWeek, logs: weekdayLogs(weekdays), today: weekToday)
    let month = stats.rate(from: septemberFirst, to: septemberLast) ?? -1
    let past7 = stats.completionRate(days: 7, endingAt: lastWednesday) ?? -1
    check(abs(month - 1) < 1e-9 && abs(past7 - 1) < 1e-9, "每周 2 次、每周\(label)打卡：九月 \(month)、截至上周三的近 7 天 \(past7)（都应为 100%）")
}
for (label, weekday) in [("周一", 0), ("周日", 6)] {
    let stats = HabitStats(spec: twicePerWeek, logs: weekdayLogs([weekday]), today: weekToday)
    let month = stats.rate(from: septemberFirst, to: septemberLast) ?? -1
    let past7 = stats.completionRate(days: 7, endingAt: lastWednesday) ?? -1
    check(abs(month - 0.5) < 1e-9 && abs(past7 - 0.5) < 1e-9, "每周 2 次但每周只在\(label)做 1 次：九月 \(month)、截至上周三的近 7 天 \(past7)（都应为 50%）")
}

// Cultivation
let sources = CultivationEngine.sources(habits: [(spec, logs, false)], today: today)
let state = CultivationEngine.compute(sources: sources, config: CultivationConfig(), today: today)
check(state.totalXP == 5 * 30, "5 天打卡且每天功课圆满 = 150 修为：\(state.totalXP)")
check(state.realmName == "筑基", "150 修为为筑基：\(state.title)")
let capped = CultivationEngine.compute(sources: (0..<30).map { XPSource(day: today, kind: "k\($0)", amount: 10) },
                                       config: CultivationConfig(), today: today)
check(capped.totalXP == 150, "每日上限 150：\(capped.totalXP)")
let diminishing = CultivationEngine.compute(sources: (0..<10).map { _ in XPSource(day: today, kind: "habit", amount: 10) },
                                            config: CultivationConfig(), today: today)
check(diminishing.totalXP == 75, "同类第 6 次起递减：\(diminishing.totalXP)")
let top = CultivationEngine.state(for: 99999, config: CultivationConfig())
check(top.realmName == "渡劫" && top.nextThreshold == nil, "最高境界没有下一阈值：\(top.title)")
let finalStages = [12000, 13300, 14600, 16999, 17000].map { CultivationEngine.state(for: $0, config: CultivationConfig()) }
check(finalStages.map(\.stage) == ["初期", "中期", "后期", "圆满", "大圆满"] && finalStages[0].progress == 0 && finalStages[4].progress == 1,
      "最高境界也按初期 → 圆满推进，满 5000 为大圆满：\(finalStages.map { "\($0.totalXP) \($0.stage)" })")

// 修为计算：随机来源与改动前的实现逐项对照
var computeMismatch = 0
let xpKinds: [(String, Int)] = [("habit", 10), ("perfect", 20), ("journal-diary", 5), ("journal-note", 3), ("journal-review", 15)]
for _ in 0..<500 {
    let sources = (0..<Int.random(in: 0...120, using: &rng)).map { _ -> XPSource in
        let kind = pick(xpKinds)
        return XPSource(day: today.adding(days: Int.random(in: -20...3, using: &rng)), kind: kind.0, amount: kind.1)
    }
    var config = CultivationConfig()
    config.dailyCap = Int.random(in: 0...200, using: &rng)
    config.enabled = chance(0.9)
    let state = CultivationEngine.compute(sources: sources, config: config, today: today)
    let reference = referencePerDay(sources, config: config, today: today)
    if state.perDay != reference || state.totalXP != reference.values.reduce(0, +) || state.todayXP != (reference[today] ?? 0) { computeMismatch += 1 }
}
check(computeMismatch == 0, "修为（含递减与每日上限）与改动前完全一致（500 组随机来源）：不一致 \(computeMismatch) 组")

// 修为来源：随机习惯与打卡（不含新字段时）与改动前完全一致；“今日圆满”判定与修为规则一致
func randomHabits(today: LocalDay, newFields: Bool) -> [HabitInput] {
    (0..<Int.random(in: 1...4, using: &rng)).map { _ in
        var spec = HabitSpec(frequency: pick(HabitFrequency.allCases), targetPerWeek: Int.random(in: 1...3, using: &rng),
                             weekdays: (0...6).filter { _ in chance(0.5) }, targetValue: chance(0.3) ? 30 : nil,
                             startDay: today.adding(days: -Int.random(in: 0...30, using: &rng)))
        let archived = chance(0.25)
        if newFields {
            if chance(0.5) { spec.createdDay = today.adding(days: -Int.random(in: 0...35, using: &rng)) }
            if archived, chance(0.6) { spec.archivedDay = today.adding(days: -Int.random(in: 0...20, using: &rng)) }
        }
        let logs = LocalDay.range(spec.startDay.adding(days: -5), today.adding(days: 2)).filter { _ in chance(0.6) }.map { day in
            HabitLogValue(day: day, completed: chance(0.9), quantity: pick([nil, 20, 30, 50]),
                          target: newFields ? pick([nil, 0, 30, 45]) : nil)
        }
        return (spec, logs, archived)
    }
}
var sourcesMismatch = 0, perfectMismatch = 0
for _ in 0..<300 {
    let legacy = randomHabits(today: today, newFields: false)
    let new = CultivationEngine.sources(habits: legacy, today: today)
    let old = referenceSources(habits: legacy, today: today)
    if sourceSignature(new) != sourceSignature(old) { sourcesMismatch += 1 }
    let habits = randomHabits(today: today, newFields: true)
    let perfectDays = Set(CultivationEngine.sources(habits: habits, today: today).filter { $0.kind == "perfect" }.map(\.day))
    for day in LocalDay.range(today.adding(days: -40), today) where CultivationEngine.isPerfectDay(day, habits: habits) != perfectDays.contains(day) {
        perfectMismatch += 1
    }
}
check(sourcesMismatch == 0, "旧数据（无归档日 / 创建日 / 当时目标）的修为来源与改动前完全一致（300 组）：不一致 \(sourcesMismatch) 组")
check(perfectMismatch == 0, "isPerfectDay 与修为里的“功课圆满”逐日一致（300 组）：不一致 \(perfectMismatch) 天")

// 归档、新建习惯、改数量目标：不改写历史修为
func xp(_ habits: [HabitInput]) -> CultivationState {
    CultivationEngine.compute(sources: CultivationEngine.sources(habits: habits, today: today), config: CultivationConfig(), today: today)
}
func history(_ state: CultivationState) -> [LocalDay: Int] { state.perDay.filter { $0.key < today } }
let habitStart = today.adding(days: -19)
let steady = HabitSpec(frequency: .daily, startDay: habitStart)
let steadyLogs = LocalDay.range(habitStart, today).map { HabitLogValue(day: $0, completed: true, quantity: nil) }
let patchy = HabitSpec(frequency: .daily, startDay: habitStart)
let patchyLogs = LocalDay.range(habitStart, today.adding(days: -1)).filter { $0.jdn % 2 == 0 }.map { HabitLogValue(day: $0, completed: true, quantity: nil) }
let beforeArchive = xp([(steady, steadyLogs, false), (patchy, patchyLogs, false)])
var archivedToday = patchy
archivedToday.archivedDay = today
let afterArchive = xp([(steady, steadyLogs, false), (archivedToday, patchyLogs, true)])
check(history(afterArchive) == history(beforeArchive) && afterArchive.totalXP - beforeArchive.totalXP == CultivationEngine.perfectDayXP,
      "归档常漏打的习惯：此前修为不变（\(beforeArchive.totalXP) → \(afterArchive.totalXP)，只有今天起不再要求它）")
check(xp([(steady, steadyLogs, false), (archivedToday, patchyLogs, false)]) == beforeArchive, "取消归档后与从未归档相同")
let oldArchived: [HabitInput] = [(steady, steadyLogs, false), (patchy, patchyLogs, true)]
check(xp(oldArchived).totalXP == CultivationEngine.compute(sources: referenceSources(habits: oldArchived, today: today), config: CultivationConfig(), today: today).totalXP,
      "旧数据里没有归档日的已归档习惯，仍按原来的方式完全不计")

let soloSteady = xp([(steady, steadyLogs, false)])
let backdated = HabitSpec(frequency: .daily, startDay: habitStart.adding(days: -30), createdDay: today)
let withBackdated = xp([(steady, steadyLogs, false), (backdated, [], false)])
check(history(withBackdated) == history(soloSteady) && soloSteady.totalXP - withBackdated.totalXP == CultivationEngine.perfectDayXP,
      "新建习惯把开始日期设在过去：过去的圆满不被抹掉（\(soloSteady.totalXP) → \(withBackdated.totalXP)，只有今天要求它）")
let backfill = (1...3).map { HabitLogValue(day: today.adding(days: -$0), completed: true, quantity: nil) }
check(xp([(steady, steadyLogs, false), (backdated, backfill, false)]).totalXP == withBackdated.totalXP + 3 * CultivationEngine.habitXP,
      "创建日之前补卡：每次 +\(CultivationEngine.habitXP)，原有的圆满保留")

let reading = (1...6).map { HabitLogValue(day: today.adding(days: -$0), completed: true, quantity: 30) }
var reading30 = HabitSpec(frequency: .daily, targetValue: 30, startDay: today.adding(days: -6))
let xpAt30 = xp([(reading30, reading, false)])
reading30.targetValue = 45
let xpAt45 = xp([(reading30, reading.map { var log = $0; log.target = 30; return log }, false)])
check(xpAt30.totalXP == 6 * 30 && xpAt45 == xpAt30, "数量目标 30 → 45（改之前把旧打卡记成当时的 30）：历史修为不变 \(xpAt45.totalXP)")
let plainLogs = (1...6).map { HabitLogValue(day: today.adding(days: -$0), completed: true, quantity: nil) }
let plain = HabitSpec(frequency: .daily, startDay: today.adding(days: -6))
var plainWithTarget = plain
plainWithTarget.targetValue = 30
check(xp([(plainWithTarget, plainLogs.map { var log = $0; log.target = 0; return log }, false)]) == xp([(plain, plainLogs, false)]),
      "给原来没有数量目标的习惯加上目标（旧打卡记为 0）：历史修为不变")

// 夏令时切换日：按墙钟时刻组装（悉尼 2026-10-04 进入夏令时，2026-04-05 结束）
if let sydney = TimeZone(identifier: "Australia/Sydney") {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = sydney
    func wallClock(_ key: String, _ minutes: Int) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: LocalDay(key: key)!.date(minutes: minutes, timeZone: sydney))
        return "\(c.month!)-\(c.day!) \(c.hour!):\(c.minute!)"
    }
    let nine = ["2026-10-04", "2026-04-05", "2026-10-14"].map { wallClock($0, 540) }
    check(nine == ["10-4 9:0", "4-5 9:0", "10-14 9:0"], "夏令时切换日的 09:00 仍是当地 09:00：\(nine)")
    check(wallClock("2026-10-04", 150) == "10-4 3:30", "被夏令时跳过的 02:30 顺延到 03:30：\(wallClock("2026-10-04", 150))")
    check(wallClock("2026-10-04", 0) == "10-4 0:0" && wallClock("2026-10-04", 1440) == "10-5 0:0" && wallClock("2026-10-04", -60) == "10-3 23:0",
          "零点与跨日的分钟数")
}

// Legacy import
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : LegacyReader.defaultDatabaseURL.path
if FileManager.default.fileExists(atPath: path) {
    do {
        let snapshot = try LegacyReader.read(url: URL(fileURLWithPath: path))
        let mapped = LegacyMapper.map(snapshot)
        print("— 旧版数据：schema \(snapshot.schemaVersion)，\(snapshot.recordCount) 条记录，设置 \(snapshot.settings.count) 项，附加表 \(snapshot.extras.mapValues(\.count))")
        for (kind, rows) in snapshot.collections.sorted(by: { $0.key < $1.key }) where !rows.isEmpty { print("    \(kind): \(rows.count)") }
        print("— 映射：档案 \(mapped.profiles.count)，目标 \(mapped.goals.count)，日程 \(mapped.events.count)，习惯 \(mapped.habits.count)，打卡 \(mapped.habitLogs.count)，作息 \(mapped.routine.count)")
        print("— 设置：时区 \(mapped.settings.timezoneID ?? "-")，境界 \(mapped.settings.cultivation?.realms.joined(separator: "/") ?? "-")")
        check(mapped.events.count == (snapshot.collections["calendar"] ?? []).count, "日程全部映射")
        check(mapped.events.allSatisfy { $0.startMinute != nil }, "日程时间全部解析")
        check(LegacyMapper.timestamp("2026-09-30T10:47:52.261242+00:00") != nil, "解析 Python 微秒时间戳")
        if let profile = mapped.profiles.first {
            let unknown = Set(profile.fields.keys).subtracting(ProfileCatalog.knownKeys)
            check(true, "档案字段 \(profile.fields.count) 个，目录外字段：\(unknown.sorted())")
        }
        let week = LocalDay(key: "2026-10-12")!
        for e in mapped.events {
            let rule = RecurrenceRule(start: LocalDay(key: e.dateKey)!, kind: e.recurrence, interval: e.interval, weekdays: e.weekdays,
                                      repeatUntil: e.repeatUntil.flatMap(LocalDay.init(key:)), stopBefore: e.stopBefore.flatMap(LocalDay.init(key:)),
                                      excluded: Set(e.excludedDates), overrides: OccurrencePatch.decodeMap(e.overridesJSON))
            let days = rule.occurrences(from: week, to: week.adding(days: 6)).map { $0.scheduledDay.weekdayName }
            print("    \(e.title)｜\(rule.summary)｜本周：\(days.joined(separator: ","))")
        }
        for w in mapped.warnings { print("    ⚠︎ \(w)") }

        // 灵石账簿：与旧版算法逐项对照
        if let raw = snapshot.settings["finance_ledger_v1"] {
            do {
                let ledger = try FinanceLedger.decode(Data(raw.utf8))
                check(!ledger.transactions.isEmpty, "账簿解码：\(ledger.transactions.count) 笔、\(ledger.sources.count) 个来源、\(ledger.monthlyReports.count) 份月报")
                let again = try FinanceLedger.decode(try ledger.encoded())
                check(again.transactions == ledger.transactions && again.sources == ledger.sources && again.monthlyReports == ledger.monthlyReports, "账簿编码后再解码完全一致")
                var parsed: [FinanceTransaction] = []
                for source in ledger.sources { parsed += try FinanceEngine.parseCSV(source.rawCsv, account: source.account) }
                let stored = Dictionary(uniqueKeysWithValues: ledger.transactions.map { ($0.id, $0) })
                check(Set(parsed.map(\.id)) == Set(stored.keys), "重新解析原始 CSV：交易 ID 与旧版完全一致（\(parsed.count) 笔）")
                let autoRows = parsed.filter { stored[$0.id]?.classification == "automatic" }
                let mismatched = autoRows.filter { p in let o = stored[p.id]!; return o.category != p.category || o.kind != p.kind || o.needsReview != p.needsReview || o.reason != p.reason }
                check(mismatched.isEmpty, "自动分类与旧版一致（\(autoRows.count) 笔）" + (mismatched.isEmpty ? "" : "，不一致：\(mismatched.prefix(3).map(\.description))"))
                if let old = ledger.monthlyReports.first {
                    let draft = FinanceEngine.reportDraft(ledger, month: old.month)
                    check(draft.summary == old.summary, "\(old.month) 月度统计与旧版月报一致：消费 \(FinanceEngine.money(draft.summary.spendCents))，退款 \(FinanceEngine.money(draft.summary.refundCents))，其他扣款 \(FinanceEngine.money(draft.summary.excludedCents))")
                    if draft.summary != old.summary { print("      新：\(draft.summary)\n      旧：\(old.summary)") }
                    check(draft.comparison == old.comparison, "环比与旧版一致：\(FinanceEngine.money(draft.comparison?.spendChangeCents ?? 0))")
                    check(draft.budgets == old.budgets, "预算统计与旧版一致")
                    check(draft.services == old.services, "固定账单检查与旧版一致（\(draft.services.count) 项）")
                    if draft.services != old.services { for (a, b) in zip(draft.services, old.services) where a != b { print("      新：\(a)\n      旧：\(b)") } }
                    check(draft.suggestions == old.suggestions, "下月三件事与旧版一致")
                    check(draft.largePurchases == old.largePurchases && draft.topCategories == old.topCategories, "大额支出与主要类别一致")
                    let html = FinanceReportHTML.render(old)
                    check(html.contains("月度修习录") && html.contains("软件与会员"), "月报 HTML 导出（\(html.count) 字）")
                }
                print("    账簿月份：\(FinanceEngine.ledgerMonths(ledger))，默认显示 \(FinanceEngine.defaultMonth(ledger, today: LocalDay(key: "2026-10-13")!))")
                var copy = ledger
                let preview = try FinanceEngine.previewImport(raw: ledger.sources[0].rawCsv, account: ledger.sources[0].account, ledger: copy, period: nil)
                check(preview.newCount == 0 && preview.duplicateCount > 0, "重复导入同一份 CSV：新增 \(preview.newCount)、重复 \(preview.duplicateCount)")
                var empty = FinanceLedger()
                let merged = FinanceEngine.merge(ledger, into: &empty)
                check(merged.transactions == ledger.transactions.count && FinanceEngine.merge(ledger, into: &empty).transactions == 0, "合并旧版账本可重复执行而不产生重复")
                let row = copy.transactions.first { $0.category == "待分类消费" && FinanceEngine.ruleEligible($0) }!
                let same = FinanceEngine.sameMerchant(in: copy, as: row, category: "餐饮与外卖")
                try FinanceEngine.updateTransaction(in: &copy, id: row.id, category: "餐饮与外卖", note: "测试", remember: true)
                check(copy.merchantRules.count == 1 && copy.transactions.first { $0.id == row.id }?.needsReview == false, "逐笔确认并记住商户（同商户另有 \(same.count) 笔可批量归类）")
                check((try? FinanceEngine.cents("+1,234.5")) == 123450 && (try? FinanceEngine.cents("-0.07")) == -7 && (try? FinanceEngine.cents("1.234")) == nil, "金额解析")
            } catch {
                check(false, "账簿检查失败：\(error)")
            }
        }

        // 用真实旧数据渲染一份 AI 摘要（隐去姓名），检查格式。
        // 注意：真正的摘要由 SummaryCollector 从 SwiftData 收集（这里编译不到），统计结果要靠 --self-test 检查；
        // 下面按与它相同的规则现算日程与时长（不是写死的数字），修为一栏只是格式样例（0 修为）。
        let hoursDays = 28
        let today = LocalDay(key: "2026-10-13")!
        var profileFields = mapped.profiles.first?.fields ?? [:]
        let hiddenNames = ["name", "nickname", "preferred_name"].compactMap { profileFields[$0] }.filter { !$0.isEmpty }
        for key in ["name", "nickname", "preferred_name"] { profileFields.removeValue(forKey: key) }
        profileFields = profileFields.filter { !$0.value.isEmpty && ProfileCatalog.knownKeys.contains($0.key) }
        var upcoming: [PlannerSummary.Occurrence] = []
        var recurring: [PlannerSummary.RecurringEvent] = []
        var hourItems: [(category: String, start: Int?, end: Int?)] = []
        for e in mapped.events {
            let rule = RecurrenceRule(start: LocalDay(key: e.dateKey)!, kind: e.recurrence, interval: e.interval, weekdays: e.weekdays,
                                      repeatUntil: e.repeatUntil.flatMap(LocalDay.init(key:)), stopBefore: e.stopBefore.flatMap(LocalDay.init(key:)),
                                      excluded: Set(e.excludedDates), overrides: OccurrencePatch.decodeMap(e.overridesJSON))
            let ended = (rule.repeatUntil.map { $0 < today } ?? false) || (rule.stopBefore.map { $0 <= today } ?? false)
            if rule.kind != .none, !ended {
                recurring.append(.init(title: e.title, category: e.category, time: ClockTime.range(e.startMinute, e.endMinute), rule: rule.summary, location: e.location))
            }
            for o in rule.occurrences(from: today, to: today.adding(days: hoursDays - 1)) {
                let patch = rule.overrides[o.sourceDay.key]
                let start = patch?.start_time.flatMap { ClockTime.minutes(from: $0) } ?? e.startMinute
                let end = patch?.end_time.flatMap { ClockTime.minutes(from: $0, allowEndOfDay: true) } ?? e.endMinute
                hourItems.append((e.category, start, end))
                guard o.scheduledDay <= today.adding(days: 6) else { continue }
                upcoming.append(.init(date: o.scheduledDay.key, weekday: o.scheduledDay.weekdayName, time: ClockTime.range(start, end),
                                      title: patch?.title ?? e.title, category: e.category))
            }
        }
        let hours = ScheduleHours.weeklyAverage(hourItems, days: hoursDays)
        upcoming.sort { ($0.date, $0.time) < ($1.date, $1.time) }
        recurring.sort { $0.title < $1.title }
        let sample = CultivationEngine.state(for: 0, config: CultivationConfig())
        let summary = PlannerSummary(generatedAt: "2026-10-13 15:00", periodDays: 30, today: today.key, profile: profileFields, goals: [],
                                     recurringEvents: recurring, upcoming: upcoming,
                                     scheduleHoursByCategory: hours,
                                     routine: [], routineHoursByKind: [], habits: [],
                                     cultivation: .init(realm: sample.title, totalXP: sample.totalXP, toNextRealm: sample.xpToNext, nextRealm: sample.nextRealmName),
                                     focusQuestion: "", hoursWindowDays: hoursDays)
        print("    日程每周平均时长（\(today.key) 起 \(hoursDays) 天，按实际规则现算）：" + hours.map { "\($0.category) \($0.hoursPerWeek) 小时" }.joined(separator: "，"))
        let md = SummaryRenderer.markdown(summary, preamble: "")
        check(!hiddenNames.contains { md.contains($0) } && md.contains("## 日程"), "AI 摘要：隐去姓名、包含日程")
        print(md.split(separator: "\n").prefix(40).map { "    | " + $0 }.joined(separator: "\n"))
        check(SummaryRenderer.json(summary).contains("\"recurringEvents\""), "AI 摘要 JSON 可编码")
    } catch {
        check(false, "读取旧版数据失败：\(error.localizedDescription)")
    }
} else {
    print("（未找到旧版数据库，跳过导入检查）")
}
// MARK: 飞剑传书解析（纯 Core，不依赖旧版数据）

do {
    func parse(_ json: String, base: String = "2026-10-13", latest: String = "2026-10-14") throws -> CourierPayload {
        try CourierParser.parse(Data(json.utf8), relativeTo: LocalDay(key: base)!, latest: LocalDay(key: latest)!)
    }
    func rejected(_ json: String) -> Bool { (try? parse(json)) == nil }
    let alias = try parse(#"{"type":"event","title":"a","date":"2026-10-14","time":"14:00"}"#)
    if case let .event(_, start, _, _, _, _, _) = alias.items[0] {
        check(start == 840 && alias.warnings.contains { $0.contains("time") }, "传书别名：time 当作 start，并在回执里提醒")
    } else { check(false, "传书别名：应解析为日程") }
    let unknown = try parse(#"{"type":"note","body":"a","tag":"x","moods":4}"#)
    if case let .entry(_, _, _, _, _, _, _, tags) = unknown.items[0] {
        check(tags == ["x"] && unknown.warnings.contains { $0.contains("moods") }, "传书别名：tag → tags；不认识的字段 moods 被忽略并提醒")
    } else { check(false, "传书：灵感应解析为修行录条目") }
    check((try? parse(#"{"type":"diary","body":"a","mood":null}"#)) != nil, "传书：mood 为 null 视同没写")
    for bad in [#"{"type":"diary","body":"a","mood":true}"#, #"{"type":"diary","body":"a","mood":4.7}"#,
                #"{"type":"expense","amount":true,"description":"a"}"#, #"{"type":"checkin","habit":"读书","quantity":-5}"#,
                #"{"type":"checkin","habit":"读书","quantity":1e999}"#] {
        check(rejected(bad), "传书拒收：\(bad)")
    }
    if case let .checkin(_, _, quantity) = try parse(#"{"type":"checkin","habit":"读书","quantity":"5"}"#).items[0] {
        check(quantity == 5, "传书：数量写成字符串 \"5\" 也认")
    }
    if case let .expense(_, cents, _, _, _) = try parse(#"{"type":"expense","amount":"$1,234.50","description":"a"}"#).items[0] {
        check(cents == 123450, "传书：金额字符串 $1,234.50 → 123450 分")
    }
    do {
        _ = try parse("{\"type\":\"diary\",\"body\":\"a\nb\"}")
        check(false, "传书：引号里直接换行应报错")
    } catch {
        let message = error.localizedDescription
        check(message.contains("第 1 行") && message.contains("\\n"), "传书语法错误指出位置并提示换行写成 \\n")
    }
    // 相对日期按写入那天（base）换算；打卡不能晚于真实的今天（latest）
    if case let .entry(_, day, _, _, _, _, _, _) = try parse(#"{"type":"note","body":"昨晚写的"}"#).items[0] {
        check(day.key == "2026-10-13", "传书：省略日期时按文件写入那天计算（\(day.key)）")
    }
    check(rejected(#"{"type":"checkin","habit":"读书","date":"2026-10-15"}"#), "传书：不能为未来打卡")
    check((try? parse(#"{"type":"checkin","habit":"读书","date":"tomorrow"}"#)) != nil, "传书：写入那天的“明天”就是收录那天，可以打卡")
    // 金额字符串：逗号后一两位是小数点（与随手记、手记一致），三位一组的是千分位；别的写法拒收
    func cents(_ amount: String) -> Int? {
        guard let payload = try? parse(#"{"type":"expense","amount":"\#(amount)","description":"a"}"#),
              case let .expense(_, value, _, _, _) = payload.items[0] else { return nil }
        return value
    }
    check(cents("12,5") == 1250 && cents("18，5") == 1850 && cents("1,234.50") == 123450,
          "传书：金额 \"12,5\" → 1250 分、\"18，5\" → 1850 分、\"1,234.50\" → 123450 分")
    for bad in ["1.234,56", "0x10", "1e2"] {
        check(rejected(#"{"type":"expense","amount":"\#(bad)","description":"a"}"#), "传书拒收金额字符串 \"\(bad)\"")
    }
    // value 写成 true：照收、不记数量，回执提醒；count 写成文字：按 quantity 理解后拒收并说明
    do {
        let payload = try parse(#"{"type":"checkin","habit":"读书","value":true}"#)
        if case let .checkin(_, _, quantity) = payload.items[0] {
            check(quantity == nil && payload.warnings.contains { $0.contains("value") }, "传书：打卡 value 为 true 时照收、不记数量，并提醒 value")
        } else { check(false, "传书：value 为 true 的打卡应解析为打卡") }
    } catch {
        check(false, "传书：value 为 true 的打卡应能收录（\(error.localizedDescription)）")
    }
    do {
        _ = try parse(#"{"type":"checkin","habit":"读书","count":"一次"}"#)
        check(false, "传书：count 写成文字应拒收")
    } catch {
        check(error.localizedDescription.contains("count（按 quantity 理解）"), "传书：count 写成文字时拒收，并说明按 quantity 理解")
    }
} catch {
    check(false, "传书解析检查失败：\(error)")
}

// MARK: 灵石账簿：CSV 解析、手记金额、正数入账的类别（纯 Core）

do {
    let quoted = try FinanceEngine.csvRecords("a,JOE\"S CAFE,b\n")
    check(quoted.count == 1 && quoted[0] == ["a", "JOE\"S CAFE", "b"], "CSV：字段中间的引号按普通字符保留（与 Python csv 一致）")
    check((try? FinanceEngine.csvRecords("a,\"bc\n")) == nil, "CSV：引号没闭合时报错，不再吞掉后面的行")
    check((try? FinanceEngine.parseCSV("1/10/26,-5.00,COLES,100.00\n", account: "A")) == nil, "CSV：两位年份的日期被拒")
    do {
        _ = try FinanceEngine.parseCSV("01/10/2026,-5.00,COLES,\n", account: "A")
        check(false, "CSV：余额为空应报错")
    } catch {
        check(error.localizedDescription.hasPrefix("第 1 行余额列"), "CSV：余额无效时指出第几行哪一列")
    }
    check((try? FinanceEngine.manualCents("18,5")) == 1850 && (try? FinanceEngine.manualCents("1,234.50")) == 123450
          && (try? FinanceEngine.manualCents("18，5")) == 1850, "手记金额：18,5 是 18.50 而不是 185，千分位照认")
    check(["18.555", "-5", "0", "1,2345"].allSatisfy { (try? FinanceEngine.manualCents($0)) == nil }, "手记金额：三位小数、负数、0、乱写的逗号都拒收")
    // 随手记、手记一笔、交易编辑、飞剑传书共用这一套规则（这组用例原先在 --self-test 里测随手记）
    let amounts: [(String, Int?)] = [("18.5", 1850), ("$18.50", 1850), ("1,234.50", 123450), ("18,5", 1850), ("18，5", 1850),
                                     ("１８．５", 1850), (".5", 50), ("18.555", nil), ("0", nil), ("-5", nil), ("abc", nil), ("1000000", nil),
                                     ("A$18", 1800), ("＄１８", 1800), ("$ 18.50", 1850), ("1 234.50", 123450), ("999999.99", 99_999_999)]
    let badAmounts = amounts.filter { (try? FinanceEngine.manualCents($0.0)) != $0.1 }.map(\.0)
    check(badAmounts.isEmpty, "手记金额解析（18,5 是 18.50，全角数字与 A$ 照收）" + (badAmounts.isEmpty ? "" : "，不符：\(badAmounts)"))
    func amountProblem(_ text: String) -> String {
        do { _ = try FinanceEngine.manualCents(text); return "" } catch { return error.localizedDescription }
    }
    check(amountProblem("abc").contains("看不懂") && amountProblem("18.555").contains("两位小数")
          && amountProblem("0").contains("大于 0") && amountProblem("1000000").contains("上限"),
          "手记金额出错时分别说明：看不懂、超过两位小数、不大于 0、太大")
    var ledger = FinanceLedger()
    ledger.transactions = try FinanceEngine.parseCSV("01/10/2026,-30.00,AMAZON AU,100.00\n03/10/2026,+30.00,AMAZON AU,130.00\n", account: "测试")
    let refund = ledger.transactions.first { $0.amountCents > 0 }!
    try FinanceEngine.updateTransaction(in: &ledger, id: refund.id, category: "购物", note: "", remember: false)
    let facts = FinanceEngine.monthFacts(ledger, month: "2026-10")
    check(ledger.transactions.first { $0.id == refund.id }?.kind == "退款" && facts.refundCents == 3000, "正数入账确认成消费类别即为退款（退款 $30）")
    try FinanceEngine.updateTransaction(in: &ledger, id: refund.id, category: "转入款待确认", note: "", remember: false)
    check(FinanceEngine.monthFacts(ledger, month: "2026-10").refundCents == 0, "改回不计入消费的类别后不再算退款")
    // 手记可改可删，银行流水不行
    var manual = ManualExpense.transaction(day: LocalDay(key: "2026-10-05")!, cents: 1234, category: "餐饮与外卖", description: "午饭", note: "", reason: "自检")
    ledger.transactions.append(manual)
    try FinanceEngine.editManual(in: &ledger, id: manual.id, date: "2026-10-04", cents: 1800, description: "改过")
    manual = ledger.transactions.first { $0.id == manual.id }!
    check(manual.amountCents == -1800 && manual.date == "2026-10-04" && manual.description == "改过", "手记可以改金额、日期、说明")
    try FinanceEngine.deleteTransaction(in: &ledger, id: manual.id)
    check(!ledger.transactions.contains { $0.id == manual.id }, "手记可以删除")
    let before = ledger.transactions
    check((try? FinanceEngine.deleteTransaction(in: &ledger, id: refund.id)) == nil && ledger.transactions == before, "银行导入的交易不能单删")
} catch {
    check(false, "账簿纯逻辑检查失败：\(error)")
}

// MARK: 灵石账簿：手记与银行流水配对、“手记”账户名、批量归类、撤销导入（纯 Core）

do {
    let today = LocalDay(key: "2026-10-14")!
    let csv = "01/10/2026,-18.50,CAFE A,1000.00\n03/10/2026,-18.50,RAMEN SHOP,981.50\n"
    let lunch = ManualExpense.transaction(day: LocalDay(key: "2026-10-03")!, cents: 1850, category: "餐饮与外卖",
                                          description: "午饭", note: "现金", reason: "手动记账")
    // (a) 两笔同价银行流水，手记配日期最近的那笔
    var ledger = FinanceLedger()
    ledger.transactions = [lunch]
    let preview = try FinanceEngine.previewImport(raw: csv, account: "CommBank 0123", ledger: ledger, period: nil, today: today)
    check(preview.manualMatches.count == 1 && preview.manualMatches[0].bank.description == "RAMEN SHOP",
          "疑似重复：10-03 的手记配同日的 RAMEN SHOP，而不是更早的 CAFE A")
    // (b) 银行账户名不能叫“手记”（前后空白也算）
    check((try? FinanceEngine.parseCSV(csv, account: " 手记 ")) == nil, "导入时账户名不能叫“手记”")
    // (c) 误记在“手记”名下的正数行不能按手记改写成扣款
    var bad = FinanceLedger()
    bad.transactions = try FinanceEngine.parseCSV("02/10/2026,-30.00,AMAZON AU,1000.00\n03/10/2026,30.00,REFUND AMAZON AU,1030.00\n", account: "X")
    for index in bad.transactions.indices { bad.transactions[index].account = ManualExpense.account }
    let positive = bad.transactions.first { $0.amountCents > 0 }!
    let unchanged = bad.transactions
    check((try? FinanceEngine.editManual(in: &bad, id: positive.id, date: positive.date, cents: 3000, description: positive.description)) == nil
          && bad.transactions == unchanged, "“手记”名下的正数行不能按手记修改，账本不变")
    // (d) 批量归类不覆盖手记记着的来源
    var courier = FinanceLedger()
    courier.transactions = [ManualExpense.transaction(id: "courier-1", day: LocalDay(key: "2026-10-03")!, cents: 1850, category: "待分类消费",
                                                      description: "午饭", note: "", reason: "飞剑传书 · Claude")]
    FinanceEngine.batchClassify(in: &courier, ids: ["courier-1"], category: "餐饮与外卖")
    check(courier.transactions[0].reason == "飞剑传书 · Claude" && courier.transactions[0].category == "餐饮与外卖",
          "批量归类后传书手记的来源（飞剑传书 · Claude）不变")
    // (e) 导入 → 删掉疑似重复的手记 → 撤销这次导入：账本与导入前逐字节相同
    let original = try ledger.encoded()
    FinanceEngine.applyImport(raw: csv, preview: preview, period: nil, to: &ledger)
    _ = try FinanceEngine.deleteDuplicateManual(in: &ledger, id: lunch.id, source: ledger.sources.last)
    let latest = ledger.sources[FinanceEngine.latestImportIndex(ledger)!]
    try FinanceEngine.undoLatestImport(in: &ledger, expected: latest)
    check(try ledger.encoded() == original, "导入后删了疑似重复的手记，撤销这次导入后账本与导入前逐字节相同")
    // (f) 先导入银行流水、后补记手记：找到 3 天内同金额的那笔
    var later = FinanceLedger()
    let bankOnly = "03/10/2026,-18.50,RAMEN SHOP,981.50\n10/10/2026,-18.50,FAR AWAY,963.00\n"
    FinanceEngine.applyImport(raw: bankOnly, preview: try FinanceEngine.previewImport(raw: bankOnly, account: "CommBank 0123", ledger: later, period: nil, today: today),
                              period: nil, to: &later)
    let probe = ManualExpense.transaction(day: LocalDay(key: "2026-10-05")!, cents: 1850, category: "餐饮与外卖", description: "", note: "", reason: "")
    check(FinanceEngine.existingBankMatches(for: probe, in: later).map(\.description) == ["RAMEN SHOP"], "后补记 10-05 的 18.50 手记：提示账上 10-03 的 RAMEN SHOP")
} catch {
    check(false, "账簿配对与撤销检查失败：\(error)")
}

// MARK: 作息跨夜切段（今日行程、时辰卷底纹、一周作息图共用）

do {
    typealias Seg = RoutineSpan.Segment
    // 0：周一 23:30–07:30 睡眠；1：周一 08:00–09:00；2：周日 22:00–06:00（跨到下周一）；3：周二 23:00–00:00（正好午夜结束）
    let blocks: [(weekday: Int, start: Int, end: Int)] = [(0, 1410, 450), (0, 480, 540), (6, 1320, 360), (1, 1380, 0)]
    check(RoutineSpan.segments(blocks, weekday: 0) == [Seg(index: 0, start: 1410, end: 1440, carried: false),
                                                      Seg(index: 1, start: 480, end: 540, carried: false),
                                                      Seg(index: 2, start: 0, end: 360, carried: true)],
          "作息切段：周一 23:30–07:30 当天只到 24:00；周日夜里跨到周一的那段从 0:00 起算作昨晚延续")
    check(RoutineSpan.segments(blocks, weekday: 1) == [Seg(index: 0, start: 0, end: 450, carried: true),
                                                      Seg(index: 3, start: 1380, end: 1440, carried: false)],
          "作息切段：周二 0:00–07:30 是周一的延续；周二 23:00–00:00 只占当天到 24:00")
    check(RoutineSpan.segments(blocks, weekday: 2).isEmpty, "作息切段：正好 0:00 结束的跨夜作息，次日没有延续段")
    check(RoutineSpan.segments([(3, 600, 600)], weekday: 3) == [Seg(index: 0, start: 600, end: 1440, carried: false)]
          && RoutineSpan.segments([(3, 600, 600)], weekday: 4) == [Seg(index: 0, start: 0, end: 600, carried: true)],
          "作息切段：开始等于结束按跨夜整 24 小时切成两段")
}

// MARK: 月份与时间的写法

do {
    let today = LocalDay(key: "2026-10-14")!
    check(MonthKey.label("2026-10") == "2026年10月" && MonthKey.label("2026-10", relativeTo: today) == "10月"
          && MonthKey.label("2025-12", relativeTo: today) == "2025年12月" && MonthKey.label("oops") == "oops",
          "月份写成“2026年10月”，当年可省略年份；认不出的原样返回")
    check(LocalDay(key: "2026-10-01")!.label(relativeTo: today) == "10月1日" && LocalDay(key: "2025-03-09")!.label(relativeTo: today) == "2025年3月9日"
          && LocalDay(key: "2026-10-01")!.axisLabel == "10/1" && today.monthKey == "2026-10",
          "日期写法：当年省略年份；图表横轴写“10/1”（月在前）")
    let sydney = TimeZone(identifier: "Australia/Sydney")!
    let moment = LocalDay(key: "2026-10-14")!.date(minutes: 21 * 60 + 30, timeZone: sydney)
    check(DateText.stamp(moment, timeZone: sydney) == "2026-10-14 21:30", "时间戳写法：2026-10-14 21:30")
    let file = DateText.fileStamp(moment)
    check(file.count == 15 && DateText.date(fileStamp: file).map { abs($0.timeIntervalSince(moment)) < 1 } == true
          && DateText.date(fileStamp: "not-a-stamp-xx") == nil, "传书归档名的时间（yyyyMMdd-HHmmss）写出后能原样解析回来")
}

// MARK: 单次改期的写入与“从这次起修改”的拆分（原在 ScheduleView，挪进 Core 后在这里测）

do {
    func object(_ json: String?) -> NSDictionary? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }
    let first = OccurrenceOverrides.write(OccurrencePatch(title: "改"), for: "2026-10-14", into: "")
    check(object(first) == ["2026-10-14": ["title": "改"]] as NSDictionary, "单次改期：空的改期里写入一次：\(first ?? "nil")")
    // 合并：旧版不认识的字段（foo）原样保留；patch 里没给的字段（title）去掉；别的日子不动
    let legacy = #"{"2026-10-14":{"title":"a","foo":"bar"},"2026-10-21":{"notes":"x"}}"#
    let merged = OccurrenceOverrides.write(OccurrencePatch(start_time: "14:00", end_time: "15:00"), for: "2026-10-14", into: legacy)
    check(object(merged) == ["2026-10-14": ["foo": "bar", "start_time": "14:00", "end_time": "15:00"], "2026-10-21": ["notes": "x"]] as NSDictionary,
          "单次改期：按 JSON 合并，保留不认识的字段与别的日子：\(merged ?? "nil")")
    check(OccurrencePatch.decodeMap(merged ?? "")["2026-10-14"]?.start_time == "14:00", "单次改期：写出的 JSON 能被重复规则读回")
    let removed = OccurrenceOverrides.write(nil, for: "2026-10-14", into: merged ?? "")
    check(object(removed) == ["2026-10-21": ["notes": "x"]] as NSDictionary && OccurrenceOverrides.write(OccurrencePatch(), for: "2026-10-21", into: removed ?? "") == "",
          "单次改期：patch 为空时删掉这一次，全删光时写回空字符串")
    check(OccurrenceOverrides.write(OccurrencePatch(title: "x"), for: "2026-10-14", into: "not json") == nil, "单次改期：原有数据无法解析时拒绝改动")

    let day = LocalDay(key: "2026-10-14")!
    check(SeriesSplit.movesToNew("2026-10-14", from: day) && !SeriesSplit.movesToNew("2026-10-13", from: day) && !SeriesSplit.movesToNew("oops", from: day),
          "从这次起修改：这一天及以后归新系列，之前的和认不出的键留在原系列")
    check(SeriesSplit.partitionOverrides("", at: day).map { $0.before == "" && $0.after == "" } == true, "从这次起修改：没有改期时两边都是空")
    let parts = SeriesSplit.partitionOverrides(#"{"2026-10-07":{"title":"早"},"2026-10-14":{"foo":1},"2026-10-21":{"notes":"晚"},"bad":{"x":"y"}}"#, at: day)
    check(object(parts?.before) == ["2026-10-07": ["title": "早"], "bad": ["x": "y"]] as NSDictionary
          && object(parts?.after) == ["2026-10-14": ["foo": 1], "2026-10-21": ["notes": "晚"]] as NSDictionary,
          "从这次起修改：改期按原定日期切成两半，不认识的字段原样带走")
    check(SeriesSplit.partitionOverrides("not json", at: day) == nil, "从这次起修改：改期数据无法解析时拒绝拆分")
}

// MARK: 习惯统计可以比较（功课页的热力图、最近记录按它判断统计变没变，没变就不重画）

do {
    let today = LocalDay(key: "2026-10-14")!
    let spec = HabitSpec(frequency: .daily, targetValue: 30, startDay: today.adding(days: -30))
    let logs = (1...20).map { HabitLogValue(day: today.adding(days: -$0), completed: true, quantity: Double(20 + $0), target: $0 % 3 == 0 ? 25 : nil) }
    let stats = HabitStats(spec: spec, logs: logs, today: today)
    check(stats == HabitStats(spec: spec, logs: logs.reversed(), today: today), "习惯统计：同样的打卡（先后不同）算出的统计相等")
    var changed = logs
    changed[3].quantity = 99
    var retargeted = logs
    retargeted[4].target = 0
    var otherSpec = spec
    otherSpec.targetValue = 31
    check(stats != HabitStats(spec: spec, logs: changed, today: today) && stats != HabitStats(spec: spec, logs: retargeted, today: today)
          && stats != HabitStats(spec: otherSpec, logs: logs, today: today) && stats != HabitStats(spec: spec, logs: logs, today: today.adding(days: 1))
          && stats != HabitStats(spec: spec, logs: Array(logs.dropLast()), today: today),
          "习惯统计：数量、当时的目标、设定、今天、打卡条数有一处不同就不相等")
    // 热力图的“最早一天”改用 stats.logs 的键：与把打卡的日期逐条解析再取最早的相同
    check(stats.logs.keys.min() == logs.map(\.day).min(), "习惯统计：按天的字典里最早的一天就是最早的打卡日")
}

// MARK: 飞剑传书摘要：一条一行（传书笺、撤销确认框按换行切条，内容里的换行不能把一条拆成几行）

do {
    let day = LocalDay(key: "2026-10-14")!
    let diary = CourierItem.entry(kind: .diary, day: day, minute: nil, title: "", body: "第一段\n\n  第二段  \r\n第三段", mood: nil, period: "", tags: [])
    check(diary.summary == "日记 · \(day.shortLabel) · 第一段 第二段 第三段" && !diary.summary.contains(where: \.isNewline),
          "传书摘要：没有标题时正文预览压成一行：\(diary.summary)")
    let titled = CourierItem.entry(kind: .note, day: day, minute: nil, title: "标题", body: "a\nb", mood: nil, period: "", tags: [])
    check(titled.summary == "灵感 · \(day.shortLabel) · 标题", "传书摘要：有标题时照旧只写标题")
    let event = CourierItem.event(day: day, start: 540, end: 600, title: "导师\n会议", location: "", category: "", notes: "")
    let expense = CourierItem.expense(day: day, cents: 1850, category: "餐饮与外卖", description: "午饭\n拉面", note: "")
    check(!event.summary.contains(where: \.isNewline) && expense.summary.contains("午饭 拉面 $18.50"), "传书摘要：日程标题、消费说明里的换行也压成一行")
    check(CourierItem.oneLine("写论文\n健身\n\n找工作", separator: "；") == "写论文；健身；找工作" && CourierItem.oneLine(" 不变 ") == " 不变 ",
          "传书摘要：多行档案内容用“；”连成一行，没有换行的内容原样不动")
}

// MARK: LocalDay：按字节拼写、按字节解析，与原来的 String(format:)、split 逐字一致

do {
    func oldKey(_ day: LocalDay) -> String { String(format: "%04d-%02d-%02d", day.year, day.month, day.day) }
    func oldParse(_ key: String) -> LocalDay? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let day = LocalDay(year: y, month: m, day: d)
        guard day.month == m, day.day == d else { return nil }
        return day
    }
    // 1899–1901（1900 不闰）、1999–2001（2000 闰）、2023–2025（2024 闰）每一天，含年初年末；再加 0 年、负年份、9999 → 10000 年前后与随机日子
    var days: [LocalDay] = []
    for (first, last) in [(1899, 1901), (1999, 2001), (2023, 2025)] {
        days += LocalDay.range(LocalDay(year: first, month: 1, day: 1), LocalDay(year: last, month: 12, day: 31))
    }
    days += LocalDay.range(LocalDay(year: -1, month: 12, day: 1), LocalDay(year: 1, month: 1, day: 31))
    days += LocalDay.range(LocalDay(year: 9999, month: 12, day: 1), LocalDay(year: 10000, month: 1, day: 31))
    days += (0..<3000).map { _ in LocalDay(jdn: Int.random(in: -2_000_000...6_000_000, using: &rng)) }
    let badKeys = days.filter { $0.key != oldKey($0) }
    check(badKeys.isEmpty, "LocalDay.key 与 String(format:) 逐字一致（\(days.count) 天，含闰年、年初年末、0 年、负年份、10000 年）"
          + (badKeys.isEmpty ? "" : "，不符：\(badKeys.prefix(3).map(oldKey))"))
    var keys = days.map(oldKey)
    keys += ["2024-02-29", "2023-02-29", "1900-02-29", "2000-02-29", "2026-02-30", "2026-04-31", "2026-13-01", "2026-00-10", "2026-10-00",
             "2026-10-32", "--2026-10-13", "2026-10-13-", "2026--10-13", "+026-10-13", "-026-10-13", "2026-+1-13", "2026-01-+5", "2026-1-13",
             "2026-10-1", "26-10-13", "２０２６-10-13", "2026-1٠-13", "2026/10/13", "", "-", "2026-10-1x", " 2026-10-13", "2026-10-13 ",
             "2026_10_13", "2026-10-13\n", "2026-10-13\r\n", "0000-01-01", "9999-12-31", "2026-10-13T00", "2026−10−13", "12345-01-01"]
    // 随机把标准写法里的一个字换掉，或删掉 / 多插一个字
    let noise: [Character] = ["0", "9", "-", "+", " ", "a", "٣", "/", "１", "\u{301}"]
    for _ in 0..<4000 {
        var chars = Array(pick(days).key)
        let at = Int.random(in: 0..<chars.count, using: &rng)
        switch Int.random(in: 0..<3, using: &rng) {
        case 0: chars[at] = pick(noise)
        case 1: chars.remove(at: at)
        default: chars.insert(pick(noise), at: at)
        }
        keys.append(String(chars))
    }
    let badParse = keys.filter { LocalDay(key: $0) != oldParse($0) }
    check(badParse.isEmpty, "LocalDay(key:) 与 split 解析结果一致（\(keys.count) 种写法，含不存在的日期、多余的“-”“+”、全角与阿拉伯数字）"
          + (badParse.isEmpty ? "" : "，不符：\(badParse.prefix(5))"))
}

// MARK: 灵石账簿：正则先按必需的字面片段预筛，结果与直接跑正则相同

do {
    check(FinanceEngine.requiredLiterals(#"UBER\s?\*\s?TRIP"#)?.map { $0.map { String(decoding: $0, as: UTF8.self) } } == [["UBER", "*", "TRIP"]]
          && FinanceEngine.requiredLiterals(#"OPENAI.*CHATGPT|ab?c"#)?.map { $0.map { String(decoding: $0, as: UTF8.self) } } == [["OPENAI", "CHATGPT"], ["A", "C"]]
          && FinanceEngine.requiredLiterals(#"TRANSFER (TO|FROM)"#) == nil && FinanceEngine.requiredLiterals(#"A|.*"#) == nil
          && FinanceEngine.requiredLiterals(#"^[0-9]+$"#) == nil && FinanceEngine.requiredLiterals(#"\d{2}"#) == nil,
          "正则预筛：取出必需的字面片段（可有可无的字拿掉）；括号、方括号、量词 + {} 等不认识的写法不预筛")
    var patterns = FinanceEngine.rules.map(\.pattern) + FinanceEngine.merchantGroups.map(\.pattern) + FinanceEngine.displayNames.map(\.pattern)
    patterns += [#"TRANSFER TO.*(COMMSEC|SELFWEALTH|STAKE|MOOMOO|SHARESIES|RAIZ|SPACESHIP)"#, #"TRANSFER (TO|FROM)|CREDIT TO ACCOUNT"#, #"WITHDRAWAL|CASH WITHDRAW|ATM "#,
                 #"RETURN|REFUND|REVERSAL"#, #"TRANSFER|CREDIT TO ACCOUNT|WITHDRAW|\bATM\b"#, #"^[0-9]*(\.[0-9]{0,2})?$"#,
                 #"AB?C"#, #"A\.B|C\\D"#, #"X*Y"#, #"KFC "#, #"YO-CHI"#, #"\bAU\b"#]
    // 文字：各条正则里的字面片段随机拼起来（大小写随机、片段之间随机隔开），专门造“缺一段”“差一个字”的近似命中；再加真实的银行描述与非 ASCII
    let fragments = ["UBER", "TRIP", "EATS", "*", " *", "OPENAI", "CHATGPT", "GOOGLE", "ONE", "APPLE", "COM/BILL", "APPLE.COM/BILL", "X CORP",
                     "PAID", "TELSTRA", "TELSTR", "OPTUS", "TELECOM", "DIDI", "MOBILITY", "DIDIMOBILITY", "AMZNPRIME", "MEMBERSHIP",
                     "ANYTIME FITNESS", "TATTS ONLINE", "HOYTS", "KFC", "YO-CHI", "TRANSPORT FOR NSW", "TFNSW", "TRANSFER", "TO", "FROM",
                     "CREDIT TO ACCOUNT", "WITHDRAW", "ATM", "REFUND", "INTERNATIONAL TRANSACTION FEE", "ACCOUNT", "FEE", "AB", "AC", "C", "X", "Y",
                     "A.B", "C\\D", "AU", "COLES", "WOOLWORTHS", "123", "\t", "\r\n", "  ", "-", "Á", "ＴＥＬＳＴＲＡ", "\u{212A}FC", "TEL\u{17F}TRA"]
    var texts = ["", " ", "OPENAI *CHATGPT SUBSCR", "openai *chatgpt", "UBER   * TRIP", "UBER\t*\tEATS", "UBERTRIP", "UBER*TRIP", "APPLEXCOM/BILL",
                 "TRANSFER TO COMMSEC", "ATM", "XATMX", "WOOLWORTHS 1234 SYDNEY NS AUS CARD XX1234 VALUE DATE: 2026-10-01"]
    for _ in 0..<6000 {
        var text = ""
        for _ in 0..<Int.random(in: 1...5, using: &rng) {
            var piece = pick(fragments)
            if chance(0.3) { piece = piece.lowercased() }
            text += pick(["", " ", "", "_", " "]) + piece
        }
        texts.append(text)
    }
    var mismatches: [String] = []
    var skipped = 0
    for pattern in patterns {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        for text in texts {
            let expected = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            if FinanceEngine.matches(pattern, text) != expected { mismatches.append("\(pattern) / \(text)") }
            if !expected { skipped += 1 }
        }
    }
    check(mismatches.isEmpty, "正则预筛与直接跑正则结果相同（\(patterns.count) 条正则 × \(texts.count) 段文字，其中 \(skipped) 次不命中）"
          + (mismatches.isEmpty ? "" : "，不符：\(mismatches.prefix(5))"))
}

// MARK: 灵石账簿：按账本版本缓存的派生数据（FinanceLedgerIndex）与直接计算、改动前的实现逐项相同

/// 改动前的实现（原样保留，只用于对照）
func oldCovers(_ intervals: [(String, String)], _ first: String, _ last: String) -> Bool {
    guard var cursor = LocalDay(key: first), let target = LocalDay(key: last) else { return false }
    for (left, right) in intervals.sorted(by: { $0.0 < $1.0 }) {
        guard let a = LocalDay(key: left), let b = LocalDay(key: right) else { continue }
        if b < cursor { continue }
        if a > cursor { return false }
        cursor = max(cursor, b.adding(days: 1))
        if cursor > target { return true }
    }
    return false
}

func oldLedgerMonths(_ ledger: FinanceLedger) -> [String] {
    var months = Set(ledger.transactions.map(\.month))
    for source in ledger.sources {
        guard source.statementPeriod != nil, let (first, last) = source.range, var day = LocalDay(key: String(first.prefix(7)) + "-01") else { continue }
        while day.key.prefix(7) <= last.prefix(7) {
            months.insert(String(day.key.prefix(7)))
            day = day.adding(days: 32).firstOfMonth
        }
    }
    return months.sorted(by: >)
}

func oldMonthFacts(_ ledger: FinanceLedger, month: String) -> MonthFacts {
    let (first, last) = FinanceEngine.monthRange(month) ?? (month + "-01", month + "-28")
    let rows = ledger.transactions.filter { $0.date >= first && $0.date <= last }
    let accounts = Set(ledger.sources.filter { ($0.range?.0 ?? "9999") <= last }.map(\.account))
    let complete = !accounts.isEmpty && accounts.allSatisfy { account in
        oldCovers(ledger.sources.filter { $0.account == account }.compactMap(\.range), first, last)
    }
    let confirmed = !accounts.isEmpty && accounts.allSatisfy { account in
        oldCovers(ledger.sources.filter { $0.account == account && $0.statementPeriod != nil }.compactMap(\.range), first, last)
    }
    var categoriesTotal: [String: Int] = [:], excluded: [String: Int] = [:]
    var refunds = 0, debit = 0
    for row in rows where !row.isIgnored {
        if row.amountCents < 0 {
            debit -= row.amountCents
            if FinanceEngine.nonSpend.contains(row.category) { excluded[row.category, default: 0] -= row.amountCents }
            else { categoriesTotal[row.category, default: 0] -= row.amountCents }
        } else if row.kind == "退款" {
            refunds += row.amountCents
        }
    }
    let spend = categoriesTotal.values.reduce(0, +)
    let education = categoriesTotal["教育与学费"] ?? 0
    return MonthFacts(month: month, start: first, end: last, rowCount: rows.count, fullMonth: complete, coverageConfirmed: confirmed,
                      accountCount: accounts.count, spendCents: spend, refundCents: refunds, netSpendCents: spend - refunds,
                      debitCents: debit, excludedCents: excluded.values.reduce(0, +), excludedCategories: excluded,
                      educationCents: education, nonEducationCents: spend - education, categories: categoriesTotal,
                      needsReviewCount: rows.filter(\.awaitingReview).count)
}

func oldBudgetStatus(_ ledger: FinanceLedger, month: String) -> [BudgetStatus] {
    let facts = oldMonthFacts(ledger, month: month)
    let ridePattern = FinanceEngine.merchantGroups.first { $0.key == "ride_hail" }!.pattern
    let ride = ledger.transactions.filter {
        $0.month == month && $0.amountCents < 0 && !$0.isIgnored && !FinanceEngine.nonSpend.contains($0.category)
            && FinanceEngine.matches(ridePattern, $0.description)
    }.reduce(0) { $0 - $1.amountCents }
    let actual = ["dining": facts.categories["餐饮与外卖"] ?? 0, "ride_hail": ride,
                  "entertainment": (facts.categories["娱乐"] ?? 0) + (facts.categories["彩票"] ?? 0)]
    let limits = ledger.budgets[month] ?? [:]
    return FinanceEngine.budgetLabels.map { item in
        let limit = limits[item.key]
        return BudgetStatus(key: item.key, label: item.label, spentCents: actual[item.key] ?? 0, limitCents: limit,
                            remainingCents: limit.map { $0 - (actual[item.key] ?? 0) })
    }
}

func oldServiceChecks(_ ledger: FinanceLedger, month: String) -> [ServiceCheck] {
    let previous = FinanceEngine.previousMonth(month)
    let priorFull = previous.map { oldMonthFacts(ledger, month: $0).fullMonth } ?? false
    let spending = ledger.transactions.filter { $0.amountCents < 0 && !$0.isIgnored && !FinanceEngine.nonSpend.contains($0.category) }
    var result: [ServiceCheck] = []
    for group in FinanceEngine.merchantGroups where FinanceEngine.serviceKeys.contains(group.key) {
        let matched = spending.filter { FinanceEngine.matches(group.pattern, $0.description) }
        let current = matched.filter { $0.month == month }.sorted { ($0.date, $0.sourceLine) < ($1.date, $1.sourceLine) }
        let prior = matched.filter { $0.month == previous }.sorted { ($0.date, $0.sourceLine) < ($1.date, $1.sourceLine) }
        if current.isEmpty && prior.isEmpty { continue }
        var signals: [ServiceSignal] = []
        if let c = current.last, let p = prior.last, -c.amountCents > -p.amountCents {
            signals.append(ServiceSignal(kind: "increase", text: "末次单笔扣款上升，核对账单内容或汇率", changeCents: p.amountCents - c.amountCents))
        }
        if !current.isEmpty && !matched.contains(where: { $0.month < month }) {
            signals.append(ServiceSignal(kind: "first_seen", text: "在已导入记录中本月首次出现；不代表订阅刚开通"))
        }
        var groups: [String: Int] = [:]
        for r in current { groups["\(r.date)|\(r.amountCents)|\(FinanceEngine.merchantKey(r))|\(r.account)", default: 0] += 1 }
        if groups.values.contains(where: { $0 > 1 }) {
            signals.append(ServiceSignal(kind: "possible_duplicate", text: "同日同商户同金额多笔扣款，需核对是否重复或不同订单"))
        }
        let pref = FinanceEngine.preferenceKey(group.key)
        result.append(ServiceCheck(key: group.key, label: group.label, preferenceKey: pref,
                                   status: ledger.reviewPreferences[pref] ?? "review",
                                   debitCents: -current.reduce(0) { $0 + $1.amountCents }, count: current.count,
                                   previousCents: priorFull ? -prior.reduce(0) { $0 + $1.amountCents } : nil,
                                   previousMonth: previous, signals: signals))
    }
    return result
}

func oldReportBasis(_ ledger: FinanceLedger, month: String) -> String {
    let previous = FinanceEngine.previousMonth(month)
    let rows = ledger.transactions.filter { $0.month == month || $0.month == previous }
    struct Basis: Encodable {
        var rows: [FinanceTransaction]; var facts: MonthFacts; var prior: MonthFacts?
        var budgets: [String: Int]; var preferences: [String: String]
    }
    let basis = Basis(rows: rows, facts: oldMonthFacts(ledger, month: month), prior: previous.map { oldMonthFacts(ledger, month: $0) },
                      budgets: ledger.budgets[month] ?? [:], preferences: ledger.reviewPreferences)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return FinanceEngine.sha256(String(decoding: (try? encoder.encode(basis)) ?? Data(), as: UTF8.self))
}

func oldReportDraft(_ ledger: FinanceLedger, month: String) -> MonthlyReport {
    let facts = oldMonthFacts(ledger, month: month)
    let previous = FinanceEngine.previousMonth(month)
    let prior = previous.map { oldMonthFacts(ledger, month: $0) }
    var comparison: MonthComparison?
    if facts.fullMonth, let prior, prior.fullMonth, let previous {
        let keys = Set(facts.categories.keys).union(prior.categories.keys)
        let changes = keys.map { key in
            CategoryChange(category: key, currentCents: facts.categories[key] ?? 0, previousCents: prior.categories[key] ?? 0,
                           changeCents: (facts.categories[key] ?? 0) - (prior.categories[key] ?? 0))
        }.sorted { abs($0.changeCents) != abs($1.changeCents) ? abs($0.changeCents) > abs($1.changeCents) : $0.category < $1.category }
        comparison = MonthComparison(previousMonth: previous, spendChangeCents: facts.spendCents - prior.spendCents,
                                     netChangeCents: facts.netSpendCents - prior.netSpendCents,
                                     nonEducationChangeCents: facts.nonEducationCents - prior.nonEducationCents, categories: changes)
    }
    let top = facts.categories.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    let budgets = oldBudgetStatus(ledger, month: month)
    let services = oldServiceChecks(ledger, month: month)
    var suggestions: [String] = []
    if !facts.fullMonth { suggestions.append("先确认银行导出日期是否覆盖整月，再判断与上月的变化。") }
    if facts.needsReviewCount > 0 {
        suggestions.append("先核对 \(facts.needsReviewCount) 笔待确认记录；商户消费可批量分类，个人转账逐笔确认。")
    }
    let overspent = budgets.filter { ($0.remainingCents ?? 0) < 0 }.map(\.label)
    if !overspent.isEmpty { suggestions.append("回看" + overspent.joined(separator: "、") + "超预算的原因，选择一项调整下月频率或额度。") }
    if (budgets.first { $0.key == "ride_hail" }?.spentCents ?? 0) > 0 {
        suggestions.append("回看打车记录，挑选一趟方便乘公共交通的行程作为下月调整目标。")
    }
    let optional = services.filter { $0.status != "keep" && $0.count > 0 }.map(\.label)
    if !optional.isEmpty { suggestions.append("核对" + optional.prefix(3).joined(separator: "、") + "的实际使用率；常用服务标记保留，闲置项目再考虑调整。") }
    if (facts.categories["彩票"] ?? 0) > 0 || (facts.categories["娱乐"] ?? 0) > 0 {
        suggestions.append("回看娱乐与彩票支出，确认用途并给下月设置一个你认可的额度。")
    }
    for fallback in ["给餐饮、打车或娱乐选择一个下月目标，额度由你决定。",
                     "把学费、年费等一次性开销写入月报备注，比较日常消费时单独查看。",
                     "下次导入后回看类别变化；支出下降不自动等同于某项措施已经省下的钱。"] where suggestions.count < 3 {
        suggestions.append(fallback)
    }
    // 原来：整本账按金额排序后再筛本月
    let large = ledger.transactions.sorted { $0.amountCents < $1.amountCents }
        .filter { $0.month == month && $0.amountCents <= -30000 && !$0.isIgnored && !FinanceEngine.nonSpend.contains($0.category) }
        .prefix(5).map { LargePurchase(date: $0.date, merchant: FinanceEngine.merchantKey($0), category: $0.category, cents: -$0.amountCents) }
    return MonthlyReport(month: month, basisHash: oldReportBasis(ledger, month: month), summary: facts, comparison: comparison,
                         topCategories: top.prefix(3).map { CategoryAmount(category: $0.key, cents: $0.value) },
                         budgets: budgets, services: services, suggestions: Array(suggestions.prefix(3)),
                         largePurchases: Array(large), engine: "swift-1")
}

func oldDefaultMonth(_ ledger: FinanceLedger, today: LocalDay) -> String {
    let months = oldLedgerMonths(ledger)
    let current = String(today.key.prefix(7))
    if let full = months.first(where: { $0 < current && oldMonthFacts(ledger, month: $0).fullMonth }) { return full }
    return months.first ?? current
}

/// 原来交易明细（TransactionsTab）的筛选与排序。原来每笔现算 FinanceEngine.merchantDisplay，
/// 这里由调用方事先逐笔算好传进来（纯函数，结果相同），免得自检跑太久
func oldTransactionRows(_ ledger: FinanceLedger, displays: [String], month: String?, filter: String, search: String) -> [FinanceTransaction] {
    let scope = ledger.transactions.indices.filter { month == nil || ledger.transactions[$0].month == month }
    let raw = search.trimmingCharacters(in: .whitespaces)
    let query = raw.uppercased()
    return scope
        .filter { filter == "全部" || (filter == "__review" ? ledger.transactions[$0].awaitingReview : ledger.transactions[$0].category == filter) }
        .filter {
            let row = ledger.transactions[$0]
            return query.isEmpty || row.description.uppercased().contains(query) || row.note.uppercased().contains(query)
                || row.category.contains(raw) || displays[$0].uppercased().contains(query)
        }
        .map { ledger.transactions[$0] }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.sourceLine < $1.sourceLine }
}

/// 三方对照：改动前的实现、FinanceEngine 直接计算、FinanceLedgerIndex。返回不一致的项（空 = 全部相同）与对照的项数
func compareLedgerIndex(_ ledger: FinanceLedger, _ index: FinanceLedgerIndex) -> (problems: [String], count: Int) {
    var problems: [String] = []
    var count = 0
    func same<T: Equatable>(_ label: String, _ old: T, _ direct: T, _ cached: T) {
        count += 1
        if old != direct || direct != cached { problems.append(label) }
    }
    same("ledgerMonths", oldLedgerMonths(ledger), FinanceEngine.ledgerMonths(ledger), index.months)
    let extra = ["2026-13", "2026-1", "2026-1-", "1999-12", "2027-01", "2026-1٠", "abc", ""]
    for month in index.months + extra {
        same("monthFacts \(month)", oldMonthFacts(ledger, month: month), FinanceEngine.monthFacts(ledger, month: month), index.monthFacts(month))
        same("budgetStatus \(month)", oldBudgetStatus(ledger, month: month), FinanceEngine.budgetStatus(ledger, month: month), index.budgetStatus(month))
        same("serviceChecks \(month)", oldServiceChecks(ledger, month: month), FinanceEngine.serviceChecks(ledger, month: month), index.serviceChecks(month))
        same("reportDraft \(month)", oldReportDraft(ledger, month: month), FinanceEngine.reportDraft(ledger, month: month), index.reportDraft(month))
        let hasRows = ledger.transactions.contains { $0.month == month }
        same("hasTransactions \(month)", hasRows, hasRows, index.hasTransactions(in: month))
        let others = ledger.transactions.filter { $0.awaitingReview && $0.month != month }.count
        same("待确认（别的月份）\(month)", others, others, index.awaitingReviewCount - index.awaitingReviewCount(in: month))
    }
    for today in ["2026-10-20", "2026-11-03", "2025-03-01", "2030-01-01", "2000-01-01"].compactMap(LocalDay.init(key:)) {
        same("defaultMonth \(today)", oldDefaultMonth(ledger, today: today), FinanceEngine.defaultMonth(ledger, today: today), index.defaultMonth(today: today))
    }
    let displays = ledger.transactions.map { FinanceEngine.merchantDisplay($0) }
    same("merchantDisplay", displays, displays, ledger.transactions.indices.map { index.merchantDisplay(at: $0) })
    let filters = ["全部", "__review", "餐饮与外卖", "转账待确认", "购物"]
    let searches = ["", "  ", "uber", "UBER ", " Opal", "公交", "房租", "餐饮", "chatgpt", "telstra prepaid", "zzz", "café", "CAFÉ", "e\u{301}",
                    "transfer", "转给", "（未写说明）", "value date", "7"]
    let scopes: [String?] = [nil] + index.months.prefix(4).map { $0 } + ["1999-12"]
    for month in scopes {
        for filter in filters {
            for search in searches {
                let old = oldTransactionRows(ledger, displays: displays, month: month, filter: filter, search: search)
                let raw = search.trimmingCharacters(in: .whitespaces)
                let rows = index.rows(month: month, query: raw) {
                    filter == "全部" || (filter == "__review" ? $0.awaitingReview : $0.category == filter)
                }.map { ledger.transactions[$0] }
                same("交易明细 \(month ?? "全部月份") \(filter) “\(search)”", old, old, rows)
            }
        }
    }
    return (problems, count)
}

do {
    // 造一本随机账：两个银行账户 + 手记，22 个月；导入有确认过的、只有首末日期的、缺月份的、日期写错的；
    // 交易里有账单与打车商户、同日同额的重复扣款、同额的大额支出（排序要稳定）、不计入统计的、退款、怪日期、非 ASCII 描述
    let merchants = ["TELSTRA PREPAID MELBOURNE VI AUS", "OPENAI *CHATGPT SUBSCR SAN FRANCISCO USA", "ANYTIME FITNESS ULTIMO NS AUS",
                     "AMZNPRIME AU MEMBERSHIP SYDNEY", "UBER *TRIP HELP.UBER.COM AU", "DIDIMOBILITY SYDNEY AUS", "UBER ONE MEMBERSHIP",
                     "X CORP PAID FEATURES", "GOOGLE ONE GOOGLE.COM AU", "APPLE.COM/BILL SYDNEY AUS", "OPTUS MOBILE SYDNEY",
                     "UBER *EATS HELP.UBER.COM AU", "HUNGRYPANDA SYDNEY AUS", "TRANSPORTFORNSW OPAL SYDNEY AUS", "TATTS ONLINE PTY LTD BRISBANE QL AUS",
                     "HOYTS BROADWAY NS AUS", "TRANSFER TO COMMSEC COMMBANK APP", "TRANSFER FROM J SMITH PAYMENT", "DIRECT CREDIT 000415 JOHN CITIZEN",
                     "SQ *YUNNN NOODLE BAR SYDNEY NS AUS", "AMPOL CHATSWOOD NS AUS", "WOOLWORTHS 1234 SYDNEY NS AUS", "REFUND AMAZON AU MARKETPLACE",
                     "CAFÉ NOIR SYDNEY NS AUS", "CAFE\u{301} NOIR SYDNEY NS AUS", "JB HI FI BROADWAY NS AUS", "INTERNATIONAL TRANSACTION FEE",
                     "ATM WITHDRAWAL CBA TOWN HALL", "UNIVERSITY STUDENT FEES"]
    let months = (0..<22).map { LocalDay(year: 2025, month: 1, day: 1).adding(days: $0 * 31).monthKey }
    func randomLedger(oddDates: Bool, nonASCII: Bool) -> FinanceLedger {
        var ledger = FinanceLedger()
        var serial = 0
        for account in ["CommBank 0123", "CommBank 1234"] {
            for month in months where !chance(0.12) {
                let (first, last) = FinanceEngine.monthRange(month)!
                let confirmed = chance(0.6)
                let start = chance(0.1) ? month + "-03" : first
                let end = chance(0.1) ? month + "-25" : last
                ledger.sources.append(FinanceSource(sha256: "s\(serial)", account: account, rawCsv: "", importedAt: "2026-01-01T00:00:00Z",
                                                    rows: 0, start: chance(0.05) ? nil : start, end: end, pendingIncluded: false,
                                                    statementPeriod: confirmed ? StatementPeriod(start: start, end: chance(0.05) ? "2026-13-40" : end) : nil))
                serial += 1
                for _ in 0..<Int.random(in: 0...14, using: &rng) {
                    let description = pick(merchants) + (chance(0.5) ? " CARD XX\(Int.random(in: 1000...1003, using: &rng)) VALUE DATE: \(month)" : "")
                    var amount = -Int.random(in: 100...9000, using: &rng)
                    if chance(0.08) { amount = -pick([30000, 30000, 45000, 120000]) }
                    if chance(0.1) { amount = Int.random(in: 100...5000, using: &rng) }
                    let date = month + "-" + String(format: "%02d", Int.random(in: 1...28, using: &rng))
                    let c = FinanceEngine.classify(description, amount: amount)
                    var row = FinanceTransaction(id: "t\(serial)", date: date, amountCents: amount, balanceCents: 0, description: description,
                                                 account: account, category: c.category, kind: c.kind, needsReview: c.review, reason: c.reason,
                                                 sourceLine: Int.random(in: 0..<4, using: &rng))
                    serial += 1
                    if chance(0.1) { row.category = pick(FinanceEngine.categories) }
                    if amount > 0 && chance(0.4) { row.kind = "退款" }
                    if chance(0.06) { row.ignored = true }
                    if chance(0.1) { row.needsReview.toggle() }
                    if chance(0.15) { row.note = pick(["房租", "uber 退款", "Café 备注", "note abc"]) }
                    ledger.transactions.append(row)
                    // 同日同商户同金额的重复扣款
                    if chance(0.05) { row.id = "t\(serial)"; serial += 1; ledger.transactions.append(row) }
                }
            }
        }
        for _ in 0..<30 {
            let day = LocalDay(key: pick(months) + "-01")!.adding(days: Int.random(in: 0...27, using: &rng))
            ledger.transactions.append(ManualExpense.transaction(id: "m\(serial)", day: day, cents: Int.random(in: 100...40000, using: &rng),
                                                                 category: pick(FinanceEngine.spendCategories),
                                                                 description: pick(["午饭 拉面", "  ", "打车 Uber", "房租"]), note: "", reason: "自检"))
            serial += 1
        }
        // 怪日期：月份前缀对、却落在这个月日期范围外的（10-32、06-31、10-00、末尾多个空格），短的、少位的；nonASCII 时再加全角 / 阿拉伯数字
        if oddDates {
            for date in ["2026-10-32", "2025-06-31", "2026-10-00", "2026-10", "2026-1-05", "2025-12-31 "]
                + (nonASCII ? ["２０２６-03-05", "2026-1٠-05"] : []) {
                ledger.transactions.append(FinanceTransaction(id: "odd\(serial)", date: date, amountCents: -1234, balanceCents: 0,
                                                              description: "WOOLWORTHS 1234", account: "CommBank 0123", category: "超市与食品",
                                                              kind: "消费", needsReview: true, reason: "", sourceLine: 1))
                serial += 1
            }
        }
        for month in months where chance(0.4) {
            ledger.budgets[month] = ["dining": Int.random(in: 0...60000, using: &rng), "ride_hail": 5000]
        }
        ledger.reviewPreferences = ["communications": "keep", "chatgpt": "review", "gym": "keep"]
        ledger.transactions.shuffle(using: &rng)
        return ledger
    }

    var problems: [String] = []
    var compared = 0
    var covered: [String: Int] = [:]
    for (oddDates, nonASCII) in [(false, false), (true, false), (true, true)] {
        let ledger = randomLedger(oddDates: oddDates, nonASCII: nonASCII)
        let index = FinanceLedgerIndex(ledger)
        // 记下这本账覆盖到的情形，确认对照不是在比一堆空结果
        for month in index.months {
            let draft = index.reportDraft(month)
            covered["整月", default: 0] += draft.summary.fullMonth ? 1 : 0
            covered["未导全", default: 0] += draft.summary.fullMonth ? 0 : 1
            covered["有环比", default: 0] += draft.comparison == nil ? 0 : 1
            covered["有大额支出", default: 0] += draft.largePurchases.isEmpty ? 0 : 1
            covered["固定账单", default: 0] += draft.services.count
            for kind in ["increase", "first_seen", "possible_duplicate"] {
                covered[kind, default: 0] += draft.services.filter { $0.signals.contains { $0.kind == kind } }.count
            }
            covered["打车", default: 0] += (draft.budgets.first { $0.key == "ride_hail" }?.spentCents ?? 0) > 0 ? 1 : 0
        }
        let first = compareLedgerIndex(ledger, index)
        // 同一个索引再对照一遍：第二次全是缓存里的结果
        let again = compareLedgerIndex(ledger, index)
        // 改一版账本（改类别、设不计入、删几笔、补几笔），沿用上一版的描述缓存
        var changed = ledger
        for i in changed.transactions.indices where chance(0.1) { changed.transactions[i].category = pick(FinanceEngine.categories) }
        for i in changed.transactions.indices where chance(0.05) { changed.transactions[i].ignored = true }
        changed.transactions.removeAll { _ in chance(0.05) }
        changed.transactions.append(contentsOf: ledger.transactions.prefix(10).map { var row = $0; row.id += "-copy"; row.description += " NEW"; return row })
        changed.budgets[months[3]] = ["entertainment": 1]
        let reused = compareLedgerIndex(changed, FinanceLedgerIndex(changed, reusing: index))
        problems += first.problems + again.problems + reused.problems
        compared += first.count + again.count + reused.count
    }
    check(problems.isEmpty, "账簿派生数据（缓存版）与直接计算、改动前的实现逐项相同：月份、各月账目、预算、固定账单、月卷草稿、默认月份、"
          + "交易明细筛选排序（\(compared) 项，含怪日期、非 ASCII 描述、沿用上一版缓存）" + (problems.isEmpty ? "" : "，不符：\(problems.prefix(5))"))
    let summary = covered.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "、")
    check(covered.count == 9 && covered.values.allSatisfy { $0 > 0 }, "上面的对照覆盖到了各种情形：\(summary)")
}

// MARK: 修为：传入已算好的统计、只算某一天（修为模型与“落笔只算当天差值”用）

do {
    var statsMismatch = 0, dayMismatch = 0, sumMismatch = 0
    for _ in 0..<300 {
        let habits = randomHabits(today: today, newFields: chance(0.7))
        let stats = habits.map { HabitStats(spec: $0.spec, logs: $0.logs, today: today) }
        if sourceSignature(CultivationEngine.sources(habits: habits, stats: stats, today: today))
            != sourceSignature(CultivationEngine.sources(habits: habits, today: today)) { statsMismatch += 1 }
        // 落笔：同一天常有好几篇（触发同类递减），也有写在未来的
        let journal = (0..<Int.random(in: 0...60, using: &rng)).map { _ in
            (day: today.adding(days: Int.random(in: -12...2, using: &rng)), kind: pick(JournalKind.allCases))
        }
        var config = CultivationConfig()
        config.dailyCap = pick([10, 40, 80, 150])
        config.enabled = chance(0.9)
        let full = CultivationEngine.compute(sources: CultivationEngine.sources(habits: habits, today: today)
                                             + CultivationEngine.journalSources(journal, today: today), config: config, today: today)
        var sum = 0
        for day in LocalDay.range(today.adding(days: -40), today.adding(days: 3)) {
            let xp = CultivationEngine.dayXP(day, habits: habits, journal: journal, config: config, today: today)
            if xp != (full.perDay[day] ?? 0) { dayMismatch += 1 }
            sum += xp
        }
        if sum != full.totalXP { sumMismatch += 1 }
    }
    check(statsMismatch == 0, "修为来源：传入已算好的统计与自己建统计完全相同（300 组）：不一致 \(statsMismatch) 组")
    check(dayMismatch == 0 && sumMismatch == 0,
          "只算某一天的修为与全量计算的当日修为逐日相同、逐日相加等于总修为（300 组，含递减、上限、圆满、未来日期）：不一致 \(dayMismatch) 天 / \(sumMismatch) 组")
}

// MARK: 岁月长卷、洞见、逐月趋势（纯 Core）

do {
    let today = LocalDay(key: "2026-10-20")!
    func d(_ key: String) -> LocalDay { LocalDay(key: key)! }
    var serial = 0
    func entry(_ day: LocalDay, _ kind: JournalKind = .diary, mood: Int? = nil, title: String = "", body: String = "",
               tags: [String] = [], pinned: Bool = false) -> RecordEntry {
        serial += 1
        return RecordEntry(uid: "e\(serial)", day: day, kind: kind, title: title, body: body, mood: mood, tags: tags, pinned: pinned)
    }
    func habit(_ title: String, _ frequency: HabitFrequency = .daily, start: LocalDay, weekdays: [Int] = [], perWeek: Int = 1,
               archived: Bool = false, archivedDay: LocalDay? = nil, created: LocalDay? = nil, done: [LocalDay]) -> RecordHabit {
        RecordHabit(title: title, symbol: "leaf",
                    spec: HabitSpec(frequency: frequency, targetPerWeek: perWeek, weekdays: weekdays, startDay: start, createdDay: created,
                                    archivedDay: archived ? archivedDay : nil),
                    logs: done.map { HabitLogValue(day: $0, completed: true) }, archived: archived)
    }
    func makeInput(_ entries: [RecordEntry] = [], history: [(day: LocalDay, kind: JournalKind)]? = nil, habits: [RecordHabit] = [],
                   ledger: FinanceLedger? = nil, config: CultivationConfig = CultivationConfig(), today day: LocalDay = today) -> RecordInput {
        RecordInput(today: day, entries: entries, history: history ?? entries.map { ($0.day, $0.kind) }, habits: habits, cultivation: config, ledger: ledger)
    }
    var txSerial = 0
    func spend(_ day: LocalDay, _ cents: Int, category: String = "餐饮与外卖", account: String = "CBA") -> FinanceTransaction {
        txSerial += 1
        return FinanceTransaction(id: "t\(txSerial)", date: day.key, amountCents: -cents, balanceCents: 0, description: "自检", account: account,
                                  category: category, kind: "消费", needsReview: false, reason: "", sourceLine: txSerial)
    }
    func statement(_ first: LocalDay, _ last: LocalDay, account: String = "CBA") -> FinanceSource {
        FinanceSource(sha256: "s\(first.key)", account: account, rawCsv: "", importedAt: "", rows: 0, start: first.key, end: last.key,
                      statementPeriod: StatementPeriod(start: first.key, end: last.key))
    }
    let banned = ["因为", "所以", "导致", "因此", "造成", "使得", "有助", "影响", "证明", "说明你"]

    // 1–2. 快捷键数字与中文数字
    check((1...9).allSatisfy { NavShortcut.digit(forPosition: $0) == Character("\($0)") } && NavShortcut.digit(forPosition: 10) == "0"
          && NavShortcut.digit(forPosition: 11) == nil && NavShortcut.digit(forPosition: 0) == nil,
          "侧栏快捷键：第 1–9 项 ⌘1–⌘9，第 10 项 ⌘0，再往后没有（不再 Character(\"10\") 崩溃）")
    check(ChineseNumerals.year(2026) == "二〇二六" && ChineseNumerals.year(2000) == "二〇〇〇"
          && (1...7).map(ChineseNumerals.ordinal) == ["一", "二", "三", "四", "五", "六", "七"] && ChineseNumerals.ordinal(10) == "十",
          "中文数字：二〇二六、二〇〇〇，其一 … 其七、十")

    // 3. 时段与对比期
    do {
        let y26 = AnnalsPeriod.make(.year(2026), today: today)!
        check(y26.first == d("2026-01-01") && y26.last == today && y26.isOngoing && y26.previousFirst == d("2025-01-01")
              && y26.previousLast == d("2025-10-20") && y26.previousLabel == "去年同期" && y26.title == "二〇二六年"
              && y26.rangeLabel == "1月1日 — 10月20日 · 尚未过完" && y26.unitLabel == "今年",
              "长卷时段：今年截到今天、尚未过完，对比去年同期 2025-01-01—2025-10-20：\(y26.rangeLabel)")
        let y25 = AnnalsPeriod.make(.year(2025), today: today)!
        check(y25.first == d("2025-01-01") && y25.last == d("2025-12-31") && !y25.isOngoing && y25.previousFirst == d("2024-01-01")
              && y25.previousLast == d("2024-12-31") && y25.previousLabel == "上一年" && y25.rangeLabel == "全年 365 天",
              "长卷时段：去年整年，对比 2024 整年")
        let q4 = AnnalsPeriod.make(.quarter(2026, 4), today: today)!
        check(q4.first == d("2026-10-01") && q4.last == today && q4.previousFirst == d("2026-07-01") && q4.previousLast == d("2026-07-20")
              && q4.previousLabel == "上一季同期" && q4.title == "二〇二六年 · 第四季" && q4.storageKey == "2026-Q4",
              "长卷时段：本季 10/1—10/20，对比上一季同期 7/1—7/20")
        let q1 = AnnalsPeriod.make(.quarter(2026, 1), today: today)!
        check(q1.dayCount == 90 && q1.previousFirst == d("2025-10-01") && q1.previousLast == d("2025-12-29")
              && q1.previousLast <= d("2025-12-31") && q1.rangeLabel == "1月1日 — 3月31日 · 共 90 天" && q1.previousLabel == "上一季",
              "长卷时段：第一季对比上一年第四季，从 10/1 起取同样 90 天、不超过 12/31")
        check(AnnalsPeriod.make(.year(2027), today: today) == nil && AnnalsPeriod.make(.quarter(2027, 1), today: today) == nil
              && AnnalsPeriod.make(.quarter(2026, 5), today: today) == nil && AnnalsPeriod.make(.quarter(2026, 4), today: d("2026-09-30")) == nil,
              "长卷时段：还没开始的年份、季度和不存在的季度都没有")
        check(AnnalsPeriod.make(.year(2024), today: d("2024-02-29"))?.previousLast == d("2023-02-28"), "长卷时段：闰日的去年同期止于 2/28")
        check([y26, y25, q4, q1].allSatisfy { AnnalsPeriod(storageKey: $0.storageKey, today: today) == $0 }
              && ["", "2026-Q5", "2026-Q0", "abc", "2027", "26", "2026-q4", "2026-"].allSatisfy { AnnalsPeriod(storageKey: $0, today: today) == nil },
              "长卷时段：storageKey 往返一致，认不出、未来的键返回 nil")
        check(AnnalsPeriod.defaultScope(today: d("2026-01-10")) == .year(2025) && AnnalsPeriod.defaultScope(today: d("2026-01-16")) == .year(2026)
              && AnnalsPeriod.defaultScope(today: today) == .year(2026),
              "长卷时段：1 月上半月默认看上一年全年，其余默认今年")
    }

    // 4. 口径与写法
    do {
        let e = RecordEntry(uid: "x", day: today, kind: .diary, title: "标题 a", body: "正文\n 一二  三\n\n" + String(repeating: "长", count: 200))
        check(RecordStats.charCount("你好 world\n") == 7 && e.chars == RecordStats.charCount("标题 a") + RecordStats.charCount(e.body)
              && e.excerpt.hasPrefix("正文 一二 三 长") && e.excerpt.count == RecordEntry.excerptLength + 2 && e.excerpt.hasSuffix("……"),
              "字数：去掉空白换行按字数（\(e.chars)），摘录折叠空白、120 字后加“……”")
        let run = RecordStats.longestRun(Set(LocalDay.range(d("2025-12-29"), d("2026-01-03")) + [d("2025-12-20"), d("2026-01-05")]),
                                         from: d("2025-12-01"), to: d("2026-01-31"))
        check(run?.count == 6 && run?.first == d("2025-12-29") && run?.last == d("2026-01-03"), "最长连续：跨 12/31 → 1/1 照算")
        check(RecordStats.dollars(120_349) == "$1,203" && RecordStats.dollars(150) == "$2" && RecordStats.dollars(0) == "$0"
              && RecordStats.dollars(-120_349) == "-$1,203" && RecordStats.grouped(12_480) == "12,480" && RecordStats.grouped(999) == "999"
              && RecordStats.grouped(-1_234_567) == "-1,234,567" && RecordStats.percent(0.82) == "82%"
              && RecordStats.charsText(184_321) == "18.4 万字" && RecordStats.charsText(8_320) == "8,320 字" && RecordStats.charsText(100_020) == "10 万字",
              "数字写法：$1,203、12,480、82%、18.4 万字、8,320 字")

        // 时段功课完成率：归档日之后不计、没有归档日的旧数据止于最后一次打卡、按有效天数加权
        let start = d("2026-01-01")
        let a = habit("A", start: start, archived: true, archivedDay: d("2026-03-01"), done: LocalDay.range(d("2026-03-01"), d("2026-10-19")))
        let b = habit("B", start: start, archived: true, done: LocalDay.range(start, d("2026-01-10")))
        let cDone = LocalDay.range(d("2026-10-01"), d("2026-10-19")).filter { $0.day % 2 == 0 }
        let c = habit("C", start: d("2026-10-01"), done: cDone)
        let habits = [a, b, c]
        let stats = habits.map { HabitStats(spec: $0.spec, logs: $0.logs, today: today) }
        let ra = RecordStats.activeRange(a, stats: stats[0], from: start, to: today)
        let rb = RecordStats.activeRange(b, stats: stats[1], from: start, to: today)
        let rc = stats[2].rate(from: d("2026-10-01"), to: today) ?? -1
        let expected = (0.0 * 59 + 1.0 * 10 + rc * 20) / Double(59 + 10 + 20)
        let rate = RecordStats.habitRate(habits, stats: stats, from: start, to: today)
        check(ra?.first == start && ra?.last == d("2026-02-28") && rb?.last == d("2026-01-10")
              && rate?.habits == 3 && abs((rate?.rate ?? -1) - expected) < 1e-9,
              "时段功课完成率：归档日之后不计、旧数据止于最后一次打卡、按有效天数加权（\(RecordStats.percent(rate?.rate ?? 0))）")
        let never = habit("D", start: start, archived: true, done: [])
        check(RecordStats.activeRange(never, stats: HabitStats(spec: never.spec, logs: [], today: today), from: start, to: today) == nil,
              "时段功课完成率：已归档、没有归档日也没打过卡的旧功课不计")

        // 当天功课完成率与“功课圆满”同一判定（随机 200 天：完成率 == 1 ⇔ 圆满）
        var rng2 = SeededRandom(state: 20261020)
        var agree = 0, perfect = 0
        for round in 0..<20 {
            let base = d("2026-01-01")
            let count = Int.random(in: 1...5, using: &rng2)
            var hs: [RecordHabit] = []
            for index in 0..<count {
                let freq: HabitFrequency = [.daily, .weekdays, .weekly][Int.random(in: 0...2, using: &rng2)]
                let hStart = base.adding(days: Int.random(in: 0...120, using: &rng2))
                let archived = Double.random(in: 0..<1, using: &rng2) < 0.3
                let archivedDay: LocalDay? = archived && Double.random(in: 0..<1, using: &rng2) < 0.7 ? hStart.adding(days: Int.random(in: 30...200, using: &rng2)) : nil
                let created: LocalDay? = Double.random(in: 0..<1, using: &rng2) < 0.5 ? hStart.adding(days: Int.random(in: 0...60, using: &rng2)) : nil
                let p = Double.random(in: 0.3...1, using: &rng2)
                let done = LocalDay.range(hStart.adding(days: -10), today).filter { _ in Double.random(in: 0..<1, using: &rng2) < p }
                hs.append(habit("H\(round)-\(index)", freq, start: hStart, weekdays: [0, 2, 4, 6].filter { _ in Double.random(in: 0..<1, using: &rng2) < 0.6 },
                                perWeek: 3, archived: archived, archivedDay: archivedDay, created: created, done: done))
            }
            let st = hs.map { HabitStats(spec: $0.spec, logs: $0.logs, today: today) }
            for _ in 0..<10 {
                let day = base.adding(days: Int.random(in: 0..<base.days(to: today), using: &rng2))
                let rate = RecordStats.dayHabitRate(hs, stats: st, on: day)
                let isPerfect = CultivationEngine.isPerfectDay(day, habits: hs.map(\.cultivationInput))
                if (rate == 1) == isPerfect { agree += 1 }
                if isPerfect { perfect += 1 }
            }
        }
        check(agree == 200 && perfect > 0, "当天功课完成率：随机 200 天里“完成率 100%”与“功课圆满”完全一致（其中圆满 \(perfect) 天）")
        check(RecordStats.dayHabitRate([c], stats: [stats[2]], on: today) == nil, "当天功课完成率：今天还没过完，不算")

        // 消费日：只含已导全且已过完的月份，金额与 monthFacts.categories 同月合计一致（随机账簿 20 组）
        var rng3 = SeededRandom(state: 1020)
        var spendOK = 0
        let categories = ["餐饮与外卖", "超市与食品", "交通出行", "投资转账", "现金取款", "教育与学费"]
        for _ in 0..<20 {
            var ledger = FinanceLedger()
            for _ in 0..<Int.random(in: 30...120, using: &rng3) {
                var row = spend(d("2026-01-01").adding(days: Int.random(in: 0...300, using: &rng3)), Int.random(in: 100...20_000, using: &rng3),
                                category: categories[Int.random(in: 0..<categories.count, using: &rng3)])
                if Double.random(in: 0..<1, using: &rng3) < 0.1 { row.ignored = true }
                if Double.random(in: 0..<1, using: &rng3) < 0.1 { row.amountCents = -row.amountCents; row.kind = "退款" }
                ledger.transactions.append(row)
            }
            let coverStart = d("2026-01-01").adding(days: Int.random(in: 0...90, using: &rng3))
            ledger.sources = [statement(coverStart, coverStart.adding(days: Int.random(in: 30...280, using: &rng3)))]
            let result = RecordStats.spendDays(ledger, from: d("2026-01-01"), to: d("2026-10-19"), today: today)
            var ok = true
            var month = d("2026-01-01")
            while month <= d("2026-10-01") {
                let facts = FinanceEngine.monthFacts(ledger, month: month.monthKey)
                let end = AnnalsPeriod.monthEnd(month)
                let days = LocalDay.range(month, end)
                let inCovered = days.filter { Set(result.covered).contains($0) }
                if facts.fullMonth && end < today {
                    ok = ok && inCovered.count == days.count && days.reduce(0) { $0 + (result.cents[$1] ?? 0) } == facts.categories.values.reduce(0, +)
                } else {
                    ok = ok && inCovered.isEmpty && days.allSatisfy { result.cents[$0] == nil }
                }
                month = end.adding(days: 1)
            }
            if ok { spendOK += 1 }
        }
        check(spendOK == 20, "消费日：只含已导全且已过完的月份，逐月合计与 monthFacts 的类别合计一致（随机账簿 \(spendOK)/20 组）")
    }

    // 5. 长卷报告（手造小数据）
    do {
        var entries: [RecordEntry] = []
        entries.append(entry(d("2026-01-05"), .diary, mood: 4, title: "开年", body: String(repeating: "字", count: 90), tags: ["乙", "睡眠"]))
        for day in 1...10 { entries.append(entry(d("2026-02-\(String(format: "%02d", day))"), .note, body: "珍藏 \(day)", tags: ["甲"], pinned: true)) }
        entries.append(entry(d("2026-03-14"), .diary, mood: 5, title: "最长", body: String(repeating: "长", count: 150), tags: ["乙"]))
        entries.append(entry(d("2026-03-15"), .diary, mood: 2, body: String(repeating: "一", count: 120), tags: ["乙"]))
        entries.append(entry(d("2026-03-16"), .diary, mood: 3, body: String(repeating: "二", count: 110), tags: ["丙"]))
        entries.append(entry(d("2026-03-17"), .diary, mood: 4, body: String(repeating: "三", count: 105), tags: ["丙"]))
        entries.append(entry(d("2026-03-18"), .diary, body: String(repeating: "藏", count: 500), pinned: true))
        entries.append(entry(d("2026-04-01"), .review, body: "复盘", tags: ["丙"]))
        for (i, tag) in (1...12).map({ "t\($0)" }).enumerated() { entries.append(entry(d("2026-05-01").adding(days: i * 2), .note, body: "标签", tags: [tag])) }
        let future = entry(d("2026-10-25"), .diary, mood: 1, body: "未来的补记")
        let prior = [entry(d("2025-01-01"), .note, body: "去年"), entry(d("2025-06-01"), .diary, body: "去年"), entry(d("2025-11-01"), .diary, body: "去年年底")]
        let all = entries + [future]
        let history = (prior + all).map { (day: $0.day, kind: $0.kind) }
        let period = AnnalsPeriod.make(.year(2026), today: today)!
        let r = AnnalsEngine.report(period, input: makeInput(all, history: history))
        let w = r.writing
        let expectedCount = entries.count
        check(w?.entries == expectedCount && w?.byKind.values.reduce(0, +) == expectedCount
              && w?.perBucket.reduce(0, { $0 + $1.diary + $1.note + $1.review }) == expectedCount && w?.perBucket.count == 10
              && w?.chars == entries.reduce(0) { $0 + $1.chars } && w?.writingDays == Set(entries.map(\.day)).count,
              "长卷笔墨：篇数、各类、字数、动笔天数、按月格子之和都对（未来日期的补记不计）")
        check(w?.tags.map(\.tag) == ["甲", "乙", "丙", "睡眠", "t1", "t2", "t3", "t4", "t5", "t6"] && w?.tags.map(\.count).prefix(4) == [10, 3, 3, 1],
              "长卷笔墨：常用标签前 10，篇数降序、同数按首次出现：\(w?.tags.map { "\($0.tag) \($0.count)" }.joined(separator: "、") ?? "")")
        check(w?.previousEntries == 2 && w?.longest?.chars == 500 && w?.longestRun?.count == 10,
              "长卷笔墨：去年同期 2 篇只从 history 数、最长一篇、最长连续 10 天")
        let onlyPeriod = AnnalsEngine.report(period, input: makeInput(all.filter { $0.day >= period.first }, history: history))
        check(onlyPeriod.writing?.previousEntries == w?.previousEntries && onlyPeriod.writing?.entries == w?.entries,
              "长卷笔墨：entries 只给本期时对比结果不变")
        let late = AnnalsEngine.report(period, input: makeInput(all, history: history.filter { $0.day >= d("2025-03-01") }))
        check(late.writing?.previousEntries == nil && w?.spanDays == period.dayCount, "长卷笔墨：记录起点晚于对比期首 7 天以上时不比")
        let h = r.highlights
        check(h.pinned.count == 8 && h.pinnedMore == 3 && h.pinned.map(\.day) == h.pinned.map(\.day).sorted() && h.pinned.first?.day == d("2026-02-01")
              && h.longest.map(\.chars) == [152, 120, 110] && !h.longest.contains { $0.pinned || $0.kind != .diary },
              "长卷珍藏：按日期取前 8 篇、另有 3 篇；最长的日记排除珍藏与非日记、≥ 100 字取前 3")
        check(r.mood?.entries == 5 && r.mood?.distribution == [0, 0, 1, 1, 2, 1] && abs((r.mood?.average ?? 0) - 3.6) < 1e-9 && r.mood?.dominant == 4,
              "长卷心境：按篇平均 3.6、分布按篇数、多在「晴」（未来日期的不计）")
        check(r.insights.map(\.kind) == [.writingStreak] && !r.isEmpty && r.habits == nil && r.finance == nil,
              "长卷：没有功课与账簿时这两节没有；洞见只有过了门槛的（连续落笔 10 天）")

        // 修为：期初期末累计与破境日（门槛正好在期内某天跨过）
        let config = CultivationConfig(realms: ["一", "二", "三"], thresholds: [0, 100, 1000], dailyCap: 150, enabled: true)
        let xpHistory = (0..<19).map { (day: d("2025-12-01").adding(days: $0), kind: JournalKind.diary) }
            + [(day: d("2026-01-05"), kind: JournalKind.diary), (day: d("2026-01-06"), kind: JournalKind.review)]
        let xp = AnnalsEngine.report(period, input: makeInput(history: xpHistory, config: config)).cultivation
        check(xp?.startXP == 95 && xp?.gained == 20 && xp?.endXP == 115 && xp?.breakthroughs.count == 1
              && xp?.breakthroughs.first?.day == d("2026-01-05") && xp?.breakthroughs.first?.realm == "二"
              && xp?.perBucket.reduce(0, { $0 + $1.xp }) == 20,
              "长卷修为：期初 95、所得 20，1 月 5 日破境入「二」")
        var off = config
        off.enabled = false
        check(AnnalsEngine.report(period, input: makeInput(history: xpHistory, config: off)).cultivation == nil, "长卷修为：修为关闭时没有这一节")

        // 灵石：未导全月份进 incompleteMonths，对比只用两边都整月导全的月份；只有手记时不标、不比
        var ledger = FinanceLedger()
        var month = d("2025-01-01")
        while month <= d("2026-10-01") {
            for k in 0..<4 { ledger.transactions.append(spend(month.adding(days: k * 6), 1000 + k * 250 + month.month * 10, category: k == 3 ? "交通出行" : "餐饮与外卖")) }
            month = AnnalsPeriod.monthEnd(month).adding(days: 1)
        }
        var pending = spend(d("2026-04-03"), 500, category: "待分类消费")
        pending.needsReview = true
        ledger.transactions.append(pending)
        ledger.sources = [statement(d("2025-01-01"), d("2026-08-31"))]
        let f = AnnalsEngine.report(period, input: makeInput(ledger: ledger)).finance
        let monthsNet = (1...10).map { FinanceEngine.monthFacts(ledger, month: String(format: "2026-%02d", $0)).netSpendCents }
        let previousNet = (1...8).reduce(0) { $0 + FinanceEngine.monthFacts(ledger, month: String(format: "2025-%02d", $1)).netSpendCents }
        check(f?.incompleteMonths == ["9月", "10月"] && f?.comparison?.months == 8 && f?.comparison?.currentNetCents == monthsNet.prefix(8).reduce(0, +)
              && f?.comparison?.previousNetCents == previousNet && f?.netCents == monthsNet.reduce(0, +) && f?.months.count == 10
              && f?.months.last?.label == "10月（至今）" && f?.months.last?.ongoing == true && f?.pendingReview == 1 && f?.manualOnly == false
              && f?.categories.first?.change != nil,
              "长卷灵石：未导全的 9、10 月单列，对比只用两边都导全的 8 个整月：\(f?.remark ?? "")")
        var manual = ledger
        manual.sources = []
        let m = AnnalsEngine.report(period, input: makeInput(ledger: manual)).finance
        check(m?.manualOnly == true && m?.incompleteMonths.isEmpty == true && m?.comparison == nil && m?.categories.allSatisfy { $0.change == nil } == true
              && m?.remark?.hasPrefix("账目只含手记，还没导入银行账单") == true,
              "长卷灵石：只有手记的账簿不标未导全、不比较")
        let empty = AnnalsEngine.report(period, input: makeInput())
        check(empty.isEmpty && empty.writing == nil && empty.mood == nil && empty.habits == nil && empty.finance == nil && empty.highlights.isEmpty,
              "长卷：什么都没有时 isEmpty")

        // 9. Markdown：只出有数据的节，节号按实际出现的重排
        let md = AnnalsRenderer.markdown(r)
        let onlyMoney = AnnalsRenderer.markdown(AnnalsEngine.report(period, input: makeInput(ledger: ledger, config: off)))
        let blank = AnnalsRenderer.markdown(empty)
        check(md.hasPrefix("# 二〇二六年 · 岁月长卷\n1月1日 — 10月20日 · 尚未过完") && md.contains("## 其一 · 笔墨") && md.contains("## 其二 · 心境")
              && md.contains("## 其三 · 修为") && md.contains("## 其四 · 珍藏与长篇") && md.contains("## 其五 · 洞见") && !md.contains("灵石")
              && onlyMoney.contains("## 其一 · 灵石") && !onlyMoney.contains("修为") && blank.contains("这段时间没有记录。") && !blank.contains("## 其")
              && !blank.contains("> ")
              && [md, onlyMoney, blank].allSatisfy { !$0.contains("nil") && !$0.contains("Optional(") && $0.contains("辑于 2026年10月20日 · 云山修习录") },
              "长卷 Markdown：只写有数据的节，节号重排，不含 nil / Optional(")
    }

    // 6. 洞见：七类各一组“刚好过门槛”与“差一点不过”
    do {
        let to = d("2026-10-19"), from = to.adding(days: -89)
        let window = LocalDay.range(from, to)
        func run(_ input: RecordInput, _ kind: Insight.Kind, from f: LocalDay = from, to t: LocalDay = to) -> Insight? {
            InsightEngine.insights(input, from: f, to: t).first { $0.kind == kind }
        }
        // 心境与功课：10 个每天的功课，晴霁日 8/10 达标、雨阴日 7/10 达标（正好差 10 个百分点）
        func moodHabitInput(bright: Int, dim: Int, flat: Int = 0, brightMiss: Int = 0) -> RecordInput {
            var entries: [RecordEntry] = []
            var doneByHabit = Array(repeating: [LocalDay](), count: 10)
            for (i, day) in window.enumerated() {
                let mood: Int?, achieved: Int
                if i < bright { mood = 4; achieved = i < brightMiss ? 7 : 8 }
                else if i < bright + dim { mood = 2; achieved = 7 }
                else if i < bright + dim + flat { mood = 3; achieved = 5 }
                else { mood = nil; achieved = 10 }
                if let mood { entries.append(entry(day, .diary, mood: mood)) }
                for h in 0..<achieved { doneByHabit[h].append(day) }
            }
            return makeInput(entries, habits: (0..<10).map { habit("H\($0)", start: d("2026-01-01"), done: doneByHabit[$0]) })
        }
        let mh = run(moodHabitInput(bright: 10, dim: 10), .moodHabits)
        check(mh?.sample == 10 && mh?.text == "心境「晴」「霁」的日子里，功课完成率平均 80%；「雨」「阴」的日子里平均 70%。" && mh?.basis == "依据 20 天的心境与打卡",
              "洞见·心境与功课：两组各 10 天、正好差 10 个百分点就出：\(mh?.text ?? "nil")")
        check(run(moodHabitInput(bright: 10, dim: 9), .moodHabits) == nil, "洞见·心境与功课：雨阴日 9 天（其余也不够 10 天）不出")
        check(run(moodHabitInput(bright: 10, dim: 10, brightMiss: 1), .moodHabits) == nil, "洞见·心境与功课：差 9 个百分点不出")
        let fallback = run(moodHabitInput(bright: 10, dim: 6, flat: 4), .moodHabits)
        check(fallback?.text.hasSuffix("其余写了心境的日子平均 62%。") == true && fallback?.sample == 10,
              "洞见·心境与功课：雨阴日不够时改比其余写了心境的日子：\(fallback?.text ?? "nil")")

        // 易断功课：“晨跑”达标两次漏一次；“喝水”只漏 3 次
        let alternate = { (start: LocalDay) in LocalDay.range(start, to).enumerated().filter { $0.offset % 3 != 2 }.map(\.element) }
        let steady = window.enumerated().filter { ![10, 40, 70].contains($0.offset) }.map(\.element)
        func fragileInput(runStart: LocalDay, steadyDone: [LocalDay] = steady, pattern: ((LocalDay) -> [LocalDay])? = nil) -> RecordInput {
            makeInput(habits: [habit("A", start: runStart, done: (pattern ?? alternate)(runStart)), habit("B", start: from, done: steadyDone)])
        }
        let fragile = run(fragileInput(runStart: to.adding(days: -27)), .fragileHabit)
        check(fragile?.text == "最稳的是「B」，最长连续 29 天；「A」平均连续 2.1 天会歇一次（共 9 次）。" && fragile?.sample == 2,
              "洞见·易断功课：应打卡正好 28 次就出：\(fragile?.text ?? "nil")")
        check(run(fragileInput(runStart: to.adding(days: -26)), .fragileHabit) == nil, "洞见·易断功课：应打卡 27 次不够格、只剩一项合格就不出")
        check(run(fragileInput(runStart: to.adding(days: -27), steadyDone: window.enumerated().filter { ![10, 40].contains($0.offset) }.map(\.element)),
                  .fragileHabit) == nil, "洞见·易断功课：另一项只漏 2 次、合格的不到 2 项就不出")
        let sixOne = { (start: LocalDay) in LocalDay.range(start, to).enumerated().filter { $0.offset % 7 != 6 }.map(\.element) }
        check(run(fragileInput(runStart: from, pattern: sixOne), .fragileHabit) == nil, "洞见·易断功课：最易断那项完成率 86%（不低于 85%）不出")

        // 花钱的星期：7–9 月整月导全；周六 $52、其余 $40（正好 1.3 倍）
        func spendLedger(saturday: Int) -> FinanceLedger {
            var ledger = FinanceLedger()
            for day in LocalDay.range(d("2026-07-01"), d("2026-10-19")) {
                ledger.transactions.append(spend(day, day.weekdayIndex == 5 ? saturday : 4000))
            }
            ledger.sources = [statement(d("2026-07-01"), d("2026-09-30"))]
            return ledger
        }
        let sw = run(makeInput(ledger: spendLedger(saturday: 5200)), .spendWeekday)
        check(sw?.text == "周六花钱最多：平均每个周六约 $52，是其余日子日均（约 $40）的 1.3 倍。" && sw?.sample == 71,
              "洞见·花钱的星期：正好 1.3 倍就出：\(sw?.text ?? "nil")")
        check(run(makeInput(ledger: spendLedger(saturday: 5190)), .spendWeekday) == nil, "洞见·花钱的星期：1.2975 倍不出")
        let ledger56 = makeInput(ledger: spendLedger(saturday: 8000))
        check(run(ledger56, .spendWeekday, from: d("2026-08-06"), to: d("2026-09-30"))?.sample == 56
              && run(ledger56, .spendWeekday, from: d("2026-08-07"), to: d("2026-09-30")) == nil,
              "洞见·花钱的星期：已导全的覆盖天数 56 天就出、55 天不出")
        // 消费笔数：8 个周六 + 其余 22 天 = 30 笔就出，29 笔不出
        func countLedger(_ others: Int) -> FinanceLedger {
            var ledger = FinanceLedger()
            var used = 0
            for day in LocalDay.range(d("2026-08-06"), d("2026-09-30")) {
                if day.weekdayIndex == 5 {
                    ledger.transactions.append(spend(day, 8000))
                } else if used < others {
                    used += 1
                    ledger.transactions.append(spend(day, 4000))
                }
            }
            ledger.sources = [statement(d("2026-08-01"), d("2026-09-30"))]
            return ledger
        }
        check(run(makeInput(ledger: countLedger(22)), .spendWeekday, from: d("2026-08-06"), to: d("2026-09-30")) != nil
              && run(makeInput(ledger: countLedger(21)), .spendWeekday, from: d("2026-08-06"), to: d("2026-09-30")) == nil,
              "洞见·花钱的星期：期内消费 30 笔就出、29 笔不出")

        // 心境与花钱：晴霁日 $30、雨阴日 $40（多的是少的 1.33 倍、正好差 $10）
        func moodSpendInput(dimCents: Int, dimDays: Int = 10) -> RecordInput {
            var entries: [RecordEntry] = []
            var ledger = FinanceLedger()
            for (i, day) in LocalDay.range(d("2026-08-01"), d("2026-09-30")).enumerated() {
                if i < 10 { entries.append(entry(day, mood: 5)); ledger.transactions.append(spend(day, 3000)) }
                else if i < 10 + dimDays { entries.append(entry(day, mood: 1)); ledger.transactions.append(spend(day, dimCents)) }
                else { ledger.transactions.append(spend(day, 3500)) }
            }
            ledger.sources = [statement(d("2026-08-01"), d("2026-09-30"))]
            return makeInput(entries, ledger: ledger)
        }
        let ms = run(moodSpendInput(dimCents: 4000), .moodSpend)
        check(ms?.text == "心境「雨」「阴」的日子里，当天平均花 $40；「晴」「霁」的日子里平均 $30。" && ms?.sample == 10 && ms?.basis == "依据 20 天同时有心境和完整账单的日子",
              "洞见·心境与花钱：正好差 $10 就出，花得多的一组写在前面：\(ms?.text ?? "nil")")
        check(run(moodSpendInput(dimCents: 3990), .moodSpend) == nil && run(moodSpendInput(dimCents: 4000, dimDays: 9), .moodSpend) == nil,
              "洞见·心境与花钱：差 $9.9、或雨阴日只有 9 天都不出")

        // 功课的星期：100 个每天的功课；周二 95%、周日 80%、其余 85%
        func weekdayHabitInput(sunday: Int, days: [LocalDay] = window) -> RecordInput {
            var done = Array(repeating: [LocalDay](), count: 100)
            for day in days {
                let achieved = day.weekdayIndex == 1 ? 95 : day.weekdayIndex == 6 ? sunday : 85
                for h in 0..<achieved { done[h].append(day) }
            }
            return makeInput(habits: (0..<100).map { habit("W\($0)", start: d("2026-01-01"), done: done[$0]) })
        }
        let hw = run(weekdayHabitInput(sunday: 80), .habitWeekday)
        check(hw?.text == "功课完成率周二最高（平均 95%），周日最低（平均 80%）。" && hw?.sample == 12,
              "洞见·功课的星期：正好差 15 个百分点就出：\(hw?.text ?? "nil")")
        check(run(weekdayHabitInput(sunday: 81), .habitWeekday) == nil, "洞见·功课的星期：差 14 个百分点不出")
        let short = weekdayHabitInput(sunday: 50)
        check(run(short, .habitWeekday, from: to.adding(days: -55), to: to)?.sample == 8 && run(short, .habitWeekday, from: to.adding(days: -54), to: to) == nil,
              "洞见·功课的星期：每个星期都有 8 天才比，有一个只有 7 天就不出")

        // 心境的星期：周六一天两篇（5、4 → 4.5 … 5、5、5、4、4 → 4.6），其余 4.0
        func moodWeekdayInput(saturday: [Int]) -> RecordInput {
            var entries: [RecordEntry] = []
            for day in window {
                for mood in day.weekdayIndex == 5 ? saturday : [4] { entries.append(entry(day, mood: mood)) }
            }
            return makeInput(entries)
        }
        let mw = run(moodWeekdayInput(saturday: [5, 5, 5, 4, 4]), .moodWeekday)
        check(mw?.text == "心境周六最好（平均 4.6），周一最低（平均 4.0）。" && mw?.basis == "依据 90 天的日记心境（1 雨 … 5 霁）",
              "洞见·心境的星期：正好差 0.6 就出：\(mw?.text ?? "nil")")
        check(run(moodWeekdayInput(saturday: [5, 4]), .moodWeekday) == nil, "洞见·心境的星期：差 0.5 不出")
        let six = moodWeekdayInput(saturday: [5, 5, 5, 5, 5])
        check(run(six, .moodWeekday, from: to.adding(days: -41), to: to)?.sample == 6 && run(six, .moodWeekday, from: to.adding(days: -40), to: to) == nil,
              "洞见·心境的星期：每个星期 6 天就比，有一个只有 5 天不出")

        // 连续落笔：止于昨天的 5 天；更早有过更长的就不说“有记录以来最长”
        let five = LocalDay.range(to.adding(days: -4), to).map { (day: $0, kind: JournalKind.note) }
        let ws = run(makeInput(history: five), .writingStreak)
        check(ws?.text == "最长连续落笔 5 天（10月15日—10月19日），也是有记录以来最长的一次，至今仍在延续。" && ws?.sample == 5,
              "洞见·连续落笔：5 天就出：\(ws?.text ?? "nil")")
        check(run(makeInput(history: Array(five.dropFirst())), .writingStreak) == nil, "洞见·连续落笔：4 天不出")
        let longer = LocalDay.range(d("2026-03-01"), d("2026-03-20")).map { (day: $0, kind: JournalKind.note) } + five
        check(run(makeInput(history: longer), .writingStreak)?.text == "最长连续落笔 5 天（10月15日—10月19日），至今仍在延续。",
              "洞见·连续落笔：以前有过更长的，就不说“有记录以来最长”")
        let since = LocalDay.range(d("2026-07-01"), to).map { (day: $0, kind: JournalKind.note) }
        let sinceRun = run(makeInput(history: since), .writingStreak)
        check(sinceRun?.text == "最长连续落笔 111 天（7月1日—10月19日），也是有记录以来最长的一次，至今仍在延续。" && sinceRun?.sample == 90,
              "洞见·连续落笔：在窗口之前就开始的那一段照实写整段（111 天），样本仍按窗口内的 90 天")
        let pastQuarter = LocalDay.range(d("2026-09-20"), d("2026-10-05")).map { (day: $0, kind: JournalKind.note) }
        check(run(makeInput(history: pastQuarter), .writingStreak, from: d("2026-09-01"), to: d("2026-09-30"))?.text
              == "最长连续落笔 11 天（9月20日—9月30日），也是有记录以来最长的一次。",
              "洞见·连续落笔：过去的时段写到最后一天也不说“至今仍在延续”")
        let newYear = LocalDay.range(d("2025-12-29"), d("2026-01-03")).map { (day: $0, kind: JournalKind.note) }
        check(run(makeInput(history: newYear), .writingStreak, from: d("2025-12-20"), to: d("2026-01-10"))?.text
              == "最长连续落笔 6 天（2025年12月29日—1月3日），也是有记录以来最长的一次。",
              "洞见·连续落笔：跨年照算，去年的日子写年份")

        // 顺序固定、同输入同输出
        var combined = moodHabitInput(bright: 10, dim: 10)
        combined.history = five
        combined.ledger = spendLedger(saturday: 9000)
        let both = InsightEngine.insights(combined, from: from, to: to)
        check(both.map(\.kind) == [.writingStreak, .moodHabits, .spendWeekday] && both == InsightEngine.insights(combined, from: from, to: to),
              "洞见：显示顺序固定（先报喜），同样的输入每次同样的结果")
        check(InsightEngine.window(combined, from: from, to: today.adding(days: 3))?.to == to && InsightEngine.insights(combined, from: today, to: today).isEmpty,
              "洞见：窗口一律止于昨天（今天还没过完）")
    }

    // 6'. 随机 300 组输入：出现的洞见都过了门槛，文字不含因果词
    do {
        var rng4 = SeededRandom(state: 300)
        func roll(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng4) < p }
        let to = d("2026-10-19"), from = to.adding(days: -89)
        let minimum: [Insight.Kind: Int] = [
            .moodHabits: InsightEngine.Rules.groupDays, .fragileHabit: 2, .spendWeekday: InsightEngine.Rules.spendDays,
            .moodSpend: InsightEngine.Rules.groupDays, .habitWeekday: InsightEngine.Rules.weekdayDays,
            .moodWeekday: InsightEngine.Rules.moodWeekdayDays, .writingStreak: InsightEngine.Rules.streakDays,
        ]
        var seen: [Insight.Kind: Int] = [:]
        var bad: [String] = []
        for round in 0..<300 {
            let days = LocalDay.range(from.adding(days: -60), to)
            let good = Set(days.filter { _ in roll(0.5) })
            var entries: [RecordEntry] = []
            for day in days where roll(0.7) {
                let mood = good.contains(day) ? (roll(0.8) ? 4 + Int.random(in: 0...1, using: &rng4) : 3) : 1 + Int.random(in: 0...2, using: &rng4)
                entries.append(entry(day, .diary, mood: roll(0.85) ? mood : nil))
            }
            var habits: [RecordHabit] = []
            for (index, title) in ["A", "B", "C", "D"].prefix(Int.random(in: 0...4, using: &rng4)).enumerated() {
                let freq: HabitFrequency = index == 3 ? .weekly : roll(0.7) ? .daily : .weekdays
                let p = Double.random(in: 0.4...0.98, using: &rng4)
                habits.append(habit(title, freq, start: from.adding(days: Int.random(in: -120...40, using: &rng4)), weekdays: [0, 1, 2, 3, 4],
                                    perWeek: 3, archived: roll(0.15), archivedDay: roll(0.5) ? to.adding(days: -Int.random(in: 0...60, using: &rng4)) : nil,
                                    done: days.filter { roll(good.contains($0) ? min(1, p + 0.2) : p - 0.2) }))
            }
            var ledger: FinanceLedger?
            if roll(0.7) {
                var l = FinanceLedger()
                for day in days where roll(0.8) {
                    l.transactions.append(spend(day, Int.random(in: 500...9000, using: &rng4) * (day.weekdayIndex >= 5 ? 2 : 1) * (good.contains(day) ? 1 : 2)))
                }
                if roll(0.8) { l.sources = [statement(from.adding(days: -Int.random(in: 0...90, using: &rng4)), to.adding(days: -Int.random(in: 0...60, using: &rng4)))] }
                ledger = l
            }
            let history = days.filter { _ in roll(round % 2 == 0 ? 0.95 : 0.6) }.map { (day: $0, kind: JournalKind.note) }
            let input = makeInput(entries, history: history, habits: habits, ledger: ledger)
            let result = InsightEngine.insights(input, from: from, to: to)
            let order = result.map { Insight.Kind.allCases.firstIndex(of: $0.kind)! }
            if order != order.sorted() || Set(result.map(\.kind)).count != result.count { bad.append("第 \(round) 组顺序") }
            if result != InsightEngine.insights(input, from: from, to: to) { bad.append("第 \(round) 组两次结果不同") }
            for insight in result {
                seen[insight.kind, default: 0] += 1
                if insight.sample < minimum[insight.kind]! { bad.append("第 \(round) 组 \(insight.kind.rawValue) 样本 \(insight.sample)") }
                if let word = banned.first(where: { insight.text.contains($0) || insight.basis.contains($0) }) { bad.append("第 \(round) 组出现“\(word)”") }
            }
        }
        check(bad.isEmpty && seen.count == Insight.Kind.allCases.count,
              "洞见：随机 300 组，出现的都过了门槛、不含因果词（" + Insight.Kind.allCases.map { "\($0.rawValue) \(seen[$0] ?? 0)" }.joined(separator: "、") + "）"
              + (bad.isEmpty ? "" : "：\(bad.prefix(5).joined(separator: "；"))"))
    }

    // 7. 逐月趋势
    do {
        var entries: [RecordEntry] = []
        for day in stride(from: 0, to: 320, by: 2).map({ d("2025-12-15").adding(days: $0) }) where day <= today {
            entries.append(entry(day, .diary, mood: 1 + day.day % 5))
        }
        var ledger = FinanceLedger()
        for day in stride(from: 0, to: 300, by: 3).map({ d("2025-12-15").adding(days: $0) }) { ledger.transactions.append(spend(day, 2500)) }
        ledger.sources = [statement(d("2025-12-01"), d("2026-08-31"))]
        let input = makeInput(entries, habits: [habit("A", start: d("2025-12-15"), done: LocalDay.range(d("2025-12-15"), today).filter { $0.day % 3 != 0 })],
                              ledger: ledger)
        let months = TrendDigest.months(input, endingAt: today)
        check(months.count == 11 && months.first?.month == "2025-12" && months.last?.month == "2026-10" && months.last?.ongoing == true
              && months.filter(\.ongoing).count == 1 && months.reduce(0, { $0 + $1.entries }) == entries.count
              && months.allSatisfy { $0.averageMood != nil && $0.habitRate != nil && $0.netSpend != nil }
              && months.filter { !$0.spendComplete }.map(\.month) == ["2026-09", "2026-10"],
              "逐月趋势：早于第一条记录的月份不列（11 个月），本月未过完，9、10 月账单未导全")
        let early = makeInput(entries, history: entries.map { ($0.day, $0.kind) } + [(day: d("2024-01-01"), kind: JournalKind.note)])
        check(TrendDigest.months(early, endingAt: today).count == 12 && TrendDigest.months(makeInput(), endingAt: today).isEmpty,
              "逐月趋势：记录够早时列满 12 个月，一条记录都没有时为空")

        var s = PlannerSummary(generatedAt: "2026-10-20 08:00", periodDays: 30, today: today.key, profile: ["city": "悉尼"], goals: [],
                               recurringEvents: [], upcoming: [], scheduleHoursByCategory: [], routine: [], routineHoursByKind: [], habits: [],
                               cultivation: nil, focusQuestion: "")
        s.overview = ["- 修为：自检"]
        let plain = SummaryRenderer.markdown(s, preamble: "")
        check(!plain.contains("## 近") && !plain.contains("统计洞察") && TrendDigest.markdownLines(s).isEmpty && !SummaryRenderer.json(s).contains("longTerm"),
              "逐月趋势：没带这一段时 Markdown 不出这两个标题、JSON 里也没有这个键（问道灵枢原有输出不变）")
        s.trends = months
        s.trendsManualOnly = false
        s.insights = (1...7).map { "第 \($0) 条：心境「晴」「霁」的日子里，功课完成率平均 82%；「雨」「阴」的日子里平均 61%。（依据 64 天的心境与打卡）" }
        s.insightWindowDays = 90
        let full = SummaryRenderer.markdown(s, preamble: "")
        let lines = TrendDigest.markdownLines(s)
        let overviewAt = full.range(of: "## 概览")!.lowerBound, trendsAt = full.range(of: "## 近 11 个月逐月趋势")?.lowerBound
        let insightsAt = full.range(of: "## 统计洞察（近 90 天")?.lowerBound, profileAt = full.range(of: "## 个人档案")!.lowerBound
        check(trendsAt != nil && insightsAt != nil && overviewAt < trendsAt! && trendsAt! < insightsAt! && insightsAt! < profileAt
              && full.contains("| 2026-10（至 20 日） |") && lines.first { $0.hasPrefix("| 2026-09 |") }?.hasSuffix("（未导全） |") == true
              && lines.first { $0.hasPrefix("| 2026-08 |") }?.contains("未导全") == false,
              "逐月趋势：插在概览之后、档案之前，本月标“至 20 日”，未导全的月份注明")
        var long = s
        long.trends = TrendDigest.months(early, endingAt: today).map { var t = $0; t.netSpend = "$12,345"; return t }
        check(long.trends.count == 12 && TrendDigest.markdownLines(long).joined(separator: "\n").count <= 2500,
              "逐月趋势：12 行加 7 条洞见不超过 2,500 字（\(TrendDigest.markdownLines(long).joined(separator: "\n").count) 字）")
        var manualOnly = s
        manualOnly.trendsManualOnly = true
        let manualLines = TrendDigest.markdownLines(manualOnly).joined(separator: "\n")
        check(manualLines.contains("账目只含手记，未导入银行账单") && !manualLines.contains("（未导全）"),
              "逐月趋势：只有手记时表头改写、各行不标“未导全”")
    }

    // 8. 隐去姓名
    do {
        typealias R = IdentityRedactor
        check(R.redact("青岚今天去了图书馆", names: ["青岚"]) == "〔姓名〕今天去了图书馆" && R.names(from: ["Al"]).isEmpty
              && R.names(from: ["青岚子；Alex, 小A / 青岚 alex"]) == ["青岚 alex", "Alex", "青岚子", "青岚"],
              "隐去姓名：汉字名直接换；太短的不算名字；拆分称呼（空格连着的整段也留着）、去重、按长度排")
        check(R.redact("Alex and ALEX met Alexson; Alex今天", names: ["Alex"]) == "〔姓名〕 and 〔姓名〕 met Alexson; 〔姓名〕今天"
              && R.redact("青岚子与青岚", names: R.names(from: ["青岚", "青岚子"])) == "〔姓名〕与〔姓名〕" && R.redact("青岚", names: []) == "青岚",
              "隐去姓名：拉丁名按单词边界、不分大小写（Alexson 不换）；长名先换；空名单原样")
        let names = R.names(from: ["测试修士", "Alex；today"])
        var s = PlannerSummary(generatedAt: "2026-10-20 08:00", periodDays: 30, today: today.key, profile: ["name": "测试修士", "main_tasks": "帮 Alex 带课"],
                               goals: [.init(title: "测试修士的论文", category: "学业", status: "进行中", progress: 40, targetDate: nil)],
                               recurringEvents: [], upcoming: [.init(date: today.key, weekday: "周二", time: "全天", title: "和测试修士吃饭", category: "")],
                               scheduleHoursByCategory: [.init(category: "学业", hoursPerWeek: .nan)], routine: [], routineHoursByKind: [], habits: [],
                               cultivation: nil, focusQuestion: "today 怎么安排？")
        s.journal = [.init(date: today.key, weekday: "周二", time: nil, kind: "日记", title: "", body: "测试修士今天写完了第三章", mood: nil, period: nil, tags: [], source: nil)]
        s.financeToDate = .init(month: "10月", through: today.key, spend: "$1", refund: "$0", netSpend: "$1", topCategories: [], bankThrough: nil,
                                manualCount: 1, manualTotal: "$1", manual: ["10-20 请测试修士喝茶 $1.00［餐饮与外卖］"], pendingReview: 0)
        s.trends = [.init(month: "2026-10", ongoing: true, entries: 3, writingDays: 2, averageMood: 3.5, habitRate: 80, netSpend: "$1", spendComplete: false)]
        let r = R.redact(s, names: names)
        func keys(_ value: Any, _ path: String = "") -> Set<String> {
            if let object = value as? [String: Any] { return object.reduce(into: Set<String>()) { $0.insert(path + "/" + $1.key); $0.formUnion(keys($1.value, path + "/" + $1.key)) } }
            if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(keys($1, path + "[]")) } }
            return []
        }
        func object(_ text: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [:] }
        let json = SummaryRenderer.json(r), md = SummaryRenderer.markdown(r, preamble: "")
        check(![json, md].contains { $0.contains("测试修士") || $0.contains("Alex") } && json.contains("〔姓名〕") && md.contains("〔姓名〕")
              && r.focusQuestion == "〔姓名〕 怎么安排？" && r.today == today.key && keys(object(json)) == keys(object(SummaryRenderer.json(s)))
              && r.scheduleHoursByCategory.first?.hoursPerWeek.isNaN == true && r.trends == s.trends && r.profile.keys.sorted() == s.profile.keys.sorted(),
              "隐去姓名：整份摘要只换字符串值（Markdown、JSON 都不含原名），键名一个不少，名字恰好是键名 today 也不动键，NaN 照样往返")
    }
}

// MARK: 传书 goal / habit（纯 Core）

/// 改动前的 CourierService.matchIndex（原样保留，只用于对照 NameMatch.index）
func referenceMatchIndex(_ name: String, titles: [String]) -> Int? {
    let key = name.trimmingCharacters(in: .whitespaces).lowercased()
    let lower = titles.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard !key.isEmpty else { return nil }
    if let exact = lower.firstIndex(of: key) { return exact }
    let partial = lower.indices.filter { !lower[$0].isEmpty && (lower[$0].contains(key) || key.contains(lower[$0])) }
    return partial.count == 1 ? partial[0] : nil
}

do {
    let base = LocalDay(key: "2026-10-21")!   // 周三
    func parse(_ json: String, base: LocalDay = base) throws -> CourierPayload {
        try CourierParser.parse(Data(json.utf8), relativeTo: base, latest: base)
    }
    func failure(_ json: String) -> String {
        do { _ = try parse(json); return "" } catch { return error.localizedDescription }
    }
    func goal(_ json: String, base: LocalDay = base) throws -> (item: CourierGoal, payload: CourierPayload) {
        let payload = try parse(json, base: base)
        guard case let .goal(g) = payload.items[0] else { throw CourierError.invalid("应解析为 goal：\(json)") }
        return (g, payload)
    }
    func habit(_ json: String) throws -> (item: CourierHabit, payload: CourierPayload) {
        let payload = try parse(json)
        guard case let .habit(h) = payload.items[0] else { throw CourierError.invalid("应解析为 habit：\(json)") }
        return (h, payload)
    }
    func warned(_ payload: CourierPayload, _ text: String) -> Bool { payload.warnings.contains { $0.contains(text) } }

    // 1–2. 最简 goal；写了 date 照收并提醒
    let simple = try goal(#"{"type":"goal","title":"读完 24 本书"}"#).item
    check(simple.action == .create && simple.priority == "should" && simple.status == nil && simple.progress == nil && simple.deadline == .keep,
          "goal：只写 title 时是新立，优先级 should，状态、进度、期限都没写")
    check(warned(try goal(#"{"type":"goal","title":"读完 24 本书","date":"2026-10-14"}"#).payload, "goal 不用 date"),
          "goal：写了 date 照收，提醒“goal 不用 date”")
    // 3. 进度
    let rounded = try goal(#"{"type":"goal","title":"a","progress":70.4}"#)
    check(try goal(#"{"type":"goal","title":"a","progress":"70%"}"#).item.progress == 70
          && rounded.item.progress == 70 && warned(rounded.payload, "progress 70.4 已取整为 70"),
          "goal：progress \"70%\" → 70；70.4 取整为 70 并提醒")
    for bad in [#"101"#, #""七成""#, #"true"#, #"-1"#] {
        check(failure(#"{"type":"goal","title":"a","progress":\#(bad)}"#).contains("progress 应为 0–100 的整数"), "goal：progress \(bad) 拒收")
    }
    // 4. 状态
    let done = try goal(#"{"type":"goal","title":"a","status":"已完成","progress":40}"#)
    check(done.item.status == "completed" && done.item.progress == 100 && warned(done.payload, "进度已按 100% 记"),
          "goal：status “已完成” → completed，进度按 100 记并提醒")
    check(try goal(#"{"type":"goal","action":"update","title":"a","status":"completed"}"#).item.progress == 100,
          "goal：update 只写 status completed 时进度也按 100 记")
    check(failure(#"{"type":"goal","title":"a","status":"cancelled"}"#).contains("新立的目标不能是 cancelled"), "goal：新立时写 cancelled 拒收")
    check(failure(#"{"type":"goal","title":"a","status":"done"}"#).contains("status 应为 active / paused / completed / cancelled"),
          "goal：认不出的 status 拒收")
    check(failure(#"{"type":"goal","action":"modify","title":"a"}"#).contains("action 应为 create（新立）或 update（更新），收到「modify」"),
          "goal：action 写错时拒收并给出原文")
    // 5. update
    check(failure(#"{"type":"goal","action":"update","title":"a"}"#).contains("update 至少要写 progress、status、target_date、notes 中的一项"),
          "goal：update 一项可改的都没写时拒收")
    check(try goal(#"{"type":"goal","action":"update","title":"a","target_date":"none"}"#).item.deadline == .clear, "goal：update 的 target_date \"none\" → 取消期限")
    let emptyDate = try goal(#"{"type":"goal","action":"update","title":"a","target_date":"","progress":10}"#)
    check(emptyDate.item.deadline == .keep && emptyDate.payload.relativeDates == 0, "goal：target_date 空字符串等于没写（不是今天），不算相对日期")
    let tomorrow = try goal(#"{"type":"goal","title":"a","target_date":"tomorrow"}"#)
    check(tomorrow.item.deadline == .set(base.adding(days: 1)) && tomorrow.payload.relativeDates == 1, "goal：target_date tomorrow 按写入那天换算，算相对日期")
    check(warned(try goal(#"{"type":"goal","title":"a","deadline":"2026-09-01"}"#).payload, "2026-09-01 已经过去"), "goal：期限已经过去时照收并提醒")
    check(failure(#"{"type":"goal","title":"a","target_date":"下个月"}"#).contains(#"target_date 应为 YYYY-MM-DD（取消期限写 "none"），收到「下个月」"#),
          "goal：认不出的期限拒收")
    check(failure(#"{"type":"goal","action":"update","title":"a","detail":"只写了说明"}"#).contains("至少要写"), "goal：update 只写 detail 时拒收（报“至少要写…”）")
    let withDetail = try goal(#"{"type":"goal","action":"update","title":"a","detail":"说明","category":"学业","notes":"第三章初稿完成"}"#)
    check(withDetail.item.detail.isEmpty && withDetail.item.category.isEmpty && withDetail.item.notes == "第三章初稿完成"
          && warned(withDetail.payload, "update 只改 progress / status / target_date / notes，detail、category 已忽略"),
          "goal：update 同写 detail、category 与 notes 时只追加备注，detail、category 忽略并提醒")
    check(warned(try goal(#"{"type":"goal","title":"a","progress":100}"#).payload, "progress 是 100，但状态没改（仍是进行中）"),
          "goal：新立时写 progress 100 却没写 status，提醒“状态没改”")
    check(failure(#"{"type":"goal","title":"\#(String(repeating: "长", count: 72))"}"#).contains("title 太长（72 字，上限 60）：细节请写进 detail")
          && failure(#"{"type":"goal","title":"a","notes":"\#(String(repeating: "长", count: 812))"}"#).contains("notes 太长（812 字，上限 500）"),
          "goal：标题超过 60 字、备注超过 500 字时拒收并写出字数")
    check(try goal(#"{"type":"goal","name":"别名","deadline":"2027-02-17","state":"paused","percent":"30%"}"#).item
          == CourierGoal(action: .create, title: "别名", status: "paused", progress: 30, deadline: .set(LocalDay(key: "2027-02-17")!), noteDay: base),
          "goal：别名 name / deadline / state / percent")
    // 6. default 陷阱：没写 case 的类型不能再被当成打卡
    let goalTrap = failure(#"{"type":"goal","date":"2026-10-14"}"#), habitTrap = failure(#"{"type":"habit"}"#)
    check(goalTrap.contains("goal 需要 title") && !goalTrap.contains("checkin") && habitTrap.contains("habit 需要 title") && !habitTrap.contains("checkin"),
          "default 陷阱：goal / habit 缺 title 时报自己的错，不再报“checkin 需要 habit”：\(goalTrap)｜\(habitTrap)")
    check(CourierParser.typeList.contains("goal") && CourierParser.typeList.contains("habit"), "typeList 含 goal、habit")
    check(try parse(#"{"type":"目标","title":"a"}"#).items.count == 1 && (try? parse(#"{"type":"功课","title":"a"}"#)) != nil,
          "type 写中文“目标”“功课”也认")
    let strayGoal = try parse(#"{"type":"goal","title":"a","colour":"red"}"#).warnings.joined()
    let strayDiary = try parse(#"{"type":"diary","body":"a","colour":"red"}"#).warnings.joined()
    check(strayGoal.contains("这一类可用：action、title") && !strayGoal.contains("可用：date") && strayDiary.contains("这一类可用：date、"),
          "goal 写了不认识的字段时，“这一类可用”不含 date（日记照旧含）")

    // 7. 星期
    let weekdays = try habit(#"{"type":"habit","title":"练琴","weekdays":["周一","三","fri",7]}"#)
    check(weekdays.item.weekdays == [0, 2, 4, 6] && weekdays.item.frequency == .weekdays && warned(weekdays.payload, "没写 frequency，按 weekdays 记为“指定星期”"),
          "habit：weekdays [\"周一\",\"三\",\"fri\",7] → [0,2,4,6]，没写 frequency 时按指定星期并提醒")
    check(failure(#"{"type":"habit","title":"a","frequency":"weekdays","weekdays":[0,2]}"#).contains("里的 0 有歧义"), "habit：星期写 0 拒收（有歧义）")
    check(failure(#"{"type":"habit","title":"a","weekdays":["周八"]}"#).contains("weekdays 里的「周八」认不出"), "habit：认不出的星期拒收")
    check(failure(#"{"type":"habit","title":"a","frequency":"weekdays"}"#).contains(#"weekdays 频率需要 weekdays，例如 ["周一", "周三", "周五"]"#),
          "habit：weekdays 频率没写星期时拒收")
    let everyDay = try habit(#"{"type":"habit","title":"a","frequency":"weekdays","weekdays":["mon","tue","wed","thu","fri","sat","sun"]}"#)
    check(everyDay.item.frequency == .daily && everyDay.item.weekdays.isEmpty && warned(everyDay.payload, "weekdays 选了全部 7 天，已按 daily（每天）记"),
          "habit：七天全选按 daily 记并提醒")
    // 8. 每周 N 次
    let weekly = try habit(#"{"type":"habit","title":"运动","times_per_week":3}"#)
    check(weekly.item.frequency == .weekly && weekly.item.timesPerWeek == 3 && warned(weekly.payload, "没写 frequency，按 times_per_week 记为“每周 3 次”"),
          "habit：没写 frequency、写了 times_per_week 3 → 每周 3 次并提醒")
    check(failure(#"{"type":"habit","title":"a","frequency":"weekly"}"#).contains("weekly 需要 times_per_week（每周几次，1–7）")
          && failure(#"{"type":"habit","title":"a","frequency":"weekly","times_per_week":8}"#).contains("times_per_week 应为 1–7 的整数"),
          "habit：weekly 没写次数、次数为 8 都拒收")
    let dailyTimes = try habit(#"{"type":"habit","title":"a","frequency":"每天","times_per_week":3}"#)
    check(dailyTimes.item.frequency == .daily && dailyTimes.item.timesPerWeek == 1 && warned(dailyTimes.payload, "frequency 是 daily，times_per_week 已忽略"),
          "habit：每天的习惯写了 times_per_week 时忽略并提醒")
    check(failure(#"{"type":"habit","title":"a","frequency":"biweekly"}"#).contains("frequency 应为 daily / weekly / weekdays（每天 / 每周 N 次 / 指定星期），收到「biweekly」"),
          "habit：认不出的 frequency 拒收")
    // 9. 图标
    let unknownIcon = try habit(#"{"type":"habit","title":"a","icon":"rocket"}"#)
    check(try habit(#"{"type":"habit","title":"a","icon":"跑步"}"#).item.symbol == "figure.run"
          && unknownIcon.item.symbol == "leaf" && warned(unknownIcon.payload, "icon「rocket」认不出，已用 leaf（可用：leaf 叶、book 书、figure.run 跑步")
          && habit(#"{"type":"habit","title":"冥想"}"#).item.symbol == "brain.head.profile"
          && habit(#"{"type":"habit","title":"整理房间"}"#).item.symbol == "leaf"
          && HabitIcons.all.count == 15 && HabitIcons.labels.count == 15 && HabitIcons.guess(title: "论文写作") == "pencil.and.scribble",
          "habit：icon 写中文“跑步”→ figure.run；认不出用 leaf 并提醒；没写按名称猜（冥想 → brain.head.profile，猜不到 leaf）；共 15 个")
    // 10. 开始日期
    let noStart = try habit(#"{"type":"habit","title":"a"}"#)
    check(noStart.item.startDay == base && noStart.payload.relativeDates == 1, "habit：start_date 省略时是写入那天，算相对日期")
    let dateAsStart = try habit(#"{"type":"habit","title":"a","date":"2026-10-20"}"#)
    check(dateAsStart.item.startDay.key == "2026-10-20" && warned(dateAsStart.payload, "已把 date 当作 start_date")
          && warned(dateAsStart.payload, "start_date 早于今天：此后没打卡的应做日会算漏打"),
          "habit：只写 date 时当作 start_date 并说明；早于今天时提醒会算漏打")
    check(warned(try habit(#"{"type":"habit","title":"a","start_date":"2026-07-30"}"#).payload, "start_date 早于今天（83 天前）"),
          "habit：开始日期早于 60 天前时写出天数")
    let noTarget = try habit(#"{"type":"habit","title":"a","unit":"分钟"}"#)
    check(noTarget.item.unit.isEmpty && warned(noTarget.payload, "没有 target，unit 已忽略")
          && failure(#"{"type":"habit","title":"a","target":0}"#).contains("target 应为正数（每次的数量目标，例如 30）")
          && failure(#"{"type":"habit","title":"a","quantity":true}"#).contains("quantity（按 target 理解） 应为正数"),
          "habit：没有 target 时忽略 unit；target 为 0、true 时拒收")

    // 11. 去重用的规范化内容
    func canonical(_ json: String, base: LocalDay = base) throws -> String { try parse(json, base: base).items[0].canonical }
    check(try canonical(#"{"type":"goal","title":"读完  24 本书","priority":"must","target_date":"2026-12-31"}"#)
          == canonical(#"{"target_date":"2026-12-31","priority":"必须","title":"读完 24 本书 ","type":"goal"}"#)
          && canonical(#"{"type":"habit","title":"冥想","target":10,"unit":"分钟","start_date":"2026-10-21"}"#)
          == canonical(#"{"start_date":"2026-10-21","unit":"分钟","target":10.0,"type":"habit","title":" 冥想"}"#),
          "canonical：换字段顺序、加多余空白，goal / habit 的规范化内容相同")
    let note1 = #"{"type":"goal","action":"update","title":"论文","notes":"第三章初稿完成"}"#
    check(try canonical(note1) != canonical(#"{"type":"goal","action":"update","title":"论文","notes":"第四章初稿完成"}"#)
          && canonical(note1) == canonical(note1, base: base.adding(days: 1)),
          "canonical：update 的 notes 不同就不同；同一封隔天解析（备注日期不同）仍相同")

    // 12. 名称匹配
    let titles = ["晨读二十分钟", "喝水", " Reading ", "背单词", "单词卡", "　冥想　"]
    let names = ["晨读", "晨读二十分钟", "喝", "水", "reading", "READING ", "单词", "背单词", "冥想", "x", "", " ", "喝水啊", "单词卡片"]
    let mismatched = names.filter { NameMatch.index($0, titles: titles) != referenceMatchIndex($0, titles: titles) }
    check(mismatched.isEmpty && NameMatch.index("单词", titles: titles) == nil && NameMatch.index("冥想", titles: titles) == 5,
          "NameMatch.index 与原来的 matchIndex 逐个一致（完全相同优先、唯一包含、两个包含返回 nil、全角空格也去掉）" + (mismatched.isEmpty ? "" : "：\(mismatched)"))
    let goalRows: [(title: String, status: String)] = [("完成学位论文初稿", "active"), ("投出第一篇期刊论文", "completed"), ("学吉他", "cancelled"),
                                                     ("学吉他和弦", "active")]
    check(NameMatch.goal("学吉他", in: goalRows) == .found(2) && NameMatch.goal("论文", in: goalRows) == .ambiguous([0, 1])
          && NameMatch.goal("吉他", in: goalRows) == .found(3) && NameMatch.goal("减肥", in: goalRows) == .none,
          "NameMatch.goal：已放弃的完全同名能找到；两个未放弃的都包含时能对上多个；包含时先看未放弃的")

    // 13. 整封预检
    let roster = CourierRoster(habits: ["晨读二十分钟", "喝水"], archivedHabits: ["跳绳"], goals: [
        .init(title: "完成学位论文初稿", status: "active", progress: 65), .init(title: "投出第一篇期刊论文", status: "completed", progress: 100),
        .init(title: "学吉他", status: "cancelled", progress: 10),
    ])
    func resolve(_ json: String, _ roster: CourierRoster = roster) throws -> CourierRoster.Resolution { try roster.resolve(parse(json).items) }
    func rejection(_ json: String, _ roster: CourierRoster = roster) -> String {
        do { _ = try resolve(json, roster); return "" } catch { return error.localizedDescription }
    }
    check(rejection(#"{"type":"habit","title":"跳绳"}"#) == "第 1 条：已有同名的已归档习惯「跳绳」。请让用户在「每日功课」里取消归档，或换个名字"
          && rejection(#"{"type":"habit","title":"喝水 "}"#) == "第 1 条：已有同名习惯「喝水」。要打卡请用 checkin；要改它的设置请让用户在应用「每日功课」里改",
          "预检：新习惯与已归档、未归档的习惯同名时拒收（原文）")
    let sameEnvelope = try resolve(#"{"items":[{"type":"habit","title":"冥想"},{"type":"checkin","habit":"冥想"},{"type":"checkin","habit":"喝水"}]}"#)
    let checkinFirst = try resolve(#"{"items":[{"type":"checkin","habit":"冥想"},{"type":"habit","title":"冥想"}]}"#)
    check(sameEnvelope.checkins[1] == .new(0) && sameEnvelope.checkins[2] == .existing(1) && checkinFirst.checkins[0] == .new(1),
          "预检：同封“新建冥想 + 打卡冥想”打卡挂到新习惯（打卡排在前面也行）")
    check(rejection(#"{"type":"checkin","habit":"跑步"}"#) == "第 1 条：找不到习惯「跑步」。现有习惯：晨读二十分钟、喝水"
          && rejection(#"{"type":"checkin","habit":"跑步"}"#, CourierRoster(habits: [])) == "第 1 条：找不到习惯「跑步」。现有习惯：（无）",
          "预检：打卡对不上时的原文与原来一字不差")
    check(rejection(#"{"items":[{"type":"habit","title":"冥想"},{"type":"habit","title":"冥想"}]}"#) == "第 2 条：同一封里新建了两次「冥想」",
          "预检：同一封里新建两个同名习惯时拒收")
    check(try resolve(#"{"type":"habit","title":"晨读"}"#).notices == ["第 1 条：新习惯「晨读」和现有习惯「晨读二十分钟」名字互相包含，以后给它们打卡请写全称"],
          "预检：新习惯与现有习惯名字互相包含时照收并提醒")
    let notFound = rejection(#"{"type":"goal","action":"update","title":"减肥","progress":10}"#)
    check(notFound == "第 1 条：找不到目标「减肥」。现有目标：完成学位论文初稿（进行中 65%）、投出第一篇期刊论文（已完成 100%）",
          "预检：update 找不到目标时列出现有目标（不含已放弃）：\(notFound)")
    check(rejection(#"{"type":"goal","action":"update","title":"减肥","progress":10}"#, CourierRoster(habits: [], goals: []))
          == "第 1 条：找不到目标「减肥」。现有目标：（暂无目标）；要新立请去掉 action",
          "预检：一个目标都没有时提示去掉 action")
    check(rejection(#"{"type":"goal","action":"update","title":"论文","progress":70}"#) == "第 1 条：「论文」能对上多个目标：完成学位论文初稿、投出第一篇期刊论文。请写全称",
          "预检：update 能对上多个目标时拒收（原文）")
    let droppedTwin = try resolve(#"{"type":"goal","title":"学吉他"}"#)
    check(rejection(#"{"type":"goal","title":"完成学位论文初稿"}"#) == #"第 1 条：已有同名目标「完成学位论文初稿」（进行中，65%）。要更新它请写 "action": "update""#
          && droppedTwin.notices == ["第 1 条：另有一个已放弃的同名目标「学吉他」，这次新立的是另一个"],
          "预检：新立与进行中的目标同名拒收；与已放弃的同名照收并提醒")
    let revive = try resolve(#"{"type":"goal","action":"update","title":"学吉他","notes":"又开始练了"}"#)
    check(revive.goalUpdates[0] == 2 && revive.notices.contains { $0.contains("「学吉他」是已放弃的目标；要重新开始请写 status: active") },
          "预检：update 对上已放弃的目标时照收并提醒")
    check(rejection(#"{"items":[{"type":"goal","action":"update","title":"完成学位论文初稿","progress":70},{"type":"goal","action":"update","title":"学位论文","notes":"x"}]}"#)
          == "第 2 条：同一封里对「完成学位论文初稿」写了两条 update，请合成一条"
          && rejection(#"{"items":[{"type":"goal","action":"update","title":"读书","progress":10},{"type":"goal","title":"读书"}]}"#)
          == "第 1 条：同一封里既新立又更新「读书」，请合成一条 create",
          "预检：同封两条 update 同一目标、同封既新立又更新，都拒收")
    let hundred = try resolve(#"{"type":"goal","action":"update","title":"完成学位论文初稿","progress":100}"#)
    let hundredDone = try resolve(#"{"type":"goal","action":"update","title":"投出第一篇期刊论文","progress":100}"#)
    check(hundred.goalUpdates[0] == 0 && hundred.notices == [#"第 1 条：progress 是 100，但状态没改（仍是进行中）；要标记完成请写 "status": "completed""#]
          && hundredDone.notices.isEmpty,
          "预检：update 只写 progress 100 时提醒“状态没改”（目标已完成时不提醒）")
    let noGoals = try resolve(#"{"type":"goal","action":"update","title":"不存在","progress":10}"#, CourierRoster(habits: ["喝水"]))
    check(noGoals.goalUpdates.isEmpty && noGoals.notices.isEmpty, "预检：goals 为 nil（小抄里没有）时跳过目标检查")

    // 14. 摘要行
    let moveLine = CourierLineDecor.goalUpdateLine(title: "论文：第三章", changes: [.note("第三章\n初稿完成"), .progress(60, 65)], today: base)
    check(moveLine == "目标 · 论文：第三章：进度\u{A0}60% →\u{A0}65%；备注 +「第三章 初稿完成」"
          && CourierLineDecor.progressMove(moveLine) == .init(title: "论文：第三章", from: 60, to: 65, completed: false),
          "摘要行：各段顺序固定、备注换行变空格；能解析回进度变化（标题含“：”也对）：\(moveLine)")
    let finishLine = CourierLineDecor.goalUpdateLine(title: "存下应急金", changes: [.status("active", "completed"), .progress(80, 100)], today: base)
    let statusDone = CourierLineDecor.goalUpdateLine(title: "a", changes: [.progress(90, 95), .status("paused", "completed")], today: base)
    check(finishLine == "目标 · 存下应急金：进度\u{A0}80% →\u{A0}100%；状态 进行中 → 已完成" && CourierLineDecor.progressMove(finishLine)?.completed == true
          && CourierLineDecor.progressMove(statusDone)?.completed == true
          && CourierLineDecor.progressMove(CourierLineDecor.goalUpdateLine(title: "a", changes: [.progress(10, 20), .note("状态 进行中 → 已完成")], today: base))?.completed == false,
          "摘要行：终值 100 或“状态 … → 已完成”算达成（备注里的字不算）")
    let created = try goal(#"{"type":"goal","title":"完成学位论文初稿","target_date":"2027-02-17","priority":"must"}"#).item
    check(created.summary == "目标 · 新立「完成学位论文初稿」（期限\u{A0}2027年2月17日，必须）" && CourierLineDecor.progressMove(created.summary) == nil
          && CourierLineDecor.progressMove(CourierLineDecor.goalUpdateLine(title: "a", changes: [.status("active", "paused")], today: base)) == nil
          && CourierLineDecor.progressMove(CourierLineDecor.goalSkipLine(title: "a")) == nil,
          "摘要行：新立行、没有进度变化的目标行解析不出进度：\(created.summary)")
    check(CourierLineDecor.goalUpdateLine(title: "a", changes: [.deadline("2026-12-19", "2027-01-15")], today: base) == "目标 · a：期限\u{A0}12月19日 →\u{A0}2027年1月15日"
          && CourierLineDecor.goalUpdateLine(title: "a", changes: [.deadline(nil, "2026-12-31")], today: base) == "目标 · a：期限\u{A0}无 →\u{A0}12月31日"
          && CourierLineDecor.goalUpdateLine(title: "a", changes: [], today: base) == "目标 · a（已是这个内容，跳过）",
          "摘要行：期限跨年带年份、没有期限写“无”；什么都没变时写“跳过”")
    let remark = "（相对日期按写入那天 10月21日 计算）"
    let goalLines = [moveLine, finishLine, remark], habitLines = ["功课 · 新立「冥想」（每天，自 10月21日 起）", "打卡 · 10月21日 · 冥想", remark]
    let mixedLines = [moveLine, "功课 · 新立「冥想」（每天，自 10月21日 起）", "打卡 · 10月21日 · 冥想"]
    check(CourierLineDecor.symbol(goalLines) == "flag" && CourierLineDecor.page(goalLines) == "profile"
          && CourierLineDecor.symbol(habitLines) == "leaf" && CourierLineDecor.page(habitLines) == "habits"
          && CourierLineDecor.symbol(mixedLines) == nil && CourierLineDecor.page(mixedLines) == nil && CourierLineDecor.symbol([remark]) == nil,
          "传书笺图标与“查看”页：全是目标、全是功课和打卡、混合三种情况各对；末尾的附注行不影响")
    // 15. 收录条数
    check(CourierRefCount.items([("goalset", "courier:A#progress"), ("goalset", "courier:A#notes"), ("goalset", "courier:A#status"),
                                 ("habit", "courier:H"), ("checkin", "courier:C"), ("hash", "x")]) == 3,
          "收录条数：一个目标的 3 项更新算 1 条，hash 不计")
    // 16. 值快照
    let values = GoalValues(title: "论文", detail: "说明", category: "学业", priority: "must", status: "active", targetDate: "2027-02-17",
                            progress: 60, notes: "2026年10月21日：第一行\n第二行\u{1F}x")
    var expected = values
    expected.progress = 70
    expected.notes = "追加后"
    check(GoalValues(fingerprint: values.fingerprint) == values && GoalValues(fingerprint: "旧数据") == nil
          && GoalValues.expected(created: values, laterWrites: [("progress", "65"), ("notes", "追加后"), ("progress", "70")]) == expected
          && values.value(of: "target_date") == "2027-02-17" && values.value(of: "progress") == "60",
          "GoalValues：指纹能原样解析回来（备注里有换行、分隔符也行）；expected 依次叠加后来的写入")
    let newHabit = try habit(#"{"type":"habit","title":"冥想","target":10,"unit":"分钟"}"#).item
    var changedHabit = HabitValues(created: newHabit)
    changedHabit.timesPerWeek = 2
    check(HabitValues(created: newHabit).fingerprint == HabitValues(created: newHabit).fingerprint && changedHabit.fingerprint != HabitValues(created: newHabit).fingerprint
          && GoalValues(created: created).status == "active" && GoalValues(created: created).targetDate == "2027-02-17",
          "HabitValues / GoalValues：新建时的值与指纹")
    // 16a. 摘要与 --add
    let update = try goal(#"{"type":"goal","action":"update","title":"论文","progress":70,"status":"completed","target_date":"2026-12-31","notes":"第三章初稿完成"}"#).item
    check(newHabit.summary == "功课 · 新立「冥想」（每天，每次\u{A0}10分钟，自\u{A0}10月21日\u{A0}起）" && CourierItem.habit(newHabit).summary == newHabit.summary
          && update.summary == "目标 · 更新「论文」：进度\u{A0}→\u{A0}100%；状态 → 已完成；期限\u{A0}→\u{A0}12月31日；备注 +「第三章初稿完成」"
          && CourierItem.goal(update).summary.hasPrefix("目标 · 更新「") && update.notePrefix == "2026年10月21日：",
          "摘要：新习惯以“功课 · 新立「”开头，update 以“目标 · 更新「”开头；追加备注的日期带年份：\(update.summary)")
    let weekdaySummary = try habit(#"{"type":"habit","title":"论文写作","weekdays":[1,2,3,4,5],"target":90,"unit":"分钟","start_date":"2027-01-04"}"#).item.summary
    check(weekdaySummary == "功课 · 新立「论文写作」（每周一、二、三、四、五，每次\u{A0}90分钟，自\u{A0}2027年1月4日\u{A0}起）", "摘要：指定星期的写法，跨年的开始日期带年份：\(weekdaySummary)")
} catch {
    check(false, "传书 goal / habit 检查失败：\(error)")
}

// MARK: 快照近况速览（纯 Core）

do {
    let today = LocalDay(key: "2026-10-21")!   // 周三
    func day(_ offset: Int) -> LocalDay { today.adding(days: offset) }
    func logs(_ days: [LocalDay]) -> [HabitLogValue] { days.map { HabitLogValue(day: $0, completed: true, quantity: nil) } }
    func fact(_ title: String, _ spec: HabitSpec, _ done: [LocalDay], today: LocalDay = today) -> SnapshotDigest.HabitFact {
        .init(title: title, stats: HabitStats(spec: spec, logs: logs(done), today: today))
    }
    let monday = today.mondayOfWeek
    let daily = HabitSpec(frequency: .daily, startDay: LocalDay(key: "2026-09-01")!)

    // 17. 复盘要点
    let standard = "【所得】\n论文写了 4,200 字。补习课一节没落下。\n【所失】\n周四熬夜，第二天状态很差。\n【所悟】\n先写后改，比反复想更快。\n【下一步】\n每天上午先写 90 分钟。周三之前回复导师的邮件。"
    let points = SnapshotDigest.reviewPoints(standard)
    check(points == "所悟：先写后改，比反复想更快；下一步：每天上午先写 90 分钟" && points.count <= 90, "复盘要点：取所悟、下一步的第一句：\(points)")
    let plain = String(repeating: "没有标记的一段话 ", count: 20)
    check(SnapshotDigest.reviewPoints(plain).count == 81 && SnapshotDigest.reviewPoints(plain).hasSuffix("…") && !SnapshotDigest.reviewPoints(plain).contains("  "),
          "复盘要点：没有【】标记时空白折叠后取前 80 字加“…”")
    check(SnapshotDigest.reviewPoints("【所得】写完第二章！【所失】\n熬夜\n【所悟】\n\n【下一步】") == "所得：写完第二章；所失：熬夜",
          "复盘要点：所悟、下一步都空时取所得、所失")
    let long = SnapshotDigest.reviewPoints("【所悟】" + String(repeating: "长", count: 60) + "【下一步】" + String(repeating: "远", count: 60))
    check(long.count <= 90 && long.contains("…"), "复盘要点：每句超过 40 字截断，整体 ≤ 90 字（\(long.count)）")

    // 18. 本周功课（今天周三，本周一 10月19日）
    let midWeek = SnapshotDigest.weekHabits([fact("晨读", daily, [monday]), fact("背单词", daily, [day(-7)])], today: today)
    check(midWeek.due == 4 && midWeek.done == 1 && midWeek.pendingToday == 2 && midWeek.behind == [.init(title: "背单词", done: 0, due: 2)],
          "本周功课：周一 ✓ 周二 ✗ 今天没打 → 1/2 不算落后；周一、周二都漏 → 落后；今天没打的两项计入 pendingToday")
    let weeklyThree = HabitSpec(frequency: .weekly, targetPerWeek: 3, startDay: LocalDay(key: "2026-08-03")!)
    let onceSoFar = SnapshotDigest.weekHabits([fact("运动", weeklyThree, [monday])], today: today)
    let saturday = today.adding(days: 3)
    let noneBySaturday = SnapshotDigest.weekHabits([fact("运动", weeklyThree, [], today: saturday)], today: saturday)
    check(onceSoFar.behind.isEmpty && onceSoFar.weekly == [.init(title: "运动", done: 1, target: 3, daysLeft: 5, streakWeeks: 0)]
          && onceSoFar.due == 0 && onceSoFar.done == 0
          && noneBySaturday.behind == [.init(title: "运动", done: 0, due: 3)] && noneBySaturday.weekly.isEmpty,
          "本周功课：每周 3 次已成 1、剩 5 天不落后；周六还是 0 次（剩 2 天）挪进落后；每周 N 次不进主行的应做 / 已成")
    // 连续 10 天的每天习惯进“稳住”；连续 4 周达标的每周 1 次只写在它那一行
    let streakDays = LocalDay.range(day(-9), today)
    let weeklyOnce = HabitSpec(frequency: .weekly, targetPerWeek: 1, startDay: LocalDay(key: "2026-08-03")!)
    let onceWeeks = (0..<4).map { monday.adding(days: -7 * $0) }
    let steadyWeek = SnapshotDigest.weekHabits([fact("喝水", daily, streakDays), fact("整理房间", weeklyOnce, onceWeeks)], today: today)
    check(steadyWeek.steady == [.init(title: "喝水", count: 10, unit: "天")]
          && steadyWeek.weekly == [.init(title: "整理房间", done: 1, target: 1, daysLeft: 5, streakWeeks: 4)],
          "本周功课：稳住只收每天 / 指定星期（连续 ≥ 7 天）；每周 N 次的连续周数记在它那一行")
    func digestLines(_ habits: [SnapshotDigest.HabitFact], today: LocalDay = today) -> [String] {
        SnapshotDigest.lines(.init(today: today, realm: .init(title: "炼气 · 初期", totalXP: 0, nextRealm: "筑基", toNext: 100, last7: 0, enabled: true),
                                   habits: habits, goals: [], reviews: [], lastReviewDay: nil, entries: [], lastEntryDay: nil, finance: nil, financeToDate: nil))
    }
    let weeklyOnly = digestLines([fact("运动", weeklyThree, [monday]), fact("整理房间", weeklyOnce, onceWeeks)])
    check(weeklyOnly[1] == "- 本周功课（10月19日起，今天第 3 天）：今天还有 1 项没打"
          && weeklyOnly[2] == "  - 每周 N 次：运动 1/3 次（剩 5 天）、整理房间 1/1 次 ✓（连续 4 周）",
          "本周功课：只有每周 N 次的习惯时主行不写“应做”：\(weeklyOnly[1])｜\(weeklyOnly[2])")
    let mainLines = digestLines([fact("晨读", daily, [monday]), fact("背单词", daily, [day(-7)]), fact("喝水", daily, streakDays)])
    check(mainLines[1] == "- 本周功课（10月19日起，今天第 3 天）：应做 7 次，已成 4 次（57%）；今天还有 2 项没打"
          && mainLines[2] == "  - 落后：背单词 0/2" && mainLines[3] == "  - 稳住：喝水 连续 10 天",
          "本周功课：主行、落后、稳住的写法：\(mainLines[1...3])")
    let freshStart = digestLines([fact("冥想", HabitSpec(frequency: .daily, startDay: today), [])])
    check(freshStart[1] == "- 本周功课（10月19日起，今天第 3 天）：还没有可统计的日子；今天还有 1 项没打", "本周功课：习惯今天才开始时写“还没有可统计的日子”")
    // 今天是周一：看上周整周
    let nextMonday = LocalDay(key: "2026-10-26")!
    let lastWeek = SnapshotDigest.weekHabits([fact("晨读", daily, LocalDay.range(monday, monday.adding(days: 5)), today: nextMonday)], today: nextMonday)
    let lastWeekLine = digestLines([fact("晨读", daily, LocalDay.range(monday, monday.adding(days: 5)) + [nextMonday], today: nextMonday)], today: nextMonday)[1]
    check(lastWeek.lastWeek && lastWeek.first == monday && lastWeek.last.key == "2026-10-25" && lastWeek.due == 7 && lastWeek.done == 6
          && lastWeekLine == "- 上周功课（10月19日–25日）：应做 7 次，已成 6 次（86%）；今天已打 1 / 1 项",
          "本周功课：今天是周一时统计上周整周，另写今天已打几项：\(lastWeekLine)")
    // 跨年那周：2025-12-29（周一）→ 2026-01-02（周五）
    let newYear = LocalDay(key: "2026-01-02")!
    let yearSpan = SnapshotDigest.weekHabits([fact("晨读", HabitSpec(frequency: .daily, startDay: LocalDay(key: "2025-12-01")!),
                                                   LocalDay.range(LocalDay(key: "2025-12-29")!, newYear), today: newYear)], today: newYear)
    let yearLine = digestLines([fact("晨读", HabitSpec(frequency: .daily, startDay: LocalDay(key: "2025-12-01")!),
                                     LocalDay.range(LocalDay(key: "2025-12-29")!, newYear), today: newYear)], today: newYear)[1]
    check(yearSpan.first.key == "2025-12-29" && yearSpan.due == 5 && yearSpan.done == 5 && yearLine.hasPrefix("- 本周功课（2025年12月29日起，今天第 5 天）：应做 5 次"),
          "本周功课：跨年那周照常统计：\(yearLine)")
    check(digestLines([])[1] == "- 功课：还没有习惯", "本周功课：一个习惯都没有")

    // 19. 目标
    func goal(_ title: String, progress: Int, deadline: String?, priority: String = "should", status: String = "active",
              created: LocalDay = LocalDay(key: "2026-01-01")!, updated: LocalDay = LocalDay(key: "2026-10-01")!) -> SnapshotDigest.GoalFact {
        .init(title: title, status: status, progress: progress, priority: priority, category: "", targetDate: deadline.flatMap(LocalDay.init(key:)),
              createdDay: created, updatedDay: updated)
    }
    let created84 = today.adding(days: -84)
    let goals = [
        goal("没有期限的", progress: 10, deadline: nil),
        goal("完成学位论文初稿", progress: 65, deadline: "2027-02-17", priority: "must", created: LocalDay(key: "2026-10-01")!),
        goal("逾期的", progress: 30, deadline: "2026-10-16"),
        goal("每周运动三次", progress: 72, deadline: created84.adding(days: 100).key, created: created84),
        goal("同期限应该", progress: 50, deadline: "2027-02-17", created: LocalDay(key: "2026-10-01")!),
        goal("学会弹《卡农》", progress: 40, deadline: nil, status: "paused"),
        goal("存下应急金", progress: 100, deadline: "2026-09-30", status: "completed", updated: LocalDay(key: "2026-09-30")!),
        goal("早就完成的", progress: 100, deadline: nil, status: "completed", updated: LocalDay(key: "2026-06-01")!),
        goal("放弃的", progress: 5, deadline: nil, status: "cancelled"),
    ]
    let goalText = SnapshotDigest.goalLines(goals, today: today)
    check(goalText == [
        "- 目标（进行中 5 · 暂停 1）：",
        "  - 逾期的 30%，期限 10月16日（已逾期 5 天）",
        "  - 每周运动三次 72%，期限 11月6日（还剩 16 天，时间已过 84%）",
        "  - 完成学位论文初稿 65%，期限 2027年2月17日（还剩 119 天）［必须］",
        "  - 同期限应该 50%，期限 2027年2月17日（还剩 119 天）",
        "  - 没有期限的 10%",
        "  - 暂停：学会弹《卡农》 40%",
        "  - 近 30 天完成：存下应急金（9月30日）",
    ], "目标：逾期 → 期限近 → 无期限，同期限必须在前；跨年带年份；时间进度落后时写出：\(goalText)")
    check(SnapshotDigest.timeShare(created: created84, deadline: created84.adding(days: 100), today: today) == 84
          && !SnapshotDigest.goalLines([goal("a", progress: 80, deadline: created84.adding(days: 100).key, created: created84)], today: today)[1].contains("时间已过")
          && SnapshotDigest.timeShare(created: today, deadline: today, today: today) == nil,
          "目标：时间已过 84%、进度 80 时不写；创建日不早于期限时不算")
    let many = SnapshotDigest.goalLines((1...7).map { goal("目标\($0)", progress: $0, deadline: nil) }, today: today)
    check(many.count == 7 && many.last == "  - 另有 2 个进行中的目标，见下方「目标」一节", "目标：超过 5 个进行中时写“另有 N 个”")
    check(SnapshotDigest.goalLines([], today: today) == ["- 目标：还没有设立具体目标"]
          && SnapshotDigest.goalLines([goals[7], goals[8]], today: today) == ["- 目标：目前没有进行中的目标（已完成 1 个）"],
          "目标：没有目标、只有已完成或已放弃的")

    // 20. 落笔
    let entries: [SnapshotDigest.EntryFact] = [
        .init(day: today, kind: .diary, mood: 4), .init(day: day(-1), kind: .diary, mood: 4), .init(day: day(-2), kind: .diary, mood: 3),
        .init(day: day(-3), kind: .note, mood: nil), .init(day: day(-6), kind: .review, mood: nil), .init(day: day(-8), kind: .diary, mood: 2),
        .init(day: day(-12), kind: .diary, mood: 3),
    ]
    check(SnapshotDigest.writingLine(entries, today: today, lastEntryDay: today) == "- 落笔：近 7 天 5 篇（日记 3 · 灵感 1 · 复盘 1），心境多「晴」，均值 3.7（前 7 天 2.5）",
          "落笔：篇数、心境（按篇平均，一位小数）与前 7 天对照")
    check(SnapshotDigest.writingLine([.init(day: today, kind: .diary, mood: 3), .init(day: day(-1), kind: .diary, mood: 4)], today: today, lastEntryDay: today)
          == "- 落笔：近 7 天 2 篇（日记 2），心境多「晴」，均值 3.5"
          && SnapshotDigest.writingLine([.init(day: today, kind: .note, mood: nil)], today: today, lastEntryDay: today) == "- 落笔：近 7 天 1 篇（灵感 1）",
          "落笔：并列时取较好的心境；前 7 天没有心境时不写括号；没有心境时整段不写")
    check(SnapshotDigest.writingLine([.init(day: day(-12), kind: .diary, mood: 3)], today: today, lastEntryDay: LocalDay(key: "2026-10-09"))
          == "- 落笔：近 7 天没有落笔（上一篇 10月9日）",
          "落笔：近 7 天没有时写上一篇的日子")

    // 21. 消费
    let finance = PlannerSummary.Finance(month: "2026年9月", fullMonth: true, spend: "$2,512.30", refund: "$80.55", netSpend: "$2,431.75", otherDebits: "$0.00",
                                         topCategories: ["餐饮与外卖 $642.10"], changeVsPreviousMonth: "消费 -$118.20，扣除教育后 -$95.00", budgets: [], pendingReview: 3)
    var toDate = PlannerSummary.FinanceToDate(month: "2026年10月", through: "2026-10-21", spend: "$1,201.40", refund: "$15.00", netSpend: "$1,186.40",
                                              topCategories: ["餐饮与外卖 $312.50", "超市与食品 $268.10", "交通出行 $145.00", "购物 $98.00"],
                                              bankThrough: "2026-10-15", manualCount: 0, manualTotal: "$0.00", manual: [], pendingReview: 0)
    let money = SnapshotDigest.moneyLines(finance, toDate, today: today)
    check(money == ["- 消费：10月至今净消费 $1,186.40（银行流水只导入到 10月15日，之后的刷卡还没进账）；主要：餐饮与外卖 $312.50、超市与食品 $268.10、交通出行 $145.00",
                    "  - 9月（最近一个整月）：净消费 $2,431.75，较上月 消费 -$118.20；另有 3 笔待确认"],
          "消费：有本月至今时写导入到哪天、主要类别前 3 个，子行写最近整月：\(money)")
    toDate.bankThrough = "2026-10-21"
    var partial = finance
    partial.fullMonth = false
    partial.changeVsPreviousMonth = nil
    partial.pendingReview = 0
    let imported = SnapshotDigest.moneyLines(partial, toDate, today: today)
    toDate.bankThrough = nil
    check(imported[0].contains("（银行流水已导入到 10月21日）") && imported[1] == "  - 9月（账单不全）：净消费 $2,431.75"
          && SnapshotDigest.moneyLines(nil, toDate, today: today)[0].contains("（还没导入过银行流水）"),
          "消费：导入到今天时写“已导入到”，没导入过写“还没导入过”；账单不全的月份标出来")
    var thisMonth = partial
    thisMonth.month = "2026年10月"
    check(SnapshotDigest.moneyLines(thisMonth, nil, today: today) == ["- 消费：10月（账单不全）净消费 $2,431.75；主要：餐饮与外卖 $642.10"]
          && SnapshotDigest.moneyLines(nil, nil, today: today) == ["- 消费：还没有账目"],
          "消费：账上只有本月、没有账两种情况")
    check(SnapshotDigest.monthText("2026年9月", today: today) == "9月" && SnapshotDigest.monthText("2025年12月", today: LocalDay(key: "2026-01-03")!) == "2025年12月",
          "消费：月份同年去掉年份，跨年保留")

    // 22. 空数据
    let empty = CultivationEngine.state(for: 0, config: CultivationConfig())
    func emptyInput(enabled: Bool) -> SnapshotDigest.Input {
        .init(today: today, realm: .init(title: empty.title, totalXP: 0, nextRealm: empty.nextRealmName, toNext: empty.xpToNext, last7: 0, enabled: enabled),
              habits: [], goals: [], reviews: [], lastReviewDay: nil, entries: [], lastEntryDay: nil, finance: nil, financeToDate: nil)
    }
    let blank = SnapshotDigest.lines(emptyInput(enabled: true))
    check(blank == ["- 境界：炼气 · 初期，累计修为 0，距「筑基」还差 100；近 7 日 +0（日均 0）", "- 功课：还没有习惯", "- 目标：还没有设立具体目标",
                    "- 最近复盘：还没有写过复盘", "- 落笔：还没有写过日记、灵感或复盘", "- 消费：还没有账目"]
          && SnapshotDigest.lines(emptyInput(enabled: false))[0] == "- 境界：修为已在设置里关闭",
          "速览：空数据时境界照写，其余各组各有一句“还没有…”；关了修为写“修为已在设置里关闭”：\(blank)")
    check(SnapshotDigest.realmLine(.init(title: "化神 · 后期", totalXP: 2318, nextRealm: "炼虚", toNext: 682, last7: 296, enabled: true))
          == "- 境界：化神 · 后期，累计修为 2,318，距「炼虚」还差 682；近 7 日 +296（日均 42）"
          && SnapshotDigest.realmLine(.init(title: "渡劫 · 大圆满", totalXP: 17000, nextRealm: nil, toNext: nil, last7: 0, enabled: true)).contains("已至最高境界"),
          "速览：境界行的千分位与日均；最高境界写“已至最高境界”")
    // 满数据时也不超过 30 行、2,000 字
    let reviews = (0..<5).map { SnapshotDigest.ReviewFact(day: day(-7 * $0), period: "week", title: "第 \(42 - $0) 周复盘", body: standard) }
    let fullHabits = [fact("晨读", daily, [monday]), fact("背单词", daily, [day(-7)]), fact("喝水", daily, streakDays),
                      fact("运动", weeklyThree, [monday]), fact("整理房间", weeklyOnce, onceWeeks)]
    let full = SnapshotDigest.lines(.init(today: today, realm: .init(title: "化神 · 后期", totalXP: 2318, nextRealm: "炼虚", toNext: 682, last7: 296, enabled: true),
                                          habits: fullHabits, goals: goals + many.indices.map { goal("又一个\($0)", progress: 1, deadline: nil) },
                                          reviews: reviews, lastReviewDay: today, entries: entries, lastEntryDay: today, finance: finance, financeToDate: toDate))
    check(full.count <= 30 && full.joined(separator: "\n").count <= 2_000 && full.contains("- 最近复盘：")
          && full.contains("  - 10月21日 周复盘「第 42 周复盘」— 所悟：先写后改，比反复想更快；下一步：每天上午先写 90 分钟")
          && full.filter { $0.hasPrefix("  - ") && $0.contains("周复盘") }.count == 3,
          "速览：数据齐全时 \(full.count) 行、\(full.joined(separator: "\n").count) 字（上限 30 行、2,000 字），复盘只列最近 3 篇")
    check(SnapshotDigest.lines(.init(today: today, realm: emptyInput(enabled: true).realm, habits: [], goals: [], reviews: [], lastReviewDay: LocalDay(key: "2026-07-02"),
                                     entries: [], lastEntryDay: nil, finance: nil, financeToDate: nil)).contains("- 最近复盘：近 60 天没有（上一篇 7月2日）")
          && SnapshotDigest.reviewLine(.init(day: today, period: "", title: "", body: "【所悟】早睡"), today: today) == "  - 10月21日 复盘 — 所悟：早睡",
          "速览：近 60 天没有复盘时写上一篇；没填周期写“复盘”、没有标题省掉「」")

    // 23. 修行录收缩
    var limits = SnapshotTrim.Limits()
    func item(_ date: LocalDay, kind: JournalKind = .diary, body: Int, title: String = "") -> PlannerSummary.JournalItem {
        .init(date: date.key, weekday: date.weekdayName, time: nil, kind: kind.label, title: title, body: String(repeating: "字", count: body),
              mood: nil, period: nil, tags: [], source: nil)
    }
    let aged = SnapshotTrim.journal([item(day(-3), body: 2_000), item(day(-15), body: 500), item(day(-20), kind: .review, body: 1_000)],
                                    today: today, limits: limits, budget: 100_000)
    check(aged.omitted == 0 && aged.items.map(\.body.count) == [1_502, 202, 802] && aged.items[1].body.hasSuffix("……"),
          "修行录：近 14 天每篇 ≤ 1,500 字，15 天前的日记 ≤ 200 字、复盘 ≤ 800 字（加“……”）")
    let ten = (0..<10).map { item(day(-$0), body: 1_000) }
    let budgeted = SnapshotTrim.journal(ten, today: today, limits: limits, budget: 4_500)
    let zero = SnapshotTrim.journal(ten, today: today, limits: limits, budget: 0)
    check(budgeted.items.count == 4 && budgeted.omitted == 6 && zero.items.count == 3 && zero.omitted == 7 && zero.items[0].date == today.key,
          "修行录：预算用完后省略最早的并计数；预算为 0 时仍留最新 3 篇")

    // 24. 全文硬上限
    let profile = ["nickname": "青岚", "main_tasks": "写完论文第三章\n周三助教辅导课\n周末补习数学", "career_goals": String(repeating: "研究型岗位。", count: 2_000)]
    var summary = PlannerSummary(generatedAt: "2026-10-21 21:42", periodDays: 60, today: today.key, profile: profile, goals: [], recurringEvents: [], upcoming: [],
                                 scheduleHoursByCategory: [], routine: [], routineHoursByKind: [], habits: [], cultivation: nil,
                                 journal: (0..<80).map { item(day(-($0 / 6)), body: 1_500, title: "第 \($0) 篇") }, journalDays: 60, focusQuestion: "",
                                 journalNewestFirst: true, overview: ["- 最近的飞剑传书（新→旧）：", "  - 2026-10-21 09:12 来自 Claude，1 条"])
    check(summary.journal.reduce(0) { $0 + $1.body.count } >= 120_000, "（构造 12 万字的修行录）")
    let composed = SnapshotTrim.compose(summary, preamble: "> 快照前言", digest: blank, today: today, limits: limits)
    let digestAt = composed.range(of: "## 近况速览")?.lowerBound, overviewAt = composed.range(of: "## 传书近况")?.lowerBound
    check(composed.count <= 40_000 && digestAt != nil && overviewAt != nil && digestAt! < overviewAt!
          && composed.contains("另有更早的") && !composed.contains("## 概览") && composed.contains("- 主要任务：\n  写完论文第三章\n  周三助教辅导课\n  周末补习数学"),
          "快照：12 万字的修行录压到 4 万字以内（\(composed.count) 字），速览在传书近况之前，注明省略条数")
    // 档案很长（压不了）时，硬上限继续压修行录；预算放得再大也一样
    var heavy = summary
    heavy.profile["life_goals"] = String(repeating: "长", count: 20_000)
    let heavyText = SnapshotTrim.compose(heavy, preamble: "> 快照前言", digest: blank, today: today, limits: limits)
    limits.journalBudget = 100_000
    let squeezed = SnapshotTrim.compose(summary, preamble: "> 快照前言", digest: blank, today: today, limits: limits)
    func journalCount(_ text: String) -> Int { text.components(separatedBy: "\n### 2026-").count - 1 }
    check(heavyText.count <= 40_000 && journalCount(heavyText) < journalCount(composed) && journalCount(heavyText) >= 3 && squeezed.count <= 40_000,
          "快照：档案多出 2 万字时，修行录从 \(journalCount(composed)) 篇再压到 \(journalCount(heavyText)) 篇（全文 \(heavyText.count) 字）；预算放大到 10 万时硬上限压到 \(squeezed.count) 字")

    // 25. 渲染参数不影响问道灵枢
    summary.journal = []
    let plainMarkdown = SummaryRenderer.markdown(summary, preamble: "")
    check(plainMarkdown == SummaryRenderer.markdown(summary, preamble: "", digest: [], overviewTitle: "概览", multilineProfile: false)
          && plainMarkdown.contains("## 概览") && !plainMarkdown.contains("近况速览")
          && plainMarkdown.contains("- 主要任务：写完论文第三章；周三助教辅导课；周末补习数学") && plainMarkdown.contains("- 昵称：青岚"),
          "SummaryRenderer：不传新参数时照旧（“概览”、多行档案用“；”连成一行）")
    let snapshotMarkdown = SummaryRenderer.markdown(summary, preamble: "", digest: ["- 境界：…"], overviewTitle: "传书近况", multilineProfile: true)
    check(snapshotMarkdown.contains("## 近况速览\n- 境界：…\n\n## 传书近况") && snapshotMarkdown.contains("- 昵称：青岚\n")
          && snapshotMarkdown.contains("- 主要任务：\n  写完论文第三章\n  周三助教辅导课\n  周末补习数学\n"),
          "SummaryRenderer：multilineProfile 时多行字段逐行缩进，单行字段不变")
    let json = SummaryRenderer.json(summary)
    check(!json.contains("digest") && !json.contains("overviewTitle") && !json.contains("multilineProfile") && json.contains("\"overview\""),
          "SummaryRenderer.json 不含 digest 之类的新键")
    // 快照“目标”一节：进行中、暂停按期限排；已完成只列 90 天内的，已放弃的不列
    let snapshotGoals = SnapshotTrim.goals(goals, today: today, limits: SnapshotTrim.Limits()).map(\.title)
    check(snapshotGoals == ["逾期的", "每周运动三次", "完成学位论文初稿", "同期限应该", "没有期限的", "学会弹《卡农》", "存下应急金"],
          "快照目标：进行中按期限、暂停在后，已完成只列 90 天内的，不列已放弃：\(snapshotGoals)")
}

// MARK: 天色随时辰（四时权重、问候与时辰、调色表：浅色夜不黑、深色昼不亮、昼等于不变）

do {
    func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
    func nearRGB(_ a: SkyRGBA, _ b: SkyRGBA, _ eps: Double = 1e-9) -> Bool { near(a.r, b.r, eps) && near(a.g, b.g, eps) && near(a.b, b.b, eps) }
    let mixes = (0..<1440).map { SkyClock.mix(minute: Double($0)) }
    // 每分钟四项权重在 [0,1]、和为 1、最多两项不为 0
    let wellFormed = mixes.allSatisfy { mix in
        let parts = SkyPhase.allCases.map { mix[$0] }
        return parts.allSatisfy { (0...1).contains($0) } && near(parts.reduce(0, +), 1) && parts.filter { $0 > 0 }.count <= 2
    }
    check(wellFormed, "天色：每分钟四时权重都在 [0,1]、和为 1、最多两项不为 0")
    // 连续：相邻两分钟（含 23:59 → 00:00）每项变化 ≤ 0.03，也都 < 0.05（平时一小步直接换，不做渐变）
    let steps = (0..<1440).map { mixes[$0].maxDelta(to: mixes[($0 + 1) % 1440]) }
    check(steps.allSatisfy { $0 <= 0.03 }, "天色：每一分钟到下一分钟（含跨午夜）每项变化 ≤ 0.03（最大 \(String(format: "%.4f", steps.max() ?? 0))）")
    check(steps.allSatisfy { $0 < 0.05 } && SkyClock.mix(minute: 240).maxDelta(to: SkyClock.mix(minute: 375)) >= 0.05,
          "天色：相邻两分钟的变化都 < 0.05（直接换）；04:00 → 06:15（合盖一夜）≥ 0.05（渐变过去）")
    // 关键时刻
    func at(_ h: Int, _ m: Int) -> SkyMix { SkyClock.mix(minute: Double(h * 60 + m)) }
    check(at(3, 0).night == 1 && at(6, 15).dawn == 1 && at(12, 0).day == 1 && at(18, 0).dusk == 1 && at(22, 0).night == 1
          && at(8, 31).day == 1 && at(12, 0) == .noon,
          "天色：03:00 夜、06:15 晨、12:00 昼、18:00 暮、22:00 夜、08:31 昼都是纯粹的一种")
    check(near(at(5, 0).dawn, 0.5, 0.01) && near(at(5, 0).night, 0.5, 0.01) && at(7, 30).dawn > 0.5 && at(7, 30).day > 0,
          "天色：05:00 晨夜各约一半；07:30 晨仍过半、昼已升起")
    check(SkyClock.mix(minute: 1440 + 720) == .noon && SkyClock.mix(minute: -60) == SkyClock.mix(minute: 1380),
          "天色：分钟超出一天按天取模")
    // 墙钟分钟数：夏令时开始那天（悉尼 10-04 当地 03:30）、换时区、跨年
    let sydney = TimeZone(identifier: "Australia/Sydney")!
    let dstMorning = LocalDay(key: "2026-10-04")!.date(minutes: 210, timeZone: sydney)
    check(near(SkyClock.minute(of: dstMorning, timeZone: sydney), 210) && !near(SkyClock.minute(of: dstMorning, timeZone: TimeZone(identifier: "UTC")!), 210),
          "天色：按墙钟取分钟（悉尼夏令时开始那天 03:30 → 210；同一时刻换成 UTC 是另一个值）")
    let lastMinute = LocalDay(key: "2026-12-31")!.date(minutes: 1439, timeZone: sydney)
    let newYear = LocalDay(key: "2027-01-01")!.date(minutes: 0, timeZone: sydney)
    check(near(SkyClock.minute(of: lastMinute, timeZone: sydney), 1439) && near(SkyClock.minute(of: newYear, timeZone: sydney), 0)
          && SkyClock.mix(at: lastMinute, timeZone: sydney).maxDelta(to: SkyClock.mix(at: newYear, timeZone: sydney)) <= 0.03,
          "天色：12-31 23:59 → 1439、次年 01-01 00:00 → 0，跨年连续")
    // 问候、时辰、整句
    let greetings = [(359, "夜深了"), (360, "早安"), (719, "早安"), (720, "午安"), (1079, "午安"), (1080, "晚上好"), (1439, "晚上好"), (0, "夜深了")]
    check(greetings.allSatisfy { SkyClock.greeting(minute: $0.0) == $0.1 }, "首页问候：分界与原来相同（6 / 12 / 18 点）")
    let hours = [(1380, "子时"), (59, "子时"), (60, "丑时"), (300, "卯时"), (660, "午时"), (1020, "酉时"), (1260, "亥时"), (1379, "亥时")]
    check(hours.allSatisfy { SkyClock.shichen(minute: $0.0) == $0.1 },
          "时辰：23:00 与 00:59 子时、01:00 丑时、05:00 卯时、11:00 午时、17:00 酉时、21:00 与 22:59 亥时")
    let line = SkyClock.greetingLine(name: "青岚", today: LocalDay(key: "2026-10-20")!, minute: 1110)
    check(line == "晚上好，青岚 · 10月20日 周二 · 酉时", "首页问候整句：\(line)")
    // 昼等于不变
    for dark in [false, true] {
        let noon = SkyLook.look(.noon, dark: dark)
        let clearColors = [noon.veil, noon.horizonTop, noon.horizonMid, noon.xiaLow, noon.xiaHigh, noon.glow, noon.heroGlow,
                           noon.xiaCloudLeft, noon.xiaCloudRight].allSatisfy { $0.a == 0 }
        let zeros = [noon.stars, noon.galaxy, noon.fog, noon.xiaClouds, noon.heroFog].allSatisfy { $0 == 0 }
        let vignette = dark ? SkyRGBA(r: 0, g: 0, b: 0, a: 0.5) : SkyRGBA(r: 0.84, g: 0.86, b: 0.79, a: 0.35)
        check(clearColors && zeros && noon.ridgeInk.a == 0 && noon.sunTint.a == 0 && noon.heroMultiply == .white
              && noon.vignette == vignette && !noon.meteors,
              "天色（\(dark ? "深" : "浅")色）：昼什么都不加，暗角是原来的值，画作不调色")
    }
    // 浅色夜不黑、小字看得清；深色昼不亮（逐分钟，含过渡）
    let inkSoft = SkyRGBA(hex: 0x627367, a: 1)
    let lightPaper = mixes.map { SkyPaper.luminance(SkyPaper.effectivePaper(SkyLook.look($0, dark: false), dark: false, atTop: false)) }
    let lightTop = mixes.map { SkyPaper.luminance(SkyPaper.effectivePaper(SkyLook.look($0, dark: false), dark: false, atTop: true)) }
    let nightPaper = SkyPaper.effectivePaper(SkyLook.preset(.night, dark: false), dark: false, atTop: false)
    check((lightPaper.min() ?? 0) >= 0.78 && (lightTop.min() ?? 0) >= 0.60,
          "天色（浅色）：任何时辰纸面亮度 ≥ 0.78（最低 \(String(format: "%.3f", lightPaper.min() ?? 0))）、顶端 ≥ 0.60（最低 \(String(format: "%.3f", lightTop.min() ?? 0))），不是黑底")
    check(SkyPaper.contrast(nightPaper, inkSoft) >= 4.0,
          "天色（浅色夜）：纸面上的次要小字（inkSoft）对比 \(String(format: "%.2f", SkyPaper.contrast(nightPaper, inkSoft))):1 ≥ 4:1")
    let xiaLight = mixes.flatMap { SkyPaper.xiaPapers(SkyLook.look($0, dark: false), dark: false).map(SkyPaper.luminance) }
    let xiaDark = mixes.flatMap { SkyPaper.xiaPapers(SkyLook.look($0, dark: true), dark: true).map(SkyPaper.luminance) }
    check((xiaLight.min() ?? 0) >= 0.78 && (xiaDark.max() ?? 1) <= 0.03,
          "天色：页面下部霞光带最浓处，浅色纸面亮度仍 ≥ 0.78（最低 \(String(format: "%.3f", xiaLight.min() ?? 0))）、深色仍 ≤ 0.03（最高 \(String(format: "%.4f", xiaDark.max() ?? 1))）")
    let darkPaper = mixes.flatMap { mix in
        [false, true].map { SkyPaper.luminance(SkyPaper.effectivePaper(SkyLook.look(mix, dark: true), dark: true, atTop: $0)) }
    }
    check((darkPaper.max() ?? 1) <= 0.03, "天色（深色）：任何时辰纸面（含顶端）亮度 ≤ 0.03（最高 \(String(format: "%.4f", darkPaper.max() ?? 1))），昼一点都不变亮")
    // 混合：纯时刻等于预设；α 与系数都在 [0,1]；乘色不透明；夜过半才有流星；预乘不发黑
    var pureMatches = true
    for dark in [false, true] {
        for phase in SkyPhase.allCases where SkyLook.look(SkyMix(pure: phase), dark: dark) != SkyLook.preset(phase, dark: dark) { pureMatches = false }
    }
    check(pureMatches, "天色：纯粹的晨 / 昼 / 暮 / 夜给出的就是预设")
    var inRange = true, meteorsRight = true, opaqueMultiply = true
    for dark in [false, true] {
        for mix in mixes {
            let look = SkyLook.look(mix, dark: dark)
            let colors = [look.veil, look.horizonTop, look.horizonMid, look.xiaLow, look.xiaHigh, look.glow, look.xiaCloudLeft, look.xiaCloudRight,
                          look.ridgeInk, look.sunTint, look.vignette, look.heroMultiply, look.heroGlow]
            let channels = colors.flatMap { [$0.r, $0.g, $0.b, $0.a] } + [look.xiaClouds, look.stars, look.galaxy, look.fog, look.heroFog, look.glowX, look.glowY]
            if !channels.allSatisfy({ $0.isFinite && (-1e-12...(1 + 1e-12)).contains($0) }) { inRange = false }
            if look.meteors != (mix.night >= 0.5) { meteorsRight = false }
            if look.heroMultiply.a != 1 { opaqueMultiply = false }
        }
    }
    check(inRange && opaqueMultiply && meteorsRight, "天色：逐分钟所有颜色分量、α、系数都在 [0,1]；画作乘色恒不透明；夜 ≥ 0.5 时才有浅色流星")
    let half = SkyRGBA(hex: 0xF7D6B8, a: 0.14).mixed(with: .clear, 0.5)
    check(nearRGB(half, SkyRGBA(hex: 0xF7D6B8, a: 1)) && near(half.a, 0.07), "天色：与“无”混合时颜色不变、只有透明度减半（预乘空间插值，不往黑里拽）")
    let five = SkyLook.look(SkyClock.mix(minute: 1020), dark: false), dusk = SkyLook.preset(.dusk, dark: false)
    check(nearRGB(five.veil, dusk.veil) && nearRGB(five.ridgeInk, dusk.ridgeInk) && five.veil.a > 0 && five.veil.a < dusk.veil.a,
          "天色：昼 → 暮过渡中点（17:00）的罩色与远山墨色就是暮色，只是更淡")
    // 星点
    let stars = SkyStarField.stars()
    let twinkling = stars.filter(\.twinkles).count, bright = stars.filter(\.isBright).count
    check(stars == SkyStarField.stars() && stars.count == 180
          && stars.allSatisfy { (0...1).contains($0.x) && (0...0.62).contains($0.y) && (0.4...1).contains($0.brightness) && (0...2).contains($0.tone)
              && (2.6...6.4).contains($0.period) && (1.2...5).contains($0.size) }
          && (25...50).contains(twinkling) && (3...10).contains(bright),
          "星点：固定种子每次相同；180 颗都在上方 62% 以内；\(twinkling) 颗会明灭、\(bright) 颗亮星")
}

// MARK: 岁月长卷页面排版（纯 Core：显示哪几节与节号、数字格分档、心境断线、PDF 装页、季度与年份切换）

do {
    let today = LocalDay(key: "2026-10-20")!
    var serial = 0
    func note(_ day: LocalDay, mood: Int? = nil, body: String = "长卷排版自检") -> RecordEntry {
        serial += 1
        return RecordEntry(uid: "layout\(serial)", day: day, kind: .diary, body: body, mood: mood)
    }
    func input(_ entries: [RecordEntry], ledger: FinanceLedger? = nil, config: CultivationConfig = CultivationConfig()) -> RecordInput {
        RecordInput(today: today, entries: entries, history: entries.map { ($0.day, $0.kind) }, habits: [], cultivation: config, ledger: ledger)
    }
    let year = AnnalsPeriod.make(.year(2026), today: today)!

    // 显示哪几节、节号按实际显示的节重排
    let empty = AnnalsEngine.report(year, input: input([]))
    check(empty.isEmpty && AnnalsLayout.parts(empty).isEmpty, "长卷排版：整段没有记录时一节都不出（只画卷首与卷尾）")
    let diaries = (0..<40).map { note(today.adding(days: -2 * $0 - 1), mood: 1 + $0 % 5) }
    let written = AnnalsEngine.report(year, input: input(diaries))
    let parts = AnnalsLayout.parts(written)
    check(parts.map(\.part) == [.writing, .mood, .cultivation, .insights] && parts.map(\.number) == ["其一", "其二", "其三", "其四"],
          "长卷排版：只有日记时出笔墨、心境、修为、洞见，节号其一…其四连续")
    var off = CultivationConfig()
    off.enabled = false
    check(AnnalsLayout.parts(AnnalsEngine.report(year, input: input(diaries, config: off))).map(\.part) == [.writing, .mood, .insights],
          "长卷排版：修为关闭时没有“修为”一节，后面的节号前移")
    var ledger = FinanceLedger()
    ledger.transactions = [ManualExpense.transaction(id: "layout-m1", day: today.adding(days: -3), cents: 1800, category: "餐饮与外卖",
                                                     description: "自检", note: "", reason: "自检")]
    let ledgerOnly = AnnalsEngine.report(year, input: input([], ledger: ledger))
    check(!ledgerOnly.isEmpty && ledgerOnly.cultivation != nil && !AnnalsLayout.showsCultivation(ledgerOnly)
          && AnnalsLayout.parts(ledgerOnly).map(\.part) == [.finance, .insights] && AnnalsLayout.parts(ledgerOnly).first?.number == "其一",
          "长卷排版：只有账目时不出“+0 修为”，灵石是其一")
    let ornaments = AnnalsLayout.Part.allCases.map(\.ornament)
    check(ornaments.count == 7 && Set(ornaments).count == 7 && ornaments.allSatisfy { $0.hasPrefix("yunshan-ornament-") && $0.hasSuffix("-v1") },
          "长卷排版：七节各有一件不同的小物插画")

    // 卷首数字格分档：宽时一行，窄时 3 + 2 / 2 + 2，不出现 4 + 1；三格以下按三列格宽靠左
    let wide = AnnalsLayout.tileRowWidth, narrow = 676.0
    check(AnnalsLayout.tileColumns(count: 5, innerWidth: wide) == 5 && AnnalsLayout.tileColumns(count: 4, innerWidth: wide) == 4
          && AnnalsLayout.tileColumns(count: 5, innerWidth: narrow) == 3 && AnnalsLayout.tileColumns(count: 4, innerWidth: narrow) == 2
          && (1...3).allSatisfy { AnnalsLayout.tileColumns(count: $0, innerWidth: narrow) == 3 && AnnalsLayout.tileColumns(count: $0, innerWidth: wide) == 3 },
          "长卷排版：数字格宽时 5 / 4 列一行，窄时 3 列、4 格时 2 列，三格以下按三列格宽")
    check(AnnalsLayout.rows(count: 5, columns: 3) == [[0, 1, 2], [3, 4]] && AnnalsLayout.rows(count: 4, columns: 2) == [[0, 1], [2, 3]]
          && AnnalsLayout.rows(count: 2, columns: 3) == [[0, 1]] && AnnalsLayout.rows(count: 0, columns: 3).isEmpty
          && !(1...5).contains { count in
              let columns = AnnalsLayout.tileColumns(count: count, innerWidth: narrow)
              let rows = AnnalsLayout.rows(count: count, columns: columns)
              return rows.count > 1 && rows.last!.count == 1 && columns > 2
          },
          "长卷排版：数字格按行切开，末行靠左，窄窗口不出现孤零零一格的 4 + 1")

    // 心境曲线断线：季度按日相隔 3 天以上断开；全年按周放宽到相隔 14 天以上
    let d0 = LocalDay(key: "2026-07-01")!
    check(AnnalsLayout.moodSegments([0, 1, 4, 8, 9].map { d0.adding(days: $0) }, weekly: false) == [0, 0, 0, 1, 1]
          && AnnalsLayout.moodSegments([0, 7, 14, 28, 42, 63].map { d0.adding(days: $0) }, weekly: true) == [0, 0, 0, 0, 0, 1]
          && AnnalsLayout.moodSegments([], weekly: true).isEmpty,
          "长卷排版：心境曲线季度相隔 3 天以上断线，全年（每周一点）相隔 14 天以上才断")

    // PDF 装页：按顺序贪心装，放不下换页；比一页还高的独占一页（等比缩小）；下标不重不漏
    let heights: [Double] = [400, 300, 200, 800, 100, 690, 1]
    let pages = AnnalsLayout.pack(heights: heights, available: 690, gap: 22)
    check(pages == [[0], [1, 2], [3], [4], [5], [6]] && pages.flatMap { $0 } == Array(heights.indices)
          && abs(AnnalsLayout.fitScale(height: 800, available: 690) - 690.0 / 800) < 1e-9 && AnnalsLayout.fitScale(height: 100, available: 690) == 1,
          "长卷排版：PDF 贪心装页（\(pages.map { $0.map(String.init).joined(separator: "+") }.joined(separator: " | "))），超高的块独占一页并等比缩小")
    var rng2 = SeededRandom(state: 20261020)
    var packOK = true
    for _ in 0..<200 {
        let hs = (0..<Int.random(in: 0...14, using: &rng2)).map { _ in Double(Int.random(in: 10...900, using: &rng2)) }
        let ps = AnnalsLayout.pack(heights: hs, available: 690, gap: 22)
        func used(_ page: [Int]) -> Double {
            let total: Double = page.reduce(0.0) { $0 + hs[$1] }
            return total + Double(max(0, page.count - 1)) * 22
        }
        let fits = ps.allSatisfy { page in page.count == 1 || used(page) <= 690 }
        // 贪心：下一页的第一块放不进上一页
        let greedy = zip(ps, ps.dropFirst()).allSatisfy { pair in used(pair.0) + 22 + hs[pair.1[0]] > 690 }
        if ps.flatMap({ $0 }) != Array(hs.indices) || !fits || !greedy || ps.contains(where: \.isEmpty) { packOK = false }
    }
    check(packOK, "长卷排版：随机 200 组块高装页，下标按顺序不重不漏、每页不超高（单块超高除外）、换页都是因为确实放不下")

    // 工具条：当年只列已开始的季度；切年份保持“全年 / 第几季”，那一季还没开始就回到全年；导出文件名
    let may = LocalDay(key: "2026-05-01")!
    check(AnnalsLayout.quarters(year: 2026, today: today) == [1, 2, 3, 4] && AnnalsLayout.quarters(year: 2026, today: may) == [1, 2]
          && AnnalsLayout.quarters(year: 2025, today: may) == [1, 2, 3, 4] && AnnalsLayout.quarters(year: 2027, today: may).isEmpty,
          "长卷排版：季度签当年只列已开始的季度")
    check(AnnalsLayout.move(.quarter(2025, 4), toYear: 2026, today: may) == .year(2026)
          && AnnalsLayout.move(.quarter(2025, 2), toYear: 2026, today: may) == .quarter(2026, 2)
          && AnnalsLayout.move(.year(2026), toYear: 2024, today: may) == .year(2024),
          "长卷排版：切年份保持全年 / 第几季，那一季在新年份还没开始就回到全年")
    check(AnnalsLayout.fileName(year) == "岁月长卷-2026" && AnnalsLayout.fileName(AnnalsPeriod.make(.quarter(2026, 4), today: today)!) == "岁月长卷-2026-第四季"
          && AnnalsLayout.tagLabel(String(repeating: "云", count: 12)) == String(repeating: "云", count: 12)
          && AnnalsLayout.tagLabel(String(repeating: "云", count: 13)) == String(repeating: "云", count: 12) + "…",
          "长卷排版：导出文件名“岁月长卷-2026 / -2026-第四季”，标签超过 12 字截断")
}

// MARK: 长期摘要：卷中洞见卡、问道灵枢“长期趋势与洞察”、快照共用（LongTermDigest，纯 Core）

do {
    let today = LocalDay(key: "2026-10-20")!
    check(LongTermDigest.fetchStart(today: today).key == "2025-11-01" && LongTermDigest.fetchStart(today: LocalDay(key: "2026-01-15")!).key == "2025-02-01"
          && LongTermDigest.insightWindow(today: today) == (LocalDay(key: "2026-07-22")!, LocalDay(key: "2026-10-19")!),
          "长期摘要：取数从本月往前 11 个月的 1 日起（跨年照算），洞见窗口为近 90 天、止于昨天")

    func blankSummary() -> PlannerSummary {
        PlannerSummary(generatedAt: "2026-10-20 08:00", periodDays: 30, today: today.key, profile: ["name": "测试修士"], goals: [], recurringEvents: [],
                       upcoming: [], scheduleHoursByCategory: [], routine: [], routineHoursByKind: [], habits: [], cultivation: nil, focusQuestion: "")
    }
    func input(entries: [RecordEntry], habits: [RecordHabit] = [], ledger: FinanceLedger? = nil) -> RecordInput {
        RecordInput(today: today, entries: entries, history: entries.map { ($0.day, $0.kind) }, habits: habits, cultivation: CultivationConfig(), ledger: ledger)
    }

    // 一条记录都没有：两段都空，摘要原样不动（JSON 不多出 longTerm、Markdown 不出两段标题）
    let none = LongTermDigest.make(input(entries: []), today: today)
    var untouched = blankSummary()
    none.attach(to: &untouched)
    check(none == .empty && none.isEmpty && none.cardInsights.isEmpty && untouched.longTerm == nil
          && SummaryRenderer.json(untouched) == SummaryRenderer.json(blankSummary())
          && SummaryRenderer.markdown(untouched, preamble: "") == SummaryRenderer.markdown(blankSummary(), preamble: ""),
          "长期摘要：一条记录都没有时为空，摘要的 Markdown 与 JSON 逐字不变")

    // 420 天的日记（近 120 天每天一篇、更早每 5 天一篇），晴雨相间；晴的日子功课打了、雨的日子没打
    let start = today.adding(days: -420)
    var entries: [RecordEntry] = []
    var done: [HabitLogValue] = []
    for offset in 1...420 where offset <= 120 || offset % 5 == 0 {
        let day = today.adding(days: -offset)
        entries.append(RecordEntry(uid: "lt\(offset)", day: day, kind: .diary, mood: offset % 2 == 0 ? 5 : 1))
        if offset % 2 == 0 { done.append(HabitLogValue(day: day, completed: true)) }
    }
    let habit = RecordHabit(title: "A", symbol: "leaf", spec: HabitSpec(frequency: .daily, startDay: start, createdDay: start), logs: done.sorted { $0.day < $1.day },
                            archived: false)
    let full = input(entries: entries.sorted { $0.day < $1.day }, habits: [habit])
    let digest = LongTermDigest.make(full, today: today)
    let window = LongTermDigest.insightWindow(today: today)
    check(digest.trends == TrendDigest.months(full, endingAt: today, count: 12) && digest.trends.count == 12
          && digest.trends.first?.month == "2025-11" && digest.trends.last?.month == "2026-10" && digest.trends.last?.ongoing == true
          && digest.insights == InsightEngine.insights(full, from: window.from, to: window.to) && !digest.manualOnly,
          "长期摘要：逐月趋势 = TrendDigest.months（2025-11 … 2026-10，本月未过完），洞见 = 近 90 天的 InsightEngine")
    let kinds = digest.insights.map(\.kind)
    check(kinds.contains(.moodHabits) && kinds.contains(.writingStreak) && kinds == Insight.Kind.allCases.filter(kinds.contains)
          && digest.cardInsights == Array(digest.insights.prefix(LongTermDigest.cardLimit)),
          "长期摘要：洞见 \(kinds.count) 条（含心境与功课、连续落笔），顺序固定，卡片取前 \(LongTermDigest.cardLimit) 条")

    var attached = blankSummary()
    digest.attach(to: &attached)
    let markdown = SummaryRenderer.markdown(attached, preamble: "")
    check(attached.trends == digest.trends && attached.insights == digest.insights.map(\.line) && attached.insightWindowDays == 90
          && attached.insights.allSatisfy { $0.contains("（依据 ") && !$0.contains("测试修士") }
          && markdown.contains("## 近 12 个月逐月趋势") && markdown.contains("## 统计洞察（近 90 天")
          && markdown.contains("| 2026-10（至 20 日） |") && SummaryRenderer.json(attached).contains("\"insightWindowDays\" : 90"),
          "长期摘要：填进摘要后 Markdown 有逐月表与统计洞察（每条“正文（依据）”、不含档案称呼），JSON 带 longTerm")

    // 只有手记的账簿：表头说明改写，不逐月标“未导全”
    var ledger = FinanceLedger()
    ledger.transactions = [ManualExpense.transaction(id: "lt-manual", day: today.adding(days: -3), cents: 1_850, category: "餐饮与外卖",
                                                     description: "长期摘要自检", note: "", reason: "自检")]
    let manual = LongTermDigest.make(input(entries: entries, ledger: ledger), today: today)
    var manualSummary = blankSummary()
    manual.attach(to: &manualSummary)
    let manualMarkdown = SummaryRenderer.markdown(manualSummary, preamble: "")
    check(manual.manualOnly && manualSummary.trendsManualOnly && manualMarkdown.contains("账目只含手记") && !manualMarkdown.contains("（未导全）"),
          "长期摘要：账簿只有手记时表头注明“只含手记”，各月不标“未导全”")

    // 卷中洞见卡：看过的几条不再闪；新出现、文字变了的才闪
    let shown = digest.cardInsights
    let token = LongTermDigest.seenToken(shown)
    var reworded = shown
    reworded[0].text += "（变）"
    check(LongTermDigest.freshKinds(seen: token, shown: shown).isEmpty
          && LongTermDigest.freshKinds(seen: "", shown: shown) == Set(shown.map(\.kind))
          && LongTermDigest.freshKinds(seen: token, shown: reworded) == [reworded[0].kind]
          && LongTermDigest.freshKinds(seen: LongTermDigest.seenToken(Array(shown.dropLast())), shown: shown) == [shown[shown.count - 1].kind],
          "卷中洞见：看过的几条不再闪，新出现或文字变了的那条才闪")
}

// MARK: 仪式的时间轴与规则（落笔入卷、功课圆满、朱印）
do {
    let steps = (-10...200).map { Double($0) / 100 }   // t ∈ [−0.1, 2]，逐 10 ms
    let start = RitualTimeline.inscription(at: 0)
    check(start.backingAlpha == 1 && start.slipAlpha == 1
          && [start.bloomAlpha, start.rodAlpha, start.flight, start.flightAlpha, start.trailAlpha, start.pulseAlpha, start.arrivalGlow].allSatisfy { $0 == 0 },
          "落笔：0 ms 时衬纸、纸笺铺满，墨晕、卷轴、飞行、涟漪都还没有")
    check(steps.filter { $0 < 1.35 }.allSatisfy { RitualTimeline.inscription(at: $0).backingAlpha == 1 },
          "落笔：衬纸在 1350 ms 前一直不透明（主线程忙时纸笺卷走也只露出白纸）")
    check([1.5, 1.6, 1.8, 2.0].allSatisfy { RitualTimeline.inscription(at: $0).alphas.allSatisfy { $0 == 0 } },
          "落笔：1.5 秒后所有新加的图层都已透明")
    let inscriptions = steps.map(RitualTimeline.inscription(at:))
    let rollMonotone = zip(inscriptions, inscriptions.dropFirst()).allSatisfy { $0.roll <= $1.roll && $0.flight <= $1.flight }
    check(rollMonotone && steps.allSatisfy { t in
        let p = RitualTimeline.inscription(at: t)
        return (t >= 0.35 || p.roll == 0) && (t < 0.9 || p.roll == 1) && (t >= 0.9 || p.flight == 0) && (t < 1.35 || p.flight == 1)
    }, "落笔：纸卷 350 ms 起卷、900 ms 卷完；小卷 900 ms 起飞、1350 ms 抵达，都只进不退")
    let peak = steps.max { RitualTimeline.inscription(at: $0).bloomAlpha < RitualTimeline.inscription(at: $1).bloomAlpha } ?? 0
    check(abs(peak - 0.32) <= 0.02, "落笔：墨晕在 \(Int((peak * 1000).rounded())) ms 最浓（约 320 ms）")

    let consummations = steps.map(RitualTimeline.consummation(at:))
    check([1.5, 1.7, 2.0].allSatisfy { RitualTimeline.consummation(at: $0).alphas.allSatisfy { $0 == 0 } }, "圆满：1.5 秒后所有图层都已透明")
    check(zip(consummations, consummations.dropFirst()).allSatisfy { $0.gather <= $1.gather } && steps.allSatisfy { t in
        let p = RitualTimeline.consummation(at: t)
        return (t < 0.65 || p.gather == 1) && (t >= 0.65 || p.unroll == 0) && (t < 1.0 || p.unroll == 1)
    }, "圆满：灵光 650 ms 汇齐；符箓 650 ms 起展开、1000 ms 展开完")
    let inRange: (Double) -> Bool = { $0.isFinite && $0 >= 0 && $0 <= 1 }
    check(inscriptions.allSatisfy { $0.values.allSatisfy(inRange) } && consummations.allSatisfy { $0.values.allSatisfy(inRange) },
          "仪式：t 在 [−0.1, 2] 秒（逐 10 ms），落笔与圆满的每个量都在 [0,1]、没有 NaN")

    let motes = (0..<48).map { RitualTimeline.mote($0, of: 48) }
    let again = (0..<48).map { RitualTimeline.mote($0, of: 48) }
    let sameMotes = zip(motes, again).allSatisfy { $0.edge == $1.edge && $0.along == $1.along && $0.swirl == $1.swirl && $0.delay == $1.delay }
    let perEdge = (0..<4).map { edge in motes.filter { $0.edge == edge }.count }
    check(sameMotes && perEdge == [12, 12, 12, 12]
          && motes.allSatisfy { (0...0.15).contains($0.delay) && (-0.61...0.61).contains($0.swirl) && (0...1).contains($0.along) && (0...2).contains($0.tone) },
          "灵光：结果固定；四条边各 12 颗；出发延迟 0–150 ms；旋向 ±35° 以内")
    check(motes.allSatisfy { RitualTimeline.moteTravel(delay: $0.delay, at: 0.65) == 1 && RitualTimeline.moteAlpha(delay: $0.delay, at: 0.66) == 0
                             && RitualTimeline.moteAlpha(delay: $0.delay, at: $0.delay - 0.01) == 0 },
          "灵光：出发前不亮，650 ms 时一齐到达丹田，到达即灭")

    let a = (x: 10.0, y: 20.0), b = (x: 410.0, y: -80.0)
    let s0 = RitualTimeline.curve(from: a, to: b, swirl: 0.5, s: 0), s1 = RitualTimeline.curve(from: a, to: b, swirl: 0.5, s: 1)
    let mid = RitualTimeline.curve(from: a, to: b, swirl: 0, s: 0.5), bent = RitualTimeline.curve(from: a, to: b, swirl: 0.5, s: 0.5)
    let offLine = abs((b.x - a.x) * (bent.y - a.y) - (b.y - a.y) * (bent.x - a.x)) / hypot(b.x - a.x, b.y - a.y)
    check(abs(s0.x - a.x) < 1e-9 && abs(s0.y - a.y) < 1e-9 && abs(s1.x - b.x) < 1e-9 && abs(s1.y - b.y) < 1e-9
          && abs(mid.x - 210) < 1e-9 && abs(mid.y + 30) < 1e-9 && offLine > 20,
          "弧线：起点、终点对得上；不旋时中点就在连线中点，旋 0.5 弧度时偏离连线 \(Int(offLine)) pt")
    let times = RitualTimeline.keyTimes()
    check(times.count == 31 && times.first == 0 && times.last == 1 && zip(times, times.dropFirst()).allSatisfy { $0 < $1 },
          "关键帧：31 个采样时刻，从 0 到 1 严格递增")

    let firstLanding = (0...300).map { Double($0) / 1000 }.first { RitualTimeline.spring($0) >= 1 } ?? 0
    let seal = RitualTimeline.seal(at: 0.6), settled = RitualTimeline.seal(at: 1.5), gone = RitualTimeline.seal(at: 2.6)
    check((0.13...0.16).contains(firstLanding) && abs(seal.alpha - 0.96) < 0.02 && abs(settled.alpha - 0.32) < 1e-9
          && gone.alpha == 0 && gone.rippleAlpha == 0 && RitualTimeline.seal(at: 0).landing == 0,
          "朱印：约 \(Int((firstLanding * 1000).rounded())) ms 第一次落到 1 倍；落定 0.96、印痕 0.32、2.6 秒散尽（与 SwiftUI 版同一时间轴）")

    let today = LocalDay(key: "2026-10-20")!, yesterday = today.adding(days: -1)
    check(RitualRules.shouldCelebratePerfectDay(day: today, today: today, wasPerfect: false, isPerfect: true, celebrated: nil)
          && RitualRules.shouldCelebratePerfectDay(day: today, today: today, wasPerfect: false, isPerfect: true, celebrated: yesterday)
          && !RitualRules.shouldCelebratePerfectDay(day: today, today: today, wasPerfect: false, isPerfect: true, celebrated: today)
          && !RitualRules.shouldCelebratePerfectDay(day: yesterday, today: today, wasPerfect: false, isPerfect: true, celebrated: nil)
          && !RitualRules.shouldCelebratePerfectDay(day: today, today: today, wasPerfect: true, isPerfect: true, celebrated: nil)
          && !RitualRules.shouldCelebratePerfectDay(day: today, today: today, wasPerfect: true, isPerfect: false, celebrated: nil),
          "功课圆满：今天由否变是且没播过才播；播过、补昨天、原本就圆满、变成不圆满都不播")
    let long = String(repeating: "修", count: 300), exact = String(repeating: "行", count: 240)
    check(RitualRules.inscriptionPreview("") == "" && RitualRules.inscriptionPreview("  \n 甲乙 \t\n") == "甲乙"
          && RitualRules.inscriptionPreview("甲\n \n\n乙") == "甲\n乙" && RitualRules.inscriptionPreview("甲\r\n\r\n乙") == "甲\n乙"
          && RitualRules.inscriptionPreview(long) == String(repeating: "修", count: 240) + "…" && RitualRules.inscriptionPreview(exact) == exact,
          "纸笺正文：去掉首尾空白、连续空行并成一行、超过 240 字截断加“…”，正好 240 字不加")
}

// MARK: 遗留打磨：撤销传书的说法、各月消费横轴
do {
    typealias W = CourierUndoWording
    check(W.items(records: 2) == "2 条记录" && W.items(records: 2, fields: 1) == "2 条记录和 1 个档案字段"
          && W.items(records: 2, fields: 1, goals: 1) == "2 条记录、1 个档案字段和 1 个目标" && W.items(goals: 3) == "3 个目标" && W.items() == nil,
          "撤销说法：记录、档案字段、目标按有的连起来")
    let cards: [(W.Plan, String)] = [
        (W.Plan(records: 3), "将删除 3 条记录。删除后无法找回。"),
        (W.Plan(fields: 1), "将恢复 1 个档案字段"),
        (W.Plan(goals: 1), "将恢复 1 个目标"),
        (W.Plan(records: 1, goals: 1), "将删除 1 条记录，恢复 1 个目标。删除后无法找回。"),
        (W.Plan(records: 2, editedRecords: 1, fields: 1, goals: 2, editedGoals: 1), "将删除 1 条记录，恢复 1 个档案字段和 1 个目标；保留你改过的 1 条记录和 1 个目标。删除后无法找回。"),
        (W.Plan(records: 2, editedRecords: 2), "不会删除或恢复任何内容，只把这封标记为已撤销；保留你改过的 2 条记录"),
        (W.Plan(goals: 1, superseded: 1, notes: ["甲", "乙"]), "将恢复 1 个目标；另有 1 个档案字段以之后的传书为准，不动；甲"),
        (W.Plan(notes: ["习惯「冥想」已有 12 条打卡，撤销时保留"]), "不会删除或恢复任何内容，只把这封标记为已撤销；习惯「冥想」已有 12 条打卡，撤销时保留"),
        (W.Plan(), "它写入的内容都已不在，只会把这封标记为已撤销"),
    ]
    let wrongCards = cards.filter { W.cardPreview($0.0) != $0.1 }.map { W.cardPreview($0.0) }
    check(wrongCards.isEmpty, "传书笺撤销说明：删除、恢复档案字段、恢复目标分开说，接第一条保留原因" + (wrongCards.isEmpty ? "" : "，不符：\(wrongCards)"))
    // 各种组合都不出现“删除 0 条”“恢复 0 个”这类说法
    var zeroes: [String] = []
    for r in 0...2 { for er in 0...r { for f in 0...1 { for ef in 0...f { for g in 0...1 { for eg in 0...g {
        let p = W.Plan(records: r, editedRecords: er, fields: f, editedFields: ef, goals: g, editedGoals: eg)
        let o = W.Outcome(deleted: r - er, restoredFields: f - ef, restoredGoals: g - eg, keptRecords: er, keptFields: ef, keptGoals: eg)
        let texts = [W.cardPreview(p), W.buttons(p).keep, W.buttons(p).all ?? "", W.resultDetail(o), W.resultSentence(o)] + W.panelLines(p) + W.resultLines(o)
        zeroes += texts.filter { $0.range(of: #"(^|[^0-9])0 (条|个|项)"#, options: .regularExpression) != nil }
    } } } } } }
    check(zeroes.isEmpty, "撤销说法：各种组合都不写“0 条 / 0 个”" + (zeroes.isEmpty ? "" : "，出现：\(zeroes.prefix(3))"))
    let mixed = W.Plan(records: 2, editedRecords: 1, fields: 2, editedFields: 1, superseded: 1, notes: ["n1", "n2", "n3", "n4"])
    check(W.panelLines(mixed) == ["将删除 1 条记录，恢复 1 个档案字段（换回这封传书之前的内容）。删除后无法找回。",
                                  "保留你改过的 1 条记录和 1 个档案字段；选“全部撤销”则记录一并删除，档案字段换回传书之前的内容（你后来改的会被覆盖）。",
                                  "另有 1 个档案字段之后又被别的传书改过，以后来的为准，这次不动。", "n1。", "n2。", "n3。"]
          && W.panelLines(W.Plan(goals: 1)) == ["将恢复 1 个目标（换回这封传书之前的内容）。"]
          && W.panelLines(W.Plan(records: 2, editedRecords: 2)) == ["这次撤销不会删除或恢复任何内容，只会把这封标记为已撤销。", "保留你改过的 2 条记录；选“全部撤销”则一并删除。"]
          && W.panelLines(W.Plan()) == ["它写入的内容都已不在，撤销只会把这封标记为已撤销。"],
          "左栏确认框：短句分行；“删除后无法找回”只在真有删除时出现；保留原因最多列 3 条")
    let buttons = W.buttons(mixed)
    check(buttons.keep == "撤销（保留改过的 1 条记录和 1 个档案字段）" && buttons.all == "全部撤销（含改过的 1 条记录和 1 个档案字段）"
          && W.panelLines(mixed)[1].hasPrefix("保留你改过的 1 条记录和 1 个档案字段") && W.buttons(W.Plan(records: 1)) == ("撤销传书", nil),
          "左栏确认框：按钮上的条数与正文同一个说法")
    let outcome = W.Outcome(deleted: 1, restoredFields: 2, keptRecords: 1, superseded: 1)
    check(W.resultDetail(outcome) == "删除 1 条 · 恢复 2 个档案字段 · 保留 1 条"
          && W.resultLines(outcome) == ["已删除这封传书写入的 1 条记录", "已恢复 2 个档案字段，回到传书之前的内容", "保留了你改过的 1 条记录", "另有 1 个档案字段以之后的传书为准，没有动"]
          && W.resultSentence(outcome) == "已撤销：删除 1 条记录，恢复 2 个档案字段；保留了你改过的 1 条记录；另有 1 个档案字段以之后的传书为准，没有动。",
          "撤销结果：删除与恢复分开写")
    let goalOutcome = W.Outcome(deleted: 1, restoredFields: 1, restoredGoals: 1, keptRecords: 1, keptGoals: 1, notes: ["习惯「冥想」已有 12 条打卡，撤销时保留"])
    check(W.resultDetail(goalOutcome) == "删除 1 条 · 恢复 2 项 · 保留 2 项" && W.resultLines(goalOutcome).last == "习惯「冥想」已有 12 条打卡，撤销时保留"
          && W.resultLines(goalOutcome).contains("已恢复 1 个档案字段和 1 个目标，回到传书之前的内容")
          && W.resultLines(goalOutcome).contains("保留了你改过的 1 条记录和 1 个目标")
          && W.resultSentence(W.Outcome(restoredGoals: 1)) == "已撤销：恢复 1 个目标。" && W.resultDetail(W.Outcome(restoredGoals: 1)) == "恢复 1 个目标"
          && W.resultLines(W.Outcome()) == ["它写入的内容都已不在，只把这封标记为已撤销"] && W.resultDetail(W.Outcome()) == "已标记为撤销",
          "撤销结果：恢复的目标不算删除，接第一条保留原因；什么都没动时只说已标记")

    // 各月消费横轴：按宽度抽稀，标签互不重叠，选中的月份始终标出
    let day = LocalDay(key: "2026-10-20")!
    func monthKeys(from start: String, count: Int) -> [String] {
        let parts = start.split(separator: "-").compactMap { Int($0) }
        return (0..<count).map { i in
            let m = parts[0] * 12 + parts[1] - 1 + i
            return String(format: "%04d-%02d", m / 12, m % 12 + 1)
        }
    }
    func overlapping(_ months: [String], _ labels: [String: String], selected: String, width: Double) -> Bool {
        let slot = width / Double(months.count)
        let boxes = months.indices.compactMap { i -> (Double, Double)? in
            labels[months[i]].map { ((Double(i) + 0.5) * slot, MonthAxis.textWidth($0, fontSize: 10.5) * (months[i] == selected ? 1.06 : 1)) }
        }
        return zip(boxes, boxes.dropFirst()).contains { $1.0 - $0.0 < ($0.1 + $1.1) / 2 + MonthAxis.gap - 1e-9 }
    }
    let five = monthKeys(from: "2021-10", count: 61)
    for width in [420.0, 620, 900, 1300] {
        let labels = MonthAxis.labels(months: five, selected: "2026-10", today: day, width: width)
        check(labels["2026-10"] == "10月" && !overlapping(five, labels, selected: "2026-10", width: width) && labels.count <= 32
              && (width < 600 || (2022...2026).allSatisfy { labels["\($0)-01"] == "\($0)年" }),
              "各月消费横轴：5 年 61 个月、宽 \(Int(width)) 点只标 \(labels.count) 个，互不重叠，选中的本月标出" + (width < 600 ? "" : "，每年 1 月写年份"))
    }
    let middle = MonthAxis.labels(months: five, selected: "2024-03", today: day, width: 620)
    check(middle["2024-03"] == "2024年3月" && !overlapping(five, middle, selected: "2024-03", width: 620),
          "各月消费横轴：选中往年的月份写全年份，挤着它的标签让开")
    let tiny = MonthAxis.labels(months: five, selected: "2023-07", today: day, width: 60)
    check(tiny["2023-07"] == "2023年7月", "各月消费横轴：再窄也标出选中的月份")
    let two = monthKeys(from: "2024-10", count: 25)
    let twoLabels = MonthAxis.labels(months: two, selected: "2026-10", today: day, width: 870)
    check(twoLabels["2024-10"] == "2024年10月" && twoLabels["2025-01"] == "2025年" && twoLabels["2026-01"] == "2026年"
          && twoLabels["2025-03"] == "3月" && twoLabels["2026-10"] == "10月" && !overlapping(two, twoLabels, selected: "2026-10", width: 870),
          "各月消费横轴：2 年时隔月一标，开头一根写全年份、年初写年份（共 \(twoLabels.count) 个）")
    let thisYear = monthKeys(from: "2026-01", count: 10)
    let yearLabels = MonthAxis.labels(months: thisYear, selected: "2026-10", today: day, width: 800)
    check(yearLabels.count == 10 && yearLabels["2026-01"] == "1月" && yearLabels["2026-10"] == "10月",
          "各月消费横轴：只有今年的几个月时每月都标，写“1月”…“10月”（与原来相同）")
    check(MonthAxis.labels(months: [], selected: "2026-10", today: day, width: 800).isEmpty
          && MonthAxis.labels(months: ["2026-10"], selected: "2026-09", today: day, width: 800) == ["2026-10": "10月"]
          && abs(MonthAxis.textWidth("2025年", fontSize: 10) - 34.8) < 1e-9,
          "各月消费横轴：没有月份时不标；选中的月份不在图里时照常标；字宽按汉字 1、数字 0.62 个字号估")
}

// MARK: 快捷键一览（Core/KeyMap：唯一底本、撞车与系统键、一览分组；再到界面源码里核对每一项都挂上了）
do {
    let conflicts = KeyMap.conflicts()
    check(conflicts.isEmpty, "快捷键：同一处同时生效的组合键没有重复" + (conflicts.isEmpty ? "" : "：" + conflicts.joined(separator: "；")))
    let reserved = KeyMap.reservedHits()
    check(reserved.isEmpty, "快捷键：不占系统常用键（\(KeyMap.reserved.count) 个约定俗成的组合键）" + (reserved.isEmpty ? "" : "：" + reserved.joined(separator: "；")))
    let guide = KeyMap.guideProblems()
    check(guide.isEmpty && KeyGuide.listed.count == KeyCommand.allCases.count && Set(KeyGuide.sections.flatMap(\.rows).map(\.id)).count == KeyGuide.sections.flatMap(\.rows).count,
          "快捷键一览：\(KeyCommand.allCases.count) 个快捷键各列一次（\(KeyGuide.sections.count) 组），行不重名" + (guide.isEmpty ? "" : "：" + guide.joined(separator: "；")))

    // 写法：修饰键按菜单次序 ⌃⌥⇧⌘，键名大写或写成符号、中文
    check(KeyCombo.command("c", .shift).display == "⇧⌘C" && KeyCombo(.return, .command).display == "⌘↩" && KeyCombo.command("j", .option).display == "⌥⌘J"
          && KeyCombo(.character("x"), [.control, .option, .shift, .command]).display == "⌃⌥⇧⌘X" && KeyCombo(.space).display == "空格"
          && KeyCombo(.escape).display == "Esc" && KeyCombo.command("[").display == "⌘[" && KeyCommand.pages.display == "⌘1 … ⌘0"
          && KeyCommand.searchMove.display == "↑ ↓" && KeyCommand.calendarMove.display == "← → ↑ ↓",
          "快捷键写法：⇧⌘C、⌘↩、⌥⌘J、⌃⌥⇧⌘X；空格、Esc；⌘1…⌘0 合写“⌘1 … ⌘0”，方向键一组合写")
    check(KeyCommand.pageCombo(forPosition: 1) == .command("1") && KeyCommand.pageCombo(forPosition: 9) == .command("9")
          && KeyCommand.pageCombo(forPosition: 10) == .command("0") && KeyCommand.pageCombo(forPosition: 11) == nil
          && KeyCommand.pageCombo(forPosition: 0) == nil && KeyCommand.pages.combos.count == KeyMap.pageIDs.count,
          "侧栏切页：第 1–9 项 ⌘1…⌘9、第 10 项 ⌘0、再往后没有（与 NavShortcut 一致）")
    check(KeyCombo(.up).isBare && KeyCombo(.space).isBare && KeyCombo(.return, .shift).isBare && !KeyCombo(.return, .command).isBare
          && !KeyCombo(.left, .option).isBare && KeyCommand.allCases.filter { $0.hookup == .pageKey }.allSatisfy { $0.combos.allSatisfy(\.isBare) },
          "页面按键都是不带 ⌘ ⌥ ⌃ 的键（方向键、空格、回车）：只在光标不在输入框里时接")

    // 同时生效的范围：主窗口每页（含菜单、全局热键、渡劫画面）+ 弹窗、搜索窗、月历、随手记
    let contexts = KeyMap.liveTogether()
    func live(_ page: String) -> [KeyCommand] { contexts.first { $0.context == KeyScope.page(page).label }?.commands ?? [] }
    check(contexts.count == KeyMap.pageIDs.count + 4 && live("chronicle").contains(.entryNext) && !live("schedule").contains(.entryNext)
          && live("data").contains(.keyGuide) && live("data").contains(.quickCapture) && live("annals").contains(.breakthroughClose)
          && !live("overview").contains(.dialogConfirm) && (contexts.first { $0.context == KeyScope.dialog.label }?.commands.contains(.settings) ?? false),
          "快捷键的生效范围：本页的键只在本页，菜单与全局热键处处有效，弹窗里只有弹窗的键")
    let commandN = KeyCommand.allCases.filter { $0.combos.contains(.command("n")) }
    let nPages = commandN.flatMap(\.scopes)
    let brackets = KeyCommand.allCases.filter { $0.combos.contains(.command("[")) }.flatMap(\.scopes)
    check(commandN.count == 6 && nPages.count == 7 && Set(nPages).count == 7 && brackets.count == 3 && Set(brackets).count == 3,
          "⌘N 在 7 页各是本页的“新建 / 落笔”，⌘[ ⌘] 在时辰卷、灵石账簿、岁月长卷各是往前 / 往后翻，互不重叠")
    check(KeyMap.reserved.contains { $0.combo == .command("q") } && KeyMap.reserved.contains { $0.combo == KeyCombo(.left, .command) }
          && !KeyMap.reserved.contains { $0.combo == .command("f") } && !KeyMap.reserved.contains { $0.combo == .command(",") },
          "系统常用键表：含 ⌘Q、⌘←（文本光标）；⌘F、⌘, 意思与系统相同（查找、设置），不算占用")

    // 界面源码：一览里的每一项都挂上了，界面里没有绕过底本直接写的快捷键
    // 源码目录：按本文件的位置找（Tools/CoreCheck/main.swift 往上两级）；swiftc 记下的是相对路径时，按当前目录（仓库根）找
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let appFolder = [repo.appendingPathComponent("APT"), URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("APT")]
        .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Core/KeyMap.swift").path) } ?? repo.appendingPathComponent("APT")
    let files = (FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "KeyMap.swift" }
    let sources = files.compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (name: url.lastPathComponent, text: $0) } }
    let unhooked = KeyCommand.allCases.filter { command in
        !KeyMap.hookupPatterns(command).contains { pattern in sources.contains { $0.text.contains(pattern) } }
    }
    check(sources.count > 50 && unhooked.isEmpty,
          "快捷键一览里的 \(KeyCommand.allCases.count) 项都在界面源码里挂着（\(sources.count) 个源文件里找 .keyCommand / .pageKeys / .keyNote）"
          + (unhooked.isEmpty ? "" : "：没挂上 " + unhooked.map(\.title).joined(separator: "、")))
    let raw = sources.filter { $0.name != "KeyCommands.swift" }.flatMap { file in
        file.text.split(separator: "\n").filter { line in
            line.contains(".keyboardShortcut(") && !line.contains(".keyboardShortcut(.defaultAction)") && !line.contains(".keyboardShortcut(.cancelAction)")
        }.map { "\(file.name)：\($0.trimmingCharacters(in: .whitespaces))" }
    }
    check(raw.isEmpty, "界面里的快捷键都从底本取：没有绕过 KeyCommand 直接写的 .keyboardShortcut（弹窗默认的回车 / Esc 除外）"
          + (raw.isEmpty ? "" : "：" + raw.joined(separator: "；")))
    let listeners = sources.filter { $0.text.contains(".onKeyPress(") || $0.text.contains("matching: .keyDown") }
    check(!listeners.isEmpty && listeners.allSatisfy { $0.text.contains("keyNote(") || $0.text.contains("KeyCombo(event:") },
          "自己接按键的地方（月历方向键、搜索窗 ↑↓、页面按键、一览小窗）都登记在底本里：\(listeners.map(\.name).sorted().joined(separator: "、"))")
}

// MARK: 空状态文案（Core/EmptyCopy.swift）：全应用一套写法

do {
    // 大号留白：标题“四字，静待两字”、说明一句话（句号结尾、≤ 32 字）、小物文件真的在 APT/Scenery 里
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scenery = [here.appendingPathComponent("APT/Scenery"), URL(fileURLWithPath: "APT/Scenery")]
        .first { FileManager.default.fileExists(atPath: $0.path) }
    for (name, copy) in EmptyCopy.all {
        let found = scenery.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(copy.ornament + ".webp").path) } ?? false
        check(copy.problems.isEmpty && found,
              "空状态 \(name)：「\(copy.title)」合写法、小物在 Scenery 里" + (copy.problems.isEmpty ? "" : "（\(copy.problems.joined(separator: "；"))）"))
    }
    let titles = EmptyCopy.all.map { $0.copy.title }, ornaments = EmptyCopy.all.map { $0.copy.ornament }
    check(Set(titles).count == titles.count && Set(ornaments).count == ornaments.count, "空状态：各页大号留白的标题、小物互不重复（\(titles.count) 页）")
    let badLines = EmptyCopy.Line.all.filter { !$0.line.problems.isEmpty }
    check(badLines.isEmpty, "空状态：\(EmptyCopy.Line.all.count) 条一行小字都是一句话、句号结尾、≤ \(EmptyCopy.maxLength) 字"
          + (badLines.isEmpty ? "" : "（\(badLines.flatMap { $0.line.problems }.joined(separator: "；"))）"))
    let texts = EmptyCopy.all.map { $0.copy.text } + EmptyCopy.Line.all.map { $0.line.text }
    let names = EmptyCopy.all.map { $0.name } + EmptyCopy.Line.all.map { $0.name }
    check(Set(texts).count == texts.count && Set(names).count == names.count, "空状态：说明与小字没有两处说同一句话，名字不重")
    // 核对规则本身：反例要拦得下
    check(EmptyCopy.isCoupletTitle("一池清莲，静待初课") && !EmptyCopy.isCoupletTitle("一池清莲静待初课")
          && !EmptyCopy.isCoupletTitle("一池清莲，等待初课") && !EmptyCopy.isCoupletTitle("一池清莲，静待初课。")
          && !EmptyCopy.isCoupletTitle("清莲，静待初课"),
          "空状态：标题核对拦下少逗号、不是“静待”、多句号、字数不对的")
    check(EmptyCopy.isOneSentence("还没有目标：拆一个吧。") && !EmptyCopy.isOneSentence("还没有目标。拆一个吧。")
          && !EmptyCopy.isOneSentence("还没有目标") && !EmptyCopy.isOneSentence(String(repeating: "字", count: 40) + "。")
          && !EmptyCopy.isOneSentence(" 前面有空格。") && !EmptyCopy.isOneSentence("真的没有？还是没有。"),
          "空状态：一句话核对拦下两句、没句号、超长、首尾空白、中间有问号的")
}

// MARK: fix-annals：长卷同一页的连续落笔一个数、本月按“至今”判断导全、卷首与心境的说法、指定星期的功课写“次”

do {
    let today = LocalDay(key: "2026-10-20")!
    func d(_ key: String) -> LocalDay { LocalDay(key: key)! }
    func input(_ days: [LocalDay], habits: [RecordHabit] = [], ledger: FinanceLedger? = nil, today now: LocalDay = today) -> RecordInput {
        let entries = days.enumerated().map { RecordEntry(uid: "fa\($0.offset)", day: $0.element, kind: .diary, mood: 4) }
        return RecordInput(today: now, entries: entries, history: entries.map { ($0.day, $0.kind) }, habits: habits,
                           cultivation: CultivationConfig(), ledger: ledger)
    }
    func streakInsight(_ r: AnnalsReport) -> Insight? { r.insights.first { $0.kind == .writingStreak } }
    let year = AnnalsPeriod.make(.year(2026), today: today)!

    // 1. 连续落笔：1–6 月每 3 天一篇，7月26日起天天写。今天写过时其一与其七、卷中洞见卡都是 87 天、到 10月20日
    let scattered = LocalDay.range(d("2026-01-01"), d("2026-06-30")).filter { d("2026-01-01").days(to: $0) % 3 == 0 }
    let written = input(scattered + LocalDay.range(d("2026-07-26"), today))
    let r1 = AnnalsEngine.report(year, input: written)
    let w1 = streakInsight(r1)
    check(r1.writing?.longestRun?.count == 87 && r1.writing?.longestRun?.last == today
          && w1?.text == "最长连续落笔 87 天（7月26日—10月20日），也是有记录以来最长的一次，至今仍在延续。"
          && w1?.basis == "依据 \(r1.writing?.writingDays ?? -1) 天的落笔",
          "长卷连续落笔：今天写过时，其一“最长连续 \(r1.writing?.longestRun?.count ?? 0) 天、动笔 \(r1.writing?.writingDays ?? 0) 天”与其七同一个数："
          + "\(w1?.text ?? "nil")（\(w1?.basis ?? "")）")
    let card = LongTermDigest.make(written, today: today).insights.first { $0.kind == .writingStreak }
    check(card?.text == w1?.text && card?.basis == "依据 87 天的落笔",
          "卷中洞见卡（近 90 日）用同一函数：今天写过也是 87 天、到 10月20日：\(card?.text ?? "nil")")
    // 今天还没写：两处都数到昨天（86 天），一段写到昨天仍说“至今仍在延续”
    let notYet = AnnalsEngine.report(year, input: input(scattered + LocalDay.range(d("2026-07-26"), d("2026-10-19"))))
    let w2 = streakInsight(notYet)
    check(notYet.writing?.longestRun?.count == 86
          && w2?.text == "最长连续落笔 86 天（7月26日—10月19日），也是有记录以来最长的一次，至今仍在延续。"
          && w2?.basis == "依据 \(notYet.writing?.writingDays ?? -1) 天的落笔",
          "长卷连续落笔：今天还没写时两处都数到昨天（86 天），仍在延续：\(w2?.text ?? "nil")")
    // 10月1日看刚过完的第三季：段尾是昨天，今天写的那篇不算进第三季
    let oct1 = d("2026-10-01")
    let q3 = AnnalsEngine.report(AnnalsPeriod.make(.quarter(2026, 3), today: oct1)!,
                                 input: input(LocalDay.range(d("2026-09-20"), oct1), today: oct1))
    check(q3.writing?.longestRun?.count == 11 && streakInsight(q3)?.text.hasPrefix("最长连续落笔 11 天（9月20日—9月30日）") == true
          && streakInsight(q3)?.basis == "依据 11 天的落笔",
          "长卷连续落笔：已过完的一季不把段外的今天算进去：\(streakInsight(q3)?.text ?? "nil")")
    // 很久以前的一段：结束在窗口末日也不说“至今仍在延续”
    let past = InsightEngine.insights(input(LocalDay.range(d("2026-03-01"), d("2026-03-20")) + [today]), from: d("2026-03-01"), to: d("2026-03-31"))
        .first { $0.kind == .writingStreak }
    check(past?.text == "最长连续落笔 20 天（3月1日—3月20日），也是有记录以来最长的一次。", "长卷连续落笔：过去的时段不说“至今仍在延续”：\(past?.text ?? "nil")")

    // 2. 本月按“至今”判断导全：导到最近几天（≤ 3 天前）算全，已过完又没导全的月份照旧标
    var ledger = FinanceLedger()
    for (i, day) in LocalDay.range(d("2025-01-01"), today).enumerated() where day.day % 5 == 1 {
        ledger.transactions.append(FinanceTransaction(id: "fa-t\(i)", date: day.key, amountCents: -(1000 + i), balanceCents: 0, description: "自检",
                                                      account: "CBA", category: "餐饮与外卖", kind: "消费", needsReview: false, reason: "", sourceLine: i))
    }
    func source(_ first: String, _ last: String, account: String = "CBA") -> FinanceSource {
        FinanceSource(sha256: "fa\(first)\(account)", account: account, rawCsv: "", importedAt: "", rows: 0, start: first, end: last,
                      statementPeriod: StatementPeriod(start: first, end: last))
    }
    func finance(_ sources: [FinanceSource], period: AnnalsScope = .year(2026), today now: LocalDay = today) -> AnnalsReport {
        var l = ledger
        l.sources = sources
        return AnnalsEngine.report(AnnalsPeriod.make(period, today: now)!, input: input([], ledger: l, today: now))
    }
    let yesterday = finance([source("2025-01-01", "2026-10-19")])
    let fy = yesterday.finance
    check(fy?.incompleteMonths == [] && fy?.months.last?.label == "10月（至今）" && fy?.months.last?.full == true && fy?.comparison?.months == 9
          && fy?.remark == "按 9 个已导全的整月比较。" && !AnnalsRenderer.markdown(yesterday).contains("（未导全）")
          && !AnnalsRenderer.markdown(yesterday).contains("（部分）"),
          "长卷灵石：本月导到昨天时 incompleteMonths 为空、本月柱子不变淡、导出不写“（未导全）”，仍按 9 个整月比较：\(fy?.remark ?? "nil")")
    check(finance([source("2025-01-01", "2026-10-17")]).finance?.incompleteMonths == []
          && finance([source("2025-01-01", "2026-10-16")]).finance?.incompleteMonths == ["10月"]
          && finance([source("2025-01-01", "2026-10-16")]).finance?.months.last?.full == false,
          "长卷灵石：本月导到 3 天前算全，落后 4 天就照旧算未导全")
    check(finance([source("2025-01-01", "2026-08-31"), source("2026-09-10", "2026-10-19")]).finance?.incompleteMonths == ["9月"]
          && finance([source("2025-01-01", "2026-10-19"), source("2026-01-01", "2026-10-05", account: "ING")]).finance?.incompleteMonths == ["10月"],
          "长卷灵石：已过完又没导全的 9 月照旧标；本月有一个账户只导到 10月5日也照旧算未导全")
    check(finance([source("2025-01-01", "2026-10-19")], period: .quarter(2026, 4)).finance?.incompleteMonths == []
          && finance([source("2025-01-01", "2026-10-31")], today: d("2026-11-02")).finance.map { $0.incompleteMonths == [] && $0.months.last?.full == true } == true
          && finance([]).finance.map { $0.manualOnly && $0.incompleteMonths.isEmpty && $0.months.last?.full == false } == true,
          "长卷灵石：本季同样不标；月初头几天（11月2日）本月还没有该覆盖的日子不算未导全；只含手记的照旧不标、full 为 false")

    // 3. 卷首灵石格只写“较去年同期 +N%”（按几个整月放进悬停），心境节不再写“周点 / 日点”
    let compare = fy.flatMap { AnnalsLayout.financeCompare($0, previousLabel: year.previousLabel) }
    check(compare.map { $0.text.hasPrefix("较去年同期 ") && !$0.text.contains("整月") && !$0.text.contains("（") } == true
          && compare?.help == "按 9 个已导全的整月比较（本月与没导全的月份不算）"
          && AnnalsLayout.moodCaption(entries: 264, weekly: true) == "按周平均 · 264 篇带心境"
          && AnnalsLayout.moodCaption(entries: 75, weekly: false) == "逐日 · 75 篇带心境",
          "长卷文案：灵石格“\(compare?.text ?? "nil")”（悬停：\(compare?.help ?? "")），心境“\(AnnalsLayout.moodCaption(entries: 264, weekly: true))”")

    // 4. 功课最长连续：每天的“天”、指定星期的“次”、每周 N 次的“周”；表格、导出一起
    let start = d("2026-09-01"), lastDone = d("2026-10-19")
    func habit(_ title: String, _ frequency: HabitFrequency, weekdays: [Int] = [], perWeek: Int = 1) -> RecordHabit {
        RecordHabit(title: title, symbol: "leaf",
                    spec: HabitSpec(frequency: frequency, targetPerWeek: perWeek, weekdays: weekdays, startDay: start, createdDay: start),
                    logs: LocalDay.range(start, lastDone).map { HabitLogValue(day: $0, completed: true) }, archived: false)
    }
    let mwf = LocalDay.range(start, lastDone).filter { [0, 2, 4].contains($0.weekdayIndex) }.count
    let habitReport = AnnalsEngine.report(year, input: input([], habits: [habit("晨读", .daily), habit("练琴", .weekdays, weekdays: [0, 2, 4]),
                                                                          habit("长跑", .weekly, perWeek: 2)]))
    let units = Dictionary(uniqueKeysWithValues: (habitReport.habits?.rows ?? []).map { ($0.title, "\($0.longest.count) \($0.longest.unit)") })
    let habitLines = AnnalsRenderer.markdown(habitReport).split(separator: "\n")
    func row(_ title: String) -> Substring? { habitLines.first { $0.hasPrefix("| \(title) |") } }
    // 长跑：8月31日那一周起到 10月12日那一周，7 个整周都打满；本周还没到 2 次不算断
    check(units["晨读"] == "49 天" && units["练琴"] == "\(mwf) 次" && units["长跑"] == "7 周"
          && row("晨读")?.hasSuffix("| 49 天 |") == true && row("练琴")?.hasSuffix("| \(mwf) 次 |") == true && row("长跑")?.hasSuffix("| 7 周 |") == true,
          "长卷功课：最长连续每天写“天”、指定星期写“次”、每周 N 次写“周”（\(units.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "、"))），导出同样")
}

// MARK: 隐去姓名：称呼里带括号、间隔号时，拆出来的每段名字单独出现也换（fix-courier）

do {
    typealias R = IdentityRedactor
    // 档案称呼的四种写法：括号（全角 / 半角）、间隔号（中文名 / 拉丁名）
    let cases: [(profile: String, names: [String], text: String, redacted: String)] = [
        ("张伟（Alex）", ["张伟（Alex）", "Alex", "张伟"],
         "张伟今天和 Alex 去图书馆；张伟（Alex）记", "〔姓名〕今天和 〔姓名〕 去图书馆；〔姓名〕记"),
        ("张伟 (Alex)", ["张伟 (Alex)", "Alex", "张伟"],
         "张伟说 Alex 明天到；张伟 (Alex) 记", "〔姓名〕说 〔姓名〕 明天到；〔姓名〕 记"),
        ("亚历克斯·张", ["亚历克斯·张", "亚历克斯"],
         "亚历克斯今天交了一张表；亚历克斯·张记", "〔姓名〕今天交了一张表；〔姓名〕记"),
        ("Alex·Zhang", ["Alex·Zhang", "Zhang", "Alex"],
         "Alex 和 Zhang 老师；Alex·Zhang；Alexson", "〔姓名〕 和 〔姓名〕 老师；〔姓名〕；Alexson"),
    ]
    for item in cases {
        let names = R.names(from: [item.profile])
        let out = R.redact(item.text, names: names)
        check(names == item.names && out == item.redacted,
              "隐去姓名：称呼写成“\(item.profile)”时，正文里单独出现的每段名字与整段原文都换成〔姓名〕（\(names)；\(out)）")
    }
    // 太短的片段不单独当名字：“亚历克斯·张”的“张”、“李（A）”的“李”和“A”都不换，正文里的“一张纸”“李同学”“A 等”原样
    let common = R.names(from: ["亚历克斯·张", "李（A）"])
    let commonText = "张老师给李同学评了 A 等，亚历克斯来了，递上一张纸"
    check(common == ["亚历克斯·张", "亚历克斯"] && R.redact(commonText, names: common) == "张老师给李同学评了 A 等，〔姓名〕来了，递上一张纸",
          "隐去姓名：拆出来的单个汉字、一个字母不单独换，常见词不误伤（\(common)）")
    check(R.names(from: ["（Alex）"]) == ["Alex"] && R.names(from: ["Alex."]) == ["Alex"] && R.names(from: ["【青岚子】、小A"]) == ["青岚子"],
          "隐去姓名：每段去掉首尾标点再判断（只剩一段时不另留整段原文）")
}

// MARK: 撤销目标更新按整个目标算：说法（fix-courier；实际撤销在 SelfTest+fix-courier 里测）

do {
    typealias W = CourierUndoWording
    // 传书改了进度和期限、用户只动过进度：预览只说保留 1 个目标，确认框多一句“整个保留”，结果与摘要都只说保留
    let partial = W.Plan(goals: 1, editedGoals: 1)
    check(W.cardPreview(partial) == "不会删除或恢复任何内容，只把这封标记为已撤销；保留你改过的 1 个目标"
          && W.panelLines(partial) == ["这次撤销不会删除或恢复任何内容，只会把这封标记为已撤销。",
                                       "保留你改过的 1 个目标；选“全部撤销”则目标换回传书之前的内容（你后来改的会被覆盖）。",
                                       W.goalKeptWhole]
          && W.buttons(partial) == ("撤销（保留改过的 1 个目标）", "全部撤销（含改过的 1 个目标）"),
          "改过的目标：传书笺、确认框、按钮都说保留 1 个目标，确认框说明整个目标都不动")
    check(!W.panelLines(W.Plan(goals: 1)).contains(W.goalKeptWhole) && !W.panelLines(W.Plan(records: 1, editedRecords: 1)).contains(W.goalKeptWhole)
          && !W.panelLines(W.Plan(fields: 1, editedFields: 1, goals: 1)).contains(W.goalKeptWhole),
          "“整个目标保留”那句只在有改过的目标时出现")
    let kept = W.Outcome(keptGoals: 1)
    check(W.resultDetail(kept) == "保留 1 项" && W.resultLines(kept) == ["保留了你改过的 1 个目标"]
          && W.resultSentence(kept) == "已撤销：保留了你改过的 1 个目标。" && W.summaryNote(kept) == "（撤销时保留了收录后改过的 1 个目标）",
          "改过的目标整个保留：结果、左栏提示、传书摘要都只说保留，不说恢复")
    check(W.summaryNote(W.Outcome(deleted: 2)) == nil && W.summaryNote(W.Outcome(keptRecords: 2)) == "（撤销时保留了 2 条收录后改过的记录）"
          && W.summaryNote(W.Outcome(restoredGoals: 1, keptRecords: 1, keptFields: 1)) == "（撤销时保留了收录后改过的 1 条记录和 1 个档案字段）",
          "传书摘要末尾的保留说明：没保留不写；只有记录按条数；有档案字段或目标时分开数")
}

// MARK: 快捷键一览的小字（r7-keys）

do {
    // 两个键合成一行时，各自的说明都留下（不再只剩第一句）
    let capture = KeyGuide.Row(commands: [.quickCaptureSubmit, .quickCaptureClose])
    // 随手记 ⌘↩ 的按钮名字间夹了 U+2060（只管折行），比较前去掉
    check(capture.note?.replacingOccurrences(of: "\u{2060}", with: "") == "按认出的类型写“落笔入卷 / 入账 / 打卡 / 记入时辰卷”；收起时写了一半的留在草稿里", "一览：合成一行的两个键各有说明时用“；”连起来（\(capture.note ?? "nil")）")
    check(KeyGuide.Row(commands: [.dialogConfirm, .dialogCancel]).note == KeyCommand.dialogConfirm.note
          && KeyGuide.Row(commands: [.weekPrev, .weekNext]).note == nil, "一览：只有一个说明或没有说明的行照旧")
    // 每一行的说明都不丢：合起来的小字里含有这一行每个命令自己的说明
    let dropped = KeyGuide.sections.flatMap(\.rows).filter { row in row.commands.contains { c in c.note.map { !(row.note ?? "").contains($0) } ?? false } }
    check(dropped.isEmpty, "一览：每一行都留下了各命令的说明（\(dropped.map(\.title))）")
    // 组标题与行标题不重复（“其二 · 落笔”下第一行不再也叫“落笔”）
    let repeated = KeyGuide.sections.flatMap { section in section.rows.filter { $0.title == section.title }.map { "\(section.title)：\($0.title)" } }
    check(repeated.isEmpty, "一览：行标题不与所在组名相同（\(repeated)）")
    // 空格打卡的说明与实际一致：数量型今天没记录时直接按目标记满，只有已记了未达标的数量才弹出数量输入
    let checkIn = KeyCommand.habitCheckIn.note ?? ""
    check(checkIn.contains("直接按目标记满") && checkIn.contains("未达标的数量时弹出数量输入"), "一览：空格打卡写明数量型按目标记满（\(checkIn)）")
}

// MARK: r7-annals：停导账簿月初不算导全、长卷连续落笔只数段内、指定星期的功课当前连续写“次”

do {
    func d(_ key: String) -> LocalDay { LocalDay(key: key)! }
    func input(_ days: [LocalDay], habits: [RecordHabit] = [], ledger: FinanceLedger? = nil, today now: LocalDay) -> RecordInput {
        let entries = days.enumerated().map { RecordEntry(uid: "r7a\($0.offset)", day: $0.element, kind: .diary, mood: 4) }
        return RecordInput(today: now, entries: entries, history: entries.map { ($0.day, $0.kind) }, habits: habits,
                           cultivation: CultivationConfig(), ledger: ledger)
    }

    // 1. 停导账簿 + 月初：最后一次导入只到 6月30日，10月1日—3日看，本月不能算“导全”
    func ledger(_ ranges: [(String, String)]) -> FinanceLedger {
        var l = FinanceLedger()
        for (i, day) in LocalDay.range(d("2026-05-01"), d("2026-06-30")).enumerated() where day.day % 7 == 1 {
            l.transactions.append(FinanceTransaction(id: "r7a-t\(i)", date: day.key, amountCents: -(1200 + i), balanceCents: 0, description: "自检",
                                                     account: "CBA", category: "餐饮与外卖", kind: "消费", needsReview: false, reason: "", sourceLine: i))
        }
        l.sources = ranges.map { FinanceSource(sha256: "r7a\($0.0)", account: "CBA", rawCsv: "", importedAt: "", rows: 0, start: $0.0, end: $0.1,
                                               statementPeriod: StatementPeriod(start: $0.0, end: $0.1)) }
        return l
    }
    let stopped = ledger([("2026-05-01", "2026-06-30")])
    var stoppedBad: [String] = []
    for key in ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"] {
        let now = d(key)
        let i = input([d("2026-05-02")], ledger: stopped, today: now)
        let f = AnnalsEngine.report(AnnalsPeriod.make(.year(2026), today: now)!, input: i).finance
        let trend = TrendDigest.months(i, endingAt: now).last
        if AnnalsEngine.coveredSoFar(stopped, today: now) || f?.months.last?.full != false || f?.incompleteMonths.last != "10月"
            || trend?.month != "2026-10" || trend?.spendComplete != false || trend?.netSpend != nil {
            stoppedBad.append("\(key)：full=\(f?.months.last?.full.description ?? "nil")、未导全=\(f?.incompleteMonths ?? [])、趋势=\(trend?.netSpend ?? "–")")
        }
    }
    check(stoppedBad.isEmpty, "停导账簿：只导到 6月30日，10月1日—4日看本月都算未导全（长卷挂“部分”、逐月趋势写“–”）：\(stoppedBad)")
    let current = ledger([("2026-05-01", "2026-09-30")])
    check(AnnalsEngine.coveredSoFar(current, today: d("2026-10-01")) && AnnalsEngine.coveredSoFar(current, today: d("2026-10-03"))
          && AnnalsEngine.coveredSoFar(ledger([("2026-05-01", "2026-09-28")]), today: d("2026-10-01"))
          && !AnnalsEngine.coveredSoFar(ledger([("2026-05-01", "2026-09-27")]), today: d("2026-10-01"))
          && !AnnalsEngine.coveredSoFar(FinanceLedger(), today: d("2026-10-02")),
          "月初头几天：导到 3 天前（上个月末前后）仍算本月导全，落后 4 天、从没导入过的照旧不算")

    // 2. 长卷连续落笔只数段内：9月20日起天天写，看第四季 / 今年；跨年时同样只数今年
    let oct20 = d("2026-10-20")
    let fromSept = input(Array(LocalDay.range(d("2026-09-20"), oct20)), today: oct20)
    let q4 = AnnalsEngine.report(AnnalsPeriod.make(.quarter(2026, 4), today: oct20)!, input: fromSept)
    let q4Streak = q4.insights.first { $0.kind == .writingStreak }
    check(q4.writing?.longestRun?.count == 20 && q4.writing?.longestRun?.first == d("2026-10-01")
          && q4Streak?.text == "最长连续落笔 20 天（10月1日—10月20日），至今仍在延续。" && q4Streak?.basis == "依据 20 天的落笔",
          "长卷连续落笔（跨季）：其一与其七都只数段内 20 天，不往 9月延伸：其一 \(q4.writing?.longestRun?.count ?? 0) 天，其七“\(q4Streak?.text ?? "nil")”")
    let jan10 = d("2026-01-10")
    let newYear = AnnalsEngine.report(AnnalsPeriod.make(.year(2026), today: jan10)!,
                                      input: input(Array(LocalDay.range(d("2025-12-20"), jan10)), today: jan10))
    let nyStreak = newYear.insights.first { $0.kind == .writingStreak }
    check(newYear.writing?.longestRun?.count == 10 && nyStreak?.text == "最长连续落笔 10 天（1月1日—1月10日），至今仍在延续。",
          "长卷连续落笔（跨年）：其一与其七都是今年的 10 天：其一 \(newYear.writing?.longestRun?.count ?? 0) 天，其七“\(nyStreak?.text ?? "nil")”")
    // 修行录卷中洞见卡（近 90 日）仍照实写整段：那一页没有“段首”，不与长卷其一比
    let card = LongTermDigest.make(fromSept, today: oct20).insights.first { $0.kind == .writingStreak }
    check(card?.text == "最长连续落笔 31 天（9月20日—10月20日），也是有记录以来最长的一次，至今仍在延续。",
          "卷中洞见卡（近 90 日）照旧写整段 31 天：\(card?.text ?? "nil")")

    // 3. 当前连续的单位：每天“天”、指定星期“次”、每周 N 次“周”；快照“稳住”一行跟着写“次”
    let start = d("2026-09-01"), tue = d("2026-10-20")
    func stats(_ spec: HabitSpec, _ done: [LocalDay]) -> HabitStats {
        HabitStats(spec: spec, logs: done.map { HabitLogValue(day: $0, completed: true, quantity: nil) }, today: tue)
    }
    let mwfSpec = HabitSpec(frequency: .weekdays, weekdays: [0, 2, 4], startDay: start)
    let mwfDays = LocalDay.range(start, d("2026-10-19")).filter { [0, 2, 4].contains($0.weekdayIndex) }
    let mwf = stats(mwfSpec, mwfDays).streak
    let daily = stats(HabitSpec(frequency: .daily, startDay: start), Array(LocalDay.range(start, d("2026-10-19")))).streak
    let weekly = stats(HabitSpec(frequency: .weekly, targetPerWeek: 1, startDay: start), [d("2026-10-13")]).streak
    let snapshot = SnapshotDigest.weekHabits([.init(title: "练琴", stats: stats(mwfSpec, mwfDays))], today: tue)
    check(mwf.count == mwfDays.count && mwf.unit == "次" && daily.unit == "天" && daily.count == 49 && weekly.unit == "周"
          && snapshot.steady == [.init(title: "练琴", count: mwfDays.count, unit: "次")],
          "当前连续：指定星期写“次”（练琴 \(mwf.count) \(mwf.unit)），每天写“天”（\(daily.count) \(daily.unit)）、每周 N 次写“周”；快照“稳住”同样写“次”")
}

// MARK: r7-misc：功课详情“自 … 起”不是今年的开始日带年份（不再像“明天才开始”）
do {
    let today = LocalDay(key: "2026-10-20")!
    check(LocalDay(key: "2024-10-21")!.label(relativeTo: today) == "2024年10月21日"
          && LocalDay(key: "2026-03-01")!.label(relativeTo: today) == "3月1日",
          "功课详情的开始日：往年的带年份，今年的只写月日")
}

// MARK: r1-quick：随手记“随心”一句话认类型（QuickParse）与习惯同类说法（HabitAlias）
do {
    let today = LocalDay(key: "2026-10-22")!   // 周四，现在 12:00
    typealias QH = QuickParse.Habit
    let habits: [QH] = [
        QH(title: "冥想", unit: "分钟", target: 10),
        QH(title: "喝水", unit: "杯", target: 8, days: [today: .init(quantity: 2, done: false)]),
        QH(title: "运动"),
        QH(title: "步数", unit: "步", target: 8000),
        QH(title: "读书", unit: "页", target: 20),
        QH(title: "早睡"),
    ]
    let noon = QuickParse.Context(today: today, nowMinute: 12 * 60, habits: habits)
    func q(_ text: String, _ ctx: QuickParse.Context = noon, _ choice: QuickParse.Choice? = nil) -> String {
        let r = QuickParse.parse(text, context: ctx, choice: choice)
        switch r.intent {
        case .expense:
            guard let e = r.expense else { return "记账|无" }
            return "记账|\(e.category)|\(e.cents)|\(e.description)|\(e.day.key)"
        case .checkin:
            guard let c = r.checkin else { return "打卡|无" }
            return "打卡|\(c.title)|\(c.added.map(QuickParse.number) ?? "-")|\(c.quantity.map(QuickParse.number) ?? "-")|\(c.day.key)|\(c.note)"
        case .event:
            guard let e = r.event else { return "日程|无" }
            return "日程|\(e.day.key)|\(ClockTime.range(e.start, e.end))|\(e.title)"
        default:
            return "\(r.intent.label)|\(r.journal.day.key)|\(r.journal.body)|\(r.journal.tags.joined(separator: ","))"
        }
    }
    let t = "2026-10-22", y = "2026-10-21"
    let cases: [(String, String)] = [
        // 记账
        ("午饭 18.5", "记账|餐饮与外卖|1850|午饭|\(t)"),
        ("打车 23.6 元", "记账|交通出行|2360|打车|\(t)"),
        ("昨天打车 25", "记账|交通出行|2500|打车|\(y)"),
        ("中午和同学吃火锅 120", "记账|餐饮与外卖|12000|中午和同学吃火锅|\(t)"),
        ("健身房 50", "记账|健康与健身|5000|健身房|\(t)"),
        ("买了本书 39", "记账|教育与学费|3900|买了本书|\(t)"),
        ("50", "记账|待分类消费|5000|待分类消费|\(t)"),
        ("$12.5 咖啡", "记账|餐饮与外卖|1250|咖啡|\(t)"),
        ("A$30 Uber", "记账|交通出行|3000|Uber|\(t)"),
        ("奶茶 ¥16", "记账|餐饮与外卖|1600|奶茶|\(t)"),
        ("超市买菜 86.4", "记账|超市与食品|8640|超市买菜|\(t)"),
        ("Coles 42.10", "记账|超市与食品|4210|Coles|\(t)"),
        ("地铁 3.5", "记账|交通出行|350|地铁|\(t)"),
        ("看电影 25 块", "记账|娱乐|2500|看电影|\(t)"),
        ("话费 30元", "记账|通讯与网络|3000|话费|\(t)"),
        ("会员 15", "记账|软件与会员|1500|会员|\(t)"),
        ("淘宝买衣服 199", "记账|购物|19900|淘宝买衣服|\(t)"),
        ("早餐五块", "记账|餐饮与外卖|500|早餐|\(t)"),
        ("晚饭吃了 32", "记账|餐饮与外卖|3200|晚饭吃了|\(t)"),
        ("前天 牙医 120", "记账|健康与健身|12000|牙医|2026-10-20"),
        ("午饭花了 25", "记账|餐饮与外卖|2500|午饭|\(t)"),
        ("1,200 学费", "记账|教育与学费|120000|学费|\(t)"),
        ("18,5 面", "记账|餐饮与外卖|1850|面|\(t)"),
        ("火锅 5块5", "记账|餐饮与外卖|550|火锅|\(t)"),
        ("记账：雨伞 35", "记账|待分类消费|3500|雨伞|\(t)"),
        ("账：38 外卖", "记账|餐饮与外卖|3800|外卖|\(t)"),
        ("明天交房租 1200", "记账|待分类消费|120000|交房租|\(t)"),
        ("打印 2.4", "记账|教育与学费|240|打印|\(t)"),
        ("麦当劳 12.95", "记账|餐饮与外卖|1295|麦当劳|\(t)"),
        ("停车费 8", "记账|交通出行|800|停车费|\(t)"),
        ("午饭 18 #聚餐", "记账|餐饮与外卖|1800|午饭|\(t)"),
        ("加油 60 刀", "记账|交通出行|6000|加油|\(t)"),
        ("晚上吃饭 30", "记账|餐饮与外卖|3000|晚上吃饭|\(t)"),
        ("中午 吃了拉面 22", "记账|餐饮与外卖|2200|中午 吃了拉面|\(t)"),
        ("一块蛋糕 15", "记账|待分类消费|1500|一块蛋糕|\(t)"),
        ("二十五元 午餐", "记账|餐饮与外卖|2500|午餐|\(t)"),
        ("１８．５ 午饭", "记账|餐饮与外卖|1850|午饭|\(t)"),
        // 打卡
        ("冥想 10 分钟", "打卡|冥想|10|10|\(t)|"),
        ("冥想", "打卡|冥想|-|10|\(t)|"),
        ("打卡 冥想", "打卡|冥想|-|10|\(t)|"),
        ("打卡：冥想", "打卡|冥想|-|10|\(t)|"),
        ("冥想 1 小时", "打卡|冥想|60|60|\(t)|"),
        ("冥想半小时", "打卡|冥想|30|30|\(t)|"),
        ("冥想一个半小时", "打卡|冥想|90|90|\(t)|"),
        ("冥想 1 刻钟", "打卡|冥想|15|15|\(t)|"),
        ("冥想 10", "打卡|冥想|10|10|\(t)|"),
        ("冥想 10 分钟，很平静", "打卡|冥想|10|10|\(t)|很平静"),
        ("打坐 15 分钟", "打卡|冥想|15|15|\(t)|"),
        ("打坐", "打卡|冥想|-|10|\(t)|"),
        ("喝水 3 杯", "打卡|喝水|3|5|\(t)|"),
        ("喝水三杯", "打卡|喝水|3|5|\(t)|"),
        ("喝水 3", "打卡|喝水|3|5|\(t)|"),
        ("喝了两杯水", "打卡|喝水|2|4|\(t)|"),
        ("喝水", "打卡|喝水|-|8|\(t)|"),
        ("跑步 30 分钟", "打卡|运动|-|-|\(t)|跑步 30 分钟"),
        ("健身了", "打卡|运动|-|-|\(t)|"),
        ("跑步 30 分钟，好累", "打卡|运动|-|-|\(t)|跑步 30 分钟，好累"),
        ("昨天跑步了", "打卡|运动|-|-|\(y)|"),
        ("游泳 1 小时", "打卡|运动|-|-|\(t)|游泳 1 小时"),
        ("运动", "打卡|运动|-|-|\(t)|"),
        ("步数 8000", "打卡|步数|8000|8000|\(t)|"),
        ("走了 8千步", "打卡|步数|8000|8000|\(t)|"),
        ("散步 3000 步", "打卡|步数|3000|3000|\(t)|"),
        ("读书 30 页", "打卡|读书|30|30|\(t)|"),
        ("看书 20 页", "打卡|读书|20|20|\(t)|"),
        ("读了 15 页", "打卡|读书|15|15|\(t)|"),
        ("早睡", "打卡|早睡|-|-|\(t)|"),
        ("昨天早睡了", "打卡|早睡|-|-|\(y)|"),
        ("8:30 跑步", "打卡|运动|-|-|\(t)|"),
        // 日程
        ("明天下午3点 组会", "日程|2026-10-23|15:00–16:00|组会"),
        ("明天下午三点组会", "日程|2026-10-23|15:00–16:00|组会"),
        ("周五晚上8点 看电影", "日程|2026-10-23|20:00–21:00|看电影"),
        ("下周一上午10点开会", "日程|2026-10-26|10:00–11:00|开会"),
        ("今晚七点半 跑步", "日程|\(t)|19:30–20:30|跑步"),
        ("10月25日 14:00 面试", "日程|2026-10-25|14:00–15:00|面试"),
        ("3点 组会", "日程|\(t)|15:00–16:00|组会"),
        ("后天交报告", "日程|2026-10-24|全天|交报告"),
        ("明天 9点 开会", "日程|2026-10-23|09:00–10:00|开会"),
        ("下午3点到5点 答辩", "日程|\(t)|15:00–17:00|答辩"),
        ("14:00-16:00 实验", "日程|\(t)|14:00–16:00|实验"),
        ("3-5点 讨论", "日程|\(t)|15:00–17:00|讨论"),
        ("明天下午3点 组会 2小时", "日程|2026-10-23|15:00–17:00|组会"),
        ("大后天 体检", "日程|2026-10-25|全天|体检"),
        ("下周三 交作业", "日程|2026-10-28|全天|交作业"),
        ("周日 爬山", "日程|2026-10-25|全天|爬山"),
        ("周一 组会", "日程|2026-10-26|全天|组会"),
        ("25号 交论文", "日程|2026-10-25|全天|交论文"),
        ("11月3日 上午9点 牙医", "日程|2026-11-03|09:00–10:00|牙医"),
        ("十一月三日 牙医复诊", "日程|2026-11-03|全天|牙医复诊"),
        ("明早8点 晨跑", "日程|2026-10-23|08:00–09:00|晨跑"),
        ("提醒我明天交报告", "日程|2026-10-23|全天|交报告"),
        ("提醒我买牛奶", "日程|\(t)|全天|买牛奶"),
        ("日程：周六 搬家", "日程|2026-10-24|全天|搬家"),
        ("晚上 8:30 和导师视频", "日程|\(t)|20:30–21:30|和导师视频"),
        ("今晚 23:30 复习", "日程|\(t)|23:30–23:59|复习"),
        ("明天凌晨2点 赶飞机", "日程|2026-10-23|02:00–03:00|赶飞机"),
        ("明天中午12点 聚餐", "日程|2026-10-23|12:00–13:00|聚餐"),
        ("明天 下午 3 点 组会", "日程|2026-10-23|15:00–16:00|组会"),
        ("18:30 健身", "日程|\(t)|18:30–19:30|健身"),
        ("明天下午3点 跑步 30 分钟", "日程|2026-10-23|15:00–15:30|跑步"),
        ("明天有个组会", "日程|2026-10-23|全天|组会"),
        ("一点 组会", "日程|\(t)|13:00–14:00|组会"),
        ("2026年12月1日 截止", "日程|2026-12-01|全天|截止"),
        ("1月5日 开学", "日程|2027-01-05|全天|开学"),
        // 修行录
        ("#灵感 先完成再完美", "灵感|\(t)|先完成再完美|"),
        ("先完成再完美 #灵感", "灵感|\(t)|先完成再完美|"),
        ("灵感：把实验图重画", "灵感|\(t)|把实验图重画|"),
        ("想法：换个角度看问题", "灵感|\(t)|换个角度看问题|"),
        ("今天心情不错，下午去了图书馆", "日记|\(t)|今天心情不错，下午去了图书馆|"),
        ("昨天睡得很晚", "日记|\(y)|睡得很晚|"),
        ("前天和朋友聊到很晚", "日记|2026-10-20|和朋友聊到很晚|"),
        ("复盘：三件事做完两件", "复盘|\(t)|三件事做完两件|"),
        ("日省：今天效率一般", "复盘|\(t)|今天效率一般|"),
        ("读完了《置身事内》#读书", "日记|\(t)|读完了《置身事内》|读书"),
        ("看了 2 集剧", "日记|\(t)|看了 2 集剧|"),
        ("3 个任务完成", "日记|\(t)|3 个任务完成|"),
        ("日记：午饭 18.5 好贵", "日记|\(t)|午饭 18.5 好贵|"),
        ("有一点累", "日记|\(t)|有一点累|"),
        ("十分开心", "日记|\(t)|十分开心|"),
        ("一周一次组会", "日记|\(t)|一周一次组会|"),
        ("这周一共跑了三次", "日记|\(t)|这周一共跑了三次|"),
        ("C# 真难", "日记|\(t)|C# 真难|"),
        ("论文进度到 70%", "日记|\(t)|论文进度到 70%|"),
        ("iPhone15 发布会", "日记|\(t)|iPhone15 发布会|"),
        ("工资 5000", "日记|\(t)|工资 5000|"),
        ("收到退款 30", "日记|\(t)|收到退款 30|"),
        ("早上好", "日记|\(t)|早上好|"),
        ("9点 开会", "日记|\(t)|9点 开会|"),
        ("下午3点开了个会", "日记|\(t)|下午3点开了个会|"),
        ("周一去了图书馆", "日记|\(t)|周一去了图书馆|"),
        ("走了 5 公里", "日记|\(t)|走了 5 公里|"),
        ("读书 1 小时", "日记|\(t)|读书 1 小时|"),
        ("晚饭后散步", "日记|\(t)|晚饭后散步|"),
        ("#冥想 今天很平静", "日记|\(t)|今天很平静|冥想"),
        ("今天 #读书 #论文 写完第三章", "日记|\(t)|今天 写完第三章|读书,论文"),
        ("周四 开会", "日记|\(t)|周四 开会|"),
        ("每周五 组会", "日记|\(t)|每周五 组会|"),
        ("3号楼 搬东西", "日记|\(t)|3号楼 搬东西|"),
        ("昨天下午3点 组会", "日记|\(y)|下午3点 组会|"),
        ("今年 2026 年过得很快", "日记|\(t)|今年 2026 年过得很快|"),
        // 审查重点里的几类误判：东西不是动作、别的饮料不是喝水、名次不是钱、改期与“前”
        ("今天跑步机坏了", "日记|\(t)|今天跑步机坏了|"),
        ("十点读书会", "日记|\(t)|十点读书会|"),
        ("喝了3杯咖啡", "日记|\(t)|喝了3杯咖啡|"),
        ("排名第 3", "日记|\(t)|排名第 3|"),
        ("晚上12点 睡", "日程|\(t)|23:59|睡"),
        ("花了 200 买衣服", "记账|购物|20000|买衣服|\(t)"),
        ("一共 128 火锅", "记账|餐饮与外卖|12800|火锅|\(t)"),
        ("打球 场地费 20", "记账|待分类消费|2000|打球 场地费|\(t)"),
        ("uber eats 32", "记账|餐饮与外卖|3200|uber eats|\(t)"),
        ("冥想了一会儿", "打卡|冥想|-|10|\(t)|一会儿"),
        ("下下周一 开会", "日程|2026-11-02|全天|开会"),
        ("周五前交论文", "日程|2026-10-23|全天|交论文"),
        ("晚上 11 点前睡觉", "日程|\(t)|23:00–23:59|睡觉"),
        ("明天的组会改到下午4点", "日程|2026-10-23|16:00–17:00|组会"),
    ]
    var bad: [String] = []
    for (input, expected) in cases {
        let got = q(input)
        if got != expected { bad.append("“\(input)”→ \(got)（应为 \(expected)）") }
    }
    check(bad.isEmpty, "随心认句：\(cases.count) 句例句全对（记账 / 打卡 / 日程 / 修行录）\(bad.isEmpty ? "" : "：\n  " + bad.joined(separator: "\n  "))")
    check(cases.count >= 120, "随心例句不少于 120 句（\(cases.count) 句）")
    // 写得长、写了几行：是在写日记，不猜；巨大的数、怪字不出错
    let longDiary = "今天上午在图书馆看了一上午论文，中午和同学吃了碗面 18 块，下午3点组会讲了进度，导师说下周一前把第三章初稿发给他，晚上还去跑步 30 分钟，回来洗完澡已经快十一点了，困。"
    check(longDiary.count > QuickParse.sentenceLimit && q(longDiary) == "日记|\(t)|\(longDiary)|"
          && q("午饭 18.5\n很好吃") == "日记|\(t)|午饭 18.5\n很好吃|"
          && QuickParse.parse(longDiary, context: noon).alternatives.contains(.expense),
          "写得较长（\(longDiary.count) 字）或写了几行：记日记，改作里仍可选记账")
    let weird = ["99999999999999999999万块", "明天下午3点 组会 99999999999999999999小时", "喝水 99999999999999999999 杯", "#", "##", "：", "打卡", "提醒我",
                 "1e400", "九千九百九十九万九千九百九十九万 元", "$", "A$", "¥.5", "3-", "-3点", "25:61 开会", "24:00", "13点99分", "2月30日 开会",
                 "下下下周一", "周", "号", "月", String(repeating: "午饭 18.5 ", count: 300)]
    let weirdResults = weird.map { QuickParse.parse($0, context: noon) }
    check(weirdResults.count == weird.count && weirdResults[0].intent != .expense && weirdResults[1].event?.end == 16 * 60
          && weirdResults[2].checkin?.added == nil,
          "怪句子不出错：巨大的金额与数量不记、时长太长按 1 小时、只写前缀或符号、不存在的日期钟点、超长正文")

    // 预览签的两行、记好后的那句、依据
    func r(_ s: String, _ ctx: QuickParse.Context = noon, _ choice: QuickParse.Choice? = nil) -> QuickParse.Result {
        QuickParse.parse(s, context: ctx, choice: choice)
    }
    let lunch = r("午饭 18.5")
    check(lunch.headline == "此句将入 · 灵石账簿" && lunch.detail == "餐饮与外卖 · $18.50 · 今天"
          && lunch.evidence == "认出：金额 18.5，“午饭”→ 餐饮与外卖" && lunch.savedText == "已入账" && lunch.intent.button == "入账",
          "预览签：午饭 18.5 → 此句将入 · 灵石账簿｜\(lunch.detail)（\(lunch.evidence)）")
    let meditate = r("冥想 10 分钟")
    check(meditate.detail == "冥想 · 10 分钟（今日 0 → 10 / 10）" && meditate.savedText == "已打卡 · 冥想 10/10 分钟"
          && meditate.headline == "此句将入 · 每日功课" && meditate.intent.seal == "功课",
          "预览签：冥想 10 分钟 → 每日功课｜\(meditate.detail)；记好写“\(meditate.savedText)”")
    check(r("喝水 3 杯").detail == "喝水 · 3 杯（今日 2 → 5 / 8）" && r("冥想").detail == "冥想 · 记满（今日 0 → 10 / 10 分钟）"
          && r("跑步 30 分钟").detail == "运动 · 打卡" && r("昨天跑步了").detail == "运动 · 打卡 · 补记 10月21日"
          && r("昨天跑步了").savedText == "已补卡 · 运动 · 10月21日",
          "打卡预览：数量累加到今天已记的（喝水 2 → 5）、没写数量写“记满”、只打卡的写“打卡”、补昨天写“补记”")
    let meeting = r("明天下午3点 组会")
    check(meeting.detail == "10月23日 周五 15:00–16:00 · 组会" && meeting.savedText == "已记入时辰卷 · 10月23日 15:00"
          && meeting.headline == "此句将入 · 时辰卷" && meeting.intent.button == "记入时辰卷" && meeting.intent.seal == "定时",
          "日程预览：\(meeting.detail)；记好写“\(meeting.savedText)”")
    check(r("后天交报告").detail == "10月24日 周六 全天 · 交报告" && r("后天交报告").savedText == "已记入时辰卷 · 10月24日 全天",
          "全天日程预览：\(r("后天交报告").detail)")
    let untitled = r("明天下午3点")
    check(untitled.intent == .event && untitled.problem == "写上要做什么" && !untitled.canSave
          && untitled.detail == "10月23日 周五 15:00–16:00 · 日程（还没写做什么）",
          "日程没写做什么：预览写“日程（还没写做什么）”，按钮变灰并提示“写上要做什么”")
    check(r("昨天睡得很晚").detail == "日记 · 补记 10月21日" && r("昨天睡得很晚").savedText == "已入卷 · 补记 10月21日"
          && r("读完了《置身事内》#读书").detail == "日记 · 今天 · #读书" && r("#灵感 先完成再完美").detail == "灵感"
          && r("复盘：三件事做完两件").detail == "日省" && r("复盘：三件事做完两件").intent.seal == "复盘",
          "修行录预览：补记写日期、标签写在后面、灵感与日省")
    // 备选与提醒
    let late = r("9点 开会")
    check(late.alternatives.first == .event && late.notice?.contains("09:00 已过") == true,
          "已过的钟点：先记日记，备选第一个是日程（\(late.notice ?? "")）")
    let walk = r("走了 5 公里")
    check(walk.alternatives.first == .checkin && walk.suggestedHabit == 3 && walk.notice?.contains("单位对不上") == true
          && walk.notice?.contains("「步数」按“步”记") == true,
          "单位对不上（公里 vs 步）：记日记，备选打卡「步数」（\(walk.notice ?? "")）")
    let book = r("读书 1 小时")
    check(book.alternatives.first == .checkin && book.suggestedHabit == 4 && book.notice?.contains("“小时”") == true,
          "单位对不上（小时 vs 页）：记日记，备选打卡「读书」")
    check(r("冥想 1 小时").checkin?.conversion == "1 小时 → 60 分钟" && r("冥想 1 小时").evidence.contains("1 小时 → 60 分钟"),
          "单位换算写进依据：1 小时 → 60 分钟")
    check(!r("冥想 10 分钟").alternatives.contains(.expense) && r("午饭 18.5").alternatives.contains(.checkin)
          && !r("午饭 18.5").alternatives.contains(.event) && r("明天下午3点 组会").alternatives.contains(.diary)
          && !r("明天下午3点 组会").alternatives.contains(.expense) && r("工资 5000").alternatives.first == .expense,
          "改作的可选项：没有金额时“记账”灰、没有日期钟点时“日程”灰；写进账的句子备选记账")
    check(r("明天交房租 1200").notice == "未来的日子不能记账，先记在今天", "未来日期的账：仍记今天并在签上提醒")
    // 今日已圆满
    var doneHabits = habits
    doneHabits[0].days = [today: .init(quantity: 10, done: true)]
    doneHabits[2].days = [today: .init(quantity: nil, done: true)]
    let doneCtx = QuickParse.Context(today: today, nowMinute: 12 * 60, habits: doneHabits)
    let doneMed = r("冥想 10 分钟", doneCtx)
    check(doneMed.intent == .diary && doneMed.notice == "「冥想」今日已圆满" && doneMed.headline == "此句将入 · 修行录" && doneMed.detail == "日记 · 今天" && doneMed.alternatives.first == .checkin
          && r("跑步了", doneCtx).intent == .diary && r("跑步了", doneCtx).notice == "「运动」今日已圆满",
          "今日已圆满：签上写“此句将入 · 修行录｜日记 · 今天”并提醒“「冥想」今日已圆满”")
    check(r("跑步了", doneCtx, .checkin("运动")).problem == "「运动」今日已圆满"
          && r("冥想 5 分钟", doneCtx, .checkin("冥想")).checkin?.quantity == 15 && r("冥想 5 分钟", doneCtx, .checkin("冥想")).canSave,
          "选定打卡已圆满的：只打卡的不能再打（再打就是取消），数量型写了数量可以接着加（10 → 15）")
    // 没有功课时永不认作打卡
    let empty = QuickParse.Context(today: today, nowMinute: 12 * 60, habits: [])
    check(q("冥想 10 分钟", empty) == "日记|\(t)|冥想 10 分钟|" && q("打卡 冥想", empty) == "打卡|无"
          && r("打卡 冥想", empty).problem == "还没有功课：先去每日功课立一项" && !r("冥想", empty).alternatives.contains(.checkin),
          "没有任何功课：永不认作打卡（写了“打卡”时提示先立功课）")
    // 改作
    check(q("9点 开会", noon, .event) == "日程|\(t)|21:00–22:00|开会" && r("9点 开会", noon, .event).headline == "已改作 · 时辰卷",
          "改作日程：没写上午下午、已过的 9 点按晚上 21:00；签上写“已改作”")
    check(q("读书 1 小时", noon, .checkin("读书")) == "打卡|读书|-|20|\(t)|1 小时" && q("走了 5 公里", noon, .checkin("步数")) == "打卡|步数|-|8000|\(t)|走了 5 公里",
          "改作打卡但单位对不上：记满，原话写进备注")
    check(q("午饭 18.5", noon, .diary) == "日记|\(t)|午饭 18.5|" && q("午饭 18.5", noon, .note) == "灵感|\(t)|午饭 18.5|"
          && q("午饭 18 很好吃", noon, .expense) == "记账|餐饮与外卖|1800|午饭 很好吃|\(t)" && q("冥想 10 分钟", noon, .expense).hasPrefix("打卡"),
          "改作日记 / 灵感 / 记账；没有金额时选记账不起作用")
    check(QuickParse.Choice(raw: QuickParse.Choice.checkin("喝水").raw) == .checkin("喝水") && QuickParse.Choice(raw: "event") == .event
          && QuickParse.Choice(raw: "") == nil && QuickParse.Choice(raw: "checkin:") == nil,
          "改作的选择按名字存进草稿、读回来一样")
    check(q("冥想", noon, .checkin("已删掉的功课")) == "打卡|冥想|-|10|\(t)|", "选定的功课已不在：回到自动认")
    // 现在几点：傍晚说“8点”是今晚；早上说“9点”是上午；半夜说“11点”已过
    let evening = QuickParse.Context(today: today, nowMinute: 18 * 60, habits: habits)
    let morning = QuickParse.Context(today: today, nowMinute: 7 * 60, habits: habits)
    let lateNight = QuickParse.Context(today: today, nowMinute: 23 * 60 + 50, habits: habits)
    check(q("8点 看电影", evening) == "日程|\(t)|20:00–21:00|看电影" && q("9点 组会", morning) == "日程|\(t)|09:00–10:00|组会"
          && q("11点 睡觉", lateNight).hasPrefix("日记") && q("明天 9点 开会", lateNight) == "日程|2026-10-23|09:00–10:00|开会"
          && q("3点 组会", evening).hasPrefix("日记"),
          "没写上午下午的钟点按现在几点理解：傍晚的 8 点是 20:00、早上的 9 点是 09:00、深夜 11 点已过")
    // 跨午夜：00:30 记账记在当天，早上 9 点还没到
    let afterMidnight = QuickParse.Context(today: today, nowMinute: 30, habits: habits)
    check(q("夜宵 26", afterMidnight) == "记账|餐饮与外卖|2600|夜宵|\(t)" && q("9点 开会", afterMidnight) == "日程|\(t)|09:00–10:00|开会",
          "00:30：记账记在当天，9 点还没到")
    // 说法对上同组的几项功课：名字里有这个说法的优先，再是名字就是组名的；还挑不出才不猜
    let twoSports = QuickParse.Context(today: today, nowMinute: 720, habits: [QH(title: "运动"), QH(title: "跑步")])
    let twoRuns = QuickParse.Context(today: today, nowMinute: 720, habits: [QH(title: "晨跑"), QH(title: "夜跑")])
    check(q("游泳 1 小时", twoSports) == "打卡|运动|-|-|\(t)|游泳 1 小时" && q("跑步", twoSports) == "打卡|跑步|-|-|\(t)|"
          && q("慢跑", twoRuns).hasPrefix("日记") && r("慢跑", twoRuns).notice == "“慢跑”能对上几项功课，没有打卡；要打卡点“改作”选一项",
          "同组对上两项功课：游泳在「运动」「跑步」之间记「运动」（名字就是组名），功课名本身对得上的照打；「晨跑」「夜跑」之间说“慢跑”不猜")
    // 功课名里带同类词（“每日冥想”）、单位写 min
    let named = QuickParse.Context(today: today, nowMinute: 720, habits: [QH(title: "每日冥想", unit: "min", target: 15)])
    check(q("冥想", named) == "打卡|每日冥想|-|15|\(t)|" && q("冥想 20 分钟", named) == "打卡|每日冥想|20|20|\(t)|",
          "功课名“每日冥想”、单位写 min：说“冥想”记满、“冥想 20 分钟”记 20")

    // HabitAlias.match（传书容错 R2 也用）
    check(HabitAlias.match("跑步", titles: ["运动", "步数"]) == .init(index: 0, via: "跑步")
          && HabitAlias.match("晨跑", titles: ["运动"]) == .init(index: 0, via: "晨跑")
          && HabitAlias.match("散步", titles: ["运动", "步数"]) == .init(index: 1, via: "散步")
          && HabitAlias.match("打坐", titles: ["每日冥想"]) == .init(index: 0, via: "打坐")
          && HabitAlias.match("看书", titles: ["阅读 30 分钟"]) == .init(index: 0, via: "看书")
          && HabitAlias.match("写论文", titles: ["写作", "运动"]) == .init(index: 0, via: "写论文")
          && HabitAlias.match("单词", titles: ["背单词"]) == .init(index: 0, via: "单词"),
          "同类说法对上：跑步→运动、晨跑→运动、散步→步数、打坐→每日冥想、看书→阅读、写论文→写作、单词→背单词")
    check(HabitAlias.match("游泳", titles: ["运动", "跑步"]) == nil && HabitAlias.match("吉他", titles: ["运动"]) == nil
          && HabitAlias.match("早睡早起", titles: ["早睡", "早起"]) == nil && HabitAlias.match("走了", titles: ["步数"]) == nil
          && HabitAlias.match("", titles: ["运动"]) == nil && HabitAlias.match("跑步", titles: []) == nil,
          "同类说法对不上：同组两项功课不猜、不在词表里的、两组各对一项、弱说法（“走了”）、空名字")
    check(HabitAlias.groups(ofTitle: "早睡早起").count == 2 && HabitAlias.groups(ofTitle: "吉他").isEmpty,
          "功课名所属的组：“早睡早起”属两组，“吉他”不属任何组")
}

// MARK: r1-quick-fix：随心审查后的修正（没做 / 打算做不打卡、长段与几句记日记、感想不当日程、上周X、两笔钱、两项功课、空正文、
// 功课名核心词与同组挑选、改作锁定、记账虚字、数量边角、晚上12点、体重气温年份不当钱）
do {
    let today = LocalDay(key: "2026-10-22")!   // 周四
    typealias QH = QuickParse.Habit
    let habits: [QH] = [
        QH(title: "冥想", unit: "分钟", target: 10),
        QH(title: "喝水", unit: "杯", target: 8, days: [today: .init(quantity: 2, done: false)]),
        QH(title: "运动"),
        QH(title: "步数", unit: "步", target: 8000),
        QH(title: "读书", unit: "页", target: 20),
        QH(title: "早睡"),
    ]
    // 14 天轻度用户（演示数据 14d）与 2 年用户（演示数据 2）的功课
    let light: [QH] = [QH(title: "晨读二十分钟"), QH(title: "喝水", unit: "杯", target: 8), QH(title: "运动")]
    let veteran: [QH] = [QH(title: "晨读二十分钟"), QH(title: "早睡（23:30 前）"), QH(title: "喝水", unit: "杯", target: 8),
                         QH(title: "背单词", unit: "个", target: 50), QH(title: "运动"), QH(title: "力量训练"),
                         QH(title: "论文写作", unit: "分钟", target: 90), QH(title: "冥想", unit: "分钟", target: 10), QH(title: "练琴"),
                         QH(title: "自己做饭"), QH(title: "整理房间"), QH(title: "步数", unit: "步", target: 8000), QH(title: "读文献")]
    func ctx(_ h: [QH], _ minute: Int = 12 * 60) -> QuickParse.Context { .init(today: today, nowMinute: minute, habits: h) }
    func r(_ s: String, _ c: QuickParse.Context, _ choice: QuickParse.Choice? = nil) -> QuickParse.Result {
        QuickParse.parse(s, context: c, choice: choice)
    }
    let noon = ctx(habits), ten = ctx(habits, 10 * 60)

    // 1. 没做、想做、打算做、时段还没到：记日记，备选打卡，说明行写清
    let notDone = ["没跑步", "今天没冥想", "不想运动", "想去跑步但是下雨了", "打算跑步", "等会去跑步", "待会冥想", "今天要跑步", "今晚冥想", "今晚 跑步"]
    var wrong: [String] = []
    for (label, c) in [("10:00", ten), ("12:00", noon)] {
        for s in notDone {
            let x = r(s, c)
            if x.intent != .diary || x.journal.body != s || x.alternatives.first != .checkin
                || x.notice != "像是还没做，先记成日记；做了要打卡点“改作”" {
                wrong.append("\(label)“\(s)”→ \(x.intent.label) \(x.detail)（\(x.notice ?? "")）")
            }
        }
    }
    let lazy = r("今天没运动，有点懒", ctx(light))
    check(wrong.isEmpty && lazy.intent == .diary && lazy.suggestedHabit == 2 && lazy.evidence.contains("前面写了“没”")
          && r("今天没冥想", noon).checkin == nil,
          "没做 / 想做 / 打算做 / 今晚还没到：10 句在 10:00、12:00 都记日记，备选打卡，提示“像是还没做”\(wrong.isEmpty ? "" : "：\n  " + wrong.joined(separator: "\n  "))")
    let done = [("今晚跑步了", ctx(habits, 21 * 60)), ("心情不错 冥想 10 分钟", noon), ("冥想了一会儿", noon), ("冥想 10 分钟，很重要", noon),
                ("下午跑步了", ctx(habits, 16 * 60)), ("昨天晚上跑步了", noon)]
    check(done.allSatisfy { r($0.0, $0.1).intent == .checkin },
          "真做了的照打卡：21:00“今晚跑步了”、“心情不错 冥想 10 分钟”（不错不是没）、“冥想了一会儿”、“很重要”、“昨天晚上跑步了”")
    check(r("今天没冥想", noon, .checkin("冥想")).intent == .checkin, "说“没冥想”但改作打卡：照选定的打")

    // 2. 写得长、写了几句：记日记；改作打卡时备注照原话（“今天”“明天”不丢）
    let para = "今天下午在图书馆待了一整个下午，把第三章的实验数据又整理了一遍，发现有两组结果对不上，需要明天和导师讨论一下再决定怎么改，晚上回来跑了 5 公里"
    let paraR = r(para, ctx(light))
    let paraChosen = r(para, ctx(light), .checkin("运动"))
    check(paraR.intent == .diary && paraR.journal.body == para && paraR.alternatives.contains(.checkin) && paraR.suggestedHabit == 2
          && paraChosen.intent == .checkin && paraChosen.checkin?.note.contains("需要明天和导师") == true
          && paraChosen.checkin?.note.hasPrefix("下午在图书馆") == true,
          "75 字的日记段落提到跑了 5 公里：整段记日记、修行录留原文；改作打卡时备注照原话（\(paraChosen.checkin?.note.prefix(12) ?? "")…）")
    let several = ["今天心情不错，下午去了图书馆", "明天下午3点 组会，记得带电脑和打印好的材料", "午饭 18，下午又买了咖啡，晚上还吃了夜宵"]
    check(several.allSatisfy { r($0, noon).intent == .diary } && r("跑步 30 分钟，好累", noon).intent == .checkin
          && r("喝水 3 杯，有点渴", noon).intent == .checkin && r("明天下午3点 组会，记得带电脑", noon).intent == .event
          && QuickParse.length("Uber 32 打车") == 4 && QuickParse.clauses("1,200 学费，好贵") == ["1,200 学费", "好贵"],
          "写了几句（第二句超过 6 字或三句以上）记日记；“跑步 30 分钟，好累”这种后面跟一小句的仍按一句认")

    // 3. 带日期的感想不当全天日程；“这周天气”不是星期天
    let feelings: [(String, String)] = [("周一好累", "10月26日"), ("明天又要早起，有点烦", "10月23日"), ("星期天的早上很安静", "10月25日"),
                                        ("周五晚上的火锅真好吃", "10月23日"), ("周三下午那个讲座很有意思", "10月28日"), ("周五的组会被取消", "10月23日")]
    var feelWrong: [String] = []
    for (s, day) in feelings {
        let x = r(s, ctx(light))
        if x.intent != .diary || x.journal.body != s || x.alternatives.first != .event || x.notice != "说到了 \(day)；要记成日程点“改作”" {
            feelWrong.append("“\(s)”→ \(x.intent.label) \(x.detail)（\(x.notice ?? "")）")
        }
    }
    let weather = r("这周天气不错，心情也好", ctx(light))
    check(feelWrong.isEmpty && weather.intent == .diary && weather.journal.body == "这周天气不错，心情也好" && !weather.alternatives.contains(.event)
          && r("这周天天加班", ctx(light)).intent == .diary && !r("这周天天加班", ctx(light)).alternatives.contains(.event)
          && r("周六 和好友聚餐", noon).intent == .event && r("这周日 爬山", noon).event?.day == LocalDay(key: "2026-10-25"),
          "带日期的感想（周一好累、周五的组会被取消……）记日记、备选日程；“这周天气 / 天天”不是星期天；“周六 和好友聚餐”“这周日 爬山”仍是日程\(feelWrong.isEmpty ? "" : "：\n  " + feelWrong.joined(separator: "\n  "))")
    let editable = r("周一好累", ctx(light), .event)
    check(editable.intent == .event && editable.event?.day == LocalDay(key: "2026-10-26"), "感想句改作日程仍可记（10月26日 全天）")

    // 4. 上周X / 上个星期X / 上上周X：补记、记账都按那一天
    func q(_ s: String, _ c: QuickParse.Context) -> String {
        let x = r(s, c)
        switch x.intent {
        case .expense: return "记账|\(x.expense?.category ?? "")|\(x.expense?.cents ?? 0)|\(x.expense?.description ?? "")|\(x.expense?.day.key ?? "")"
        case .checkin: return "打卡|\(x.checkin?.title ?? "")|\(x.checkin.flatMap { $0.added }.map(QuickParse.number) ?? "-")|\(x.checkin?.day.key ?? "")"
        case .event: return "日程|\(x.event?.day.key ?? "")|\(ClockTime.range(x.event?.start, x.event?.end))|\(x.event?.title ?? "")"
        default: return "\(x.intent.label)|\(x.journal.day.key)|\(x.journal.body)"
        }
    }
    let lastWeek: [(String, String)] = [
        ("上周五 打车 30", "记账|交通出行|3000|打车|2026-10-16"),
        ("上周日 爬山", "日记|2026-10-18|爬山"),
        ("上上周五 聚餐 200", "记账|待分类消费|20000|聚餐|2026-10-09"),
        ("上周五和朋友吃饭", "日记|2026-10-16|和朋友吃饭"),
        ("上个星期三 看电影 40", "记账|娱乐|4000|看电影|2026-10-14"),
        ("上礼拜一 组会讲了进度", "日记|2026-10-12|组会讲了进度"),
        ("马上周末了", "日记|2026-10-22|马上周末了"),
        ("上周很忙", "日记|2026-10-22|上周很忙"),
    ]
    let lastBad = lastWeek.filter { q($0.0, ctx(light)) != $0.1 }.map { "“\($0.0)”→ \(q($0.0, ctx(light)))（应为 \($0.1)）" }
    check(lastBad.isEmpty && r("上周五 打车 30", ctx(light)).notice == nil && r("上周五 打车 30", ctx(light)).detail == "交通出行 · $30.00 · 补记 10月16日",
          "上周X：记账记在那天（不再提示“未来的日子”）、句首的补记那天；“马上周末”“上周很忙”不当日期\(lastBad.isEmpty ? "" : "：\n  " + lastBad.joined(separator: "\n  "))")
    check(q("上周五跑步了", noon) == "日记|2026-10-16|跑步了" && r("上周五跑步了", noon).alternatives.first == .checkin
          && q("前天跑步了", noon) == "打卡|运动|-|2026-10-20",
          "补卡只自动补到前天；更早的（上周五跑步了）补记日记、备选打卡")

    // 5. 一句两笔钱：记日记，提醒分两句；改作记账按第一笔，另一笔的数字不留在说明里
    let twoMoney: [(String, String)] = [("午饭 18.5 晚饭 30", "18.5、30"), ("午饭 18 咖啡 5", "18、5"), ("午饭18.5，晚饭30", "18.5、30"),
                                        ("午饭 18元 咖啡 5元", "18、5")]
    check(twoMoney.allSatisfy { s, amounts in
        let x = r(s, noon)
        return x.intent == .diary && x.notice == "这句有两笔钱（\(amounts)），分两句记更准" && x.alternatives.first == .expense
    } && r("午饭 18.5 晚饭 30", noon, .expense).expense?.cents == 1850 && r("午饭 18.5 晚饭 30", noon, .expense).expense?.description == "午饭 晚饭"
          && q("iPhone 15 Pro 999", noon) == "记账|待分类消费|99900|iPhone 15 Pro|2026-10-22",
          "一句两笔钱：记日记并提醒“分两句记更准”；改作记账按第一笔 18.5、说明不留 30；“iPhone 15 Pro 999”的 15 是型号")

    // 6. 一句说到两项功课：说清是两项，记日记；同一说法对上多项才说“能对上几项”
    let medWater = r("今天冥想了 10 分钟，喝水 3 杯", noon)
    let medWaterVet = r("今天冥想了 10 分钟，喝水 3 杯", ctx(veteran))
    check(medWater.intent == .diary && medWater.notice == "说到了「冥想」「喝水」两项功课，先记成日记；分两句各打一次卡"
          && medWaterVet.notice == "说到了「冥想」「喝水」两项功课，先记成日记；分两句各打一次卡"
          && r("跑步和冥想", noon).notice == "说到了「运动」「冥想」两项功课，先记成日记；分两句各打一次卡" && r("跑步和冥想", noon).checkin == nil
          && r("跑步和喝水", ctx(light)).intent == .diary && r("跑步和喝水", ctx(light)).alternatives.first == .checkin
          && r("打卡：跑步和冥想", noon).problem?.hasPrefix("说到了「运动」「冥想」两项功课") == true,
          "说到两项功课：说明行写“说到了「冥想」「喝水」两项功课”，不只挑一项打卡")

    // 7. 只写了前缀、标签或日期：不能记
    let blanks = ["复盘：", "#灵感", "昨天", "#读书", "日记：", "灵感：", "想法：", "日省： "]
    check(blanks.allSatisfy { let x = r($0, noon); return !x.canSave && x.problem == "写上要记的话" && x.journal.body.isEmpty }
          && r("复盘：三件事做完两件", noon).canSave && r("#灵感 先完成再完美", noon).canSave,
          "只写前缀、标签或日期（复盘： / #灵感 / 昨天 / #读书 / 日记： / 灵感：）：按钮变灰、提示“写上要记的话”")

    // 8. 功课名的核心词与同组挑选（14d 的“晨读二十分钟”、2 年的「运动」「力量训练」）
    check(HabitAlias.coreKey("晨读二十分钟") == "晨读" && HabitAlias.coreKey("早睡（23:30 前）") == "早睡" && HabitAlias.coreKey("每天喝水 8 杯") == "喝水"
          && HabitAlias.coreKey("阅读30min") == "阅读" && HabitAlias.coreKey("跑步") == nil && HabitAlias.coreKey("冥想") == nil
          && HabitAlias.coreKey("一万步") == nil && HabitAlias.coreKey("晨跑打卡") == "晨跑",
          "功课名的核心词：晨读二十分钟→晨读、早睡（23:30 前）→早睡、每天喝水 8 杯→喝水；跑步、一万步不拆")
    let lightCases: [(String, String)] = [("晨读", "打卡|晨读二十分钟|-|2026-10-22"), ("晨读了 20 分钟", "打卡|晨读二十分钟|-|2026-10-22"),
                                          ("读书 20 分钟", "打卡|晨读二十分钟|-|2026-10-22"), ("早读", "打卡|晨读二十分钟|-|2026-10-22"),
                                          ("晨读二十分钟", "打卡|晨读二十分钟|-|2026-10-22")]
    let vetCases: [(String, String)] = [("跑步 30 分钟", "打卡|运动|-|2026-10-22"), ("健身 1 小时", "打卡|运动|-|2026-10-22"),
                                        ("撸铁", "打卡|力量训练|-|2026-10-22"), ("力量", "打卡|力量训练|-|2026-10-22"),
                                        ("早睡", "打卡|早睡（23:30 前）|-|2026-10-22"), ("晨读", "打卡|晨读二十分钟|-|2026-10-22")]
    let coreBad = lightCases.filter { q($0.0, ctx(light)) != $0.1 }.map { "14d“\($0.0)”→ \(q($0.0, ctx(light)))" }
        + vetCases.filter { q($0.0, ctx(veteran)) != $0.1 }.map { "2y“\($0.0)”→ \(q($0.0, ctx(veteran)))" }
    check(coreBad.isEmpty && r("晨读了 20 分钟", ctx(light)).checkin?.note == "20 分钟",
          "14d 说“晨读 / 读书 20 分钟”打「晨读二十分钟」；2 年说“跑步 / 健身”打「运动」、“撸铁”打「力量训练」\(coreBad.isEmpty ? "" : "：\n  " + coreBad.joined(separator: "\n  "))")
    check(HabitAlias.preferred(word: "撸铁", group: 0, owners: [0, 1], titles: ["运动", "力量训练"]) == 1
          && HabitAlias.preferred(word: "跑步", group: 0, owners: [0, 1], titles: ["运动", "力量训练"]) == 0
          && HabitAlias.preferred(word: "慢跑", group: 0, owners: [0, 1], titles: ["晨跑", "夜跑"]) == nil
          && HabitAlias.preferred(word: "游泳", group: 0, owners: [0, 1], titles: ["健身", "游泳课"]) == 1,
          "同组几项功课里挑：名字里有这一撮说法的优先（撸铁→力量训练、游泳→游泳课），再挑名字就是组名的（跑步→运动），都不行不猜")

    // 10. 改作锁定：还在改那一句就锁着，全选重写一句就回到自动
    check(!QuickParse.keepsChoice(original: "喝水", current: "明天下午3点 组会") && QuickParse.keepsChoice(original: "喝水", current: "喝水 3 杯")
          && QuickParse.keepsChoice(original: "读书 1 小时", current: "读书 1 小时，很充实") && QuickParse.keepsChoice(original: "读书 1 小时", current: "读书 2 小时")
          && !QuickParse.keepsChoice(original: "午饭 18.5 好贵", current: "午") && !QuickParse.keepsChoice(original: "喝水", current: "")
          && !QuickParse.keepsChoice(original: "", current: "喝水") && !QuickParse.keepsChoice(original: "午饭 18.5", current: "午饭后散步了一圈很舒服"),
          "改作锁定：补几个字、改个数还锁着；开头变了（⌘A 重写）、删得只剩一点就回到自动认")

    // 11. 记账说明不剩虚字
    check(q("花了 50", noon) == "记账|待分类消费|5000|待分类消费|2026-10-22" && q("花了50", noon) == "记账|待分类消费|5000|待分类消费|2026-10-22"
          && q("今天花了 50", noon) == "记账|待分类消费|5000|待分类消费|2026-10-22" && q("一共 120", noon) == "记账|待分类消费|12000|待分类消费|2026-10-22"
          && q("共花了 30", noon) == "记账|待分类消费|3000|待分类消费|2026-10-22" && q("午饭花了 25", noon) == "记账|餐饮与外卖|2500|午饭|2026-10-22"
          && q("18,5 面", noon) == "记账|餐饮与外卖|1850|面|2026-10-22",
          "记账说明去完只剩“了 / 一 / 共”时用类别名；一个字的正经说明（面）照留")

    // 12. 数量边角：“1.2 万步”、数量 0、选定打卡而单位对不上
    check(q("走了 1.2 万步", noon) == "打卡|步数|12000|2026-10-22" && q("走了 1.2万步", noon) == "打卡|步数|12000|2026-10-22"
          && q("走了 8 千步", noon) == "打卡|步数|8000|2026-10-22",
          "“1.2 万步”（数字和万之间有空格）记 12000 步")
    let zero = r("喝水 0 杯", noon)
    check(zero.intent == .diary && zero.notice == "数量写的是 0，先记成日记" && zero.alternatives.first == .checkin
          && r("喝水 0", noon).notice == "数量写的是 0，先记成日记" && r("喝水 0 杯", noon, .checkin("喝水")).problem == "数量写的是 0：写上这次的数量"
          && r("喝水 99999999999999999999 杯", noon).notice == "数量太大，先记成日记",
          "数量写 0：记日记并说“数量写的是 0”（不再说单位对不上）；选定打卡也不让记 0；数量太大另说")
    let ml = r("喝水 500ml", noon, .checkin("喝水"))
    check(ml.intent == .checkin && ml.notice == "单位对不上：「喝水」按“杯”记，这句写的是“毫升”；将按记满" && ml.detail == "喝水 · 记满（今日 2 → 8 / 8 杯）",
          "选定打卡而单位对不上：签上说明“将按记满”")

    // 13. 晚上12点：按 23:59 截止记日程
    let midnight = r("晚上12点 睡觉", noon)
    check(midnight.intent == .event && midnight.event?.start == 23 * 60 + 59 && midnight.event?.end == nil && midnight.event?.byMidnight == true
          && midnight.detail == "10月22日 周四 23:59 前 · 睡觉" && midnight.savedText == "已记入时辰卷 · 10月22日 23:59 前"
          && r("今晚12点前睡", noon).event?.title == "睡" && r("今晚12点前睡", noon).detail == "10月22日 周四 23:59 前 · 睡"
          && r("晚上12点 睡觉", noon, .event).intent == .event && r("明晚12点 赶稿", noon).event?.day == LocalDay(key: "2026-10-23")
          && r("凌晨12点 收衣服", noon).intent == .diary,
          "“晚上12点 睡觉”记成今天 23:59 前的日程，预览写“23:59 前”；改作日程也能选；凌晨12点按 0 点（已过）")

    // 15. 体重、气温、分数、年份、感受句里的数：不当钱（说到贵、便宜照记账）
    let notMoney = ["体重 65", "体重65.3", "气温 25", "2026", "考了 92", "今天好累 不想动 1", "血压 120", "心率 72"]
    let notMoneyBad = notMoney.filter { let x = r($0, noon); return x.intent != .diary || x.alternatives.first != .expense }
    check(notMoneyBad.isEmpty && q("雨伞 好贵 35", noon) == "记账|待分类消费|3500|雨伞 好贵|2026-10-22" && q("50", noon) == "记账|待分类消费|5000|待分类消费|2026-10-22"
          && q("2026 年会门票 120", noon).hasPrefix("记账") && q("买书 2026", noon).hasPrefix("记账"),
          "体重 / 气温 / 分数 / 年份 / 感受句的数不自动记账（备选记账）；“雨伞 好贵 35”“50”“买书 2026”照记账\(notMoneyBad.isEmpty ? "" : "：" + notMoneyBad.joined(separator: "、"))")
}

// MARK: r1-remind：落笔时辰 / 功课时辰的排程、三日一问的退避、周复盘的星期与时刻（Core/ReminderPlan）
do {
    let today = LocalDay(key: "2026-10-22")!   // 周四
    let noon = 12 * 60
    typealias Plan = ReminderPlan

    // 1. 标识：自己排的认得出、别的（周复盘）不认
    let writeID = Plan.identifier(.write, day: today)
    check(writeID == "apt.write.2026-10-22" && Plan.identifier(.habits, day: today) == "apt.habits.2026-10-22"
          && Plan.parse(identifier: writeID).map { $0.kind == .write && $0.day == today } == true
          && Plan.parse(identifier: "apt.habits.2026-10-23")?.day == today.adding(days: 1)
          && Plan.parse(identifier: "apt.weekly-review") == nil && Plan.parse(identifier: "apt.write.2026-13-40") == nil,
          "提醒标识：apt.write.<日期> / apt.habits.<日期> 认得出，周复盘与写坏的日期不认")

    // 2. 文案：落笔按日期轮换 5 句（同一天同一句），功课写实名、超过 3 项写总数
    let lines = (0..<5).map { Plan.writeBody(on: today.adding(days: $0)) }
    check(Set(lines).count == 5 && Plan.writeBody(on: today) == Plan.writeBody(on: today.adding(days: 5))
          && !Plan.writeBody(on: LocalDay(key: "1900-01-01")!).isEmpty,
          "落笔提醒的正文按日期轮换 5 句，五天一轮")
    check(Plan.habitsBody(pending: ["冥想", "喝水"]) == "还有「冥想」「喝水」未圆满。"
          && Plan.habitsBody(pending: ["冥想", "喝水", "读书", "运动", "早睡"]) == "还有「冥想」「喝水」「读书」等 5 项未圆满。"
          && Plan.habitsBody(pending: []) == "今日功课可都圆满了？",
          "功课提醒写出前三项的名字：\(Plan.habitsBody(pending: ["冥想", "喝水", "读书", "运动", "早睡"]))")
    let allText = Plan.writeLines + [Plan.habitsGeneric, Plan.backoffNote, Plan.backoffHint, Plan.writeTitle, Plan.habitsTitle]
    check(!allText.contains { t in ["失败", "中断", "漏打", "没写"].contains { t.contains($0) } },
          "提醒文案不说“失败 / 中断 / 漏打 / 没写”")

    // 3. 落笔：中午排今天起 7 天；过了时刻、已写过、已提醒过、已回应过都不排今天
    var input = Plan.Input(today: today, nowMinute: noon, write: true)
    let fresh = Plan.plan(input)
    check(fresh.count == 7 && fresh.first?.day == today && fresh.last?.day == today.adding(days: 6)
          && fresh.allSatisfy { $0.kind == .write && $0.minute == 21 * 60 + 30 && $0.title == "落笔时辰" },
          "落笔时辰默认 21:30，一次排今天起 7 天、每天一条")
    input.nowMinute = 22 * 60
    check(Plan.plan(input).first?.day == today.adding(days: 1) && Plan.plan(input).count == 6, "已过 21:30：不排今天，从明天排起")
    input.nowMinute = 21 * 60 + 30
    check(Plan.plan(input).first?.day == today.adding(days: 1), "正好到点那一分钟也不再排今天（过期的不补）")
    input.nowMinute = noon
    input.wroteToday = true
    check(Plan.plan(input).first?.day == today.adding(days: 1), "今天已写过一篇：不排今天")
    input.wroteToday = false
    input.writeMinute = 23 * 60
    input.nowMinute = 22 * 60
    input.state.armedWrite = [today.key: 21 * 60 + 30]
    check(Plan.plan(input).first?.day == today.adding(days: 1), "今天 21:30 已提醒过、又把时刻改到 23:00：今天不再来第二条")
    input.state = Plan.answered(Plan.State(), day: today)
    input.nowMinute = noon
    check(Plan.plan(input).first?.day == today.adding(days: 1), "今天的落笔提醒已回应（点开 / 回复 / 今日免）：不再排今天")
    check(Plan.plan(Plan.Input(today: today, nowMinute: noon)).isEmpty, "两样都关着：一条也不排")

    // 4. 功课：只在还有未圆满的功课时排今天，正文写实名；以后几天只排有功课要做的日子、先用通用句
    let someDays: Set<LocalDay> = [today.adding(days: 1), today.adding(days: 4)]
    var habits = Plan.Input(today: today, nowMinute: noon, habits: true, pendingHabits: ["冥想", "喝水"], habitDays: someDays)
    let habitSlots = Plan.plan(habits)
    check(habitSlots.map(\.day) == [today, today.adding(days: 1), today.adding(days: 4)]
          && habitSlots.first?.body == "还有「冥想」「喝水」未圆满。" && habitSlots.first?.minute == 20 * 60
          && habitSlots.dropFirst().allSatisfy { $0.body == "今日功课可都圆满了？" && $0.title == "功课时辰" },
          "功课时辰默认 20:00：今天写实名，以后几天只排有功课的日子、用通用句")
    habits.pendingHabits = []
    check(Plan.plan(habits).first?.day == today.adding(days: 1), "今天功课都圆满了：不排今天")
    habits.habitDays = []
    check(Plan.plan(habits).isEmpty, "还没有功课：一条也不排")
    habits.pendingHabits = ["冥想"]
    habits.nowMinute = 20 * 60 + 10
    check(Plan.plan(habits).isEmpty, "功课时刻已过：今天不补")

    // 5. 退避：连续 3 次到点没理会 → 从那天起三日一问；回应、落笔、恢复每日都清零
    // （应用开着、Mac 醒着时每跨一天结算一天：这里也一天一天算）
    var state = Plan.State()
    for offset in (1...3).reversed() {
        state.armedWrite[today.adding(days: -offset).key] = 21 * 60 + 30
        state = Plan.settle(state, today: today.adding(days: -offset + 1), wrote: [])
    }
    check(state.ignored == 3 && state.backingOff && state.backoffStart == today.key && state.noticePending && state.armedWrite.isEmpty,
          "连续 3 天到点没理会：改成三日一问，从今天算起，并待主窗口说一句")
    input = Plan.Input(today: today, nowMinute: noon, write: true, state: state)
    check(Plan.plan(input).map(\.day) == [today, today.adding(days: 3), today.adding(days: 6)], "三日一问：只排今天、+3、+6 天")
    let restored = Plan.restoreDaily(state)
    check(!restored.backingOff && Plan.plan(Plan.Input(today: today, nowMinute: noon, write: true, state: restored)).count == 7,
          "点“恢复每日”：回到每天")
    check(Plan.answered(state, day: today).ignored == 0 && Plan.answered(state, day: today).backoffStart == nil,
          "回应一次（点开、回复、今日免）即清零")
    let wroteNow = Plan.settle(state, today: today, wrote: [today])
    check(wroteNow.ignored == 0 && !wroteNow.backingOff && !wroteNow.noticePending, "落一笔即清零，退避一并撤掉")
    var mixed = Plan.State()
    for offset in 1...3 { mixed.armedWrite[today.adding(days: -offset).key] = 21 * 60 + 30 }
    mixed = Plan.settle(mixed, today: today, wrote: [today.adding(days: -2)])
    check(mixed.ignored == 1 && !mixed.backingOff, "中间那天写过：只算最后一次没理会（连续才算）")
    var replied = Plan.State()
    replied.armedWrite[today.adding(days: -1).key] = 21 * 60 + 30
    replied = Plan.answered(replied, day: today.adding(days: -1))
    replied.ignored = 2
    replied = Plan.settle(replied, today: today, wrote: [])
    check(replied.ignored == 0 && replied.answered.isEmpty, "回应过的那天结算时不算没理会")
    check(Plan.disabled(state, .write).armedWrite.isEmpty && !Plan.disabled(state, .write).backingOff,
          "关掉落笔提醒：排程记录与退避一并清掉，再打开就是每天")

    // 6. 连跑 12 天：一直不写 → 前三天每天问，第 4 天起三日一问；第 12 天落一笔 → 明天起回到每天
    var sim = Plan.State()
    var fired: [Int] = []
    for d in 0..<12 {
        let day = today.adding(days: d)
        let wrote: Set<LocalDay> = d == 11 ? [day] : []
        sim = Plan.settle(sim, today: day, wrote: wrote)
        let plan = Plan.plan(Plan.Input(today: day, nowMinute: noon, write: true, wroteToday: !wrote.isEmpty, state: sim))
        sim = Plan.arm(sim, plan: plan, today: day, nowMinute: noon)
        if plan.first?.day == day { fired.append(d) }
        if d == 11 {
            check(plan.map(\.day) == (1..<7).map { day.adding(days: $0) } && !sim.backingOff, "落一笔后：今天已写不再问，明天起每天")
        }
    }
    check(fired == [0, 1, 2, 3, 6, 9], "一直不理会：前三天每天问，之后三日一问（实际问了第 \(fired.map(String.init).joined(separator: "、")) 天）")

    // 7. 记下排了哪些：今天已到点的留着（次日结算），还没到点的换成这次排上的
    var armed = Plan.State()
    armed.armedWrite = [today.key: 9 * 60, today.adding(days: 1).key: 21 * 60 + 30, today.adding(days: -1).key: 21 * 60 + 30]
    armed = Plan.arm(armed, plan: [], today: today, nowMinute: noon)
    check(armed.armedWrite == [today.key: 9 * 60, today.adding(days: -1).key: 21 * 60 + 30], "关掉或写过后重排：还没到点的撤掉，已到点的留着待结算")
    check(Plan.earliestArmed(armed, today: today) == today.adding(days: -1) && Plan.earliestArmed(Plan.State(), today: today) == today,
          "结算从最早一个待结算的日子取起")
    let encoded = try? JSONEncoder().encode(state)
    check(encoded.flatMap { try? JSONDecoder().decode(Plan.State.self, from: $0) } == state, "排程记录存成 JSON 再读回来一模一样")

    // 8. 周复盘：可选星期与时刻，默认周日 21:00
    let weekly = Plan.weeklyComponents(weekday: Plan.defaultWeeklyWeekday, minute: Plan.defaultWeeklyMinute)
    check(weekly.weekday == 1 && weekly.hour == 21 && weekly.minute == 0 && Plan.weeklyLabel(weekday: 1, minute: 21 * 60) == "每周日 21:00"
          && Plan.weeklyLabel(weekday: 2, minute: 8 * 60 + 5) == "每周一 08:05" && Plan.clampWeekday(9) == 1
          && Plan.weekdayOrder.map(Plan.weekdayName) == ["周一", "周二", "周三", "周四", "周五", "周六", "周日"],
          "周复盘：默认周日 21:00，星期按周一到周日列出")
    check(Plan.clampMinute(24 * 60) == 24 * 60 - 1 && Plan.clampMinute(-5) == 0, "提醒时刻夹在 00:00–23:59")

    // 9. 设置组摘要：没开的不写
    check(Plan.summary(write: 21 * 60 + 30, habits: nil, weekly: true, loginItem: false) == ["落笔 21:30", "周复盘已开"]
          && Plan.summary(write: nil, habits: 20 * 60, weekly: false, loginItem: true) == ["功课 20:00", "开机自启"]
          && Plan.summary(write: nil, habits: nil, weekly: false, loginItem: false).isEmpty,
          "“景致与提醒”收起时的摘要只写开着的提醒")

    // 10. 只算提醒真到了眼前的日子：合盖 / 关机那几天、没有通知权限时不算没理会（修审查：合盖几天回来就成了三日一问）
    let writeAt = 21 * 60 + 30
    /// 一天的模样：某时刻重排一次（先结算、再排、记下排了哪些）
    func run(_ s: Plan.State, day: LocalDay, minute: Int, wrote: Set<LocalDay> = [], canNotify: Bool = true) -> Plan.State {
        let settled = Plan.settle(s, today: day, wrote: wrote, canNotify: canNotify)
        let plan = Plan.plan(Plan.Input(today: day, nowMinute: minute, write: true, wroteToday: wrote.contains(day), state: settled))
        return Plan.arm(settled, plan: plan, today: day, nowMinute: minute)
    }
    func at(_ day: LocalDay, _ minute: Int) -> Plan.Moment { Plan.Moment(day: day, minute: minute) }
    let friday = LocalDay(key: "2026-10-23")!
    for away in [3, 10] {
        // 周五 20:00 写过一篇后合盖，away 天后 09:00 打开
        var lid = run(Plan.State(), day: friday, minute: 20 * 60, wrote: [friday])
        lid = Plan.away(lid, at: at(friday, 20 * 60 + 5))
        let back = friday.adding(days: away)
        lid = Plan.back(lid, at: at(back, 9 * 60))
        let unseenDays = lid.unseen
        lid = run(lid, day: back, minute: 9 * 60 + 1, wrote: [friday])
        check(lid.ignored == 0 && !lid.backingOff && !lid.noticePending && lid.awaySince == nil && lid.unseen.isEmpty
              && unseenDays == (1..<min(away, Plan.horizonDays)).map { friday.adding(days: $0).key },
              "合盖 \(away) 天（周五 20:05 睡下、\(back.key) 09:00 醒来）：这几天到点的提醒没送到，不算没理会（没理会 \(lid.ignored) 次）")
        // 中间没留下睡眠记录（例如应用没在跑）：一次结算好几天，这一批最多算 1 次
        var noRecord = run(Plan.State(), day: friday, minute: 20 * 60, wrote: [friday])
        noRecord = run(noRecord, day: back, minute: 9 * 60, wrote: [friday])
        check(noRecord.ignored == 1 && !noRecord.backingOff,
              "离开 \(away) 天、没有睡眠记录：一次补算好几天最多算 1 次，不进三日一问（没理会 \(noRecord.ignored) 次）")
    }
    // 每晚 21:00 合盖、次晨 08:00 才开：21:30 的提醒从没到眼前，连着几天也不进三日一问
    var nightly = Plan.State()
    for d in 0..<6 {
        let day = today.adding(days: d)
        nightly = run(nightly, day: day, minute: 8 * 60)
        nightly = Plan.away(nightly, at: at(day, 21 * 60))
        nightly = Plan.back(nightly, at: at(day.adding(days: 1), 8 * 60))
    }
    nightly = run(nightly, day: today.adding(days: 6), minute: 8 * 60 + 1)
    check(nightly.ignored == 0 && !nightly.backingOff, "每晚 21:00 合盖、次晨才开：21:30 的提醒从没送到，六天下来也不算没理会")
    // 醒着连着 3 天不理会（每晚 23:00 才合盖）：照样进入三日一问
    var awake = Plan.State()
    for d in 0..<4 {
        let day = today.adding(days: d)
        awake = run(awake, day: day, minute: 8 * 60)
        if d < 3 {
            awake = Plan.away(awake, at: at(day, 23 * 60))
            awake = Plan.back(awake, at: at(day.adding(days: 1), 7 * 60 + 50))
        }
    }
    check(awake.ignored == 3 && awake.backingOff && awake.noticePending && awake.backoffStart == today.adding(days: 3).key,
          "醒着连着 3 天到点没理会（夜里 23:00 才合盖）：照样改成三日一问（没理会 \(awake.ignored) 次）")
    // 睡下那一刻正好在到点前后：到点那一刻还醒着就算送到了；睡下一刻和醒来一刻本身算没送到
    var edge = Plan.State()
    edge.armedWrite = [today.key: writeAt, today.adding(days: 1).key: writeAt]
    check(Plan.back(Plan.away(edge, at: at(today, writeAt + 1)), at: at(today.adding(days: 1), 8 * 60)).unseen.isEmpty
          && Plan.back(Plan.away(edge, at: at(today, writeAt)), at: at(today, writeAt + 5)).unseen == [today.key]
          && Plan.back(Plan.away(edge, at: at(today, 20 * 60)), at: at(today.adding(days: 1), writeAt)).unseen
              == [today.key, today.adding(days: 1).key]
          && Plan.back(edge, at: at(today.adding(days: 1), 8 * 60)) == edge,
          "睡下 / 醒来的边界：21:31 才合盖算送到了；正好 21:30 合盖、正好 21:30 醒来算没送到；没有睡下记录时醒来不动")
    // 先睡下又关机：记着最早的那一刻
    let twice = Plan.away(Plan.away(Plan.State(), at: at(today, 20 * 60)), at: at(today, 22 * 60))
    check(twice.awaySince == at(today, 20 * 60), "先合盖又关机：记着最早睡下的那一刻")
    // 没有通知权限的那几天（事后在系统设置里关了通知）：不算没理会，也不清零
    var denied = Plan.State()
    denied.ignored = 2
    denied.armedWrite[today.adding(days: -1).key] = writeAt
    denied = Plan.settle(denied, today: today, wrote: [], canNotify: false)
    check(denied.ignored == 2 && !denied.backingOff && denied.armedWrite.isEmpty, "没有通知权限时到点的那天：不算没理会（仍是 \(denied.ignored) 次，不进三日一问）")
    // 一批里有写过的日子：清零后又一天没理会，仍记 1 次；回应过、写过的照样清零
    var batch = Plan.State()
    batch.ignored = 2
    for offset in 1...4 { batch.armedWrite[today.adding(days: -offset).key] = writeAt }
    batch = Plan.settle(batch, today: today, wrote: [today.adding(days: -3)])
    check(batch.ignored == 1 && !batch.backingOff, "一次补算四天、中间写过一篇：写过那天清零，之后最多再记 1 次")
    // 重排撞上“刚睡下”：睡下 10 分钟内先不结算（可能还没真睡），隔了好一阵才轮到的当场收尾再结算；时钟往回拨也收尾
    var pending = Plan.State()
    pending.armedWrite = [today.adding(days: -1).key: writeAt]
    pending = Plan.away(pending, at: at(today, 20 * 60))
    let early = Plan.resume(pending, now: at(today, 20 * 60 + 3))
    let late = Plan.resume(pending, now: at(today.adding(days: 1), 7 * 60))
    let rewound = Plan.resume(pending, now: at(today, 19 * 60))
    check(!early.settle && early.state == pending && late.settle && late.state.awaySince == nil && rewound.settle
          && rewound.state.awaySince == nil && Plan.resume(Plan.State(), now: at(today, 0)).settle
          && at(today, 23 * 60).minutes(to: at(today.adding(days: 1), 60)) == 120,
          "重排撞上刚睡下：10 分钟内先不结算、等醒来；隔了好一阵或时钟回拨就当场收尾")
    // 关掉落笔提醒：没送到的记录、睡下的记录一并清掉
    var withAway = Plan.away(Plan.State(), at: at(today, 20 * 60))
    withAway.unseen = [today.key]
    check(Plan.disabled(withAway, .write).awaySince == nil && Plan.disabled(withAway, .write).unseen.isEmpty,
          "关掉落笔提醒：睡下与没送到的记录一并清掉")
    // 早先存下的记录没有 unseen / awaySince：照读，不整份作废；新记录存了再读回来一模一样
    let oldJSON = #"{"armedWrite":{"2026-10-21":1290},"armedHabits":{},"answered":[],"ignored":2,"noticePending":false}"#
    let old = try? JSONDecoder().decode(Plan.State.self, from: Data(oldJSON.utf8))
    let full = Plan.back(Plan.away(edge, at: at(today, 20 * 60)), at: at(today.adding(days: 1), 22 * 60))
    let fullAway = Plan.away(full, at: at(today.adding(days: 1), 23 * 60))
    let roundTrip = (try? JSONEncoder().encode(fullAway)).flatMap { try? JSONDecoder().decode(Plan.State.self, from: $0) }
    check(old?.ignored == 2 && old?.armedWrite == ["2026-10-21": 1290] && old?.unseen == [] && old?.awaySince == nil
          && roundTrip == fullAway && fullAway.unseen.count == 2 && fullAway.awaySince != nil,
          "排程记录：早先存的（缺新字段）照读；带睡眠记录的存了再读回来一模一样")
}

// MARK: r1-ritual：#4 首页落笔卡——晨课一愿、问心签、晚课三省（Core/DailyPrompts.swift）
do {
    let oct22 = LocalDay(key: "2026-10-22")!
    func hm(_ text: String) -> Int { ClockTime.minutes(from: text)! }

    // 1. 时段：晨 05:00–10:59 / 昼 11:00–17:59 / 暮夜 18:00–04:59；晚课 00:00–04:59 记前一天（与暮夜同在 05:00 分界）
    let phases: [(String, DailyRitePhase)] = [("00:00", .evening), ("03:59", .evening), ("04:00", .evening), ("04:59", .evening),
                                              ("05:00", .morning), ("07:30", .morning), ("10:59", .morning), ("11:00", .daytime),
                                              ("14:00", .daytime), ("17:59", .daytime), ("18:00", .evening), ("21:30", .evening), ("23:59", .evening)]
    let wrongPhase = phases.filter { DailyRite.phase(minute: hm($0.0)) != $0.1 }.map(\.0)
    check(wrongPhase.isEmpty && DailyRite.phase(minute: 1440 + 450) == .morning && DailyRite.phase(minute: -30) == .evening,
          "落笔卡时段：晨 05:00–10:59、昼 11:00–17:59、暮夜 18:00–04:59（越界按天取模）：\(wrongPhase)")
    check(DailyRite.ritualDay(minute: hm("00:00"), today: oct22).key == "2026-10-21"
          && DailyRite.ritualDay(minute: hm("03:59"), today: oct22).key == "2026-10-21"
          && DailyRite.ritualDay(minute: hm("04:30"), today: oct22).key == "2026-10-21"
          && DailyRite.ritualDay(minute: hm("04:59"), today: oct22).key == "2026-10-21"
          && DailyRite.ritualDay(minute: hm("05:00"), today: oct22) == oct22
          && DailyRite.ritualDay(minute: hm("21:30"), today: oct22) == oct22
          && DailyRite.ritualDay(minute: hm("00:30"), today: LocalDay(key: "2026-01-01")!).key == "2025-12-31",
          "晚课记到哪天：00:00–04:59 记前一天（跨年也对），05:00 起记今天")
    // 暮夜里每一分钟（18:00 到次日 04:59）晚课都记到同一天：凌晨 04:30 写的“明日第一件事”，05:00 晨课读“昨夜所定”正好读到
    let eveningMinutes = Array(18 * 60..<1440).map { (oct22, $0) } + Array(0..<5 * 60).map { (oct22.adding(days: 1), $0) }
    let eveningDays = Set(eveningMinutes.map { DailyRite.ritualDay(minute: $0.1, today: $0.0) })
    let morningDays = Set((5 * 60..<11 * 60).map { DailyRite.ritualDay(minute: $0, today: oct22.adding(days: 1)) })
    check(eveningDays == [oct22] && eveningMinutes.allSatisfy { DailyRite.phase(minute: $0.1) == .evening }
          && morningDays == [oct22.adding(days: 1)],
          "时段与晚课的日子同在 05:00 分界：一整段暮夜都记到同一天，第二天晨课的“昨夜所定”读的就是这一天")

    // 2. 题库：≥150 题、七类各 ≥15、签号与签文都不重复、一句一问、不写“失败 / 中断 / 漏打”、不含「」（答签靠它认）
    let all = DailyPrompts.all
    let perCategory = DailyPrompts.Category.allCases.map { c in all.filter { $0.category == c }.count }
    let banned = ["失败", "中断", "漏打", "天没写"]
    let badText = all.filter { p in
        !p.text.hasSuffix("？") || p.text.count > 30 || p.text.contains("「") || p.text.contains("」") || banned.contains { p.text.contains($0) }
    }.map(\.text)
    check(all.count >= 150 && perCategory.allSatisfy { $0 >= 15 } && Set(all.map(\.id)).count == all.count
          && Set(all.map(\.text)).count == all.count && badText.isEmpty
          && all.allSatisfy { $0.id / 100 == $0.category.rawValue && DailyPrompts.prompt(id: $0.id) == $0 },
          "问心签题库：\(all.count) 题，七类各 \(perCategory)，签号 = 类别×100+序号、不重复，句句是一问：\(badText)")
    let examples = ["今天哪一刻最专注？", "今天最想感谢的一个人是谁？", "这周花得最值的一笔钱是什么？", "今天身体哪里在提醒你？",
                    "今天卡住你的是事，还是心？", "如果今天重来一次，你会先做哪件事？", "今天学到的一个小东西是？",
                    "今天有没有一刻觉得“刚刚好”？", "最近反复想起的一件事是？", "今天对自己说过最好的一句话是？",
                    "明天想少做的一件事是？", "今天和谁说话最舒服？"]
    check(examples.allSatisfy { e in all.contains { $0.text == e } }, "问心签题库收了设计说明里的 12 个示例")

    // 3. 轮换：同一天同一签；相邻两天不同类；一轮之内不重复；换一签换成别的、换一类
    let rotation = DailyPrompts.rotation
    check(rotation.count == all.count && Set(rotation.map(\.id)).count == all.count, "轮换次序含全部签、各一次")
    let days = (0..<all.count).map { oct22.adding(days: $0) }
    let picks = days.map { DailyPrompts.pick(on: $0) }
    let sameCategoryNeighbours = zip(picks, picks.dropFirst()).filter { $0.category == $1.category }.count
    check(DailyPrompts.pick(on: oct22) == DailyPrompts.pick(on: oct22) && Set(picks.map(\.id)).count == all.count && sameCategoryNeighbours == 0,
          "问心签按日期轮换：同一天总是同一签，连续 \(all.count) 天不重复，相邻两天不同类（同类相邻 \(sameCategoryNeighbours) 次）")
    let skipped = (0..<6).map { DailyPrompts.pick(on: oct22, skips: $0) }
    check(Set(skipped.map(\.id)).count == 6 && zip(skipped, skipped.dropFirst()).allSatisfy { $0.category != $1.category }
          && !skipped.dropFirst().contains(DailyPrompts.pick(on: oct22.adding(days: 1))),
          "换一签：连换 5 次支支不同、每次换一类，也不会换成明天的签")

    // 4. 答过的签：半年内（今天以前答的）不再抽到，今天答的仍是今天的签；半年后回来；全答过取最久以前的
    let today = DailyPrompts.pick(on: oct22)
    check(DailyPrompts.pick(on: oct22, answered: [today.id: oct22]) == today, "今天答的签仍是今天的签（卡上写“今日已答”，不会一答就换掉）")
    let tomorrowBase = DailyPrompts.pick(on: oct22.adding(days: 1))
    check(DailyPrompts.pick(on: oct22.adding(days: 1), answered: [tomorrowBase.id: oct22]) != tomorrowBase
          && DailyPrompts.pick(on: oct22.adding(days: 1), answered: [tomorrowBase.id: oct22.adding(days: -200)]) == tomorrowBase
          && DailyPrompts.pick(on: oct22.adding(days: 1), answered: [tomorrowBase.id: oct22.adding(days: -180)]) != tomorrowBase,
          "答过的签半年（183 天）内不再抽到，过了半年回来")
    var everything: [Int: LocalDay] = [:]
    for (index, prompt) in all.enumerated() { everything[prompt.id] = oct22.adding(days: -1 - index % 100) }
    let fallback = DailyPrompts.pick(on: oct22, answered: everything)
    let todayCategory = DailyPrompts.pick(on: oct22).category
    let oldestInCategory = all.filter { $0.category == todayCategory }.compactMap { everything[$0.id] }.min()!
    check(fallback.category == todayCategory && everything[fallback.id] == oldestInCategory,
          "半年里整个题库都答过：取今天这一类里最久以前答过的那一签（不换类，相邻两天照样不同类）：\(fallback.text)")
    // 答过的那一格顺延时留在同一类里，不挪到下一格（那是明天的格）
    let laterBase = DailyPrompts.pick(on: oct22.adding(days: 30))
    let moved = DailyPrompts.pick(on: oct22.adding(days: 30), answered: [laterBase.id: oct22])
    check(moved != laterBase && moved.category == laterBase.category && moved != DailyPrompts.pick(on: oct22.adding(days: 31))
          && moved != DailyPrompts.pick(on: oct22.adding(days: 29)) && DailyPrompts.categoryStride(22) == 9
          && DailyPrompts.categoryStride(1) == 1 && DailyPrompts.categoryStride(2) == 1,
          "答过的签顺延：在同一类里隔 9 道取没答过的，不是明天、昨天的签")

    // 4b. 模拟两年：各种答签习惯（隔天答、三天答两天、天天答、只答第一天、隔几天换几次签），
    //     每天显示的签都要和前一天不同题、不同类；半年内答过的不再出现（除非这一类半年里都答过了）
    func simulate(_ days: Int, answerOn: (Int) -> Bool, skipsOn: (Int) -> Int) -> (repeats: Int, sameCategory: Int, quietShown: Int, first: String) {
        var answered: [Int: LocalDay] = [:]
        var previous: DailyPrompt?
        var repeats = 0, sameCategory = 0, quietShown = 0
        var first = ""
        for index in 0..<days {
            let day = oct22.adding(days: index)
            let shown = DailyPrompts.pick(on: day, skips: skipsOn(index), answered: answered)
            func isQuiet(_ p: DailyPrompt) -> Bool {
                guard let when = answered[p.id], when < day else { return false }
                return when.days(to: day) < DailyPrompts.quietDays
            }
            if isQuiet(shown) && !all.filter({ $0.category == shown.category }).allSatisfy(isQuiet) { quietShown += 1 }
            if let previous {
                if previous == shown {
                    repeats += 1
                    if first.isEmpty { first = day.key + "「\(shown.text)」" }
                } else if previous.category == shown.category {
                    sameCategory += 1
                    if first.isEmpty { first = day.key + " 同类" }
                }
            }
            if answerOn(index) { answered[shown.id] = day }
            previous = shown
        }
        return (repeats, sameCategory, quietShown, first)
    }
    let habits: [(String, (Int) -> Bool, (Int) -> Int)] = [
        ("不答", { _ in false }, { _ in 0 }),
        ("隔天答", { $0 % 2 == 0 }, { _ in 0 }),
        ("三天答两天", { $0 % 3 != 2 }, { _ in 0 }),
        ("天天答", { _ in true }, { _ in 0 }),
        ("只答第一天", { $0 == 0 }, { _ in 0 }),
        ("每三天换几次签再答", { $0 % 3 == 0 }, { $0 % 3 == 0 ? 1 + ($0 / 3) % 6 : 0 }),
        ("天天答、隔几天换签", { _ in true }, { $0 % 4 == 1 ? 1 + $0 % 5 : 0 }),
    ]
    var simBad: [String] = []
    for (name, answerOn, skipsOn) in habits {
        let result = simulate(730, answerOn: answerOn, skipsOn: skipsOn)
        if result.repeats + result.sameCategory + result.quietShown > 0 {
            simBad.append("\(name)：同题相邻 \(result.repeats)、同类相邻 \(result.sameCategory)、半年内答过又出 \(result.quietShown)，首次 \(result.first)")
        }
    }
    check(simBad.isEmpty, "问心签模拟两年（7 种答签习惯）：相邻两天从不同题、不同类，半年内答过的不再出现：\(simBad)")
    // 换一签：不论换几次，都不和昨天、明天的签同类
    let neighbourClash = (0..<40).flatMap { offset -> [Int] in
        let day = oct22.adding(days: offset)
        let around = [DailyPrompts.pick(on: day.adding(days: -1)).category, DailyPrompts.pick(on: day.adding(days: 1)).category]
        return (1...12).filter { around.contains(DailyPrompts.pick(on: day, skips: $0).category) }
    }
    check(neighbourClash.isEmpty, "换一签换几次都不会换成昨天、明天那一类：\(neighbourClash.count) 次撞类")

    // 5. 答此签：开头插「签文」；已插过不重复；换签后再答换掉旧签、留下正文；认得出正文在答哪一签
    let q = all[0], q2 = all[30]
    let once = DailyPrompts.insertingAnswer(q, into: "")
    check(once == "「\(q.text)」\n" && DailyPrompts.insertingAnswer(q, into: once) == once
          && DailyPrompts.insertingAnswer(q, into: "下午去了图书馆") == "「\(q.text)」\n下午去了图书馆"
          && DailyPrompts.insertingAnswer(q2, into: "「\(q.text)」\n写到一半") == "「\(q2.text)」\n写到一半",
          "答此签：正文开头插「签文」加换行；已插过不再插；换签后再答只换掉旧签，写的字留着")
    check(DailyPrompts.answered(in: "  \n「\(q.text)」\n上午三个小时") == q && DailyPrompts.answered(in: "「不是题库里的话」\n…") == nil
          && DailyPrompts.answered(in: "今天\(q.text)") == nil && DailyPrompts.answered(in: "「\(q.text)") == nil,
          "认答签：正文（去掉开头空白）以「签文」开头才算；题库外的、没写在开头的、没合上的都不算")

    // 6. 答过的记法：签号字符串 → 日期，最多 400 条，丢最早的；写坏的条目跳过
    var raw: [String: Any] = ["101": "2026-01-01", "x": "2026-01-02", "102": 5, "103": "坏日期"]
    check(DailyPrompts.decodeAnswered(raw) == [101: LocalDay(key: "2026-01-01")!], "答过的签：读偏好时写坏的条目跳过")
    let q3 = all[25]
    raw = DailyPrompts.recording(q3.id, on: oct22, into: raw)
    check(q3.id != 101 && raw.count == 2 && raw[String(q3.id)] as? String == "2026-10-22" && raw["101"] as? String == "2026-01-01",
          "记下答签：签号 → 日期（原有的照留）")
    var many: [String: Any] = [:]
    for index in 0..<400 { many[String(1000 + index)] = oct22.adding(days: -500 + index).key }
    let trimmed = DailyPrompts.recording(q.id, on: oct22, into: many)
    check(trimmed.count == 400 && trimmed[String(q.id)] == "2026-10-22" && trimmed["1000"] == nil && trimmed["1399"] != nil,
          "答过的签最多留 400 条：满了丢最早答的")

    // 7. 晚课三省合成日省：空段不写；有一愿时写“已成 / 未成”；三格全空不合成（只有一愿也不算）
    let full = DailyRite.eveningReview(vow: " 写完第三章 3 页 ", vowDone: true, done: "第三章写到第 3 页\n图也重画了", stuck: "  ", next: "先改第二节")
    check(full == "【今日一愿】写完第三章 3 页（已成）\n【所得】第三章写到第 3 页\n图也重画了\n【下一步】先改第二节",
          "晚课合成日省：一愿带“（已成）”，空的“所失”不写，段名与复盘模板同一套：\(full ?? "nil")")
    check(DailyRite.eveningReview(vow: "跑完 5 公里", vowDone: false, done: "", stuck: "腿疼", next: "")
            == "【今日一愿】跑完 5 公里（未成）\n【所失】腿疼"
          && DailyRite.eveningReview(vow: "跑完\n5 公里", vowDone: nil, done: "a", stuck: "b", next: "c")
            == "【今日一愿】跑完 5 公里\n【所得】a\n【所失】b\n【下一步】c"
          && DailyRite.eveningReview(vow: "", vowDone: true, done: "a", stuck: "", next: "") == "【所得】a"
          && DailyRite.eveningReview(vow: "写完第三章", vowDone: true, done: " ", stuck: "\n", next: "") == nil,
          "晚课合成：未成写“（未成）”、没勾不写、没有一愿不写那一行；三格全空不合成")
    let digest = SnapshotDigest.reviewPoints(full ?? "")
    check(digest.contains("下一步：先改第二节"), "合成的日省快照照样摘得出“下一步”：\(digest)")

    // 8. 一愿写法、类型不再沿用、过期的按日记录
    check(DailyRite.cleanVow("  写完\n第三章  ") == "写完 第三章" && DailyRite.cleanVow(String(repeating: "愿", count: 80)).count == 60
          && DailyRite.cleanVow(" \n ").isEmpty, "一愿：去掉首尾空白、换行并成一行、最多 60 字")
    check(DailyRite.composerKind(.note, draftBlank: true) == .diary && DailyRite.composerKind(.review, draftBlank: true) == .diary
          && DailyRite.composerKind(.note, draftBlank: false) == .note && DailyRite.composerKind(.diary, draftBlank: true) == .diary,
          "首页落笔类型不再沿用：入卷后、或打开时草稿是空的都回到日记；写了一半的保留原类型")
    let keys = ["dashboard.vow.2026-10-22", "dashboard.vow.2026-08-23", "dashboard.vow.2026-08-22", "dashboard.vowDone.2026-01-01",
                "dashboard.nextFirst.2026-10-21", "prompts.skip.2026-10-22", "prompts.skip.2026-10-21", "dashboard.vow.坏日期",
                "dashboard.evening.open", "prompts.answered", "draft.dashboard.vow", "draft.dashboard.vow.2026-10-22",
                "draft.dashboard.vow.2026-10-21", "draft.dashboard.vow.2026-10-20", "draft.dashboard.vow.坏日期"]
    check(DailyRite.staleKeys(keys, today: oct22) == ["dashboard.vow.2026-08-22", "dashboard.vowDone.2026-01-01",
                                                      "draft.dashboard.vow.2026-10-20", "prompts.skip.2026-10-21"],
          "过期清理：一愿、已成与否、明日第一件事留 60 天，换签次数只留今天，立愿草稿留到第二天；日期写坏的与别的键不动：\(DailyRite.staleKeys(keys, today: oct22))")
    check(DailyRite.vowKey(oct22) == "dashboard.vow.2026-10-22" && DailyRite.nextFirstKey(oct22) == "dashboard.nextFirst.2026-10-22"
          && DailyRite.skipKey(oct22) == "prompts.skip.2026-10-22" && DailyRite.eveningDraftKey("next") == "draft.dashboard.evening.next"
          && DailyRite.vowDraftKey(oct22) == "draft.dashboard.vow.2026-10-22",
          "偏好键名与设计说明一致（dashboard.vow.<日期>、prompts.skip.<日期>、draft.dashboard.evening.*；立愿草稿按日期 draft.dashboard.vow.<日期>）")

    // 9. 晚课三格开不开（只在进页、换到暮夜、换一天时判定一次）：暮夜 + 开关开着 + 正文框空着 + 这一晚还没合成才自动打开；
    //    三格里写着字时跨过 05:00 也不收，仍记到开始写的那一晚；查“合成过没有”只在前几条都满足时才查
    var savedAsked = 0
    func panel(_ current: LocalDay?, blank: Bool = true, _ phase: DailyRitePhase = .evening, on: Bool = true,
               written: Bool = false, saved: Bool = false) -> LocalDay? {
        DailyRite.eveningPanel(current: current, draftsBlank: blank, phase: phase, ritualDay: oct22, switchOn: on,
                               bodyWritten: written, saved: { savedAsked += 1; return saved })
    }
    let oct21 = oct22.adding(days: -1)
    check(panel(nil) == oct22 && panel(nil, written: true) == nil && panel(nil, saved: true) == nil && panel(nil, on: false) == nil
          && panel(nil, .daytime) == nil && panel(nil, .morning) == nil,
          "晚课三格：暮夜、开关开着、正文框空着、这一晚还没合成入卷才自动打开；正文写了字、已合成、开关关着、不在暮夜都收着")
    let askedBefore = savedAsked
    _ = panel(nil, .morning); _ = panel(nil, written: true); _ = panel(nil, on: false)
    check(savedAsked == askedBefore, "晚课三格：不在暮夜、正文写了字、开关关着时不去查修行录")
    check(panel(oct21, blank: false, .morning, written: true, saved: true) == oct21 && panel(oct21, blank: true, .morning) == nil
          && panel(oct22, blank: true, written: true) == nil,
          "晚课三格：三格里正写着字时跨过 05:00 也留着（仍记到 10月21日那一晚）；三格空着就按此刻重新判定")
}

// MARK: r1-home：今日洞府首页结构——数量型“3/8 杯 +1”、功课多时收起已圆满、两栏最多多拉 160、旧笔新读取哪几天与写法
do {
    // 1. “+1”的步长：目标 ≤ 20 加 1，≤ 120 加 5，更大加八分之一（取整）；按钮上写实际步长
    let steps: [(Double, Double)] = [(8, 1), (20, 1), (2.5, 1), (0, 1), (-3, 1), (21, 5), (90, 5), (120, 5), (121, 15), (8000, 1000), (10000, 1250)]
    let wrong = steps.filter { DashboardRules.quantityStep(target: $0.0) != $0.1 }
    check(wrong.isEmpty, "首页 +1 步长：8 杯 +1、90 分钟 +5、8000 步 +1000（不对的：\(wrong.map { "\($0.0)→\(DashboardRules.quantityStep(target: $0.0))" })）")
    check(DashboardRules.stepLabel(1) == "+1" && DashboardRules.stepLabel(5) == "+5" && DashboardRules.stepLabel(1000) == "+1000",
          "首页 +1 按钮上写实际步长：+1 / +5 / +1000")
    check(DashboardRules.quantityText(done: 3, target: 8, unit: "杯") == "3/8 杯"
          && DashboardRules.quantityText(done: 0, target: 8000, unit: "步") == "0/8000 步"
          && DashboardRules.quantityText(done: 2.5, target: 8, unit: "") == "2.5/8"
          && DashboardRules.quantityText(done: 1.234, target: 2, unit: " 升 ") == "1.23/2 升"
          && DashboardRules.quantityText(done: -1, target: 8, unit: "杯") == "0/8 杯",
          "首页功课行尾写“3/8 杯”：整数不带小数点，小数最多两位，没有单位只写“2.5/8”")

    // 2. 功课多时收起已圆满：要做的超过 6 项、且至少圆满一项
    check(DashboardRules.foldsDone(due: 12, done: 7) && DashboardRules.foldsDone(due: 7, done: 1)
          && !DashboardRules.foldsDone(due: 6, done: 3) && !DashboardRules.foldsDone(due: 12, done: 0),
          "首页功课：12 项里圆满 7 项时收成“已圆满 7 项”；6 项以内、或一项都没圆满时不收")

    // 3. 两栏不再强行等高：较矮那栏的最后一张最多多拉 160
    check(DashboardRules.stretch(column: 224, other: 1300) == 160 && DashboardRules.stretch(column: 900, other: 1000) == 100
          && DashboardRules.stretch(column: 1000, other: 900) == 0 && DashboardRules.stretch(column: 500, other: 500) == 0,
          "首页两栏：比另一栏矮 1076 时只多拉 160，矮 100 时正好齐平，不比另一栏矮时不拉")

    // 4. 旧笔新读取哪几天：一年前、半年前、一月前、一周前（先远后近），各自前后放宽一天，先看正好那天、再前一天、再后一天
    let thu = LocalDay(key: "2026-10-22")!
    let spans = DashboardRules.lookBackSpans(today: thu)
    check(spans.map(\.label) == ["一年前", "半年前", "一月前", "一周前"]
          && spans.map(\.day.key) == ["2025-10-22", "2026-04-22", "2026-09-22", "2026-10-15"],
          "旧笔新读：2026-10-22 往前看 2025-10-22、2026-04-22、2026-09-22、2026-10-15")
    check(DashboardRules.monthAgo(1, today: LocalDay(key: "2026-03-31")!).key == "2026-02-28"
          && DashboardRules.monthAgo(6, today: LocalDay(key: "2026-08-31")!).key == "2026-02-28"
          && DashboardRules.monthAgo(12, today: LocalDay(key: "2028-02-29")!).key == "2027-02-28"
          && DashboardRules.monthAgo(1, today: LocalDay(key: "2026-01-15")!).key == "2025-12-15",
          "旧笔新读：那个月没有这一天时取月底（3月31日的一月前是2月28日），跨年照算")
    let keys = DashboardRules.lookBackKeys(today: thu)
    check(keys.count == 12 && Set(keys).count == 12 && keys.contains("2025-10-21") && keys.contains("2026-10-16"),
          "旧笔新读：一次只查 12 个日期（四个时点各前后一天）")
    let found = DashboardRules.lookBackFound(today: thu, written: ["2025-10-22", "2026-04-23", "2026-04-21", "2026-10-14", "2026-10-16"])
    check(found.map(\.label) == ["一年前", "半年前", "一周前"]
          && found.map(\.day.key) == ["2025-10-22", "2026-04-21", "2026-10-14"] && found.map(\.exact) == [true, false, false],
          "旧笔新读：正好那天优先，否则前一天先于后一天；一月前没写就跳过")
    check(DashboardRules.spanEyebrow("一年前", day: LocalDay(key: "2025-10-22")!, exact: true) == "一年前的今天 · 周三"
          && DashboardRules.spanEyebrow("一周前", day: LocalDay(key: "2026-10-14")!, exact: false) == "一周前 · 周三",
          "旧笔新读眉题：“一年前的今天 · 周三”；放宽了一天的写“一周前 · 周三”")
    check(DashboardRules.olderCutoff(today: thu).key == "2026-10-15"
          && DashboardRules.age(from: LocalDay(key: "2026-10-12")!, to: thu) == "10 日前"
          && DashboardRules.age(from: LocalDay(key: "2026-07-14")!, to: thu) == "3 个月前"
          && DashboardRules.age(from: LocalDay(key: "2024-10-22")!, to: thu) == "2 年前"
          && DashboardRules.pinnedEyebrow(day: LocalDay(key: "2026-07-14")!, today: thu) == "珍藏 · 3 个月前"
          && DashboardRules.olderEyebrow(day: LocalDay(key: "2026-10-12")!, today: thu) == "10 日前 · 周一",
          "旧笔新读：珍藏、旧笔只取 7 天以前的；眉题写“珍藏 · 3 个月前”“10 日前 · 周一”")

    // 5. 摘句、落款、按日期固定的位置
    let long = String(repeating: "山", count: 70)
    check(DashboardRules.excerpt(long) == String(repeating: "山", count: 60) + "……"
          && DashboardRules.excerpt("  第一行\n\n  第二行  \n") == "第一行 第二行"
          && DashboardRules.excerpt(String(repeating: "水", count: 60)) == String(repeating: "水", count: 60)
          && DashboardRules.excerpt("") == "",
          "旧笔新读摘句：前 60 字加“……”，换行并成一个空格，不到 60 字原样")
    check(DashboardRules.signature(kindLabel: nil, mood: 4, day: LocalDay(key: "2025-10-22")!) == "心境 晴 · 2025年10月22日"
          && DashboardRules.signature(kindLabel: nil, mood: nil, day: LocalDay(key: "2025-10-22")!) == "2025年10月22日"
          && DashboardRules.signature(kindLabel: "灵感", mood: 9, day: LocalDay(key: "2026-01-02")!) == "灵感 · 2026年1月2日",
          "旧笔新读落款：“心境 晴 · 2025年10月22日”；没记心境只写日期，灵感、复盘在前面写类型")
    let indices = (0..<30).map { DashboardRules.dailyIndex(thu.adding(days: $0), count: 7) }
    check(DashboardRules.dailyIndex(thu, count: 7) == DashboardRules.dailyIndex(LocalDay(key: "2026-10-22")!, count: 7)
          && indices.allSatisfy { (0..<7).contains($0) } && Set(indices).count == 7 && DashboardRules.dailyIndex(thu, count: 0) == 0,
          "旧笔新读：按日期固定挑一篇（同一天总是同一篇，换一天顺延，七篇轮得到每一篇）")
    check(DashboardRules.rotation(count: 5, start: 3, limit: 12) == [3, 4, 0, 1, 2] && DashboardRules.rotation(count: 20, start: 18, limit: 4) == [18, 19, 0, 1]
          && DashboardRules.rotation(count: 0, start: 0, limit: 5).isEmpty,
          "旧笔新读“换一篇”：从固定的那篇起绕一圈，最多取 limit 篇")
    check(EmptyCopy.isOneSentence(DashboardRules.waitingLine) && !DashboardRules.waitingLine.contains("没") && !DashboardRules.waitingLine.contains("失败"),
          "旧笔新读等待语合“一句话”写法：\(DashboardRules.waitingLine)")
}

// MARK: r1-menubar：菜单栏小窗上半段“今日”的取舍与说法（MenuBarDigest）
do {
    typealias Item = MenuBarDigest.HabitItem
    func item(_ title: String, due: Bool = true, done: Bool = false, keep: Bool = false) -> Item {
        Item(title: title, due: due, achieved: done, keepShown: keep)
    }

    // 1. “+1”步长与首页同一规则；数量写法（与首页同样最多两位小数）、签上的进度、按钮字样（半角加号，与首页、功课页一致）
    let steps: [(Double, Double)] = [(8, 1), (20, 1), (21, 5), (120, 5), (121, 15), (8000, 1000), (10000, 1250), (0, 1), (-3, 1), (.nan, 1)]
    let badSteps = steps.filter { MenuBarDigest.step(target: $0.0) != $0.1 }.map { "\($0.0)→\(MenuBarDigest.step(target: $0.0))" }
    check(badSteps.isEmpty, "小窗 +1 步长：目标 ≤20 加 1、≤120 加 5、更大加目标的 1/8（8000 步 → 1000）\(badSteps.isEmpty ? "" : "：\(badSteps)")")
    let numbers = [3, 2.5, 2.25, 1.25, 1.0 / 3, 0.1, 1000, 2.999, -0.001, .infinity, .nan].map { MenuBarDigest.number($0) }
    check(numbers == ["3", "2.5", "2.25", "1.25", "0.33", "0.1", "1000", "3", "0", "0", "0"]
          && MenuBarDigest.progress(quantity: 3, target: 8, unit: "杯") == "3/8 杯"
          && MenuBarDigest.progress(quantity: nil, target: 10, unit: "分钟") == "0/10 分钟"
          && MenuBarDigest.progress(quantity: 2.5, target: 3, unit: "") == "2.5/3"
          && MenuBarDigest.progress(quantity: 1.25, target: 2, unit: "升") == "1.25/2 升"
          && MenuBarDigest.stepLabel(target: 8000) == "+1000" && MenuBarDigest.stepLabel(target: 8) == "+1"
          && MenuBarDigest.stepLabel(target: 60) == "+5" && !MenuBarDigest.stepLabel(target: 8).contains("＋"),
          "小窗功课签：“3/8 杯”“0/10 分钟”“1.25/2 升”，整数不带小数点、小数最多两位（\(numbers.joined(separator: " "))），按钮写半角“+1”“+1000”")

    // 2. 标题行：时辰与首页问候同一套；“功课 2/5 · 已落 1 篇”，没有要做的功课只写落笔，还没写写“尚未落笔”
    check(MenuBarDigest.heading(minute: 15 * 60) == "今日 · 申时" && MenuBarDigest.heading(minute: 23 * 60 + 30) == "今日 · 子时"
          && MenuBarDigest.heading(minute: 0) == "今日 · 子时" && MenuBarDigest.heading(minute: 60) == "今日 · 丑时"
          && MenuBarDigest.heading(minute: 9 * 60 + 30) == "今日 · 巳时",
          "小窗标题：申时（15:00）、子时（23:30、00:00）、丑时（01:00）、巳时（09:30）")
    let summaries = [MenuBarDigest.summary(done: 2, due: 5, entries: 1), MenuBarDigest.summary(done: 0, due: 0, entries: 0),
                     MenuBarDigest.summary(done: 3, due: 3, entries: 0), MenuBarDigest.summary(done: 0, due: 0, entries: 4)]
    check(summaries == ["功课 2/5 · 已落 1 篇", "尚未落笔", "功课 3/3 · 尚未落笔", "已落 4 篇"]
          && !summaries.joined().contains { "漏失败断没".contains($0) },
          "小窗标题行：\(summaries.joined(separator: " ｜ "))（不说“没写”“漏打”）")

    // 3. 功课签的取舍
    check(MenuBarDigest.plan([]).state == .noHabits && MenuBarDigest.plan([]).due == 0, "小窗功课：一项都没立 → “还没有功课 · 立一项 →”")
    let rest = MenuBarDigest.plan([item("运动", due: false), item("练琴", due: false)])
    check(rest.state == .restDay && rest.chips.isEmpty && rest.doneTitles.isEmpty, "小窗功课：有功课但今天都不用打 → 且歇一歇")
    let allDone = MenuBarDigest.plan([item("冥想", done: true), item("运动", due: false), item("早睡", done: true)])
    check(allDone.state == .allDone && allDone.allDone && allDone.chips.isEmpty && allDone.doneTitles == ["冥想", "早睡"]
          && allDone.done == 2 && allDone.due == 2,
          "小窗功课：今天要做的都圆满 → 金字“功课圆满”（不用打的不算进 2/2）")
    let many = (1...8).map { item("功课\($0)") } + [item("早睡", done: true), item("读书", done: true), item("运动", due: false)]
    let manyPlan = MenuBarDigest.plan(many)
    check(manyPlan.state == .chips && manyPlan.chips == Array(0..<6) && manyPlan.overflow == 2 && manyPlan.doneTitles == ["早睡", "读书"]
          && manyPlan.done == 2 && manyPlan.due == 10 && !manyPlan.allDone,
          "小窗功课：未圆满的按原次序列前 6 枚，“另有 2 项”，已圆满的另成一行（功课 2/10）")
    // 刚在小窗里打上卡的留在原位；全打完了签还在，签下方写“功课圆满”（签不挪）
    let kept = MenuBarDigest.plan([item("冥想", done: true, keep: true), item("喝水"), item("早睡", done: true)])
    check(kept.state == .chips && kept.chips == [0, 1] && kept.doneTitles == ["早睡"] && kept.overflow == 0 && kept.done == 2,
          "小窗功课：刚打上卡的冥想留在原位（不挪进“已圆满”），早睡照旧在“已圆满”一行")
    let keptAll = MenuBarDigest.plan([item("冥想", done: true, keep: true), item("喝水", done: true, keep: true)])
    check(keptAll.state == .chips && keptAll.allDone && keptAll.chips == [0, 1] && keptAll.doneTitles.isEmpty,
          "小窗功课：在小窗里打完最后一项，签留着、签下方写“功课圆满”")
    let keptOver = MenuBarDigest.plan([item("冥想", done: true, keep: true)] + (1...7).map { item("功课\($0)") })
    check(keptOver.chips == Array(0..<6) && keptOver.overflow == 2 && keptOver.doneTitles.isEmpty,
          "小窗功课：留在原位的也占 6 枚里的一枚，未列出的未圆满项照实写“另有 2 项”")
    check(MenuBarDigest.doneLine([]) == nil && MenuBarDigest.doneLine(["运动", "早睡"]) == "已圆满：运动、早睡"
          && MenuBarDigest.doneLine(["甲", "乙", "丙", "丁", "戊", "己"]) == "已圆满：甲、乙、丙、丁 等 6 项",
          "小窗“已圆满”一行：列名字，多于 4 项写“等 N 项”")

    // 4. 下一项：今天还没开始的第一项（按开始时刻，同时刻按原次序）优先；都开始了看正在进行的；再看全天的
    typealias Slot = MenuBarDigest.Slot
    let day = [Slot(start: 14 * 60, end: 15 * 60, title: "组会"), Slot(start: 9 * 60, end: 10 * 60, title: "早会"),
               Slot(start: nil, end: nil, title: "交报告")]
    check(MenuBarDigest.next(day, now: 8 * 60) == .upcoming(1, minutes: 60)
          && MenuBarDigest.next(day, now: 9 * 60 + 30) == .upcoming(0, minutes: 270)
          && MenuBarDigest.next(day, now: 14 * 60) == .running(0, minutes: 60)
          && MenuBarDigest.next(day, now: 14 * 60 + 30) == .running(0, minutes: 30)
          && MenuBarDigest.next(day, now: 15 * 60) == .allDay(2)
          && MenuBarDigest.next(Array(day.prefix(2)), now: 15 * 60) == .none
          && MenuBarDigest.next([], now: 600) == .none,
          "小窗下一项：输入不按时刻排也找得对；9:30 早会进行中仍先报还没开始的组会；14:00 整算进行中；散了只剩全天；都没有为空")
    let tie = [Slot(start: 600, end: nil, title: "甲"), Slot(start: 600, end: 660, title: "乙")]
    check(MenuBarDigest.next(tie, now: 540) == .upcoming(0, minutes: 60) && MenuBarDigest.next(tie, now: 600) == .running(0, minutes: nil)
          && MenuBarDigest.next([Slot(start: 600, end: nil, title: "电话")], now: 601) == .none,
          "小窗下一项：同一时刻按原次序；没有结束时间的只在开始那一分钟算进行中")
    check(MenuBarDigest.nextLine(day, now: 12 * 60 + 40) == .init(label: "下一项", text: "14:00–15:00 组会", detail: "还有 1 时 20 分")
          && MenuBarDigest.nextLine(day, now: 14 * 60 + 30) == .init(label: "进行中", text: "14:00–15:00 组会", detail: "还剩 30 分")
          && MenuBarDigest.nextLine(day, now: 16 * 60) == .init(label: "今日全天", text: "交报告", detail: "")
          && MenuBarDigest.nextLine([], now: 600) == .init(label: "", text: "今日已无安排", detail: "")
          && MenuBarDigest.nextLine([Slot(start: 700, end: nil, title: "")], now: 600) == .init(label: "下一项", text: "11:40 （未命名日程）", detail: "还有 1 时 40 分")
          && MenuBarDigest.nextLine([Slot(start: 600, end: nil, title: "电话")], now: 600).detail == "",
          "小窗下一项那一行：“下一项 14:00–15:00 组会 · 还有 1 时 20 分”、进行中写还剩、全天、今日已无安排、没名字的日程")
    let countdowns = [0, 1, 59, 60, 61, 125, 600].map { MenuBarDigest.countdown($0) }
    check(countdowns == ["还有 1 分", "还有 1 分", "还有 59 分", "还有 1 时", "还有 1 时 1 分", "还有 2 时 5 分", "还有 10 时"]
          && MenuBarDigest.countdown(30, prefix: "还剩") == "还剩 30 分",
          "小窗倒计时：\(countdowns.joined(separator: "、"))")

    // 5. 签下方写哪一行“功课圆满”：都圆满写金字（修为里也算圆满才带 +20）；只剩每周 N 次的签、修为里已算圆满，
    //    写一行金色小字（刚飘过“功课圆满”、加了修为，页面上要有对应的说明）；都不是不写
    check(MenuBarDigest.consummation(allDone: true, perfectToday: true) == .full(bonus: true)
          && MenuBarDigest.consummation(allDone: true, perfectToday: false) == .full(bonus: false)
          && MenuBarDigest.consummation(allDone: false, perfectToday: true) == .bonusOnly
          && MenuBarDigest.consummation(allDone: false, perfectToday: false) == .none
          && MenuBarDigest.bonusLine() == "功课圆满，今日额外 +\(CultivationEngine.perfectDayXP) 修为",
          "小窗“功课圆满”：全部圆满写金字、修为圆满才带 +20；只剩每周 N 次时写“\(MenuBarDigest.bonusLine())”")
    // 与首页说法对上：14d 那种“晨读打了、喝水记满、运动（每周 3 次）还没够”的一天，修为算圆满、小窗签还剩运动
    let weekPlan = MenuBarDigest.plan([item("晨读", done: true), item("喝水", done: true, keep: true), item("运动")])
    check(!weekPlan.allDone && weekPlan.chips == [1, 2]
          && MenuBarDigest.consummation(allDone: weekPlan.allDone, perfectToday: true) == .bonusOnly,
          "小窗“功课圆满”：只剩每周 N 次的运动时标题行仍写 2/3，签下方写一行金色小字")

    // 6. 记完自动收起：Esc 照常收；自动收起前这一小会儿里点过上半段就不收；没点过、或点得早照常收
    check(MenuBarDigest.autoCloses(escape: false, sinceTopAction: nil) && MenuBarDigest.autoCloses(escape: true, sinceTopAction: 0.2)
          && !MenuBarDigest.autoCloses(escape: false, sinceTopAction: 0.2) && !MenuBarDigest.autoCloses(escape: false, sinceTopAction: 2.9)
          && MenuBarDigest.autoCloses(escape: false, sinceTopAction: 10) && MenuBarDigest.autoCloses(escape: false, sinceTopAction: -5)
          && MenuBarDigest.autoCloseGrace >= 3,
          "小窗记完自动收起：在收起前点过打卡圈 / +1 就不收（记账约 3 秒内都算），按 Esc 照常收起")
}

// MARK: r1-habits：#7 功法谱（十二式、胶囊写法、已立）、“＋1”步长、最长连续 / 距纪录 / 打破纪录的那一下
do {
    let all = HabitTemplates.all
    check(all.count == 12 && Set(all.map(\.title)).count == 12 && Set(all.map(\.group)) == Set(HabitTemplates.groups)
          && HabitTemplates.grouped.map(\.group) == ["起居", "身体", "心神", "学业"]
          && HabitTemplates.grouped.map(\.items.count) == [3, 4, 1, 4],
          "功法谱：十二式、名称不重复，按起居 / 身体 / 心神 / 学业四组（3 / 4 / 1 / 4 式）")
    let chips = Dictionary(uniqueKeysWithValues: all.map { ($0.title, $0.chipText) })
    check(chips["喝水"] == "喝水 · 8 杯" && chips["运动"] == "运动 · 每周 3 次" && chips["早睡"] == "早睡"
          && chips["步数"] == "步数 · 8000 步" && chips["专注"] == "专注 · 90 分钟" && chips["冥想"] == "冥想 · 10 分钟",
          "功法谱胶囊：数量型写“喝水 · 8 杯”，每周 N 次写“运动 · 每周 3 次”，打卡型只写名称：\(chips["喝水"] ?? "nil")、\(chips["运动"] ?? "nil")")
    let focus = HabitTemplates.named("专注")
    let water = HabitTemplates.named(" 喝水 ")
    check(focus?.frequency == .weekdays && focus?.weekdays == [0, 1, 2, 3, 4] && focus?.scheduleText == "周一至周五"
          && focus?.detailText == "周一至周五 · 每次 90 分钟 · 上午先做最难的一件"
          && water?.targetValue == 8 && water?.unit == "杯" && water?.notes == "锚点：每顿饭后一杯"
          && HabitTemplates.named("运动")?.targetPerWeek == 3 && HabitTemplates.named("运动")?.targetValue == nil,
          "功法谱：专注周一至周五 90 分钟、喝水每天 8 杯（备注写锚点）、运动每周 3 次不带数量：\(focus?.detailText ?? "nil")")
    check(all.allSatisfy { $0.group != "" && !$0.symbol.isEmpty && ($0.targetValue == nil) == $0.unit.isEmpty },
          "功法谱：每式都有组名、图标；有数量的才有单位")
    check(HabitTemplates.starter.map(\.chipText) == ["早睡", "喝水 · 8 杯", "运动 · 每周 3 次", "冥想 · 10 分钟", "读书 · 20 页", "背单词 · 30 个"],
          "筑基三关的六式：\(HabitTemplates.starter.map(\.chipText))")
    let titles = ["  喝水", "晨读二十分钟", "Meditation"]
    check(HabitTemplates.isInstalled(water!, titles: titles) && !HabitTemplates.isInstalled(focus!, titles: titles)
          && HabitTemplates.isInstalled(HabitTemplate(group: "心神", title: "meditation", symbol: "leaf"), titles: titles),
          "已立：与现有功课同名（去首尾空白、不分大小写）才算，别的不算")

    // “＋1”步长：≤20 → 1；≤120 → 5；更大 → 目标的 1/8 取整
    let steps: [(Double?, Double)] = [(nil, 1), (0, 1), (8, 1), (20, 1), (2.5, 1), (20.5, 5), (30, 5), (90, 5), (120, 5),
                                      (300, 38), (8000, 1000), (121, 15), (1e9, 125_000_000)]
    let badSteps = steps.filter { HabitStepRule.step(forTarget: $0.0) != $0.1 }
    check(badSteps.isEmpty && HabitStepRule.label(forTarget: 8) == "+1" && HabitStepRule.label(forTarget: 8000) == "+1000"
          && HabitStepRule.label(forTarget: 30) == "+5" && HabitStepRule.step(forTarget: .infinity) == 1,
          "＋1 步长：8 杯 ＋1、30 分钟 ＋5、8000 步 ＋1000（按钮写实际步长）：不对的 \(badSteps.map { "\($0.0.map { String($0) } ?? "nil")" })")

    // 个人纪录：每天的冥想，9月20日起开始；9月21–25日连 5 天，9月28日–10月1日连 4 天，10月18–21日连 4 天，今天 10月22日
    let today = LocalDay(key: "2026-10-22")!
    let start = LocalDay(key: "2026-09-20")!
    func days(_ a: String, _ b: String) -> [LocalDay] { LocalDay.range(LocalDay(key: a)!, LocalDay(key: b)!) }
    func daily(_ done: [LocalDay], frequency: HabitFrequency = .daily, weekdays: [Int] = [], perWeek: Int = 1) -> HabitStats {
        HabitStats(spec: HabitSpec(frequency: frequency, targetPerWeek: perWeek, weekdays: weekdays, startDay: start),
                   logs: done.map { HabitLogValue(day: $0, completed: true, quantity: nil) }, today: today)
    }
    let history = days("2026-09-21", "2026-09-25") + days("2026-09-28", "2026-10-01") + days("2026-10-18", "2026-10-21")
    let before = daily(history), afterToday = daily(history + [today])
    check(HabitRecord.longest(before).count == 5 && HabitRecord.previousBest(before) == 5 && before.streak.count == 4
          && HabitRecord.longest(afterToday).count == 5 && HabitRecord.broken(before: before, after: afterToday) == nil,
          "个人纪录：最长连续 5 天（与长卷同一口径），今天打卡后当前 5 天只是追平，不算新纪录")
    let tied = daily(history + days("2026-10-17", "2026-10-17"))   // 10月17–21日已连 5 天（追平），今天再打就是 6 天
    let broke = daily(history + days("2026-10-17", "2026-10-17") + [today])
    let record = HabitRecord.broken(before: tied, after: broke)
    check(record?.count == 6 && record?.unit == "天" && HabitRecord.brokenText(title: "冥想", record!) == "新纪录 · 「冥想」连续 6 天",
          "打破纪录的那一下：旧纪录 5 天、昨天追平，今天打卡变 6 天 → “新纪录 · 「冥想」连续 6 天”：\(record.map { "\($0.count)\($0.unit)" } ?? "nil")")
    // 接着延续这段纪录：明天（看成新的今天）不再提示
    let nextDay = today.adding(days: 1)
    let longRun = history + days("2026-10-17", "2026-10-17") + [today]
    let extendBefore = HabitStats(spec: tied.spec, logs: longRun.map { HabitLogValue(day: $0, completed: true, quantity: nil) }, today: nextDay)
    let extendAfter = HabitStats(spec: tied.spec, logs: (longRun + [nextDay]).map { HabitLogValue(day: $0, completed: true, quantity: nil) }, today: nextDay)
    check(HabitRecord.previousBest(extendAfter) == 5 && HabitRecord.broken(before: extendBefore, after: extendAfter) == nil
          && HabitRecord.longest(extendAfter).count == 7,
          "纪录破了之后接着延续（7 天）不再每天提示；旧纪录仍按这一段之前的 5 天算")
    // 第一段就超过 3 天：没有旧纪录（之前没有 ≥3 的一段）不提示；旧纪录只有 2 天也不提示
    let fresh = days("2026-10-18", "2026-10-21")
    let shortOld = days("2026-09-21", "2026-09-22") + days("2026-10-19", "2026-10-21")
    check(HabitRecord.broken(before: daily(fresh), after: daily(fresh + [today])) == nil
          && HabitRecord.broken(before: daily(shortOld), after: daily(shortOld + [today])) == nil
          && HabitRecord.previousBest(daily(shortOld + [today])) == 2,
          "新纪录只在旧纪录 ≥3 时提示：头一段、旧纪录只有 2 天都不提示")
    // 取消今天的打卡、或今天本来就达标（数量型再加一点）：当前连续没有变长，不提示
    check(HabitRecord.broken(before: broke, after: tied) == nil && HabitRecord.broken(before: broke, after: broke) == nil,
          "取消今天的打卡、今天已达标再改数量：不提示新纪录")
    // 指定星期按“次”、每周 N 次按“周”
    let mwf = [0, 2, 4]
    let mwfDone = LocalDay.range(start, today.adding(days: -1)).filter { mwf.contains($0.weekdayIndex) }
    let gapDay = mwfDone[3]   // 第 4 个应打卡日没打：前 3 次一段（旧纪录 3 次），之后一直打到昨天
    let mwfHistory = mwfDone.filter { $0 != gapDay }
    let mwfBefore = daily(mwfHistory, frequency: .weekdays, weekdays: mwf)
    // 今天 10月22日是周四，不是应打卡日：看下一个应打卡日 10月23日（周五）
    let fri = LocalDay(key: "2026-10-23")!
    func weekdayStats(_ done: [LocalDay], on day: LocalDay) -> HabitStats {
        HabitStats(spec: mwfBefore.spec, logs: done.map { HabitLogValue(day: $0, completed: true, quantity: nil) }, today: day)
    }
    let mwfRun = mwfHistory.filter { $0 > gapDay }.count
    let mwfRecord = HabitRecord.broken(before: weekdayStats(mwfHistory, on: fri), after: weekdayStats(mwfHistory + [fri], on: fri))
    check(mwfRun == 10 && HabitRecord.previousBest(weekdayStats(mwfHistory, on: fri)) == 3 && mwfRecord == nil
          && HabitRecord.longest(weekdayStats(mwfHistory, on: fri)).unit == "次",
          "指定星期按“次”：旧纪录 3 次早已被这一段（\(mwfRun) 次）超过，再打一次不重复提示")
    let weeklySpec = HabitSpec(frequency: .weekly, targetPerWeek: 2, startDay: start)
    func weekly(_ done: [String], today: LocalDay) -> HabitStats {
        HabitStats(spec: weeklySpec, logs: done.map { HabitLogValue(day: LocalDay(key: $0)!, completed: true, quantity: nil) }, today: today)
    }
    // 9月21日那周、9月28日那周达标（旧纪录 2 周）；10月5日那周只 1 次；10月12日那周、10月19日那周（本周）各 2 次 → 本周第 2 次打完 3 周
    let weeklyLogs = ["2026-09-21", "2026-09-23", "2026-09-28", "2026-09-30", "2026-10-06", "2026-10-12", "2026-10-14", "2026-10-19"]
    let wBefore = weekly(weeklyLogs, today: today), wAfter = weekly(weeklyLogs + ["2026-10-22"], today: today)
    let wRecord = HabitRecord.broken(before: wBefore, after: wAfter)
    check(wBefore.streak.count == 1 && wAfter.streak.count == 2 && HabitRecord.previousBest(wAfter) == 2 && wRecord == nil
          && HabitRecord.broken(before: weekly(["2026-09-21", "2026-09-23", "2026-09-28", "2026-09-30", "2026-10-01", "2026-10-02",
                                                 "2026-10-12", "2026-10-14", "2026-10-15", "2026-10-19"], today: today),
                                after: weekly(["2026-09-21", "2026-09-23", "2026-09-28", "2026-09-30", "2026-10-01", "2026-10-02",
                                                "2026-10-12", "2026-10-14", "2026-10-15", "2026-10-19", "2026-10-22"], today: today)) == nil,
          "每周 N 次按“周”：本周打满只追平旧纪录 2 周，不提示（旧纪录不到 3 周也不提示）")
    let wLong = ["2026-09-21", "2026-09-22", "2026-09-28", "2026-09-29", "2026-10-05", "2026-10-06",   // 三周一段（旧纪录 3 周）
                 "2026-10-13",                                                                       // 10月12日那周只 1 次
                 "2026-10-19"]
    // 再往后推三周看：10月19日起连 4 周，第 4 周打满的那一下破纪录
    let later = LocalDay(key: "2026-11-11")!
    let wLongBefore = weekly(wLong + ["2026-10-20", "2026-10-26", "2026-10-27", "2026-11-02", "2026-11-03", "2026-11-09"], today: later)
    let wLongAfter = weekly(wLong + ["2026-10-20", "2026-10-26", "2026-10-27", "2026-11-02", "2026-11-03", "2026-11-09", "2026-11-11"], today: later)
    let wLongRecord = HabitRecord.broken(before: wLongBefore, after: wLongAfter)
    check(wLongBefore.streak.count == 3 && wLongAfter.streak.count == 4 && HabitRecord.previousBest(wLongAfter) == 3
          && wLongRecord?.count == 4 && wLongRecord?.unit == "周",
          "每周 N 次：旧纪录 3 周，本周第 2 次打完变 4 周 → 新纪录 4 周：\(wLongRecord.map { "\($0.count)\($0.unit)" } ?? "nil")")

    // 数字格下的一行小字
    check(HabitRecord.note(current: 3, longest: 5, unit: "天") == "距纪录还差 2 天"
          && HabitRecord.note(current: 5, longest: 5, unit: "天") == "正在创纪录"
          && HabitRecord.note(current: 2, longest: 2, unit: "天") == nil
          && HabitRecord.note(current: 0, longest: 9, unit: "天") == nil
          && HabitRecord.note(current: 1, longest: 4, unit: "周") == "距纪录还差 3 周",
          "数字格小字：距纪录还差 2 天 / 正在创纪录（≥3）/ 当前 0 时不写")
}

// MARK: e-dialogs
// #24 尾巴：首页、功课页、菜单栏三处“+1”同一个步长、同一种写法。功课页已直接用首页的 DashboardRules；
// 首页（DashboardRules）、菜单栏（MenuBarDigest）、旧的 HabitStepRule（自检里还在用）这里逐个目标对一遍，谁改了口径都会报出来
do {
    var targets: [Double] = [-5, 0, 0.5, 1, 2.5, 8, 19.5, 20, 20.5, 21, 30, 60, 90, 119, 120, 121, 150, 300, 500, 1000, 8000, 10000, 12345]
    targets += [.infinity, -.infinity, .nan]
    let disagree = targets.filter { t in
        let home = DashboardRules.quantityStep(target: t)
        return home != MenuBarDigest.step(target: t) || home != HabitStepRule.step(forTarget: t)
            || DashboardRules.stepLabel(home) != MenuBarDigest.stepLabel(target: t)
            || DashboardRules.stepLabel(home) != HabitStepRule.label(forTarget: t)
    }
    check(disagree.isEmpty && HabitStepRule.step(forTarget: nil) == DashboardRules.quantityStep(target: 0),
          "首页、功课页、菜单栏的 +1 步长与按钮字一致（8 杯 +1、30 分钟 +5、8000 步 +1000）" + (disagree.isEmpty ? "" : "（不一致：\(disagree)）"))
    check(DashboardRules.stepLabel(DashboardRules.quantityStep(target: 8000)) == "+1000" && DashboardRules.stepLabel(1) == "+1"
          && !DashboardRules.stepLabel(5).contains("＋"),
          "按钮上写半角“+1”“+5”“+1000”（全角＋在等宽数字旁读成“+ 1”）")
    // 功课页的数量写法也换成首页那套：整数不带小数点，小数最多两位
    check(DashboardRules.number(3) == "3" && DashboardRules.number(2.5) == "2.5" && DashboardRules.number(1.25) == "1.25"
          && DashboardRules.number(-0.0) == "0" && MenuBarDigest.number(1.25) == DashboardRules.number(1.25),
          "数量写法：3、2.5、1.25（功课页与首页、菜单栏一致）")
}

// MARK: e-misc（#25 杂项：撤销说明的警示句、往日回看的空状态、随手记 ⌘↩ 的说法）

do {
    typealias W = CourierUndoWording
    // 撤销说明：真有删除时句末是“删除后无法找回。”，传书笺把它切出来单独用朱砂，其余正文色
    let deleting = W.cardPreview(W.Plan(records: 2, editedRecords: 1, fields: 1))
    let split = W.splitWarning("再点一次即撤销：" + deleting)
    check(deleting == "将删除 1 条记录，恢复 1 个档案字段；保留你改过的 1 条记录。删除后无法找回。"
          && split.body == "再点一次即撤销：将删除 1 条记录，恢复 1 个档案字段；保留你改过的 1 条记录。" && split.warning == W.deletionWarning,
          "传书笺撤销说明：有删除时句末加“删除后无法找回。”，切开后正文与警示各一段（\(deleting)）")
    // 没有删除（只恢复、只保留、什么都不剩）时不写这句，也就整段正文色
    let quiet = [W.Plan(fields: 1), W.Plan(goals: 2, editedGoals: 1), W.Plan(records: 1, editedRecords: 1), W.Plan(), W.Plan(notes: ["甲"])]
    let loud = quiet.map(W.cardPreview).filter { $0.contains("无法找回") || W.splitWarning($0).warning != nil }
    check(loud.isEmpty, "传书笺撤销说明：没有删除时不写“删除后无法找回”（\(loud)）")
    // 各种组合：有删除 ⇔ 结尾是警示句；左栏确认框第一行同一个说法
    var mismatched: [String] = []
    for r in 0...2 { for er in 0...r { for f in 0...1 { for g in 0...1 {
        let p = W.Plan(records: r, editedRecords: er, fields: f, goals: g)
        let warns = r - er > 0
        if (W.splitWarning(W.cardPreview(p)).warning != nil) != warns { mismatched.append(W.cardPreview(p)) }
        if (W.panelLines(p).first?.hasSuffix(W.deletionWarning) ?? false) != warns { mismatched.append(W.panelLines(p).first ?? "") }
    } } } }
    check(mismatched.isEmpty, "撤销说明：传书笺与左栏确认框都只在真有删除时以“删除后无法找回。”收尾（\(mismatched.prefix(3))）")
    check(W.splitWarning("将恢复 1 个目标") == ("将恢复 1 个目标", nil) && W.splitWarning(W.deletionWarning) == ("", W.deletionWarning),
          "splitWarning：不以警示句结尾时整段是正文")

    // 往日回看的空状态：短成一句“往年今日”，仍合一行小字的写法
    check(EmptyCopy.Line.lookback.text == "往年今日写过的，会在这里重现。" && EmptyCopy.Line.lookback.problems.isEmpty,
          "往日回看空状态：一句“往年今日写过的，会在这里重现。”")

    // 快捷键一览：随手记 ⌘↩ 叫“随手记记下”，小字列出按钮随认出的类型写的几种说法，与随手记按钮上的字一一对得上
    let submit = KeyCommand.quickCaptureSubmit
    let labels = Set(QuickParse.Intent.allCases.map(\.button))
    // 按钮名字间夹了 U+2060（折行时整个词一起走），比较前去掉
    let submitNote = (submit.note ?? "").replacingOccurrences(of: "\u{2060}", with: "")
    check(submit.title == "随手记记下" && submitNote == "按认出的类型写“落笔入卷 / 入账 / 打卡 / 记入时辰卷”"
          && labels.allSatisfy { submitNote.contains($0) } && submit.combos == [KeyCombo(.return, .command)],
          "一览：随手记 ⌘↩ 叫“随手记记下”，小字含按钮的每种说法（\(labels.sorted())），组合键不变")
    // 每个按钮名在小字里字字相连（U+2060），一览折行时不折成“记入时辰 / 卷”
    let gluedLabels = labels.filter { label in !(submit.note ?? "").contains(label.map(String.init).joined(separator: "\u{2060}")) }
    check(gluedLabels.isEmpty && (submit.note ?? "").contains("记\u{2060}入\u{2060}时\u{2060}辰\u{2060}卷"),
          "一览：随手记 ⌘↩ 小字里的按钮名整词不折开（\(gluedLabels.sorted())）")
}

// MARK: r2-onboard：#8 筑基三关（判定、出不出现、落印只放一次、功成次日收起）、所向目标细条、本月落笔 N 日（Core/Onboarding）
do {
    typealias G = Onboarding.Gate
    let today = LocalDay(key: "2026-10-22")!

    // 三关判定与写法
    let none = Onboarding.Facts()
    check(Onboarding.passed(none).isEmpty && Onboarding.progressText([]) == "已过 0 / 3", "什么都没有：已过 0 / 3")
    let real = Onboarding.Facts(habitTitles: [], entries: 1, quickUsed: false, letters: 0)
    check(Onboarding.passed(real) == [.write] && Onboarding.progressText(Onboarding.passed(real)) == "已过 1 / 3",
          "正式数据（1 篇、0 习惯）：二关已过，已过 1 / 3")
    let mid = Onboarding.Facts(habitTitles: ["冥想", "喝水"], entries: 3, quickUsed: false, letters: 0)
    check(Onboarding.passed(mid) == [.habit, .write] && Onboarding.doneText(.habit, mid) == "已立「冥想」等 2 项"
          && Onboarding.doneText(.write, mid) == "已落 3 篇",
          "一关写“已立「冥想」等 2 项”、二关写“已落 3 篇”")
    check(Onboarding.doneText(.habit, Onboarding.Facts(habitTitles: ["早睡"])) == "已立「早睡」", "只立一项：已立「早睡」")
    check(Onboarding.passed(Onboarding.Facts(quickUsed: true)) == [.quick] && Onboarding.passed(Onboarding.Facts(letters: 2)) == [.quick]
          && Onboarding.doneText(.quick, Onboarding.Facts(quickUsed: true)) == "已用过随手记"
          && Onboarding.doneText(.quick, Onboarding.Facts(letters: 2)) == "已收到 2 封 AI 传书"
          && Onboarding.doneText(.quick, Onboarding.Facts(quickUsed: true, letters: 1)) == "已用过随手记，也收到过 AI 传书",
          "三关：用过随手记或收到过任一封传书都算过")
    check(G.allCases.map(\.seal) == ["一", "二", "三"] && G.habit.title == "一关 · 立一项功课" && G.write.title == "二关 · 落第一笔"
          && G.quick.title == "三关 · 随手一记，或请 AI 代笔", "三关的印文与标题")
    check(Onboarding.todo(.quick).contains("⌥⌘J") && Onboarding.todo(.quick).contains("「yunshan-journal」")
          && Onboarding.todo(.quick).contains(Onboarding.askExample) && Onboarding.todo(.write).contains("⌘↩"),
          "三关说明写清在哪儿说、怎么说；二关写 ⌘↩")
    let copy = [Onboarding.intro, Onboarding.doneTitle, Onboarding.doneLine, Onboarding.copiedHint, Onboarding.copyHelp,
                Onboarding.dismissedHint, Onboarding.dismissHelp] + G.allCases.flatMap { [$0.title, Onboarding.todo($0)] }
    check(!copy.contains { $0.contains("失败") || $0.contains("中断") || $0.contains("漏") || $0.contains("没写") },
          "筑基卡文案不出现“失败 / 中断 / 漏 / 没写”")

    // 出不出现：收起、老用户（≥30 个有记录的日子）、功成次日、还没数出来
    check(Onboarding.shows(dismissed: false, doneDay: "", today: today, recordDays: 1), "新手（1 个有记录的日子）：出现")
    check(Onboarding.shows(dismissed: false, doneDay: "", today: today, recordDays: 29)
          && !Onboarding.shows(dismissed: false, doneDay: "", today: today, recordDays: 30)
          && !Onboarding.shows(dismissed: false, doneDay: "", today: today, recordDays: 700),
          "有记录的日子 29 天还出现，30 天起（2 年用户）永不出现")
    check(!Onboarding.shows(dismissed: false, doneDay: "", today: today, recordDays: nil), "还没数出来时先不出（老用户不会看见一闪）")
    check(!Onboarding.shows(dismissed: true, doneDay: "", today: today, recordDays: 0), "点过“收起”：不再出现")
    check(Onboarding.shows(dismissed: false, doneDay: "2026-10-22", today: today, recordDays: 5)
          && !Onboarding.shows(dismissed: false, doneDay: "2026-10-22", today: today.adding(days: 1), recordDays: 5),
          "三关全过当天留着“筑基功成”，次日不再出现")
    check(Onboarding.recordDays(journal: ["2026-10-01", "2026-10-01", "2026-10-03", "坏日期"],
                                habits: [LocalDay(key: "2026-10-03")!, LocalDay(key: "2026-10-05")!]) == 3,
          "有记录的日子：落笔与打卡合起来数，同一天只算一次，认不出的日期不算")

    // 落印：第一次出现静默记下；之后每关只落一次；全过掠一次金光并记下功成那天
    let first = Onboarding.step(passed: [.write], sealed: nil, doneDay: "", today: today)
    check(first.land.isEmpty && !first.celebrate && first.sealed == "2" && first.doneDay == nil,
          "第一次出现：已过的二关静默记下，不落印：\(first)")
    check(!Onboarding.isFresh(.write, passed: [.write], sealed: nil) && Onboarding.isFresh(.habit, passed: [.habit, .write], sealed: "2")
          && !Onboarding.isFresh(.write, passed: [.habit, .write], sealed: "2"),
          "画的时候：从没出现过的不算刚过；记下的不再落；新过的一关算刚过")
    let second = Onboarding.step(passed: [.habit, .write], sealed: first.sealed, doneDay: "", today: today)
    check(second.land == [.habit] && !second.celebrate && second.sealed == "1,2", "立了功课：一关落印一次：\(second)")
    let again = Onboarding.step(passed: [.habit, .write], sealed: second.sealed, doneDay: "", today: today)
    check(again.land.isEmpty && again.sealed == "1,2", "同样的三关再看一眼：不再落印")
    let undone = Onboarding.step(passed: [.write], sealed: again.sealed, doneDay: "", today: today)
    let redone = Onboarding.step(passed: [.habit, .write], sealed: undone.sealed, doneDay: "", today: today)
    check(undone.sealed == "1,2" && redone.land.isEmpty, "删掉功课又立：一关的印不再落第二次")
    let all = Onboarding.step(passed: Set(G.allCases), sealed: redone.sealed, doneDay: "", today: today)
    check(all.land == [.quick] && all.celebrate && all.sealed == "1,2,3,done" && all.doneDay == "2026-10-22",
          "三关全过：三关落印、掠一次金光、记下功成那天：\(all)")
    check(!Onboarding.step(passed: Set(G.allCases), sealed: all.sealed, doneDay: "2026-10-22", today: today).celebrate
          && !Onboarding.step(passed: Set(G.allCases), sealed: nil, doneDay: "", today: today).celebrate
          && !Onboarding.step(passed: [.habit], sealed: "1", doneDay: "", today: today).celebrate,
          "金光只在全过、还没掠过时放；从没出现过（一上来就全过）不放；没全过不放")

    // 卡片看不见（主窗口在别的应用后面、随手记浮窗开着、挂着弹窗）：不写落印记录、不掠金光不提示，只记功成那天；看得见了再落
    let hidden = Onboarding.step(passed: Set(G.allCases), sealed: "1,2", doneDay: "", today: today, visible: false)
    check(hidden.land.isEmpty && !hidden.celebrate && hidden.sealed == nil && hidden.doneDay == "2026-10-22",
          "在别的应用里按 ⌥⌘J 过了三关（主窗口在后面）：不落印、不掠金光、不提示、落印记录不改，只记下功成那天：\(hidden)")
    check(Onboarding.shown(passed: Set(G.allCases), sealed: "1,2", visible: false) == [.habit, .write]
          && Onboarding.shown(passed: Set(G.allCases), sealed: "1,2", visible: true) == Set(G.allCases),
          "看不见时刚过的三关先按没过画（印位虚线、标题不换“筑基功成”）；看得见了按全过画")
    let back = Onboarding.step(passed: Set(G.allCases), sealed: "1,2", doneDay: hidden.doneDay ?? "", today: today, visible: true)
    check(back.land == [.quick] && back.celebrate && back.sealed == "1,2,3,done" && back.doneDay == nil,
          "切回来（主窗口重新成为键盘窗口）：三关这时才落印、掠金光、提示，功成那天不再改：\(back)")
    check(Onboarding.isFresh(.quick, passed: Onboarding.shown(passed: Set(G.allCases), sealed: "1,2", visible: true), sealed: "1,2")
          && !Onboarding.isFresh(.quick, passed: Onboarding.shown(passed: Set(G.allCases), sealed: "1,2", visible: false), sealed: "1,2"),
          "三关的印在看得见的那一刻才算刚过（落印动画留到切回来再放）")
    let hiddenFirst = Onboarding.step(passed: [.write], sealed: nil, doneDay: "", today: today, visible: false)
    check(hiddenFirst.sealed == nil && hiddenFirst.doneDay == nil && Onboarding.shown(passed: [.write], sealed: nil, visible: false) == [.write],
          "登录时自动打开、窗口还在后面就出现：先不记，等第一次看得见时再静默盖上已过的几关")
    check(Onboarding.step(passed: [.habit], sealed: "2", doneDay: "", today: today, visible: false) == .init(land: [], celebrate: false, sealed: nil, doneDay: nil),
          "没全过、看不见：什么都不写")

    // 复制例句与收起的说法
    check(Onboarding.copiedHint.contains("换成你今天真的一件事") && !Onboarding.copiedHint.contains("回车即可")
          && Onboarding.copyHelp.contains(Onboarding.askExample) && Onboarding.copyHelp.contains("换成你今天真的一件事"),
          "复制例句：提示与悬停都叫用户换成今天真的一件事再回车（不再说“回车即可”，免得原样记下一笔现金 18）")
    check(Onboarding.dismissedHint.contains("不再出现") && Onboarding.dismissedHint.contains("随手记")
          && Onboarding.dismissHelp.contains("不再出现"),
          "收起：点了提示“不再出现”，并说立功课、落笔、随手记照常都在")
    let later = Onboarding.step(passed: Set(G.allCases), sealed: all.sealed, doneDay: "2026-10-22", today: today)
    check(!later.celebrate && later.land.isEmpty && later.doneDay == nil, "功成之后再看：不再掠金光，功成那天不改")
    let silentAll = Onboarding.step(passed: Set(G.allCases), sealed: nil, doneDay: "", today: today)
    check(!silentAll.celebrate && silentAll.sealed == "1,2,3,done" && silentAll.doneDay == "2026-10-22",
          "第一次出现就全过：静默记下，当天写“筑基功成”，次日收起")
    check(Onboarding.parseSealed(" 3, done,1,x").gates == [.habit, .quick] && Onboarding.parseSealed("3,done").done
          && Onboarding.formatSealed([.quick, .habit], done: false) == "1,3",
          "落印记录的读写（容空格、认不出的跳过）")

    // 本月落笔 N 日
    let keys = ["2026-10-01", "2026-10-01", "2026-10-09", "2026-10-21", "2026-10-22", "2026-09-30", "2026-10-23", "2025-10-05", "坏"]
    check(Onboarding.monthDays(keys, today: today) == 4, "本月落笔：同一天几篇算一日，上月、明天、去年同月不算")
    check(Onboarding.todayLine(todayCount: 2, monthDays: 9) == "今日已落 2 篇 · 本月落笔 9 日"
          && Onboarding.todayLine(todayCount: 1, monthDays: 0) == "今日已落 1 篇",
          "今日已落那行接“ · 本月落笔 9 日”")
    check(Onboarding.monthOnlyLine(todayCount: 0, monthDays: 9) == "本月已落笔 9 日"
          && Onboarding.monthOnlyLine(todayCount: 1, monthDays: 9) == nil && Onboarding.monthOnlyLine(todayCount: 0, monthDays: 0) == nil,
          "今天还没写、本月写过：单独一行“本月已落笔 9 日”；本月一日都没有时不写")
    check(Onboarding.monthDays(["2026-11-01", "2026-10-31"], today: LocalDay(key: "2026-11-01")!) == 1, "跨月：11月1日只数 11 月")

    // 所向
    typealias GI = GoalStripRules.Item
    let goals = [
        GI(title: "今年读完 24 本书", priority: "should", progress: 55, targetDate: "2027-01-02"),
        GI(title: "毕业后找到研究型岗位", priority: "must", progress: 15, targetDate: "2027-08-18"),
        GI(title: "每周运动三次", priority: "should", progress: 72, targetDate: "2026-12-21"),
        GI(title: "完成学位论文初稿", priority: "must", progress: 65, targetDate: "2026-12-19"),
        GI(title: "学弹《卡农》", priority: "could", progress: 40, targetDate: nil),
    ]
    let picked = GoalStripRules.pick(goals)
    check(picked.shown.map(\.title) == ["完成学位论文初稿", "毕业后找到研究型岗位"] && picked.more == 3
          && GoalStripRules.moreText(picked.more) == "另有 3 个",
          "所向：必须的在前、再按期限近，最多两行，另有 3 个：\(picked.shown.map(\.title))")
    let tie = GoalStripRules.pick([GI(title: "乙", priority: "should", progress: 1, targetDate: nil),
                                   GI(title: "甲", priority: "should", progress: 1, targetDate: "2026-11-01"),
                                   GI(title: "丙", priority: "怪", progress: 1, targetDate: "2026-10-23")])
    check(tie.shown.map(\.title) == ["甲", "乙"] && tie.more == 1 && GoalStripRules.moreText(0) == nil,
          "同优先级有期限的在前；认不出的优先级排最后；两个以内不写“另有”")
    check(GoalStripRules.deadline("2026-12-19", today: today) == ("还剩 58 天", false)
          && GoalStripRules.deadline("2026-10-22", today: today) == ("今日到期", false)
          && GoalStripRules.deadline("2026-10-19", today: today) == ("期限已过 3 天", true)
          && GoalStripRules.deadline(nil, today: today) == ("未定期限", false)
          && GoalStripRules.deadline("明年", today: today) == ("未定期限", false),
          "期限：还剩 58 天 / 今日到期 / 期限已过 3 天（警示）/ 未定期限")
    check(GoalStripRules.percent(65) == "65%" && GoalStripRules.percent(130) == "100%" && GoalStripRules.percent(-5) == "0%", "进度百分比夹在 0–100")
}

// MARK: r2-courier：#9 飞剑传书容错——同类说法、打卡对不上只退这一条、单位核对与换算（CourierRoster / CheckinUnit / HabitAlias）
do {
    let base = LocalDay(key: "2026-10-22")!
    func parse(_ json: String) throws -> CourierPayload { try CourierParser.parse(Data(json.utf8), relativeTo: base, latest: base) }
    func items(_ list: String) throws -> CourierPayload { try parse(#"{"from":"Claude","items":["# + list + "]}") }
    func failure(_ roster: CourierRoster, _ payload: CourierPayload, partial: Bool = true) -> String {
        do { _ = try roster.resolve(payload.items, units: payload.checkinUnits, partial: partial); return "" } catch { return error.localizedDescription }
    }
    let lunch = #"{"type":"expense","amount":18,"description":"午饭"}"#

    // 1. 解析：unit（也认“单位”）、“1小时”拆开、只写单位不写数量
    let unitPayload = try items(#"{"type":"checkin","habit":"冥想","quantity":1,"unit":"小时"},{"type":"checkin","habit":"步数","quantity":5,"单位":"公里"},"#
                                + #"{"type":"checkin","habit":"冥想","quantity":"1.5小时"},{"type":"checkin","habit":"喝水","unit":"杯"}"#)
    check(unitPayload.checkinUnits == [0: "小时", 1: "公里", 2: "小时"]
          && unitPayload.warnings.contains("第 3 条：quantity「1.5小时」已拆成数量 1.5 与单位“小时”（下次请分开写 quantity 与 unit）")
          && unitPayload.warnings.contains("第 4 条：unit 要和 quantity 一起写，只写单位已忽略（按达标记）")
          && unitPayload.warnings.contains("第 2 条：已把 单位 当作 unit"),
          "解析：checkin 认 unit 与别名“单位”；“1.5小时”拆成数与单位；只写单位不写数量时忽略：\(unitPayload.warnings)")
    if case let .checkin(_, _, q) = unitPayload.items[2] { check(q == 1.5, "“1.5小时”的数量是 1.5") } else { check(false, "第 3 条应是打卡") }
    check((try? parse(#"{"type":"checkin","habit":"冥想","quantity":"很久"}"#)) == nil, "quantity 写成拆不开的文字仍拒收")

    // 2. 单位换算：同单位、小时↔分钟、公里↔米、千步↔步、升↔毫升；功课没设单位不核对；对不上
    check(CheckinUnit.reconcile(1, unit: "小时", habitUnit: "分钟") == .converted(60)
          && CheckinUnit.reconcile(1.1, unit: "h", habitUnit: "分钟") == .converted(66)
          && CheckinUnit.reconcile(2, unit: "km", habitUnit: "米") == .converted(2000)
          && CheckinUnit.reconcile(8, unit: "千步", habitUnit: "步") == .converted(8000)
          && CheckinUnit.reconcile(500, unit: "毫升", habitUnit: "升") == .converted(0.5)
          && CheckinUnit.reconcile(30, unit: "min", habitUnit: "分钟") == .same
          && CheckinUnit.reconcile(3, unit: "杯", habitUnit: "杯") == .same
          && CheckinUnit.reconcile(5, unit: "公里", habitUnit: "") == .same
          && CheckinUnit.reconcile(5, unit: "公里", habitUnit: "步") == .mismatch
          && CheckinUnit.reconcile(20, unit: "分钟", habitUnit: "页") == .mismatch,
          "单位：小时↔分钟、公里↔米、千步↔步、毫升↔升能换算；功课没设单位不核对；公里记不到“步”上")
    check(CheckinUnit.split("1 小时").map { $0.value == 1 && $0.unit == "小时" } == true
          && CheckinUnit.split("5公里").map { $0.value == 5 && $0.unit == "公里" } == true && CheckinUnit.split("30") == nil
          && CheckinUnit.split("很久") == nil && CheckinUnit.split("0 分钟") == nil,
          "“1 小时”“5公里”拆成数与单位；只有数、没有数、数是 0 都不拆")

    // 3. 同类说法：跑步 → 运动（收录并提醒）
    let sport = CourierRoster(habits: ["运动", "步数"], habitUnits: ["", "步"])
    let run = try items(lunch + #",{"type":"checkin","habit":"跑步"}"#)
    let runResult = try sport.resolve(run.items, units: run.checkinUnits, partial: true)
    check(runResult.checkins[1] == .existing(0) && runResult.skipped.isEmpty
          && runResult.notices == ["第 2 条：按「运动」打卡（你写的是「跑步」，属于同类说法）"],
          "“跑步”在只有“运动”“步数”的库里按同类说法对上“运动”，回执提醒：\(runResult.notices)")
    check(try sport.resolve(try parse(#"{"type":"checkin","habit":"晨跑"}"#).items).checkins[0] == .existing(0),
          "整封校验（直接调用 apply 的老路子）也认同类说法")

    // 4. 找不到习惯：只退这一条，其余照收
    let steps = CourierRoster(habits: ["步数"], habitUnits: ["步"])
    let swim = try items(lunch + #",{"type":"checkin","habit":"游泳","quantity":30,"unit":"分钟"}"#)
    let swimResult = try steps.resolve(swim.items, units: swim.checkinUnits, partial: true)
    check(swimResult.checkins.isEmpty && swimResult.skipped.keys.sorted() == [1]
          && swimResult.skipped[1]?.receipt == "找不到习惯「游泳」。现有习惯：步数。请向用户确认是哪项功课，再只重投这一条。"
          && swimResult.skipped[1]?.short == "打卡「游泳」：没有这项功课",
          "“游泳 30 分钟”在只有“步数”的库里：这一条退回，午饭照收：\(swimResult.skipped[1]?.receipt ?? "nil")")
    check(failure(steps, swim, partial: false) == "第 2 条：找不到习惯「游泳」。现有习惯：步数",
          "不按条退回时（直接调用 apply）仍整封拒收，原文不变")
    // 同类说法能对上几项：不猜，退回并列出候选
    let twoSports = CourierRoster(habits: ["运动", "力量训练", "步数"])
    let swim2 = try items(lunch + #",{"type":"checkin","habit":"游泳"}"#)
    let twoResult = try twoSports.resolve(swim2.items, units: swim2.checkinUnits, partial: true)
    check(twoResult.skipped[1]?.receipt == "找不到习惯「游泳」。现有习惯：运动、力量训练、步数。若是给「运动」、「力量训练」中的一项打卡，请把名字写成那一项的全称，只重投这一条。",
          "同类说法对上两项：退回并列出候选：\(twoResult.skipped[1]?.receipt ?? "nil")")
    check(HabitAlias.candidates("读书", titles: ["晨读书", "读书笔记", "喝水"]) == [0, 1]
          && CourierRoster.notFound("读书", titles: ["晨读书", "读书笔记"]).reason
          == "找不到习惯「读书」。现有习惯：晨读书、读书笔记。若是给「晨读书」、「读书笔记」中的一项打卡，请把名字写成那一项的全称",
          "名字互相包含两项、又同属一组：候选合在一起列")
    check(CourierRoster.notFound("游泳", titles: ["运动"]).reason == "找不到习惯「游泳」。现有习惯：运动。若是给「运动」打卡，请把名字写成「运动」"
          && CourierRoster.notFound("跑步", titles: []).reason == "找不到习惯「跑步」。现有习惯：（无）",
          "候选只有一项时点名；一项功课都没有时写（无）")

    // 5. 单位对不上：只退这一条；能换算：换算并提醒
    let km = try items(lunch + #",{"type":"checkin","habit":"步数","quantity":5,"unit":"公里"}"#)
    let kmResult = try steps.resolve(km.items, units: km.checkinUnits, partial: true)
    check(kmResult.skipped[1]?.reason == "单位对不上：「步数」按“步”计，这一条写的是“公里”。请换算成“步”再写 quantity，或去掉 quantity 只打卡"
          && kmResult.skipped[1]?.short == "打卡「步数」：单位对不上（写的是“公里”）" && kmResult.checkins.isEmpty,
          "“步数 5 公里”退回并说明单位对不上")
    let zen = CourierRoster(habits: ["冥想"], habitUnits: ["分钟"])
    let hour = try items(#"{"type":"checkin","habit":"冥想","quantity":1,"unit":"小时"}"#)
    let hourResult = try zen.resolve(hour.items, units: hour.checkinUnits, partial: true)
    check(hourResult.quantities == [0: 60] && hourResult.notices == ["第 1 条：1 小时按 60 分钟记"] && hourResult.checkins[0] == .existing(0),
          "“冥想 1 小时”对“冥想（分钟）”记成 60 分钟并提醒：\(hourResult.notices)")
    let oldState = CourierRoster(habits: ["步数"])   // 旧版小抄没有单位：不核对，由应用收录时再查
    let mismatchedCount = CourierRoster(habits: ["步数", "冥想"], habitUnits: ["步"])
    check(try oldState.resolve(km.items, units: km.checkinUnits, partial: true).skipped.isEmpty
          && (try mismatchedCount.resolve(km.items, units: km.checkinUnits, partial: true)).skipped.isEmpty,
          "小抄里没有单位、或单位条数对不上：不核对单位")
    let newHabit = try items(#"{"type":"habit","title":"冥想","target":10,"unit":"分钟"},{"type":"checkin","habit":"冥想","quantity":"0.5 小时"}"#)
    let newResult = try CourierRoster(habits: []).resolve(newHabit.items, units: newHabit.checkinUnits, partial: true)
    check(newResult.checkins[1] == .new(0) && newResult.quantities[1] == 30, "同封新建的习惯也按它的单位换算（0.5 小时 → 30 分钟）")

    // 6. 整封全是对不上的打卡：整封拒收；其余校验错误仍整封拒收
    check(failure(steps, try items(#"{"type":"checkin","habit":"游泳"}"#)) == "第 1 条：找不到习惯「游泳」。现有习惯：步数",
          "只有一条且对不上：整封拒收，原文与原来一样")
    check(failure(steps, try items(#"{"type":"checkin","habit":"游泳"},{"type":"checkin","habit":"步数","quantity":5,"unit":"公里"}"#))
          == "第 1 条：找不到习惯「游泳」。现有习惯：步数\n第 2 条：单位对不上：「步数」按“步”计，这一条写的是“公里”。请换算成“步”再写 quantity，或去掉 quantity 只打卡",
          "两条都对不上：整封拒收，逐行列出两条原因")
    let withGoal = CourierRoster(habits: ["步数"], goals: [], habitUnits: ["步"])
    check(failure(withGoal, try items(#"{"type":"checkin","habit":"游泳"},{"type":"goal","action":"update","title":"减肥","progress":10}"#))
          == "第 2 条：找不到目标「减肥」。现有目标：（暂无目标）；要新立请去掉 action",
          "同封还有别的校验错误（目标找不到）：仍整封拒收，报那一条")

    // 7. 传书笺：退回的那行不算条目，一封只有打卡时仍是叶、去每日功课
    let noteLines = ["打卡 · 10月22日 · 运动", CourierLineDecor.skippedLine("打卡「游泳」：没有这项功课")]
    check(noteLines[1] == "未收 · 打卡「游泳」：没有这项功课" && CourierLineDecor.symbol(noteLines) == "leaf"
          && CourierLineDecor.page(noteLines) == "habits" && CourierLineDecor.isSkipped(noteLines[1]) && !CourierLineDecor.isSkipped(noteLines[0]),
          "传书笺：“未收 ·”行不影响笺头图标与“查看”去哪页")

    // 8. README“也能对上的说法”：一组只对上一项功课时才列；名字里已有的词不列
    let words = HabitAlias.readmeWords(titles: ["运动", "冥想（分钟）", "喝水"], limit: 4)
    let shared = HabitAlias.readmeWords(titles: ["运动", "力量训练", "早睡早起"])
    check(words[0] == ["锻炼", "健身", "跑步", "慢跑"] && words[1] == ["打坐", "静坐", "正念"] && words[2] == ["饮水", "补水"]
          && shared[0].isEmpty && shared[1].isEmpty && shared[2].contains("入睡") && shared[2].contains("起床"),
          "README 同类说法：\(words) / \(shared)")

    // 9.（修复）只是相关的同类说法没写数量：不替他记满目标值，退回这一条；写了数量照记
    let loose = CourierRoster(habits: ["步数", "背单词", "写作", "冥想"], habitUnits: ["步", "个", "字", "分钟"], habitTargets: [8000, 30, 300, 10])
    let walkBare = try items(lunch + #",{"type":"checkin","habit":"散步"}"#)
    let walkBareResult = try loose.resolve(walkBare.items, units: walkBare.checkinUnits, partial: true)
    check(walkBareResult.checkins.isEmpty && walkBareResult.skipped.keys.sorted() == [1]
          && walkBareResult.skipped[1]?.receipt == "「散步」和「步数」相关但不是一回事：请写 quantity（单位“步”）后只重投这一条。"
          && walkBareResult.skipped[1]?.short == "打卡「散步」：要写数量才记到「步数」" && walkBareResult.notices.isEmpty,
          "“散步”没写数量：退回，不记满 8000 步：\(walkBareResult.skipped[1]?.receipt ?? "nil")")
    let walkSome = try items(#"{"type":"checkin","habit":"散步","quantity":3000,"unit":"步"}"#)
    let walkSomeResult = try loose.resolve(walkSome.items, units: walkSome.checkinUnits, partial: true)
    check(walkSomeResult.checkins[0] == .existing(0) && walkSomeResult.skipped.isEmpty && walkSomeResult.quantities.isEmpty
          && walkSomeResult.notices == ["第 1 条：按「步数」打卡（你写的是「散步」，属于同类说法）"],
          "“散步 3000 步”：按「步数」记 3000（数量照用）")
    let englishWriting = try items(lunch + #",{"type":"checkin","habit":"英语听力"},{"type":"checkin","habit":"写论文"},{"type":"checkin","habit":"打坐"}"#)
    let ewResult = try loose.resolve(englishWriting.items, units: englishWriting.checkinUnits, partial: true)
    check(ewResult.skipped.keys.sorted() == [1, 2] && ewResult.checkins[3] == .existing(3)
          && ewResult.skipped[1]?.receipt == "「英语听力」和「背单词」相关但不是一回事：请写 quantity（单位“个”）后只重投这一条。",
          "“英语听力”“写论文”没写数量都退回；“打坐”就是冥想，照常记满")
    check(failure(loose, walkBare, partial: false) == "第 2 条：「散步」和「步数」相关但不是一回事，没写数量时不替用户记满目标：请写 quantity（单位“步”）后再投",
          "不按条退回时（直接调用 apply）整封拒收并说明")
    let noTarget = CourierRoster(habits: ["步数"], habitUnits: [""], habitTargets: [0])
    let oldStateLoose = CourierRoster(habits: ["步数"], habitUnits: ["步"])
    let walkOnly = try items(#"{"type":"checkin","habit":"散步"}"#)
    check(try noTarget.resolve(walkOnly.items, units: [:], partial: true).checkins[0] == .existing(0)
          && (try oldStateLoose.resolve(walkOnly.items, units: [:], partial: true)).checkins[0] == .existing(0)
          && (try CourierRoster(habits: ["散步8000步"], habitUnits: ["步"], habitTargets: [8000]).resolve(walkOnly.items, units: [:], partial: true)).skipped.isEmpty,
          "功课没有数量目标、旧版小抄不知道目标、功课名里就有“散步”：照常打卡")
    let newSteps = try items(#"{"type":"habit","title":"步数","target":8000,"unit":"步"},{"type":"checkin","habit":"走路"}"#)
    check((try CourierRoster(habits: []).resolve(newSteps.items, units: newSteps.checkinUnits, partial: true)).skipped.keys.sorted() == [1],
          "同封新建的「步数 8000」也不替“走路”记满")
    check(HabitAlias.fillsTarget(via: "打坐", title: "冥想") && !HabitAlias.fillsTarget(via: "散步", title: "步数")
          && HabitAlias.fillsTarget(via: "散步", title: "晚饭后散步") && !HabitAlias.fillsTarget(via: "英语", title: "背单词"),
          "同类说法能否替他记满：打坐→冥想能，散步→步数、英语→背单词不能")
    check(HabitAlias.readmeCell(["走路", "散步", "步行", "万步"], title: "步数", hasTarget: true) == "走路、散步、步行、万步（需写数量）"
          && HabitAlias.readmeCell(["走路", "散步"], title: "步数", hasTarget: false) == "走路、散步"
          && HabitAlias.readmeCell(["打坐", "静坐"], title: "冥想", hasTarget: true) == "打坐、静坐"
          && HabitAlias.readmeCell([], title: "弹琴", hasTarget: true) == "—",
          "README 说法一格：只是相关的说法对有数量目标的功课注明“需写数量”")

    // 10.（修复）quantity 自带单位又另写了不同的 unit：按 quantity 自带的单位记并提醒；同一单位或认不出的不提醒
    let doubleUnit = try items(#"{"type":"checkin","habit":"冥想","quantity":"1小时","unit":"分钟"},{"type":"checkin","habit":"冥想","quantity":"30分钟","unit":"min"},"#
                               + #"{"type":"checkin","habit":"冥想","quantity":"30 分钟左右","unit":"分钟"}"#)
    check(doubleUnit.checkinUnits == [0: "小时", 1: "min", 2: "分钟"]
          && doubleUnit.warnings == ["第 1 条：quantity「1小时」里的单位“小时”和 unit“分钟”不同，已按“小时”记（下次请分开写：quantity 只写数，单位写在 unit）"],
          "“1小时”配 unit“分钟”按小时记并提醒；“30分钟”配 min 同一单位、“分钟左右”认不出，都按 unit：\(doubleUnit.warnings)")
    let doubleResult = try zen.resolve(doubleUnit.items, units: doubleUnit.checkinUnits, partial: true)
    check(doubleResult.quantities[0] == 60 && doubleResult.notices.contains("第 1 条：1 小时按 60 分钟记"), "“1小时”配 unit“分钟”最后记 60 分钟")

    // 11.（修复）「背单词」按“个”计：写“个单词”“单词”“词”“words”“个句子”都是个；“个小时”“个月”仍对不上
    check(["个单词", "单词", "词", "个词", "生词", "words", "word", "个句子"].allSatisfy { CheckinUnit.reconcile(50, unit: $0, habitUnit: "个") == .same }
          && CheckinUnit.reconcile(50, unit: "个小时", habitUnit: "个") == .mismatch && CheckinUnit.reconcile(3, unit: "个月", habitUnit: "个") == .mismatch
          && CheckinUnit.reconcile(500, unit: "words", habitUnit: "字") == .same && CheckinUnit.reconcile(500, unit: "单词", habitUnit: "字") == .mismatch,
          "背单词（个）认“个单词 / 单词 / 词 / words”；写作（字）认 words")
    let vocab = try items(#"{"type":"checkin","habit":"背单词","quantity":"50个单词"}"#)
    let vocabResult = try loose.resolve(vocab.items, units: vocab.checkinUnits, partial: true)
    check(vocabResult.checkins[0] == .existing(1) && vocabResult.skipped.isEmpty && vocabResult.quantities.isEmpty,
          "“背单词 50 个单词”记 50")

    // 12.（修复）换算后不到 0.01：退回并说明太小，不记成 0
    check(CheckinUnit.reconcile(1, unit: "米", habitUnit: "公里") == .tooSmall && CheckinUnit.reconcile(4, unit: "米", habitUnit: "公里") == .tooSmall
          && CheckinUnit.reconcile(10, unit: "秒", habitUnit: "小时") == .tooSmall && CheckinUnit.reconcile(1, unit: "步", habitUnit: "万步") == .tooSmall
          && CheckinUnit.reconcile(10, unit: "米", habitUnit: "公里") == .converted(0.01),
          "换算后不到 0.01 的算太小；10 米是 0.01 公里")
    let runKm = CourierRoster(habits: ["跑步"], habitUnits: ["公里"])
    let meter = try items(lunch + #",{"type":"checkin","habit":"跑步","quantity":1,"unit":"米"}"#)
    let meterResult = try runKm.resolve(meter.items, units: meter.checkinUnits, partial: true)
    check(meterResult.checkins.isEmpty && meterResult.quantities.isEmpty
          && meterResult.skipped[1]?.reason == "数量太小：「跑步」按“公里”计，1 米换算后不到 0.01 公里。请确认数量和单位没写错，或去掉 quantity 只打卡"
          && meterResult.skipped[1]?.short == "打卡「跑步」：数量太小（1 米）",
          "“跑步 1 米”对按公里计的功课：退回并说明太小：\(meterResult.skipped[1]?.reason ?? "nil")")

    // 13.（修复）传书笺与撤销框用的几行：副标题“1 条未收”、未收行不被折进“另有 N 条”、多封时每封注明、撤销框不列未收行
    let partialLines = ["记账 · 10月22日 · 午饭", "打卡 · 10月22日 · 运动", "日记 · 10月22日 · a", "日记 · 10月22日 · b", "日记 · 10月22日 · c",
                        "日记 · 10月22日 · d", CourierLineDecor.skippedLine("打卡「游泳」：没有这项功课")]
    check(CourierLineDecor.cardDetail(from: "Claude", itemCount: 6, lines: partialLines) == "来自 Claude · 收录 6 条 · 1 条未收"
          && CourierLineDecor.cardDetail(from: "Claude", itemCount: 2, lines: Array(partialLines.prefix(2))) == "来自 Claude · 收录 2 条",
          "传书笺副标题：有退回时写“1 条未收”")
    check(CourierLineDecor.cardLines(partialLines) == ["记账 · 10月22日 · 午饭", "打卡 · 10月22日 · 运动", "日记 · 10月22日 · a", "日记 · 10月22日 · b",
                                                        "…… 另有 2 条", "未收 · 打卡「游泳」：没有这项功课"]
          && CourierLineDecor.cardLines(Array(partialLines.suffix(3))) == Array(partialLines.suffix(3)),
          "传书笺摘要：收下的多时只折收下的，未收行留在最后")
    let threeSkips = ["记账 · a"] + (1...5).map { "日记 · \($0)" } + (1...3).map { CourierLineDecor.skippedLine("打卡「x\($0)」：没有这项功课") }
    check(CourierLineDecor.cardLines(threeSkips) == ["记账 · a", "日记 · 1", "日记 · 2", "日记 · 3", "…… 另有 2 条",
                                                      "未收 · 打卡「x1」「x2」等 3 条：没有这项功课"],
          "传书笺摘要：要折叠时几条未收并成一行（r3-courierui 修复后的写法）")
    check(CourierLineDecor.batchLine(from: "Claude", itemCount: 6, summary: partialLines.joined(separator: "\n")) == "Claude · 6 条 · 1 条未收：记账 · 10月22日 · 午饭"
          && CourierLineDecor.batchLine(from: "Claude", itemCount: 1, summary: "日记 · x") == "Claude · 1 条：日记 · x"
          && CourierLineDecor.undoLines(partialLines) == Array(partialLines.prefix(6))
          && CourierLineDecor.skippedCount(summary: partialLines.joined(separator: "\n")) == 1
          && CourierRefCount.items([("checkin", "courier:C"), ("hash", "x"), ("skip", "2")]) == 1,
          "多封合并时每封注明“1 条未收”；撤销框不列未收行；skip 引用不算收录条数")
}

// MARK: r2-skill（#10 apt-record 技能里的示例 JSON 都能被应用解析：日期写 today / yesterday / tomorrow，不先跑 date）
do {
    let base = LocalDay(key: "2026-10-22")!
    func parse(_ json: String) -> CourierPayload? { try? CourierParser.parse(Data(json.utf8), relativeTo: base, latest: base) }
    // “一条命令”里的示例：记账（说了现金写进 note）+ 带单位的打卡
    let sample = parse(#"""
    {"from": "Claude", "items": [
      {"type": "expense", "date": "today", "amount": 18, "category": "餐饮与外卖", "description": "午饭", "note": "现金"},
      {"type": "checkin", "date": "today", "habit": "冥想", "quantity": 10, "unit": "分钟"}
    ]}
    """#)
    var expenseOK = false, checkinOK = false
    for item in sample?.items ?? [] {
        if case let .expense(day, cents, category, description, note) = item {
            expenseOK = day == base && cents == 1800 && category == "餐饮与外卖" && description == "午饭" && note == "现金"
        }
        if case let .checkin(habit, day, quantity) = item { checkinOK = habit == "冥想" && day == base && quantity == 10 }
    }
    check(sample?.from == "Claude" && sample?.items.count == 2 && expenseOK && checkinOK && sample?.relativeDates == 2,
          "技能示例：午饭 18（现金）+ 冥想 10 分钟，today 按投递那天换算")
    // 没说支付方式：照记，note 写“未说明支付方式”；昨天的写 yesterday
    let unpaid = parse(#"{"from":"Claude","items":[{"type":"expense","date":"yesterday","amount":"18.5","category":"餐饮与外卖","description":"晚饭","note":"未说明支付方式"}]}"#)
    if case let .expense(day, cents, _, _, note)? = unpaid?.items.first {
        check(day == base.adding(days: -1) && cents == 1850 && note == "未说明支付方式", "技能示例：没说支付方式照记、note 写明，yesterday 记到前一天")
    } else {
        check(false, "技能示例：没说支付方式的记账解析失败")
    }
    // 明天下午 3 点组会
    let meeting = parse(#"{"from":"Claude","items":[{"type":"event","date":"tomorrow","title":"组会","start":"15:00","end":"16:00"}]}"#)
    if case let .event(day, start, end, title, _, _, _)? = meeting?.items.first {
        check(day == base.adding(days: 1) && start == 15 * 60 && end == 16 * 60 && title == "组会", "技能示例：明天 15:00–16:00 组会")
    } else {
        check(false, "技能示例：明天组会解析失败")
    }
    // “陪我复盘今天”整理成的日省：period day、四段、记在今天
    let review = parse(#"{"from":"Claude","items":[{"type":"review","period":"day","date":"today","body":"【所得】论文写了一节\n【所失】午后刷手机一小时\n【所悟】先写再改\n【下一步】明早先写 90 分钟"}]}"#)
    if case let .entry(kind, day, _, _, body, _, period, _)? = review?.items.first {
        check(kind == .review && day == base && period == "day" && body.contains("【下一步】明早先写 90 分钟") && !body.contains("\\n"),
              "技能示例：陪我复盘今天 → 一篇日省，四段分行、记在今天")
    } else {
        check(false, "技能示例：日省解析失败")
    }
    // 新建功课：start_date 也可写 today
    let habit = parse(#"{"from":"Claude","items":[{"type":"habit","title":"冥想","target":10,"unit":"分钟","start_date":"today"}]}"#)
    if case let .habit(h)? = habit?.items.first {
        check(h.title == "冥想" && h.startDay == base && h.target == 10 && h.unit == "分钟", "技能示例：新建冥想功课，start_date 写 today 即投递那天")
    } else {
        check(false, "技能示例：新建功课解析失败")
    }
    // 技能里抄了一份消费类别（记账不先读 README，写错类别会落进“待分类消费”）：与应用对不上时提醒去改 ../.claude/skills/apt-record/SKILL.md
    let skillCategories = ["餐饮与外卖", "超市与食品", "交通出行", "通讯与网络", "软件与会员", "教育与学费",
                           "购物", "健康与健身", "娱乐", "彩票", "银行手续费", "待分类消费"]
    check(skillCategories == FinanceEngine.spendCategories, "技能里列的 12 个消费类别与应用的消费类别一字不差、顺序相同")
    let taxi = parse(#"{"from":"Claude","items":[{"type":"expense","date":"today","amount":23,"category":"交通出行","description":"打车","note":"未说明支付方式"}]}"#)
    if case let .expense(_, cents, category, _, _)? = taxi?.items.first {
        check(cents == 2300 && category == "交通出行" && taxi?.warnings.isEmpty == true, "技能示例：打车 23 记“交通出行”，不落待分类、没有提醒")
    } else {
        check(false, "技能示例：打车解析失败")
    }
    // “陪我复盘今天”的凌晨分界与应用晚课相同：00:00–04:59 算前一天（日省写 yesterday），05:00 起算今天
    check(DailyRite.ritualDay(minute: 40, today: base) == base.adding(days: -1)
          && DailyRite.ritualDay(minute: 4 * 60 + 59, today: base) == base.adding(days: -1)
          && DailyRite.ritualDay(minute: 5 * 60, today: base) == base
          && DailyRite.ritualDay(minute: 23 * 60 + 50, today: base) == base,
          "技能“陪我复盘今天”：00:40、04:59 记前一天，05:00、23:50 记当天（与晚课同在 05:00 分界）")
}

// MARK: r2-weekly（#11 七日小卷：周边界、摘句、心境七日、功课本周对上周、花费与账单没导全、洞见、草稿与周信）
do {
    func day(_ key: String) -> LocalDay { LocalDay(key: key)! }
    func pair(_ line: WeeklyDigest.HabitLine?) -> [Int] { line.map { [$0.done, $0.expected] } ?? [] }
    // 周边界：周四看本周；周一 12:00 之前看上一整周（凌晨 00:30 也是），12:00 起看本周；周日深夜仍是本周
    let thu = WeeklyDigest.defaultWeek(today: day("2026-10-22"), minute: 10 * 60)
    let range = WeeklyDigest.fetchRange(thu)
    check(thu.monday == day("2026-10-19") && thu.last == day("2026-10-22") && thu.isCurrent && thu.next == nil
          && thu.title == "10月19日 – 25日" && thu.compactLabel == "10月19日–25日"
          && thu.previous.monday == day("2026-10-12") && thu.previous.last == day("2026-10-18") && !thu.previous.isCurrent
          && thu.previous.next == thu && range.from == day("2026-10-12") && range.to == day("2026-10-22"),
          "七日小卷：周四看本周 10月19日 – 25日（算到今天），上一周 10月12日–18日 整周，取数只取这两周")
    let monEarly = WeeklyDigest.defaultWeek(today: day("2026-10-26"), minute: 30)
    let monMorning = WeeklyDigest.defaultWeek(today: day("2026-10-26"), minute: 11 * 60 + 59)
    let monNoon = WeeklyDigest.defaultWeek(today: day("2026-10-26"), minute: 12 * 60)
    let sunLate = WeeklyDigest.defaultWeek(today: day("2026-10-25"), minute: 23 * 60 + 50)
    check(monEarly.monday == day("2026-10-19") && monEarly.last == day("2026-10-25") && !monEarly.isCurrent
          && monEarly.next?.monday == day("2026-10-26") && monMorning == monEarly
          && monNoon.monday == day("2026-10-26") && monNoon.last == day("2026-10-26") && monNoon.next == nil
          && sunLate.monday == day("2026-10-19") && sunLate.last == day("2026-10-25") && sunLate.isCurrent,
          "七日小卷：周一凌晨、11:59 看上一整周（可翻到本周），12:00 起看本周；周日深夜仍是本周")
    let crossMonth = WeeklyDigest.defaultWeek(today: day("2026-10-28"), minute: 600)
    let crossYear = WeeklyDigest.defaultWeek(today: day("2027-01-01"), minute: 600)
    let newYearMonday = WeeklyDigest.defaultWeek(today: day("2027-01-04"), minute: 8 * 60)
    let lastYear = WeeklyDigest.Week(monday: day("2026-12-21"), today: day("2027-01-05"))
    check(crossMonth.title == "10月26日 – 11月1日" && crossMonth.compactLabel == "10月26日–11月1日"
          && crossYear.monday == day("2026-12-28") && crossYear.title == "2026年12月28日 – 2027年1月3日"
          && newYearMonday.monday == day("2026-12-28") && WeeklyDigest.draftDay(newYearMonday) == day("2027-01-03")
          && WeeklyDigest.draftTitle(newYearMonday) == "2026年12月28日–2027年1月3日 周复盘"
          && lastYear.title == "2026年12月21日 – 27日" && WeeklyDigest.draftDay(thu) == day("2026-10-22"),
          "七日小卷：跨月写两个月份，跨年两头都带年份，整周在去年的带年份；草稿补记日期是这周最后一天、不晚于今天")

    // 摘句：珍藏优先，其次心境最好那天的第一篇，其次最长一篇；各取第一句；复盘的小标题与〔本期素材〕段去掉
    let review = RecordEntry(uid: "r", day: day("2026-10-20"), kind: .review, title: "第 43 周复盘",
                             body: "【所得】\n\n〔本期素材 · 10月19日—10月20日，仅供参考〕\n· 落笔 3 篇\n\n论文第三章终于成形，图也重画完了。后面还有很多要改的地方，慢慢来吧。\n【所失】\n睡得太晚")
    let entries = [
        RecordEntry(uid: "a", day: day("2026-10-19"), minute: 600, kind: .diary, body: "早上去跑步。下午开组会。", mood: 3),
        RecordEntry(uid: "b", day: day("2026-10-19"), minute: 900, kind: .note, body: "先完成再完美", pinned: true),
        review,
        RecordEntry(uid: "c", day: day("2026-10-21"), minute: 480, kind: .diary, body: "雨停了\n去图书馆坐了一整天，读完了《置身事内》！", mood: 5),
        RecordEntry(uid: "d", day: day("2026-10-21"), minute: 1200, kind: .diary, body: "晚上散步", mood: 4),
        RecordEntry(uid: "x", day: day("2026-10-12"), kind: .diary, body: "上周的一篇，不该出现在本周摘句里", pinned: true),
    ]
    let quotes = WeeklyDigest.quotes(entries, week: thu)
    check(quotes.map(\.uid) == ["a", "b", "c"] && quotes.first?.text == "早上去跑步。" && quotes.dropFirst().first?.text == "先完成再完美"
          && quotes.last?.text == "雨停了，去图书馆坐了一整天，读完了《置身事内》！",
          "七日小卷摘句：珍藏、心境最好那天（霁）的第一篇、还没选上的里最长一篇，按日期时刻排；没珍藏的复盘不入选（统计句不算自己的话），上周的珍藏不算：\(quotes.map(\.text))")
    var pinnedReview = review
    pinnedReview.pinned = true
    let withPinnedReview = WeeklyDigest.quotes([entries[0], pinnedReview, entries[4]], week: thu)
    let statsReview = RecordEntry(uid: "s", day: day("2026-10-25"), kind: .review, title: "第 43 周复盘",
                                  body: "【所得】\n功课：早睡（23:30 前）6/7 天，力量训练 1/3 天，论文写作 2/5 天。周末把第三章的图重画了一遍，比上周顺手。\n【所失】\n睡得太晚")
    let onlyShort = [RecordEntry(uid: "n", day: day("2026-10-20"), kind: .note, body: "晚上散步"), statsReview]
    let sundayWeek = WeeklyDigest.Week(monday: day("2026-10-19"), today: day("2026-10-26"))
    check(withPinnedReview.map(\.uid) == ["a", "r", "d"] && withPinnedReview[1].text == "论文第三章终于成形，图也重画完了。"
          && WeeklyDigest.quotes(onlyShort, week: sundayWeek).map(\.uid) == ["n"],
          "七日小卷摘句：珍藏的复盘照样入选（去掉小标题和素材段）；复盘再长也不当“最长一篇”：\(WeeklyDigest.quotes(onlyShort, week: sundayWeek).map(\.text))")
    func sentence(_ body: String) -> String { WeeklyDigest.firstSentence(RecordEntry(uid: "f", day: day("2026-10-22"), kind: .diary, body: body)) }
    let sentences = [sentence("早。\n今天去爬山了，很累但是很开心。"), sentence("好累！\n终于交稿"), sentence("- 买菜\n- 做饭"),
                     sentence("### 周四\n读了半本书"), sentence("· 跑三次步 —— 做到了\n今天跑了五公里。"), sentence("1. 早起\n2、读书\n（3）散步"),
                     sentence("#运动 跑了五公里。"), sentence("-5 度，好冷。"), sentence("> 引一句\n* 再记一句"), sentence("· 买了花")]
    check(sentences == ["早。今天去爬山了，很累但是很开心。", "好累！终于交稿", "买菜，做饭", "周四，读了半本书", "今天跑了五公里。",
                        "早起，读书，散步", "#运动 跑了五公里。", "-5 度，好冷。", "引一句，再记一句", "买了花"],
          "七日小卷摘句：句号叹号后换行不补“，”；去掉“- ”“### ”“1. ”“2、”“（3）”“> ”“* ”“· ”行首记号，跳过“· … —— 做到了”回访行；“#标签”“-5 度”不动：\(sentences)")
    let long = RecordEntry(uid: "l", day: day("2026-10-22"), kind: .diary, body: String(repeating: "长", count: 80))
    check(WeeklyDigest.firstSentence(long) == String(repeating: "长", count: 48) + "……"
          && WeeklyDigest.firstSentence(RecordEntry(uid: "t", day: day("2026-10-22"), kind: .note, title: "只有标题")) == "只有标题"
          && WeeklyDigest.firstSentence(RecordEntry(uid: "e", day: day("2026-10-22"), kind: .review, body: ReviewPeriod.template)) == ""
          && WeeklyDigest.quotes([], week: thu).isEmpty,
          "七日小卷摘句：超长截到 48 字加“……”，正文空用标题，空白复盘模板不算一句，没有落笔没有摘句")

    // 心境七日：10月19日 平、21日 晴霁平均（4.5 → 霁）、20日写了没记心境是墨点、22日（今天）没写、23–25日还没到
    let marks = WeeklyDigest.moodMarks(entries, week: thu)
    check(marks.map(\.mark) == [.mood(3), .ink, .mood(5), .today, .future, .future, .future]
          && WeeklyDigest.moodTally(marks) == "霁 1 · 平 1 · 未记 1",
          "七日小卷心境：有心境上色、写了没记是墨点、今天还没写单独一格不算未记、还没到的不画；“霁 1 · 平 1 · 未记 1”：\(WeeklyDigest.moodTally(marks))")
    let mondayOnly = [RecordEntry(uid: "m", day: day("2026-10-19"), kind: .diary, body: "周一", mood: 4)]
    let thursdayMarks = WeeklyDigest.moodMarks(mondayOnly, week: thu)
    let todayInk = WeeklyDigest.moodMarks(mondayOnly + [RecordEntry(uid: "t", day: day("2026-10-22"), kind: .note, body: "今天一句")], week: thu)
    let pastMarks = WeeklyDigest.moodMarks(mondayOnly, week: WeeklyDigest.Week(monday: day("2026-10-19"), today: day("2026-10-28")))
    check(thursdayMarks.map(\.mark) == [.mood(4), .blank, .blank, .today, .future, .future, .future]
          && WeeklyDigest.moodTally(thursdayMarks) == "晴 1 · 未记 2"
          && todayInk[3].mark == .ink && WeeklyDigest.moodTally(todayInk) == "晴 1 · 未记 3"
          && !pastMarks.contains { $0.mark == .today || $0.mark == .future } && WeeklyDigest.moodTally(pastMarks) == "晴 1 · 未记 6",
          "七日小卷心境：周四上午今天还没写不算未记（“晴 1 · 未记 2”）；今天写了没记心境照常是墨点；过去的周没有“今天”这一格")

    // 功课：每天一项（上周 7/7，本周一到三 3/3、今天还没打不算缺）、指定星期（一三五）、每周 3 次、本周才立的
    func habit(_ spec: HabitSpec, _ done: [String], today now: LocalDay) -> HabitStats {
        HabitStats(spec: spec, logs: done.map { HabitLogValue(day: day($0), completed: true, quantity: nil) }, today: now)
    }
    let now = day("2026-10-22")
    let start = day("2026-09-01")
    let daily = habit(HabitSpec(frequency: .daily, startDay: start),
                      ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18",
                       "2026-10-19", "2026-10-20", "2026-10-21"], today: now)
    let mwf = habit(HabitSpec(frequency: .weekdays, weekdays: [0, 2, 4], startDay: start), ["2026-10-12", "2026-10-19"], today: now)
    let weekly = habit(HabitSpec(frequency: .weekly, targetPerWeek: 3, startDay: start),
                       ["2026-10-13", "2026-10-15", "2026-10-17", "2026-10-18"], today: now)
    let fresh = habit(HabitSpec(frequency: .daily, startDay: day("2026-10-21")), ["2026-10-21", "2026-10-22"], today: now)
    check(pair(WeeklyDigest.tally(daily, week: thu)) == [3, 3] && pair(WeeklyDigest.tally(daily, week: thu.previous)) == [7, 7]
          && pair(WeeklyDigest.tally(mwf, week: thu)) == [1, 2] && pair(WeeklyDigest.tally(mwf, week: thu.previous)) == [1, 3]
          && pair(WeeklyDigest.tally(weekly, week: thu.previous)) == [3, 3] && pair(WeeklyDigest.tally(weekly, week: thu)) == [0, 1]
          && pair(WeeklyDigest.tally(fresh, week: thu)) == [2, 2] && WeeklyDigest.tally(fresh, week: thu.previous) == nil,
          "七日小卷功课：每天的数到今天（今天没打不算缺）、指定星期只数轮到的、每周 N 次本周按已过天数折算、本周才立的上周不算")
    let h = WeeklyDigest.habits([("冥想", daily), ("跑步", mwf), ("运动", weekly), ("早睡", fresh)], week: thu)
    check(h != nil && h?.lines.count == 4 && abs((h?.rate ?? 0) - 6.0 / 8.0) < 1e-9 && abs((h?.previousRate ?? 0) - 11.0 / 13.0) < 1e-9
          && h?.steadiest?.title == "冥想" && h?.steadiest?.fraction == "3/3"
          && h?.tending?.title == "运动" && h?.tending?.fraction == "0/1"
          && h.map { WeeklyDigest.habitHeadline($0, week: thu) } == "本周完成 75%（上周 85%）"
          && (h.map { WeeklyDigest.habitHeadline($0, week: thu.previous) } ?? "") == "那一周完成 75%（前一周 85%）",
          "七日小卷功课：本周 75%（上周 85%）、最稳 冥想 3/3（同为满分取次数多的）、可再护持 运动 0/1：\(h.map { WeeklyDigest.habitHeadline($0, week: thu) } ?? "nil")")
    check(WeeklyDigest.habits([], week: thu) == nil
          && WeeklyDigest.habits([("冥想", daily)], week: thu)?.tending == nil
          && WeeklyDigest.habits([("早睡", fresh)], week: thu)?.previousRate == nil,
          "七日小卷功课：没有功课整节不显示；只有一项不写“可再护持”；上周还没有功课时不写上周")

    // 灵石：只算这周已过的日子、计入消费的扣款；最多一类；账单没导到这周最后一天时写“不全”；只有手记不写
    func spendRow(_ key: String, _ cents: Int, _ category: String, ignored: Bool = false) -> FinanceTransaction {
        var row = ManualExpense.transaction(id: "w\(key)\(cents)", day: day(key), cents: cents, category: category, description: category, note: "", reason: "")
        row.account = "CBA"
        if ignored { row.ignored = true }
        return row
    }
    var investment = spendRow("2026-10-22", 50000, "餐饮与外卖")
    investment.category = "投资转账"
    let rows = [spendRow("2026-10-19", 4000, "餐饮与外卖"), spendRow("2026-10-20", 10000, "餐饮与外卖"),
                spendRow("2026-10-21", 6240, "交通出行"), spendRow("2026-10-21", 9900, "购物", ignored: true),
                investment, spendRow("2026-10-18", 3000, "餐饮与外卖"),
                ManualExpense.transaction(id: "m1", day: day("2026-10-22"), cents: 1850, category: "餐饮与外卖", description: "午饭", note: "", reason: "")]
    func source(_ first: String, _ last: String, account: String = "CBA") -> FinanceSource {
        FinanceSource(sha256: "wk\(first)\(account)", account: account, rawCsv: "", importedAt: "", rows: 0, start: first, end: last)
    }
    let partial = WeeklyDigest.spend(rows, sources: [source("2026-09-01", "2026-09-30"), source("2026-10-01", "2026-10-20"),
                                                     source("2026-08-01", "2026-10-22", account: "ANZ")], week: thu)
    check(partial?.cents == 4000 + 10000 + 6240 + 1850 && partial?.topCategory == "餐饮与外卖" && partial?.topCents == 15850
          && partial?.coveredThrough == day("2026-10-20") && partial?.incomplete == true
          && partial.map { WeeklyDigest.spendHeadline($0, week: thu) } == "本周花费 $220.90 · 最多一类：餐饮与外卖 $158.50"
          && partial.flatMap { WeeklyDigest.spendNote($0, week: thu) } == "账单只导到 10月20日，本周不全",
          "七日小卷灵石：本周花费 $220.90（不计“不计入统计”、投资转账、上周的），最多一类餐饮与外卖；CBA 只导到 10月20日 → 本周不全")
    let manualOnly = WeeklyDigest.spend(rows, sources: [], week: thu)
    let lastWeekFull = WeeklyDigest.spend(rows, sources: [source("2026-10-01", "2026-10-20")], week: thu.previous)
    check(manualOnly?.coveredThrough == nil && manualOnly?.incomplete == false && manualOnly.flatMap { WeeklyDigest.spendNote($0, week: thu) } == nil
          && lastWeekFull?.cents == 3000 && lastWeekFull?.incomplete == false
          && lastWeekFull.map { WeeklyDigest.spendHeadline($0, week: thu.previous) } == "那一周花费 $30.00 · 最多一类：餐饮与外卖 $30.00"
          && WeeklyDigest.spend([], sources: [], week: thu) == nil
          && WeeklyDigest.coveredThrough([source("2026-10-01", "2026-10-20"), source("2026-10-15", "2026-10-25", account: ManualExpense.account)],
                                         activeSince: day("2026-09-01")) == day("2026-10-20"),
          "七日小卷灵石：只有手记不写“不全”；上一周账单导全了不写；一笔都没有整节不显示；手记账户不算账单")
    // 停用的旧卡（半年前就不再导入）不拖累“导到哪天”：与复盘素材本期花费（#12 ReviewThread.bankThrough）同一条规则
    let withOldCard = WeeklyDigest.spend(rows, sources: [source("2026-10-01", "2026-10-22"), source("2025-01-01", "2026-03-31", account: "OLD")], week: thu)
    let onlyOldCard = WeeklyDigest.spend(rows, sources: [source("2025-01-01", "2026-03-31", account: "OLD")], week: thu)
    let pastPartial = WeeklyDigest.spend(rows, sources: [source("2026-10-01", "2026-10-16")], week: thu.previous)
    check(withOldCard?.coveredThrough == day("2026-10-22") && withOldCard?.incomplete == false
          && withOldCard.flatMap { WeeklyDigest.spendNote($0, week: thu) } == nil
          && onlyOldCard?.coveredThrough == day("2026-03-31") && onlyOldCard?.incomplete == true
          && WeeklyDigest.bankThrough([("CBA", "2026-10-22"), ("OLD", "2026-03-31")], activeSince: day("2026-09-04")) == "2026-10-22"
          && WeeklyDigest.bankThrough([("CBA", "2026-10-20"), ("ANZ", "2026-10-22")], activeSince: day("2026-09-04")) == "2026-10-20"
          && WeeklyDigest.bankThrough([("OLD", "2026-03-31"), ("OLDER", "2025-12-31")], activeSince: day("2026-09-04")) == "2026-03-31"
          && WeeklyDigest.bankThrough([], activeSince: day("2026-09-04")) == nil
          && pastPartial.flatMap { WeeklyDigest.spendNote($0, week: thu.previous) } == "账单只导到 10月16日，那一周不全",
          "七日小卷灵石：有停用的旧卡时只看还在导的账户，不写“不全”；都停用了取最晚的那天；过去的周写“那一周不全”")

    // 洞见：只挑正向的几类；挑不出时看这一周动笔的天数比上周多才说
    let streak = Insight(kind: .writingStreak, text: "最长连续落笔 9 天。", basis: "", sample: 9)
    let fragile = Insight(kind: .fragileHabit, text: "「读书」最容易中断", basis: "", sample: 3)
    let spendDay = Insight(kind: .spendWeekday, text: "周五花得多", basis: "", sample: 8)
    check(WeeklyDigest.pickInsight([fragile, spendDay, streak]) == streak && WeeklyDigest.pickInsight([fragile, spendDay]) == nil
          && WeeklyDigest.weekNote(entries, week: thu) == WeeklyDigest.Note(text: "本周动笔 3 天，比上周多 2 天。", basis: "本周对上周 · 动笔天数")
          && WeeklyDigest.weekNote(entries, week: thu.previous) == nil,
          "七日小卷洞见：只取正向的一条（易断、花钱的不取）；本周动笔 3 天比上周多 2 天才说")
    // 这一周自己的变化：过去的周叫“那一周 / 前一周”；动笔天数 → 心境 → 功课完成率，挑第一条
    let past = thu.previous
    func diary(_ key: String, _ mood: Int? = nil) -> RecordEntry { RecordEntry(uid: "p\(key)", day: day(key), kind: .diary, body: "一句", mood: mood) }
    let moreDays = [diary("2026-10-12"), diary("2026-10-14"), diary("2026-10-16"), diary("2026-10-07")]
    let brighter = [diary("2026-10-12", 4), diary("2026-10-14", 4), diary("2026-10-06", 3), diary("2026-10-08", 3)]
    let habitUp = WeeklyDigest.HabitWeek(rate: 0.61, previousRate: 0.56, steadiest: nil, tending: nil, lines: [])
    let habitFlat = WeeklyDigest.HabitWeek(rate: 0.59, previousRate: 0.56, steadiest: nil, tending: nil, lines: [])
    let pastNotes = [WeeklyDigest.weekNote(moreDays, week: past), WeeklyDigest.weekNote(brighter, week: past),
                     WeeklyDigest.weekNote([], habits: habitUp, week: past)]
    check(pastNotes.map { $0?.text } == ["那一周动笔 3 天，比前一周多 2 天。", "那一周心境平均「晴」，前一周是「平」。", "那一周功课完成 61%，比前一周高 5 个百分点。"]
          && pastNotes.allSatisfy { $0?.basis.hasPrefix("那一周对前一周 · ") == true }
          && WeeklyDigest.weekNote([], habits: habitFlat, week: past) == nil
          && WeeklyDigest.weekNote(brighter, habits: habitUp, week: past)?.text == "那一周心境平均「晴」，前一周是「平」。",
          "七日小卷洞见：这一周自己的正向变化——动笔更多、心境更明朗、功课完成率高 5 个百分点以上；只报喜：\(pastNotes.map { $0?.text ?? "nil" })")
    // 卷中洞见（近 90 日）只在看本周时退回去用；看过去的周不出现（那是那一周之后的事）
    let own = WeeklyDigest.weekNote(moreDays, week: past)
    check(WeeklyDigest.insight(own: nil, rolling: [fragile, streak], week: past, windowDays: 90) == nil
          && WeeklyDigest.insight(own: nil, rolling: [fragile, streak], week: past.previous, windowDays: 90) == nil
          && WeeklyDigest.insight(own: own, rolling: [streak], week: past, windowDays: 90) == own
          && WeeklyDigest.insight(own: nil, rolling: [fragile, streak], week: thu, windowDays: 90)
              == WeeklyDigest.Note(text: streak.text, basis: "卷中洞见 · 近 90 日 · \(streak.basis)")
          && WeeklyDigest.insight(own: own, rolling: [streak], week: thu, windowDays: 90) == own
          && WeeklyDigest.insight(own: nil, rolling: [fragile], week: thu, windowDays: 90) == nil,
          "七日小卷洞见：看过去的周时不出现近 90 日的洞见；本周先说这一周自己的变化，没有才退回卷中洞见")
    // 看过去的周：同一张卷上只叫“那一周 / 前一周”，不出现“这周 / 上周 / 本周”
    let pastWords = [h.map { WeeklyDigest.habitHeadline($0, week: past) }, lastWeekFull.map { WeeklyDigest.spendHeadline($0, week: past) },
                     pastPartial.flatMap { WeeklyDigest.spendNote($0, week: past) }].map { $0 ?? "" } + pastNotes.map { $0?.text ?? "" }
        + [past.selfName, past.priorName]
    check(pastWords.allSatisfy { !$0.isEmpty && !$0.contains("这周") && !$0.contains("上周") && !$0.contains("本周") }
          && thu.selfName == "本周" && thu.priorName == "上周" && past.selfName == "那一周" && past.priorName == "前一周"
          && monEarly.selfName == "那一周",
          "七日小卷措辞：看过去的周（含周一上午默认的上一整周）统一叫“那一周 / 前一周”：\(pastWords)")

    // 往前翻到最早一条记录所在的那一周为止；一条记录都没有时不能翻
    check(!thu.hasPrevious(earliest: nil) && thu.hasPrevious(earliest: day("2026-10-14")) && !thu.previous.hasPrevious(earliest: day("2026-10-14"))
          && thu.previous.hasPrevious(earliest: day("2026-10-11")) && !thu.hasPrevious(earliest: day("2026-10-19"))
          && !thu.hasPrevious(earliest: day("2026-10-22")),
          "七日小卷翻页：“‹ 上一周”翻到最早一条记录所在的周为止，全新使用者不能往前翻")
    // 其一没有摘句：本周空卷多一句怎么写满；过去的空周只说没有记录
    let emptyNow = WeeklyDigest.emptyWords(week: thu, hasEntries: false, blank: true)
    let emptyPast = WeeklyDigest.emptyWords(week: past, hasEntries: false, blank: true)
    let emptyPastSome = WeeklyDigest.emptyWords(week: past, hasEntries: false, blank: false)
    let emptyNowSome = WeeklyDigest.emptyWords(week: thu, hasEntries: false, blank: false)
    check(emptyNow.line == "这一周还没有落笔。" && emptyNow.hint == "写下一句、打一次卡、记一笔账，这一卷就会慢慢写满。"
          && emptyPast.line == "那一周没有留下记录。" && emptyPast.hint == nil
          && emptyPastSome.line == "那一周没有落笔。" && emptyPastSome.hint == nil
          && emptyNowSome.line == "这一周还没有落笔。" && emptyNowSome.hint == nil
          && WeeklyDigest.emptyWords(week: thu, hasEntries: true, blank: false).line == "这一周的落笔都还没有成句的话。",
          "七日小卷空卷：本周空着写“这一周还没有落笔。”加一句怎么写满；过去的空周写“那一周没有留下记录。”，不说“慢慢写满”")

    // 卷尾：摘句一段、接在已有草稿后面、请 AI 写周信那句话
    check(WeeklyDigest.quoteBlock(quotes, today: now) == "〔本周摘句〕\n· 「早上去跑步。」（10月19日）\n· 「先完成再完美」（10月19日）\n· 「雨停了，去图书馆坐了一整天，读完了《置身事内》！」（10月21日）"
          && WeeklyDigest.quoteBlock([], today: now) == ""
          && WeeklyDigest.appended("写了一半的日记\n\n  ", "【所得】") == "写了一半的日记\n\n【所得】"
          && WeeklyDigest.appended(" \n", "【所得】") == "【所得】"
          && WeeklyDigest.aiPrompt(thu) == "用 apt-record 技能读我的快照，给我写这一周（10月19日–25日）的小结，问我一两个问题后投成一篇周复盘。",
          "七日小卷卷尾：〔本周摘句〕带日期；接在后面空一行；周信那句话带这周的日期")
    // 存草稿：落笔框已是这一周的周复盘时不再问、不再叠；“接在后面”不把月复盘、别的周的周复盘悄悄改成这一周的
    typealias Head = WeeklyDigest.DraftHead
    let diaryHead = Head(kind: "diary", period: "week", day: nil, title: "")
    let monthHead = Head(kind: "review", period: "month", day: "2026-10-31", title: "")
    let thisWeekHead = Head(kind: "review", period: "week", day: nil, title: "我的周复盘")
    let otherWeekHead = Head(kind: "review", period: "week", day: "2026-10-11", title: "")
    check(WeeklyDigest.appendedHead(diaryHead, week: thu) == Head(kind: "review", period: "week", day: "2026-10-22", title: "10月19日–25日 周复盘")
          && WeeklyDigest.appendedHead(monthHead, week: thu) == monthHead
          && WeeklyDigest.appendedHead(otherWeekHead, week: thu) == otherWeekHead
          && WeeklyDigest.appendedHead(thisWeekHead, week: thu) == Head(kind: "review", period: "week", day: "2026-10-22", title: "我的周复盘")
          && WeeklyDigest.appendedHead(Head(kind: "review", period: "week", day: "2026-10-18", title: ""), week: past)
              == Head(kind: "review", period: "week", day: "2026-10-18", title: "10月12日–18日 周复盘")
          && WeeklyDigest.isSameWeekDraft(Head(kind: "review", period: "week", day: "2026-10-22", title: " 10月19日–25日 周复盘 "), week: thu)
          && !WeeklyDigest.isSameWeekDraft(Head(kind: "diary", period: "week", day: nil, title: "10月19日–25日 周复盘"), week: thu)
          && !WeeklyDigest.isSameWeekDraft(Head(kind: "review", period: "week", day: nil, title: "10月19日–25日 周复盘"), week: past),
          "七日小卷存草稿：日记接上后改成本周复盘；月复盘、别的周的周复盘只接素材不改周期日期；同一周的周复盘草稿认得出来")
}

// MARK: r2-review：#12 复盘闭环——【下一步】拆条、回访插回正文、周一补写上周、本期花费（Core/ReviewThread.swift）
do {
    // 1. 【下一步】拆条：换行、“；”“。”、编号与圆点都拆；“1.5 小时”不当编号；没有模板、空段都是 []
    let template = ReviewPeriod.template
    check(ReviewThread.nextSteps(from: template).isEmpty && ReviewThread.nextSteps(from: "这周还行，就是有点累。").isEmpty
          && ReviewThread.nextSteps(from: "【所得】写了 6000 字\n【下一步】\n").isEmpty,
          "【下一步】：空白模板、没有模板、段是空的 → 不回访")
    let semi = ReviewThread.nextSteps(from: "【所得】论文写了 6000 字。\n【所悟】晚上 11 点后的产出几乎都要重写。\n【下一步】23:30 前收工；每天上午先写 90 分钟。")
    let joined = ReviewThread.nextSteps(from: "【所得】\n读完了一本书。\n\n【所失】\n外卖点多了。\n\n【所悟】\n先完成再完美。\n\n【下一步】\n23:30 前收工。每天上午先写 90 分钟。")
    check(semi == ["23:30 前收工", "每天上午先写 90 分钟"] && joined == semi,
          "【下一步】按“；”和句号拆，去掉句末标点：\(semi) / \(joined)")
    let numbered = ReviewThread.nextSteps(from: "【下一步】\n1. 跑三次步\n2、读完第三章\n（3）早睡\n- 周三前回导师邮件\n· 每天冥想 10 分钟\n• 记账")
    check(numbered == ["跑三次步", "读完第三章", "早睡", "周三前回导师邮件", "每天冥想 10 分钟"],
          "【下一步】编号、短横、圆点都去掉，最多 5 条：\(numbered)")
    let inline = ReviewThread.nextSteps(from: "【下一步】1. 跑步 2. 读书 （3）早睡")
    let decimal = ReviewThread.nextSteps(from: "【下一步】每天阅读 1.5 小时，周末 2.5 小时")
    check(inline == ["跑步", "读书", "早睡"] && decimal == ["每天阅读 1.5 小时，周末 2.5 小时"],
          "同一行接着写的编号也拆开；小数不当编号：\(inline) / \(decimal)")
    let twice = ReviewThread.nextSteps(from: "【下一步】\n\n【所悟】x\n【下一步】至少运动三次；至少运动三次。")
    let evening = ReviewThread.nextSteps(from: "【今日一愿】写完第三章 3 页（已成）\n【所得】写完了\n【下一步】明早先改摘要")
    let material = ReviewThread.nextSteps(from: "【下一步】早睡\n〔本期素材 · 10月19日—10月25日，仅供参考〕\n· 落笔 3 篇。")
    check(twice == ["至少运动三次"] && evening == ["明早先改摘要"] && material == ["早睡"],
          "同名两段取有内容的那段、重复只留一条；晚课合成的日省认得；插进来的〔本期素材〕不算下一步：\(twice) / \(evening) / \(material)")
    let long = ReviewThread.nextSteps(from: "【下一步】" + String(repeating: "长", count: 80))
    check(long.count == 1 && long[0].count == ReviewThread.maxStepLength + 1 && long[0].hasSuffix("…"), "一条太长只留 60 字加“…”")

    // 2. 回访插回正文：做到的进【所得】，没做到的进【所失】，改主意的进【所悟】；插过的不重复；没模板补段名
    let picks: [(text: String, verdict: ReviewThread.Verdict)] = [("跑三次步", .done), ("早睡", .missed), ("周三前回邮件", .changed), ("读完第三章", .done)]
    let filled = ReviewThread.insert(picks, into: template)
    check(filled == "【所得】\n· 跑三次步 —— 做到了\n· 读完第三章 —— 做到了\n\n【所失】\n· 早睡 —— 没做到\n\n【所悟】\n· 周三前回邮件 —— 改主意了\n\n【下一步】\n",
          "回访插进空白模板：各进各段，段间空行不变：\(filled.debugDescription)")
    let written = "【所得】论文写了 6000 字。\n【所失】周三熬夜。\n【所悟】晚上效率低。\n【下一步】早睡"
    let intoWritten = ReviewThread.insert([("跑三次步", .done), ("早睡", .missed)], into: written)
    check(intoWritten == "【所得】论文写了 6000 字。\n· 跑三次步 —— 做到了\n【所失】周三熬夜。\n· 早睡 —— 没做到\n【所悟】晚上效率低。\n【下一步】早睡"
          && ReviewThread.insert([("跑三次步", .done), ("早睡", .missed)], into: intoWritten) == intoWritten,
          "回访接在已写内容后面；再插一次不重复：\(intoWritten.debugDescription)")
    let plain = ReviewThread.insert([("跑三次步", .done)], into: "这周还行。")
    let empty = ReviewThread.insert([("跑三次步", .done)], into: "")
    check(plain == "这周还行。\n\n【所得】\n· 跑三次步 —— 做到了\n" && empty == "【所得】\n· 跑三次步 —— 做到了\n",
          "正文里没有那一段：末尾补上段名：\(plain.debugDescription)")
    let withBlock = "【所得】\n\n【所失】\n周三熬夜。\n\n〔本期素材 · 10月19日—10月25日，仅供参考〕\n· 落笔 3 篇。\n\n【所悟】\n"
    check(ReviewThread.insert([("早睡", .missed)], into: withBlock)
          == "【所得】\n\n【所失】\n周三熬夜。\n· 早睡 —— 没做到\n\n〔本期素材 · 10月19日—10月25日，仅供参考〕\n· 落笔 3 篇。\n\n【所悟】\n",
          "段里已插过〔本期素材〕：回访接在素材上面")

    // 3. 回访选择的存取：再点同一枚是取消，换一枚是改选
    var raw = ReviewThread.toggled("", key: "2026-10-18 跑三次步", verdict: .done)
    raw = ReviewThread.toggled(raw, key: "2026-10-18 早睡", verdict: .missed)
    raw = ReviewThread.toggled(raw, key: "2026-10-18 早睡", verdict: .changed)
    let map = ReviewThread.decode(raw)
    let cleared = ReviewThread.decode(ReviewThread.toggled(raw, key: "2026-10-18 跑三次步", verdict: .done))
    check(map == ["2026-10-18 跑三次步": .done, "2026-10-18 早睡": .changed] && cleared == ["2026-10-18 早睡": .changed]
          && ReviewThread.decode("坏的一行\nmaybe\t跑步\ndone\t").isEmpty,
          "回访选择：点选、改选、再点取消；认不出的行跳过：\(raw.debugDescription)")

    // 4. 说法：小标题“10月12日–18日 周复盘”；跨月、跨年、不在今年
    let today = LocalDay(key: "2026-10-22")!
    check(ReviewThread.promiseLabel(period: "week", day: LocalDay(key: "2026-10-18")!, today: today) == "10月12日–18日 周复盘"
          && ReviewThread.promiseLabel(period: "week", day: LocalDay(key: "2026-10-01")!, today: today) == "9月28日–10月4日 周复盘"
          && ReviewThread.promiseLabel(period: "day", day: LocalDay(key: "2026-10-21")!, today: today) == "10月21日 日省"
          && ReviewThread.promiseLabel(period: "month", day: LocalDay(key: "2026-09-30")!, today: today) == "9月1日–30日 月复盘"
          && ReviewThread.promiseLabel(period: "", day: LocalDay(key: "2026-10-20")!, today: today) == "10月20日 复盘"
          && ReviewThread.promiseLabel(period: "week", day: LocalDay(key: "2025-12-31")!, today: today) == "2025年12月29日–2026年1月4日 周复盘"
          && ReviewThread.promiseLabel(period: "week", day: LocalDay(key: "2025-10-12")!, today: today) == "2025年10月6日–12日 周复盘",
          "回访小标题：周 / 跨月 / 日省 / 月 / 没填周期 / 跨年 / 不在今年")

    // 5. 周一补写上周：只在周一、周复盘、补记日期没改过时问
    let monday = LocalDay(key: "2026-10-19")!
    let offer = ReviewThread.lastWeekOffer(today: monday, period: .week, picked: nil)
    check(offer?.first.key == "2026-10-12" && offer?.last.key == "2026-10-18"
          && ReviewThread.lastWeekOffer(today: monday, period: .week, picked: monday) != nil
          && ReviewThread.lastWeekOffer(today: monday, period: .week, picked: monday.adding(days: -1)) == nil
          && ReviewThread.lastWeekOffer(today: monday, period: .month, picked: nil) == nil
          && ReviewThread.lastWeekOffer(today: today, period: .week, picked: nil) == nil
          && offer.map { ReviewThread.lastWeekOfferText($0, today: monday) } == "今天是周一：要写上一周（10月12日–18日）的复盘吗？",
          "周一补写上周：周一 + 周复盘 + 补记日期是今天才问；改过日期、月复盘、周四都不问")

    // 6. 本期花费：口径同账簿（不计入的、转账不算）；没导全写“不全：已知”；比上一期（没过完比同期）；没有花费不写
    func tx(_ date: String, _ cents: Int, _ category: String, ignored: Bool? = nil) -> FinanceTransaction {
        var row = FinanceTransaction(id: UUID().uuidString, date: date, amountCents: cents, balanceCents: 0, description: "x", account: "CBA",
                                     category: category, kind: cents < 0 ? "消费" : "退款", needsReview: false, reason: "", sourceLine: 0)
        row.ignored = ignored
        return row
    }
    let rows = [tx("2026-10-12", -10000, "餐饮与外卖"), tx("2026-10-14", -5000, "交通出行"), tx("2026-10-15", -20000, "投资转账"),
                tx("2026-10-19", -14000, "餐饮与外卖"), tx("2026-10-20", -3000, "交通出行"), tx("2026-10-21", -900, "购物", ignored: true),
                tx("2026-10-21", 2000, "餐饮与外卖")]
    let week = (first: LocalDay(key: "2026-10-19")!, last: LocalDay(key: "2026-10-25")!)
    let sofar = (first: week.first, last: today)
    let full = ReviewThread.spendingLine(rows: rows, first: week.first, last: week.last, period: .week, bankThrough: "2026-10-25", today: today)
    let partial = ReviewThread.spendingLine(rows: rows, first: sofar.first, last: sofar.last, period: .week, bankThrough: "2026-10-22", today: today)
    let behind = ReviewThread.spendingLine(rows: rows, first: sofar.first, last: sofar.last, period: .week, bankThrough: "2026-10-20", today: today)
    let manual = ReviewThread.spendingLine(rows: rows, first: sofar.first, last: sofar.last, period: .week, bankThrough: nil, today: today)
    check(full == "灵石：本期花费 $170.00（较上周 +13%），最多一类是 餐饮与外卖 $140.00。"
          && partial == "灵石：本期花费 $170.00（较上周同期 +13%），最多一类是 餐饮与外卖 $140.00。"
          && behind == "灵石：账单只导到 10月20日，本期花费不全：已知 $170.00。"
          && manual == partial,
          "本期花费：整周比上周、没过完比上周同期（转账、不计入的不算）；银行流水没导到写“不全：已知”；只有手记照常比：\(full ?? "nil") / \(partial ?? "nil") / \(behind ?? "nil")")
    let prevBehind = ReviewThread.spendingLine(rows: Array(rows.dropFirst(3)), first: week.first, last: week.last, period: .week, bankThrough: "2026-10-25", today: today)
    let flat = ReviewThread.spendingLine(rows: [tx("2026-10-13", -5000, "购物"), tx("2026-10-20", -5000, "购物")],
                                         first: week.first, last: week.last, period: .week, bankThrough: nil, today: today)
    let daily = ReviewThread.spendingLine(rows: rows, first: today.adding(days: -3), last: today.adding(days: -3), period: .day, bankThrough: nil, today: today)
    check(prevBehind == "灵石：本期花费 $170.00，最多一类是 餐饮与外卖 $140.00。"
          && flat == "灵石：本期花费 $50.00（与上周持平），全在 购物。"
          && daily == "灵石：本期花费 $140.00，全在 餐饮与外卖。"
          && ReviewThread.spendingLine(rows: rows, first: LocalDay(key: "2026-10-01")!, last: LocalDay(key: "2026-10-07")!, period: .week, bankThrough: nil, today: today) == nil
          && ReviewThread.spendingLine(rows: [], first: week.first, last: week.last, period: .week, bankThrough: nil, today: today) == nil,
          "上一期是 0 不比、持平写“与上周持平”、日省不比；只有一类写“全在 …”不重复总额；这一期没有花费不写：\(prevBehind ?? "nil") / \(flat ?? "nil") / \(daily ?? "nil")")
    let month = ReviewThread.previous(period: .month, first: LocalDay(key: "2026-10-01")!, last: today)
    let fullMonth = ReviewThread.previous(period: .month, first: LocalDay(key: "2026-03-01")!, last: LocalDay(key: "2026-03-31")!)
    let event = ReviewThread.previous(period: .event, first: LocalDay(key: "2026-10-16")!, last: today)
    check(month.map { "\($0.first.key)…\($0.last.key) \($0.name)" } == "2026-09-01…2026-09-22 上月同期"
          && fullMonth.map { "\($0.first.key)…\($0.last.key) \($0.name)" } == "2026-02-01…2026-02-28 上月"
          && event.map { "\($0.first.key)…\($0.last.key) \($0.name)" } == "2026-10-09…2026-10-15 前 7 天"
          && ReviewThread.previous(period: .day, first: today, last: today) == nil,
          "上一期：月没过完比上月同期、整月比上月（2 月 28 天）、事后复盘比前 7 天、日省不比")
    check(ReviewThread.bankThrough([("CBA", "2026-10-18"), ("CBA", "2026-10-20"), ("ING", "2026-10-15"), ("旧卡", "2024-03-31")],
                                   activeSince: LocalDay(key: "2026-09-04")!) == "2026-10-15"
          && ReviewThread.bankThrough([("旧卡", "2024-03-31"), ("旧卡2", "2024-05-31")], activeSince: LocalDay(key: "2026-09-04")!) == "2024-05-31"
          && ReviewThread.bankThrough([], activeSince: today) == nil,
          "银行流水导到哪天：还在用的账户里最早的那天（早已停用的旧卡不拖累）；都停用取最晚；没导入过 nil")
    check(ReviewThread.inferPeriod(first: week.first, last: week.last) == .week && ReviewThread.inferPeriod(first: week.first, last: today) == .week
          && ReviewThread.inferPeriod(first: LocalDay(key: "2026-10-01")!, last: today) == .month
          && ReviewThread.inferPeriod(first: LocalDay(key: "2026-06-01")!, last: LocalDay(key: "2026-06-07")!) == .week
          && ReviewThread.inferPeriod(first: today.adding(days: -6), last: today) == .event
          && ReviewThread.inferPeriod(first: today, last: today) == .day,
          "只给首末两天时猜周期：周一起的是周（6 月 1 日是周一也算周）、1 日起同月是月、正好 7 天是事后复盘")
}

// MARK: r2-review 修复：#12 段名只认行首、改签换行、插过不再引着插、【下一步】常见写法、同一期的“上次”、只有一类的花费、账单口径
do {
    let template = ReviewPeriod.template
    // 1. 段名只认行首的五个（所得 / 所失 / 所悟 / 下一步 / 今日一愿）：正文里写的【三体】【重要】不截断，回访也不插进句子中间
    let book = ReviewThread.nextSteps(from: "【下一步】读完【三体】第二部；周末去爬山")
    let important = ReviewThread.nextSteps(from: "【所得】x\n【下一步】\n先做【重要】那件事\n周末去爬山")
    let indented = ReviewThread.nextSteps(from: "【所得】x\n  【下一步】早睡")
    check(book == ["读完【三体】第二部", "周末去爬山"] && important == ["先做【重要】那件事", "周末去爬山"] && indented == ["早睡"],
          "【下一步】里自己写的【】不当段名；行首有空格的段名也认：\(book) / \(important) / \(indented)")
    let intoBook = ReviewThread.insert([("跑步", .done)], into: "【所得】读完【三体】\n【所失】熬夜")
    let midLine = ReviewThread.insert([("跑步", .done)], into: "上周我在【所得】里写过\n【所失】熬夜")
    check(intoBook == "【所得】读完【三体】\n· 跑步 —— 做到了\n【所失】熬夜"
          && midLine == "上周我在【所得】里写过\n【所失】熬夜\n\n【所得】\n· 跑步 —— 做到了\n"
          && ReviewThread.section("所得", in: "【所得】读完【三体】\n【所失】熬夜") == "读完【三体】",
          "回访接在整段末尾，不插进“读完【三体】”中间；句中的“【所得】”不算段名：\(intoBook.debugDescription) / \(midLine.debugDescription)")

    // 2. 插入后改签：原样的旧行换掉，不会“做到了”“没做到”两行并存；旧行后面自己补过字的不动
    let flipped = ReviewThread.insert([("跑步", .missed)], into: ReviewThread.insert([("跑步", .done)], into: template))
    let annotated = ReviewThread.insert([("跑步", .missed)], into: "【所得】\n· 跑步 —— 做到了，跑了三次\n\n【所失】\n")
    let backAgain = ReviewThread.insert([("跑步", .changed)], into: flipped)
    check(flipped == "【所得】\n\n【所失】\n· 跑步 —— 没做到\n\n【所悟】\n\n【下一步】\n"
          && annotated == "【所得】\n· 跑步 —— 做到了，跑了三次\n\n【所失】\n· 跑步 —— 没做到\n"
          && backAgain == "【所得】\n\n【所失】\n\n【所悟】\n· 跑步 —— 改主意了\n\n【下一步】\n",
          "插入后改签：旧行换掉、新行进对应的段；自己补过字的旧行留着：\(flipped.debugDescription) / \(annotated.debugDescription)")

    // 3. 正文里已经有什么：素材段、回访各行（补过字也算插过）；还没进正文的几条
    let withAll = ReviewThread.insert([("跑步", .done)], into: "【所得】\n\n【所失】\n\n〔本期素材 · 10月19日–25日，仅供参考〕\n· 落笔 3 篇。\n\n【所悟】\n")
    let state = ReviewThread.inserted(in: withAll)
    let edited = ReviewThread.inserted(in: "【所得】\n· 跑步 —— 做到了，三次\n")
    let pend = ReviewThread.pending([("跑步", .done), ("早睡", .missed), ("跑步", .missed)], in: withAll)
    check(state.material && state.has("跑步", .done) && !state.has("跑步", .missed) && edited.has("跑步", .done) && !edited.material
          && pend.map { "\($0.text)\($0.verdict.rawValue)" } == ["早睡missed", "跑步missed"]
          && ReviewThread.inserted(in: template) == ReviewThread.Inserted(),
          "正文里插过的：〔本期素材〕、回访各行（补过字也算）；还没进正文的按签算：\(pend.map(\.text))")

    // 4. 【下一步】常见写法：汉字后不空格的编号、冒号引子、圈码、待办方框；“20、30 页”“第2、3章”不拆
    let cases: [(String, [String])] = [
        ("1、早睡2、跑步3、读书", ["早睡", "跑步", "读书"]),
        ("下周：1) 早睡 2) 跑步", ["早睡", "跑步"]),
        ("下周:\n1. 早睡\n2. 跑步", ["早睡", "跑步"]),
        ("①早睡\n②跑步", ["早睡", "跑步"]),
        ("①早睡②跑步③读书", ["早睡", "跑步", "读书"]),
        ("- [ ] 早睡\n- [x] 跑步\n[ ] 读书", ["早睡", "跑步", "读书"]),
        ("每天读 20、30 页", ["每天读 20、30 页"]),
        ("第2、3章写完", ["第2、3章写完"]),
        ("周三：回导师邮件；周五：交初稿", ["周三：回导师邮件", "周五：交初稿"]),
        ("23:30 前收工；每天上午先写 1.5 小时", ["23:30 前收工", "每天上午先写 1.5 小时"]),
        ("1. Run 5km 2. 读书", ["Run 5km", "读书"]),
    ]
    for (text, expected) in cases {
        let got = ReviewThread.nextSteps(from: "【下一步】" + text)
        check(got == expected, "【下一步】拆条「\(text.replacingOccurrences(of: "\n", with: "⏎"))」→ \(got)")
    }

    // 5. “上次”那篇管的正是正在写的这一期：小标题写“10月1日写的月复盘”，不与这期同名
    let today = LocalDay(key: "2026-10-22")!
    func day(_ key: String) -> LocalDay { LocalDay(key: key)! }
    check(ReviewThread.promiseLabel(period: "month", day: day("2026-10-01"), today: today, writing: (.month, day("2026-10-31"))) == "10月1日写的月复盘"
          && ReviewThread.promiseLabel(period: "week", day: day("2026-10-19"), today: today, writing: (.week, day("2026-10-25"))) == "10月19日写的周复盘"
          && ReviewThread.promiseLabel(period: "week", day: day("2026-10-18"), today: today, writing: (.week, day("2026-10-25"))) == "10月12日–18日 周复盘"
          && ReviewThread.promiseLabel(period: "month", day: day("2026-09-30"), today: today, writing: (.month, day("2026-10-31"))) == "9月1日–30日 月复盘"
          && ReviewThread.promiseLabel(period: "day", day: day("2026-10-21"), today: today, writing: (.day, day("2026-10-22"))) == "10月21日 日省"
          && ReviewThread.promiseLabel(period: "week", day: day("2026-10-20"), today: today, writing: (.month, day("2026-10-31"))) == "10月19日–25日 周复盘",
          "回访小标题：落在正在写的同一周 / 同一月里写“X月X日写的周复盘”；上一期、别的周期照旧写日期范围")

    // 6. 素材的日期范围与回访小标题同一种写法（“10月19日–22日”）
    check(ReviewThread.spanLabel(day("2026-10-19"), day("2026-10-22"), today: today) == "10月19日–22日"
          && ReviewThread.spanLabel(day("2026-09-28"), day("2026-10-04"), today: today) == "9月28日–10月4日",
          "日期范围：同月省掉月份、用短横")

    // 7. 只有一类的花费：不把总额再写一遍
    func tx(_ date: String, _ cents: Int, _ category: String) -> FinanceTransaction {
        FinanceTransaction(id: UUID().uuidString, date: date, amountCents: cents, balanceCents: 0, description: "x", account: "手记",
                           category: category, kind: "消费", needsReview: false, reason: "", sourceLine: 0)
    }
    let light = ReviewThread.spendingLine(rows: [tx("2026-10-13", -1666, "餐饮与外卖"), tx("2026-10-20", -750, "餐饮与外卖")],
                                          first: day("2026-10-19"), last: today, period: .week, bankThrough: nil, today: today)
    check(light == "灵石：本期花费 $7.50（较上周同期 −55%），全在 餐饮与外卖。", "只有一类花费：写“全在 餐饮与外卖”：\(light ?? "nil")")

    // 8. 账单导到哪天（直接给导入记录）：手记不算账单；早已停用的旧卡不拖累；七日小卷也应走这一个口径
    func source(_ account: String, _ start: String, _ end: String) -> FinanceSource {
        FinanceSource(sha256: "rt\(account)\(end)", account: account, rawCsv: "", importedAt: "", rows: 0, start: start, end: end)
    }
    let sources = [source("CBA", "2026-09-01", "2026-10-20"), source("旧卡", "2023-01-01", "2024-03-31"), source(ManualExpense.account, "2026-10-01", "2026-10-22")]
    check(ReviewThread.bankThrough(sources: sources, activeSince: day("2026-09-04")) == "2026-10-20"
          && ReviewThread.bankThrough(sources: [source(ManualExpense.account, "2026-10-01", "2026-10-22")], activeSince: day("2026-09-04")) == nil
          && ReviewThread.bankThrough(sources: [source("旧卡", "2023-01-01", "2024-03-31")], activeSince: day("2026-09-04")) == "2024-03-31",
          "账单导到哪天（导入记录）：只看还在导的账户，停用旧卡不拖累，手记不算")
}

// MARK: r2-annals
// #13 回看口径：长卷默认时段按记录多少、洞见先报喜换说法、修为没破境只一句、变化为 0 写“持平”

do {
    func d(_ key: String) -> LocalDay { LocalDay(key: key)! }

    // 1. 默认时段：记录不满 90 天看本季；本季开头 15 天内、上一季也有记录时看上一季；其余看全年（1 月上半月看上一年）
    let now = d("2026-10-22")
    func scope(_ first: String?, today: LocalDay = now) -> AnnalsScope {
        AnnalsPeriod.defaultScope(today: today, firstRecord: first.map(d))
    }
    check(scope("2026-10-08") == .quarter(2026, 4) && scope("2026-07-25") == .quarter(2026, 4) && scope("2026-07-24") == .year(2026)
          && scope(nil) == .year(2026) && AnnalsPeriod.defaultScope(today: now) == .year(2026),
          "长卷默认时段：记录 14 天、89 天看本季；满 90 天、没有记录看全年")
    check(scope("2026-09-01", today: d("2026-10-10")) == .quarter(2026, 3) && scope("2026-10-02", today: d("2026-10-10")) == .quarter(2026, 4)
          && scope("2026-09-01", today: d("2026-10-16")) == .quarter(2026, 4),
          "长卷默认时段：本季头 15 天、上一季也有记录时看上一季；记录都在本季、或过了 15 天看本季")
    check(scope("2026-11-01", today: d("2027-01-10")) == .quarter(2026, 4) && scope("2027-01-03", today: d("2027-01-10")) == .quarter(2027, 1)
          && scope("2025-06-01", today: d("2027-01-10")) == .year(2026) && scope("2025-06-01", today: d("2027-01-16")) == .year(2027),
          "长卷默认时段：1 月上半月新人看上一年第四季，老用户照旧看上一年全年")
    let samples = ["2026-10-08", "2026-07-25", "2026-07-24", "2026-09-01", "2026-10-02"].flatMap { first in
        ["2026-10-22", "2026-10-01", "2026-10-15", "2027-01-01", "2027-01-15", "2026-04-03"].map { (first, d($0)) }
    }
    check(samples.allSatisfy { first, today in AnnalsPeriod.make(scope(first, today: today), today: today) != nil },
          "长卷默认时段：默认的时段一定已经开始（make 不为 nil）")

    // 2. 对比句：变化四舍五入为 0 写“与去年同期持平”
    check(AnnalsReport.compareText(10, from: 10, label: "去年同期") == "与去年同期持平"
          && AnnalsReport.compareText(1001, from: 1000, label: "上一季同期") == "与上一季同期持平"
          && AnnalsReport.compareText(12, from: 10, label: "去年同期") == "较去年同期 +20%"
          && AnnalsReport.compareText(8, from: 10, label: "去年同期") == "较去年同期 −20%"
          && AnnalsReport.compareText(5, from: 0, label: "去年同期") == nil
          && AnnalsReport.rateCompareText(0.62, previous: 0.621, label: "去年同期") == "与去年同期持平"
          && AnnalsReport.rateCompareText(0.62, previous: 0.5, label: "去年同期") == "去年同期 50%",
          "长卷对比句：+0% 写“与去年同期持平”，完成率显示一样也写持平，其余照旧")

    // 3. 洞见：先报喜，常歇的功课最后，不说“中断 / 漏打 / 失败”
    let kinds = Insight.Kind.allCases
    let firstPlain = kinds.firstIndex { !$0.isEncouraging } ?? kinds.count
    check(kinds.prefix(firstPlain).allSatisfy(\.isEncouraging) && kinds.dropFirst(firstPlain).allSatisfy { !$0.isEncouraging }
          && kinds.first == .writingStreak && kinds.last == .fragileHabit && firstPlain == 4,
          "洞见顺序：连续落笔、心境与功课、心境与功课的星期在前，花钱居中，常歇的功课最后")
    let today = d("2026-10-20"), to = today.adding(days: -1), from = to.adding(days: -89)
    func habit(_ title: String, start: LocalDay, skipEvery: Int) -> RecordHabit {
        let done = LocalDay.range(start, to).enumerated().filter { $0.offset % skipEvery != skipEvery - 1 }.map(\.element)
        return RecordHabit(title: title, symbol: "leaf", spec: HabitSpec(frequency: .daily, startDay: start, createdDay: start),
                           logs: done.map { HabitLogValue(day: $0, completed: true) }, archived: false)
    }
    func input(_ habits: [RecordHabit], streak: Int = 0) -> RecordInput {
        let history = (0..<streak).map { (day: to.adding(days: -$0), kind: JournalKind.diary) }
        return RecordInput(today: today, entries: history.map { RecordEntry(uid: "r2\($0.day.key)", day: $0.day, kind: .diary) },
                           history: history, habits: habits, cultivation: CultivationConfig(), ledger: nil)
    }
    // 两项都常歇（最长连续都不到 7 天）：只写后半句
    let pair = [habit("A", start: to.adding(days: -27), skipEvery: 3), habit("B", start: from, skipEvery: 4)]
    let plain = InsightEngine.insights(input(pair), from: from, to: to).first { $0.kind == .fragileHabit }
    check(plain?.text == "「A」平均连续 2.1 天会歇一次（共 9 次）。",
          "洞见·常歇的功课：没有够稳的另一项时只说统计：\(plain?.text ?? "nil")")
    // 有连续落笔、又有常歇的功课：第一条报喜，常歇的那条在最后
    let mixed = InsightEngine.insights(input(pair, streak: 6), from: from, to: to)
    let banned = ["中断", "漏打", "漏一次", "失败", "最容易", "天没写"]
    check(mixed.first?.kind == .writingStreak && mixed.last?.kind == .fragileHabit && mixed.count >= 2
          && mixed.allSatisfy { insight in !banned.contains { insight.text.contains($0) } },
          "洞见：卡片第一条是报喜的（\(mixed.map(\.kind.rawValue).joined(separator: " → "))），不含“中断 / 漏打 / 失败”")

    // 4. 修为：境界与小阶都没变才只一句“今年稳在「…」，累计 +N”；本境升了小阶或破境写期初 → 期末（破境另列破境日）
    let config = CultivationConfig(realms: ["一", "二", "三"], thresholds: [0, 100, 1000], dailyCap: 150, enabled: true)
    let period = AnnalsPeriod.make(.year(2026), today: today)!
    func report(_ history: [(day: LocalDay, kind: JournalKind)]) -> AnnalsReport {
        let entries = history.filter { $0.day >= period.first }.map { RecordEntry(uid: "x\($0.day.key)", day: $0.day, kind: $0.kind) }
        return AnnalsEngine.report(period, input: RecordInput(today: today, entries: entries, history: history, habits: [], cultivation: config, ledger: nil))
    }
    func diaries(_ start: String, _ count: Int) -> [(day: LocalDay, kind: JournalKind)] {
        (0..<count).map { (day: d(start).adding(days: $0), kind: JournalKind.diary) }
    }
    // 去年已入「二」（21 篇 = 105），今年再 5 篇 → 130：期初期末都是「二 · 初期」
    let quiet = report(diaries("2025-06-01", 21) + diaries("2026-03-01", 5))
    let quietMarkdown = AnnalsRenderer.markdown(quiet)
    let steady = quiet.cultivation.map { $0.steadyLine(unitLabel: period.unitLabel) }
    check(quiet.cultivation?.isSteady == true && steady == "今年稳在「二 · 初期」，累计 +25" && quiet.cultivation?.tileNote == "稳在 二 · 初期"
          && quietMarkdown.contains("- " + (steady ?? "?") + "（修为共 130）") && !quietMarkdown.contains("仍在「") && !quietMarkdown.contains("所得修为"),
          "长卷修为：境界与小阶都没变时只一句“\(steady ?? "nil")”，导出不再写“A → A”和“仍在”")
    // 同一境界里升了小阶（0 → 25：一 · 初期 → 一 · 中期）：不算“稳在”，照旧写期初 → 期末
    let stage = report(diaries("2026-03-01", 5))
    let stageMarkdown = AnnalsRenderer.markdown(stage)
    check(stage.cultivation?.breakthroughs.isEmpty == true && stage.cultivation?.isSteady == false && stage.cultivation?.stagesAdvanced == 1
          && stage.cultivation?.tileNote == "一 · 初期 → 中期" && stageMarkdown.contains("- 所得修为 +25（一 · 初期 → 一 · 中期，累计 25）")
          && !stageMarkdown.contains("稳在") && !stageMarkdown.contains("破境入"),
          "长卷修为：同境界内升了小阶不写“稳在”，导出写期初 → 期末：\(stage.cultivation?.tileNote ?? "nil")")
    // 演示数据 2025 年 7–9 月那一季：渡劫 · 中期（14,310）→ 渡劫 · 大圆满（19,997），进 3 阶
    let dujie = AnnalsReport.CultivationPart(gained: 5_687, startXP: 14_310, endXP: 19_997, config: CultivationConfig(), breakthroughs: [], perBucket: [])
    check(dujie.startState.title == "渡劫 · 中期" && dujie.endState.title == "渡劫 · 大圆满" && !dujie.isSteady && dujie.stagesAdvanced == 3
          && dujie.advanceLabel == "进 3 阶" && dujie.advanceLine == "由「渡劫 · 中期」进到「渡劫 · 大圆满」" && dujie.tileNote == "渡劫 · 中期 → 大圆满"
          && !dujie.tileNote.contains("稳在"),
          "长卷修为：渡劫 · 中期 → 大圆满写“\(dujie.advanceLabel)”“\(dujie.advanceLine)”，卷首格“\(dujie.tileNote)”")
    let rising = report((0..<19).map { (day: d("2025-12-01").adding(days: $0), kind: JournalKind.diary) }
                        + [(day: d("2026-01-05"), kind: .diary), (day: d("2026-01-06"), kind: .review)])
    let risingMarkdown = AnnalsRenderer.markdown(rising)
    check(rising.cultivation?.breakthroughs.count == 1 && risingMarkdown.contains("- 所得修为 +20（") && risingMarkdown.contains("破境入「二」")
          && !risingMarkdown.contains("稳在"),
          "长卷修为：破境时照旧写期初 → 期末与破境日")

    // 5. 落笔篇数与去年同期一样：导出写“与去年同期持平”
    let same = ["01-05", "02-05", "03-05"].flatMap { [(day: d("2025-" + $0), kind: JournalKind.diary), (day: d("2026-" + $0), kind: JournalKind.diary)] }
    let flatMarkdown = AnnalsRenderer.markdown(report(same))
    check(flatMarkdown.contains("- 落笔 3 篇（日记 3），与去年同期持平") && !flatMarkdown.contains("+0%"),
          "长卷对比：篇数与去年同期一样时写“与去年同期持平”")

    // 6. 灵石类别：差不到 50 分（取整后是 $0）写“与上一季持平”，不写“+$0 / −$0”；50 分起照旧写金额
    check(AnnalsReport.isFlatCents(0) && AnnalsReport.isFlatCents(30) && AnnalsReport.isFlatCents(-30) && AnnalsReport.isFlatCents(49)
          && !AnnalsReport.isFlatCents(50) && !AnnalsReport.isFlatCents(-50) && RecordStats.dollars(49) == "$0" && RecordStats.dollars(50) == "$1",
          "长卷灵石类别：持平的界线与 RecordStats.dollars 取整一致（不到 50 分算持平）")
    var serial = 0
    func pay(_ key: String, _ cents: Int, _ category: String) -> FinanceTransaction {
        serial += 1
        return FinanceTransaction(id: "r2f\(serial)", date: key, amountCents: -cents, balanceCents: 0, description: "自检", account: "CBA",
                                  category: category, kind: "消费", needsReview: false, reason: "", sourceLine: serial)
    }
    // 7–9 月对 4–6 月：订阅多 30 分、交通少 30 分、娱乐正好 0、餐饮多 $150
    var ledger = FinanceLedger()
    for (now, before) in [("2026-07", "2026-04"), ("2026-08", "2026-05"), ("2026-09", "2026-06")] {
        let first = now == "2026-07"
        ledger.transactions += [pay(now + "-03", first ? 1_030 : 1_000, "订阅与会员"), pay(before + "-03", 1_000, "订阅与会员"),
                                pay(now + "-05", first ? 2_000 : 2_030, "交通出行"), pay(before + "-05", 2_030, "交通出行"),
                                pay(now + "-07", 1_500, "娱乐休闲"), pay(before + "-07", 1_500, "娱乐休闲"),
                                pay(now + "-09", 15_000, "餐饮与外卖"), pay(before + "-09", 10_000, "餐饮与外卖")]
    }
    ledger.sources = [FinanceSource(sha256: "r2f", account: "CBA", rawCsv: "", importedAt: "", rows: 0, start: "2026-04-01", end: "2026-09-30",
                                    statementPeriod: StatementPeriod(start: "2026-04-01", end: "2026-09-30"))]
    let q3 = AnnalsPeriod.make(.quarter(2026, 3), today: today)!
    let money = AnnalsEngine.report(q3, input: RecordInput(today: today, entries: [], history: [], habits: [], cultivation: config, ledger: ledger))
    let changes = Dictionary(uniqueKeysWithValues: (money.finance?.categories ?? []).map { ($0.name, $0.change) })
    let moneyMarkdown = AnnalsRenderer.markdown(money)
    let flat = AnnalsReport.flatText(q3.previousLabel)
    let parts = moneyMarkdown.split(separator: "\n").first { $0.hasPrefix("- 主要类别：") }.map { $0.dropFirst(7).components(separatedBy: "；") } ?? []
    func part(_ name: String) -> String { parts.first { $0.hasPrefix(name + " ") } ?? "无" }
    check(changes["订阅与会员"] == 30 && changes["交通出行"] == -30 && changes["娱乐休闲"] == 0 && changes["餐饮与外卖"] == 15_000
          && part("订阅与会员").hasSuffix("，\(flat)）") && part("交通出行").hasSuffix("，\(flat)）") && part("娱乐休闲").hasSuffix("，\(flat)）")
          && part("餐饮与外卖").hasSuffix("，较\(q3.previousLabel) +$150）") && !moneyMarkdown.contains("+$0") && !moneyMarkdown.contains("−$0"),
          "长卷灵石类别：差 ±30 分、正好 0 都写“\(flat)”，差 $150 照旧写金额：\(parts.joined(separator: " / "))")
}

// MARK: r2-seals（#16 印谱：八枚各自的达成日、第一次运行静默补记、一天最多庆一枚；名帖目标列表：以状态为准、编辑窗联动、刚功成留原处、折叠与期限写法、功成飘字并句）
do {
    let today = LocalDay(key: "2026-10-22")!
    func keys(_ from: String, _ count: Int) -> [String] {
        let start = LocalDay(key: from)!
        return (0..<count).map { start.adding(days: $0).key }
    }

    // 1. 全新：什么都没有 → 一枚也没达成
    check(Milestones.reached(MilestoneInput(), today: today).isEmpty, "印谱：没有任何记录时一枚也没达成")

    // 2. 各枚的达成日：第一篇取最早一天；复盘取最早一篇复盘；功课 / 传书 / 目标照给的那天
    var input = MilestoneInput(entryDays: ["2026-10-20", "2026-10-03", "2026-10-03", "2026-10-21"], reviewDays: ["2026-10-21"],
                               firstHabit: LocalDay(key: "2026-10-05"), firstCourier: LocalDay(key: "2026-10-19"),
                               firstGoalDone: LocalDay(key: "2026-10-22"))
    var reached = Milestones.reached(input, today: today)
    check(reached[.firstEntry]?.key == "2026-10-03" && reached[.firstReview]?.key == "2026-10-21" && reached[.firstHabit]?.key == "2026-10-05"
          && reached[.firstCourier]?.key == "2026-10-19" && reached[.goalDone]?.key == "2026-10-22"
          && reached[.sevenDays] == nil && reached[.thirtyDays] == nil && reached[.hundredDays] == nil,
          "印谱：山门取最早一篇、初省取最早一篇复盘，立功 / 飞剑 / 功成照给的日子；3 个落笔日不够不辍、三旬、百日")

    // 3. 不辍：同一天多篇只算一日，第一次连到 7 日的那天；中间断一天重新数
    input = MilestoneInput(entryDays: keys("2026-09-01", 6) + keys("2026-09-08", 7) + ["2026-09-10", "2026-09-10"] + keys("2026-10-01", 9))
    reached = Milestones.reached(input, today: today)
    check(reached[.sevenDays]?.key == "2026-09-14", "印谱：9月1–6日连 6 日、断一天，9月8日起第 7 日（9月14日）得不辍：\(reached[.sevenDays]?.key ?? "nil")")

    // 4. 三旬 / 百日：第 30 / 100 个不同的落笔日；今天以后的日子不算进去
    input = MilestoneInput(entryDays: keys("2026-06-01", 99) + keys("2026-10-23", 5) + ["2026-06-01"])
    reached = Milestones.reached(input, today: today)
    check(reached[.thirtyDays]?.key == "2026-06-30" && reached[.hundredDays] == nil,
          "印谱：第 30 个落笔日（6月30日）得三旬；99 日 + 将来的 5 日不够百日")
    input.entryDays.append("2026-10-22")
    reached = Milestones.reached(input, today: today)
    check(reached[.hundredDays]?.key == "2026-10-22" && reached[.sevenDays]?.key == "2026-06-07",
          "印谱：今天补上第 100 个落笔日 → 百日关今天达成；不辍取最早连到 7 日的那天")

    // 5. 写在将来、写法认不出的：第一篇照算（记为今天），不进连续与累计
    reached = Milestones.reached(MilestoneInput(entryDays: ["2026-12-01", "昨天"], firstHabit: LocalDay(key: "2027-01-01")), today: today)
    check(reached[.firstEntry] == today && reached[.firstHabit] == today && reached[.sevenDays] == nil,
          "印谱：只有将来日期 / 认不出的落笔时，山门记为今天；功课开始日在将来也记为今天")

    // 6. 第一次运行：已达成的全部静默记下（得印日写达成那天），一枚不庆
    let all: [Milestone: LocalDay] = Dictionary(uniqueKeysWithValues: Milestone.allCases.enumerated().map { ($1, today.adding(days: -100 + $0)) })
    let seed = Milestones.step(ledger: nil, lastCelebrated: nil, reached: all, today: today)
    check(seed.celebrate == nil && seed.pending.isEmpty && seed.changed && seed.ledger.isComplete
          && seed.ledger.earned[.firstEntry] == today.adding(days: -100).key,
          "印谱第一次运行：2 年用户 8 枚全部静默记下（得印日是各自达成那天），不放庆祝")
    let empty = Milestones.step(ledger: nil, lastCelebrated: nil, reached: [:], today: today)
    check(empty.ledger.earned.isEmpty && empty.changed && empty.ledger.encoded == "" && MilestoneLedger(encoded: "") == MilestoneLedger(),
          "印谱第一次运行：全新用户记下一本空印谱（写成空字符串，下次读出来不再当第一次）")

    // 7. 之后：新达成两枚 → 今天庆第一枚，另一枚等明天；明天再看补上；再之后没有新的就什么都不动
    var ledger = MilestoneLedger()
    let day1 = Milestones.step(ledger: ledger, lastCelebrated: nil,
                               reached: [.firstEntry: today, .firstHabit: today], today: today)
    check(day1.celebrate == .firstEntry && day1.pending == [.firstHabit] && day1.ledger.earned[.firstEntry] == today.key && day1.ledger.earned[.firstHabit] == nil,
          "印谱：同一天落第一篇又立第一项功课 → 今天只庆山门，立功留到明天")
    ledger = day1.ledger
    let again = Milestones.step(ledger: ledger, lastCelebrated: today.key, reached: [.firstEntry: today, .firstHabit: today], today: today)
    check(again.celebrate == nil && !again.changed && again.pending == [.firstHabit], "印谱：今天已庆过一枚，再保存几次也不再庆")
    let tomorrow = today.adding(days: 1)
    let day2 = Milestones.step(ledger: ledger, lastCelebrated: today.key, reached: [.firstEntry: today, .firstHabit: today], today: tomorrow)
    check(day2.celebrate == .firstHabit && day2.pending.isEmpty && day2.ledger.earned[.firstHabit] == tomorrow.key,
          "印谱：次日补庆立功（得印日写补庆那天）")
    let quiet = Milestones.step(ledger: day2.ledger, lastCelebrated: nil, reached: [.firstEntry: today, .firstHabit: today], today: tomorrow.adding(days: 1))
    check(quiet.celebrate == nil && !quiet.changed, "印谱：每枚只庆一次——都记下以后不再庆")
    let kept = Milestones.step(ledger: day2.ledger, lastCelebrated: nil, reached: [:], today: tomorrow.adding(days: 1))
    check(kept.ledger.earned.count == 2 && !kept.changed, "印谱：删光记录后已得的印照旧在，不收回")

    // 8. 存取：同样内容同一行字；认不出的段落略过；nil 才是第一次运行
    var mixed = MilestoneLedger()
    mixed.earned = [.sevenDays: "2026-10-29", .firstEntry: "2026-10-22"]
    check(mixed.encoded == "firstEntry@2026-10-22,sevenDays@2026-10-29" && MilestoneLedger(encoded: mixed.encoded) == mixed
          && MilestoneLedger(encoded: "firstEntry@2026-10-22,bogus@2026-01-01,sevenDays@坏日子,,thirtyDays") == {
              var l = MilestoneLedger(); l.earned = [.firstEntry: "2026-10-22"]; return l }()
          && MilestoneLedger(encoded: nil) == nil && mixed.countText == "已得 2 / 8 枚",
          "印谱存取：按印谱次序写成一行、读回一样；坏段略过；没有这一项才算第一次运行；“已得 2 / 8 枚”")
    check(MilestoneLedger.list("sevenDays, firstEntry,nope") == [.sevenDays, .firstEntry]
          && MilestoneLedger.listText([.goalDone, .firstEntry]) == "firstEntry,goalDone",
          "印谱小单：逗号分隔读写，按印谱次序写出")

    // 9. 说法
    check(Milestone.sevenDays.toast == "得印 · 七日不辍：连续落笔七日" && Milestone.sevenDays.requirement == "连续落笔七日可得"
          && Milestone.earnedHelp("2026-10-22", today: today) == "10月22日得" && Milestone.earnedHelp("2025-03-02", today: today) == "2025年3月2日得"
          && Milestone.allCases.allSatisfy { $0.seal.count == 2 } && Set(Milestone.allCases.map(\.seal)).count == 8,
          "印谱说法：得印飘字、未得的条件、得印日（不是今年带年份）；八枚印文各两字、互不相同")
    let banned = ["失败", "中断", "漏打", "没写"]
    check(Milestone.allCases.allSatisfy { m in !banned.contains { m.toast.contains($0) || m.requirement.contains($0) } },
          "印谱说法里没有“失败 / 中断 / 漏打 / 没写”")

    // 10. 目标列表（M5）：达成以状态为准、刚功成、编辑窗里完成度与状态联动、两列怎么分、折叠区标题、期限带年份
    check(GoalListRules.isDone(status: "completed") && !GoalListRules.isDone(status: "active") && !GoalListRules.isDone(status: "paused"),
          "目标达成以状态为准：已完成才算；进度 100% 但仍是进行中的不算（与首页所向条、AI 传书同一口径）")
    check(GoalListRules.justAchieved(before: "active", after: "completed")
          && GoalListRules.justAchieved(before: "paused", after: "completed")
          && GoalListRules.justAchieved(before: nil, after: "completed")
          && !GoalListRules.justAchieved(before: "completed", after: "completed")
          && !GoalListRules.justAchieved(before: "active", after: "active")
          && !GoalListRules.justAchieved(before: nil, after: "active"),
          "刚功成：改成已完成才算；原本就已完成的再存一次不算；仍是进行中不算")
    // 编辑窗：拉到 100% 时状态跟着改成已完成，拉回去又改回进行中；暂停 / 已放弃不动；特意点回“进行中”就按进行中存
    var link = GoalEditorLink(status: "active", progress: 80)
    link.slide(to: 95)
    let at95 = link.status
    link.slide(to: 100)
    let at100 = link.status
    link.slide(to: 90)
    check(at95 == "active" && at100 == "completed" && link.status == "active" && link.progress == 90,
          "目标编辑窗：完成度拉到 100% 状态自动改成已完成，拉回 90% 又改回进行中")
    link.slide(to: 100)
    link.pick("active")
    check(link.status == "active" && link.progress == 100 && !GoalListRules.justAchieved(before: "active", after: link.status),
          "目标编辑窗：拉到 100% 后特意点回“进行中”→ 按进行中、100% 存，不算功成、不放庆祝（列表也照旧在进行中那一列）")
    var paused = GoalEditorLink(status: "paused", progress: 60)
    paused.slide(to: 100)
    check(paused.status == "paused", "目标编辑窗：暂停的拉到 100% 不改状态")
    var picked = GoalEditorLink(status: "active", progress: 40)
    picked.pick("completed")
    let filled = picked.progress
    picked.pick("active")
    check(filled == 100 && picked.status == "active" && picked.progress == 40,
          "目标编辑窗：点“已完成”完成度补到 100%，再点回“进行中”完成度还原成 40%")
    picked.pick("completed")
    picked.slide(to: 85)
    picked.pick("completed")
    picked.pick("paused")
    check(picked.status == "paused" && picked.progress == 85, "目标编辑窗：点了已完成又拖过滑块的，改回别的状态时完成度保留拖到的数")
    var loadedDone = GoalEditorLink(status: "completed", progress: 100)
    loadedDone.slide(to: 70)
    check(loadedDone.status == "active" && loadedDone.progress == 70, "目标编辑窗：已完成的目标把完成度拉低 → 改回进行中（不再保存时悄悄改回 100%）")
    // 两列：进行中在上；折叠区 已完成 → 暂停 → 已放弃；这次刚功成的留在原处
    let rows: [(id: String, status: String)] = [("a", "active"), ("b", "paused"), ("c", "completed"), ("d", "cancelled"), ("e", "active")]
    let plain = GoalListRules.partition(rows, keepShown: [], foldedPlace: [:])
    check(plain.shown == [0, 4] && plain.folded == [2, 1, 3], "目标两列：进行中按创建先后在上；折叠区按 已完成 → 暂停 → 已放弃")
    var doneA = rows
    doneA[0].status = "completed"
    let keptA = GoalListRules.partition(doneA, keepShown: ["a"], foldedPlace: [:])
    check(keptA.shown == [0, 4] && keptA.folded == [2, 1, 3], "进行中那一列里刚功成的：这次照旧留在那一列原位，不收进折叠区")
    check(GoalListRules.partition(doneA, keepShown: [], foldedPlace: [:]).shown == [4], "下次进页（不再记得刚功成）：收进折叠区")
    var doneB = rows
    doneB[1].status = "completed"
    let keptB = GoalListRules.partition(doneB, keepShown: [], foldedPlace: ["b": "paused"])
    check(keptB.shown == [0, 4] && keptB.folded == [2, 1, 3],
          "折叠区里暂停的改成已完成：这次留在折叠区原位（仍排在暂停那一段），不跳到上面进行中那一列")
    check(GoalListRules.partition(doneB, keepShown: [], foldedPlace: [:]).folded == [1, 2, 3], "下次进页：按已完成归位")
    var pausedAgain = doneA
    pausedAgain[0].status = "paused"
    check(GoalListRules.partition(pausedAgain, keepShown: ["a"], foldedPlace: [:]).shown == [4],
          "刚功成后又改成暂停的：不再留在进行中那一列，照常收进折叠区")
    // 飘字：目标名过长截断；同时得“功成”印并成一句
    check(GoalListRules.achievedToast("完成学位论文初稿") == "所向功成 · 完成学位论文初稿"
          && GoalListRules.achievedToast("完成学位论文初稿", sealEarned: true) == "所向功成 · 完成学位论文初稿 · 得「功成」印"
          && GoalListRules.achievedToast(String(repeating: "长", count: 30)) == "所向功成 · " + String(repeating: "长", count: 23) + "…",
          "目标功成飘字：“所向功成 · 目标名”（超 24 字截断）；同时得“功成”印并成“… · 得「功成」印”一句")
    check(GoalListRules.foldedLabel(statuses: ["completed", "completed"]) == "已完成 · 2 项"
          && GoalListRules.foldedLabel(statuses: ["cancelled", "completed", "paused"]) == "已完成 · 暂停 · 已放弃 · 3 项"
          && GoalListRules.foldedLabel(statuses: ["paused"]) == "暂停 · 1 项",
          "目标折叠区：“已完成 · 2 项”；混着暂停、已放弃时按 已完成 → 暂停 → 已放弃 写出")
    check(GoalListRules.deadlineText("2027-02-17", today: today) == "期限 2027年2月17日"
          && GoalListRules.deadlineText("2026-12-31", today: today) == "期限 12月31日"
          && GoalListRules.deadlineText("2025-06-30", today: today) == "期限 2025年6月30日"
          && GoalListRules.deadlineText("坏日子", today: today) == nil,
          "目标期限：今年的只写月日，不是今年的带年份")
}

// MARK: r2-quick2：#19 随手记的日期签——选了哪天就当句中写的是这天（日记灵感复盘补记、记账、补卡、日程按这天的钟点）
do {
    let today = LocalDay(key: "2026-10-22")!   // 周四，现在 12:00
    let y = today.adding(days: -1), b = today.adding(days: -2), tomorrow = today.adding(days: 1)
    let far = LocalDay(key: "2026-10-15")!, old = LocalDay(key: "2026-07-01")!
    typealias QH = QuickParse.Habit
    let habits: [QH] = [
        QH(title: "冥想", unit: "分钟", target: 10),
        QH(title: "喝水", unit: "杯", target: 8, days: [today: .init(quantity: 2, done: false), y: .init(quantity: 5, done: false)]),
        QH(title: "运动", days: [b: .init(quantity: nil, done: true)]),
    ]
    let ctx = QuickParse.Context(today: today, nowMinute: 12 * 60, habits: habits)
    func p(_ text: String, _ day: LocalDay?, _ choice: QuickParse.Choice? = nil) -> QuickParse.Result {
        QuickParse.parse(text, context: ctx, choice: choice, day: day)
    }

    // 不选、或句中没写日子时选今天：与原来一模一样
    let plain = ["午饭 18.5", "冥想 10 分钟", "明天下午3点 组会", "昨天睡得很晚", "#灵感 先完成再完美", "9点 开会", "后天交报告"]
    check(plain.allSatisfy { p($0, nil) == QuickParse.parse($0, context: ctx) }
          && ["午饭 18.5", "冥想 10 分钟", "#灵感 先完成再完美", "9点 开会"].allSatisfy { p($0, today) == p($0, nil) },
          "日期签不选（或句中没写日子时选今天）：认法与原来相同")

    // 修行录：补记那天；句首写的日子被签盖过时从正文去掉，签选今天时句首的“昨天”照留
    let d1 = p("睡得很晚", y), d2 = p("今天心情不错", y), d3 = p("昨天睡得很晚", today), d4 = p("在海边看日落", old)
    check(d1.intent == .diary && d1.journal.day == y && d1.journal.body == "睡得很晚" && d1.detail == "日记 · 补记 10月21日"
          && d1.recordDay == y && d1.savedText == "已入卷 · 补记 10月21日" && d1.evidence.contains("日期签 → 补记 10月21日"),
          "签选昨天：“睡得很晚”补记 10月21日：\(d1.detail)｜\(d1.evidence)")
    check(d2.journal.day == y && d2.journal.body == "心情不错" && d3.journal.day == today && d3.journal.body == "昨天睡得很晚"
          && d4.journal.day == old && d4.intent == .diary && d4.problem == nil,
          "签盖过句首的日子：“今天心情不错”→ 10月21日“心情不错”；签选今天时“昨天睡得很晚”记今天、原话照留；几个月前也能补")
    let n1 = p("#灵感 先完成再完美", y), r1 = p("复盘：三件事做完两件", b)
    check(n1.intent == .note && n1.journal.day == y && n1.detail == "灵感 · 补记 10月21日"
          && r1.intent == .review && r1.journal.day == b && r1.detail == "日省 · 补记 10月20日",
          "灵感、复盘也按签上的日子：\(n1.detail) / \(r1.detail)")

    // 记账：记那天（几天前也行）；以后的日子仍记今天并提醒；签选今天盖过句中的“昨天”
    let e1 = p("午饭 18.5", y), e2 = p("午饭 18.5", far), e3 = p("午饭 18.5", tomorrow), e4 = p("昨天打车 25", today)
    check(e1.intent == .expense && e1.expense?.day == y && e1.expense?.cents == 1850 && e1.expense?.description == "午饭"
          && e1.recordDay == y && e1.savedText == "已入账 · 10月21日" && e1.evidence.contains("日期签 → 10月21日"),
          "签选昨天记账：午饭 ¥18.50 记在 10月21日：\(e1.evidence)")
    check(e2.expense?.day == far && e3.expense?.day == today && e3.expense?.movedFromFuture == true && e3.notice == "未来的日子不能记账，先记在今天"
          && e4.expense?.day == today && e4.expense?.description == "打车",
          "记账：一周前照记那天；签选明天仍记今天并提醒；签选今天盖过“昨天”")

    // 打卡：补那天的卡，按那天已记的数量累加；那天已圆满的改记日记；签选一周前也补（不受“前天以内”限制）
    let c1 = p("冥想 10 分钟", y), c2 = p("喝水 3 杯", y), c3 = p("运动", b), c4 = p("冥想", far)
    check(c1.intent == .checkin && c1.checkin?.day == y && c1.checkin?.added == 10 && c1.recordDay == y
          && c1.savedText == "已补卡 · 冥想 10/10 分钟 · 10月21日",
          "签选昨天：“冥想 10 分钟”补 10月21日：\(c1.savedText)")
    check(c2.checkin?.day == y && c2.checkin?.before == 5 && c2.checkin?.quantity == 8 && c2.detail == "喝水 · 3 杯（10月21日 5 → 8 / 8）",
          "补卡按那天已记的数量累加：\(c2.detail)")
    check(c3.intent == .diary && c3.notice == "「运动」10月20日已圆满" && c3.alternatives.first == .checkin
          && c4.intent == .checkin && c4.checkin?.day == far && c4.checkin?.quantity == 10,
          "那天已圆满改记日记（\(c3.notice ?? "nil")）；签选一周前照样补卡（\(c4.intent.label)）")
    let c5 = p("冥想", tomorrow, .checkin("冥想")), c6 = p("打卡：冥想", tomorrow)
    check(!c5.canSave && c5.problem == "以后的日子不能打卡：日期签改选今天或以前" && !c6.canSave && c6.intent == .checkin
          && p("冥想 10 分钟", tomorrow).intent != .checkin,
          "以后的日子不打卡：改作 / 前缀都不让记，自动认也不认作打卡")

    // 日程：按签上的日子、句中的钟点；没写上午下午的 9 点在以后的日子按上午；签选以前的日子不记日程
    let v1 = p("下午3点 组会", tomorrow), v2 = p("明天下午3点 组会", today.adding(days: 2)), v3 = p("9点 开会", tomorrow)
    let v4 = p("今晚七点半 跑步", tomorrow), v5 = p("下午3点 组会", y), v6 = p("后天交报告", tomorrow)
    check(v1.intent == .event && v1.event?.day == tomorrow && v1.event?.start == 15 * 60 && v1.event?.title == "组会" && v1.recordDay == tomorrow
          && v1.evidence.contains("日期签 → 10月23日"),
          "签选明天：“下午3点 组会”→ 10月23日 15:00：\(v1.detail)")
    check(v2.event?.day == today.adding(days: 2) && v2.event?.title == "组会" && v3.intent == .event && v3.event?.start == 9 * 60
          && v4.event?.day == tomorrow && v4.event?.start == 19 * 60 + 30 && v4.event?.title == "跑步"
          && v6.intent == .event && v6.event?.day == tomorrow && v6.event?.start == nil && v6.event?.title == "交报告",
          "签盖过句中的“明天 / 今晚 / 后天”，钟点照旧；“9点 开会”在明天按上午：\(v2.detail) / \(v3.detail) / \(v4.detail) / \(v6.detail)")
    check(v5.intent == .diary && v5.journal.day == y && v5.journal.body == "下午3点 组会",
          "签选昨天的“下午3点 组会”：已过，补记成日记")

    // 修行录不记以后的日子：按钮变灰，签上说清楚，可改作日程；改作记账 / 日记也跟着签
    let f1 = p("今天心情不错，下午去了图书馆，见到了好多老朋友", tomorrow)
    check(f1.intent == .diary && !f1.canSave && f1.problem == "修行录只记今天和以前：日期签改个日子，或改作日程"
          && f1.alternatives.contains(.event) && p("今天心情不错，下午去了图书馆，见到了好多老朋友", tomorrow, .event).event?.day == tomorrow,
          "签选明天的日记：不让记（\(f1.problem ?? "nil")），可改作明天的日程")
    check(p("跑步好累 18", y, .expense).expense?.day == y && p("午饭 18.5", y, .diary).journal.day == y,
          "改作记账、改作日记也按签上的日子")

    // 签上的字
    check(QuickParse.daySignLabel(today, today: today) == "今天" && QuickParse.daySignLabel(y, today: today) == "昨天"
          && QuickParse.daySignLabel(b, today: today) == "前天" && QuickParse.daySignLabel(tomorrow, today: today) == "明天"
          && QuickParse.daySignLabel(today.adding(days: 2), today: today) == "后天" && QuickParse.daySignLabel(far, today: today) == "10月15日"
          && QuickParse.daySignLabel(LocalDay(key: "2025-12-31")!, today: today) == "2025年12月31日",
          "日期签的字：今天 / 昨天 / 前天 / 明天 / 后天 / 10月15日 / 不是今年的带年份")
    check(p("午饭 18.5", nil).recordDay == today && p("明天下午3点 组会", nil).recordDay == tomorrow && p("睡得很晚", y).recordDay == y,
          "签上没选时显示这句认出的日子（明天的日程写明天）")

    // 签盖过句中的日子时，正文一字不动——只有原来就指签上这天、或原来写的是今天（今天 / 今晚）才当日期去掉
    let keep = ["周五的组会被取消了，有点失落", "明天要考试，好紧张", "后天交报告", "下周一上午10点开会", "10月1日国庆出去玩了"]
    let kept = keep.map { p($0, y) }
    check(zip(keep, kept).allSatisfy { $0.1.journal.body == $0.0 && $0.1.journal.day == y && $0.1.intent == .diary },
          "签选昨天：句中写的别的日子是话的一部分，正文照留：\(kept.map(\.journal.body))")
    let idea = p("灵感：明天试试新方法", y), tonight = p("今晚吃了火锅", y), same = p("昨天睡得很晚", y), oct1 = p("10月1日国庆出去玩了", nil)
    check(idea.intent == .note && idea.journal.body == "明天试试新方法" && idea.journal.day == y
          && p("今天心情不错", y).journal.body == "心情不错" && tonight.journal.body == "吃了火锅" && tonight.journal.day == y
          && same.journal.body == "睡得很晚" && oct1.journal.body == "国庆出去玩了" && oct1.journal.day == LocalDay(key: "2026-10-01")!,
          "“灵感：明天试试新方法”照留“明天”；“今天 / 今晚”与本来就指昨天的“昨天”照旧去掉；不选签时句首“10月1日”仍补记那天")
    let note1 = p("周五开完组会 冥想 10 分钟 很放松", y), note2 = p("昨天开完组会 冥想 10 分钟 很放松", y)
    check(note1.intent == .checkin && note1.checkin?.day == y && note1.checkin?.note == "周五开完组会 很放松"
          && note2.checkin?.note == "开完组会 很放松",
          "补卡的备注同理：“周五”不是签上那天就留在备注里（\(note1.checkin?.note ?? "nil")），“昨天”照旧去掉")

    // 补记到往年 / 记到明年：记好后的提示、依据、打卡与日程明细都带年份，与签上一致；同一年照旧不带
    let lastYear = LocalDay(key: "2025-12-31")!, nextYear = LocalDay(key: "2027-01-05")!
    let xe = p("午饭 18.5", lastYear), xd = p("心情不错", lastYear), xc = p("冥想 10 分钟", lastYear), xv = p("下午3点 组会", nextYear)
    check(xe.savedText == "已入账 · 2025年12月31日" && xe.evidence.contains("日期签 → 2025年12月31日")
          && xe.detail == "餐饮与外卖 · $18.50 · 补记 2025年12月31日",
          "跨年记账：\(xe.savedText)｜\(xe.evidence)")
    check(xd.savedText == "已入卷 · 补记 2025年12月31日" && xd.evidence.contains("日期签 → 补记 2025年12月31日"),
          "跨年补记日记：\(xd.savedText)｜\(xd.evidence)")
    check(xc.detail == "冥想 · 10 分钟（2025年12月31日 0 → 10 / 10）" && xc.savedText == "已补卡 · 冥想 10/10 分钟 · 2025年12月31日"
          && xc.evidence.contains("日期签 → 补 2025年12月31日"),
          "跨年补卡：\(xc.detail)｜\(xc.savedText)")
    check(xv.intent == .event && xv.detail == "2027年1月5日 周二 15:00–16:00 · 组会" && xv.savedText == "已记入时辰卷 · 2027年1月5日 15:00"
          && xv.evidence.contains("日期签 → 2027年1月5日"),
          "跨年日程：\(xv.detail)｜\(xv.savedText)")
    let doneCtx = QuickParse.Context(today: today, nowMinute: 12 * 60, habits: [QH(title: "运动", days: [lastYear: .init(quantity: nil, done: true)])])
    let xr = QuickParse.parse("运动", context: doneCtx, day: lastYear), xb = p("运动", lastYear)
    check(xr.notice == "「运动」2025年12月31日已圆满" && xb.detail == "运动 · 打卡 · 补记 2025年12月31日" && xb.savedText == "已补卡 · 运动 · 2025年12月31日",
          "跨年：已圆满的提示与只打卡功课的明细也带年份（\(xr.notice ?? "nil")｜\(xb.detail)）")
}

// MARK: r2-schedule：#23 时辰卷周视图——重叠日程宽够并排、窄了错位叠放、被压住的标题挪下来；空周只画 08–20 点；“每周一、四”
do {
    typealias Span = WeekStack.Span
    let label = 47   // 周视图里 34pt 标题 ÷ 44pt 一小时，向上取整
    // 视觉审计 H2：周四 13:00 GEOS2115（13–15）、图书馆写作（14–17）、导师会面（14–14:30）三件重叠；故意打乱先后传入
    let h2 = [Span(start: 14 * 60, end: 14 * 60 + 30), Span(start: 14 * 60, end: 17 * 60), Span(start: 13 * 60, end: 15 * 60)]
    for width in [107.0, 144.0] {   // 1180 与 1440 宽窗口下一天的宽
        let slots = WeekStack.layout(h2, dayWidth: width, labelMinutes: label)
        let frames = slots.map { WeekStack.frame($0, dayWidth: width) }
        check(slots.allSatisfy { $0.stacked && $0.columns == 3 } && slots.map(\.column) == [2, 1, 0],
              "周视图 H2（一天 \(Int(width))pt）：三件重叠、并排每块不到 64pt → 整组错位叠放，GEOS 在底、图书馆中间、导师会面在上：\(slots.map(\.column))")
        check(slots.map(\.labelOffset) == [0, 30, 0],
              "周视图 H2：图书馆写作的标题被导师会面压住 → 挪到 14:30 露出来的地方，另两块不挪：\(slots.map(\.labelOffset))")
        check(frames.map { $0.x } == [30, 16, 2] && frames.allSatisfy { $0.width >= WeekStack.compactWidth && $0.x + $0.width <= width - 2 + 0.001 },
              "周视图 H2：后一块右移 14pt、伸到这天右边，最上面那块也有 ≥ 64pt 写时间和标题：\(frames.map { "\($0.x)+\(Int($0.width))" })")
        // 标题下面露出来多少：GEOS 14:00 起被图书馆写作压住 → 只有 60 分钟（按这一段挑写法，不再露半行“Tutorial”、露边里一个“M”）；
        // 图书馆写作从挪到的 14:30 起一直露到 17:00；导师会面在最上面，整块都露着
        check(slots.map(\.labelRoom) == [30, 150, 60],
              "周视图 H2：标题下露出来的分钟数 导师会面 30 / 图书馆写作 150 / GEOS 60：\(slots.map(\.labelRoom))")
        // 悬停浮起哪一块按原先层次算，不看此刻谁浮着：从上方先碰到 GEOS、再移到 14:10 的导师会面，浮起的是导师会面
        func top(_ minute: Double, _ x: Double) -> Int? {
            WeekStack.topmost(at: minute, x: x, spans: h2, slots: slots, dayWidth: width, minMinutes: 18.0 / 44 * 60)
        }
        let picks = [top(13 * 60 + 30, 50), top(14 * 60 + 10, 40), top(16 * 60, 50),
                     top(14 * 60 + 10, 20), top(14 * 60 + 10, 8), top(14 * 60 + 40, 40), top(16 * 60, 8), top(12 * 60, 50)]
        check(picks == [2, 0, 1, 1, 2, 1, nil, nil],
              "周视图 H2（一天 \(Int(width))pt）：指针下浮起的块 13:30→GEOS、14:10 x=40→导师会面、16:00→图书馆写作、14:10 x=20→图书馆写作、"
              + "14:10 x=8 左边露边→GEOS、14:40→图书馆写作、16:00 x=8 空白与 12:00 都不浮：\(picks)")
    }
    // 没叠放的块：标题下露出整块；20 分钟的短块按画出来的 18pt（约 24.5 分钟）算悬停范围，紧接着的下一块在它下面开始也照样选得到
    let short = [Span(start: 540, end: 560), Span(start: 600, end: 660)]
    let shortSlots = WeekStack.layout(short, dayWidth: 107, labelMinutes: label)
    check(shortSlots.map(\.labelRoom) == [20, 60]
          && WeekStack.topmost(at: 562, x: 50, spans: short, slots: shortSlots, dayWidth: 107, minMinutes: 18.0 / 44 * 60) == 0
          && WeekStack.topmost(at: 566, x: 50, spans: short, slots: shortSlots, dayWidth: 107, minMinutes: 18.0 / 44 * 60) == nil
          && WeekStack.topmost(at: 600, x: 50, spans: short, slots: shortSlots, dayWidth: 107) == 1,
          "周视图：不叠放的块标题下露出整块；短块按画出来的高矮算悬停范围")
    // 宽窗口（一天 300pt）三列并排每块也有 96pt：照旧并排，不叠
    let wide = WeekStack.layout(h2, dayWidth: 300, labelMinutes: label)
    check(wide.allSatisfy { !$0.stacked && $0.columns == 3 } && WeekStack.frame(wide[0], dayWidth: 300).width >= 90,
          "周视图：宽到并排也写得下时照旧并排")

    // 周三 16:30 补习（16:30–18:00）与 17:45 健身房（17:45–18:45）：两列，窄窗口里并排只剩 49pt
    let wed = [Span(start: 16 * 60 + 30, end: 18 * 60), Span(start: 17 * 60 + 45, end: 18 * 60 + 45)]
    let wedNarrow = WeekStack.layout(wed, dayWidth: 107, labelMinutes: label)
    let wedWide = WeekStack.layout(wed, dayWidth: 144, labelMinutes: label)
    check(wedNarrow.allSatisfy(\.stacked) && wedNarrow.map(\.labelOffset) == [0, 0] && wedWide.allSatisfy { !$0.stacked && $0.columns == 2 }
          && WeekStack.frame(wedWide[0], dayWidth: 144).width >= WeekStack.compactWidth,
          "周视图两列：窄窗口里叠放后两块标题都露得出来 → 叠；1440 宽并排每块 ≥ 64pt → 并排")
    // 两件同时开始、同样长：叠了下面那块标题无处可挪 → 两列时不叠，仍并排（窄块只写一行标题）
    let twin = WeekStack.layout([Span(start: 840, end: 900), Span(start: 840, end: 900)], dayWidth: 107, labelMinutes: label)
    check(twin.allSatisfy { !$0.stacked } && twin.map(\.column).sorted() == [0, 1]
          && WeekStack.frame(twin[0], dayWidth: 107).width < WeekStack.compactWidth,
          "周视图两列：叠了会整块盖住标题时不叠，并排、只写一行标题")
    // 同时开始的长短两件：长的在底下（前一列），标题挪到短的结束处
    let longShort = WeekStack.layout([Span(start: 600, end: 630), Span(start: 600, end: 720)], dayWidth: 107, labelMinutes: label)
    check(longShort.map(\.column) == [1, 0] && longShort.allSatisfy(\.stacked) && longShort.map(\.labelOffset) == [0, 30],
          "周视图：同时开始的长在下、短在上，长的标题挪到短的结束处：\(longShort.map(\.labelOffset))")
    // 单独一块、首尾相接的两块：各自一列、占满一天（与原来一样宽）
    let single = WeekStack.layout([Span(start: 540, end: 600), Span(start: 600, end: 660)], dayWidth: 107, labelMinutes: label)
    check(single.allSatisfy { $0.columns == 1 && $0.column == 0 && !$0.stacked && $0.labelOffset == 0 }
          && WeekStack.frame(single[0], dayWidth: 107) == (2, 101) && WeekStack.layout([], dayWidth: 107, labelMinutes: label).isEmpty,
          "周视图：不重叠的（含首尾相接）各占满一天；没有日程时为空")
    // 一下午压了 12 件：照样叠，每块都在这一天里、最上面那块仍留一天宽的 55% 以上、步长收小
    let pile = (0..<12).map { Span(start: 13 * 60 + $0 * 5, end: 17 * 60) }
    let pileSlots = WeekStack.layout(pile, dayWidth: 107, labelMinutes: label)
    let pileFrames = pileSlots.map { WeekStack.frame($0, dayWidth: 107) }
    check(pileSlots.allSatisfy { $0.stacked && $0.columns == 12 }
          && pileFrames.allSatisfy { $0.x >= 2 && $0.x + $0.width <= 105.001 && $0.width >= 103 * 0.55 - 0.001 }
          && Set(pileFrames.map(\.x)).count == 12,
          "周视图：12 件压在一起也都在这一天里，最上面那块 ≥ 55% 宽，步长收小、各不相同")
    // 网格画哪几个钟点
    check(WeekStack.hours(hasItems: false, earliestMinute: nil) == 8..<20
          && WeekStack.hours(hasItems: true, earliestMinute: 7 * 60 + 30) == 6..<24
          && WeekStack.hours(hasItems: true, earliestMinute: 5 * 60 + 10) == 5..<24
          && WeekStack.hours(hasItems: true, earliestMinute: nil) == 6..<24,
          "周视图：空周只画 08–20 点；平时 06–24 点，有更早的从那一小时起；只有全天日程也照常")

    // 全部日程 / 详情里的重复方式：“每周一、四”，不再“每周周一、周四”
    let tue = LocalDay(key: "2026-10-13")!
    let ruleToday = LocalDay(key: "2026-10-22")!
    func rule(_ kind: RecurrenceKind, _ interval: Int = 1, _ days: [Int] = [], until: LocalDay? = nil, stop: LocalDay? = nil) -> String {
        RecurrenceRule(start: tue, kind: kind, interval: interval, weekdays: days, repeatUntil: until, stopBefore: stop)
            .summary(relativeTo: ruleToday)
    }
    let texts = [rule(.custom, 1, [0, 3]), rule(.custom, 1, [3, 0, 3]), rule(.weekly), rule(.custom, 2, [1, 3]),
                 rule(.custom, 1, [0, 1, 2, 3, 4]), rule(.custom, 1, Array(0..<7)), rule(.custom, 2, Array(0..<7)),
                 rule(.custom, 1, [0, 1, 3]), rule(.daily), rule(.daily, 3), rule(.none),
                 rule(.weekly, until: LocalDay(key: "2026-12-31")!), rule(.custom, 1, [0, 3], stop: LocalDay(key: "2026-11-02")!)]
    check(texts == ["每周一、四", "每周一、四", "每周二", "每 2 周的周二、四",
                    "每周一至五", "每天", "每 2 周的周一至日",
                    "每周一、二、四", "每天", "每 3 天", "不重复",
                    "每周二，至 12月31日", "每周一、四（11月2日 起停止）"],
          "重复方式的说法：每周一、四 / 每 2 周的周二、四 / 每周一至五 / 七天都有写每天：\(texts)")
    // 止日、停止日不是今年的带年份（只写“至 1月15日”读着像今年）
    let otherYears = [rule(.weekly, until: LocalDay(key: "2027-01-15")!), rule(.custom, 1, [0, 3], stop: LocalDay(key: "2025-11-07")!)]
    check(otherYears == ["每周二，至 2027年1月15日", "每周一、四（2025年11月7日 起停止）"],
          "重复方式：止日、停止日不是今年的写上年份：\(otherYears)")
}

// MARK: e2-remind：#17 日程开始前、那年今日、周复盘写本周实数（Core/ReminderPlan）
do {
    typealias Plan = ReminderPlan
    let today = LocalDay(key: "2026-10-22")!   // 周四
    let noon = 12 * 60
    func day(_ key: String) -> LocalDay { LocalDay(key: key)! }
    /// 摘句里还带着复盘模板的小标题或素材段
    func copyHasTemplate(_ bodies: [String]) -> Bool { bodies.contains { $0.contains("【") || $0.contains("〔") || $0.contains("· 功课") } }

    // 1. 标识与点开去哪：三类各认得出，落笔 / 功课 / 旧的每周重复那条（apt.weekly-review）与写坏的不认
    check(Plan.parseExtra(identifier: "apt.event.2026-10-22.1500.0").map { $0.kind == .event && $0.day == today } == true
          && Plan.parseExtra(identifier: "apt.lookback.2026-10-23")?.day == today.adding(days: 1)
          && Plan.parseExtra(identifier: "apt.weekly.2026-10-25")?.kind == .weekly
          && Plan.parseExtra(identifier: "apt.weekly-review") == nil && Plan.parseExtra(identifier: "apt.event.2026-10-22") == nil
          && Plan.parseExtra(identifier: "apt.lookback.2026-13-40") == nil && Plan.parseExtra(identifier: "apt.lookback.2026-10-22.1") == nil
          && Plan.parseExtra(identifier: "apt.write.2026-10-22") == nil && Plan.parse(identifier: "apt.event.2026-10-22.1500.0") == nil,
          "#17 提醒标识：apt.event.<日期>.<时刻>.<序> / apt.lookback.<日期> / apt.weekly.<日期> 认得出，别的不认")
    check(Plan.route(for: "apt.event.2026-10-24.0900.1") == .schedule(day("2026-10-24")) && Plan.route(for: "apt.lookback.2026-10-22") == .overview
          && Plan.route(for: "apt.weekly.2026-10-25") == .weekly && Plan.route(for: "apt.weekly-review") == nil
          && Plan.route(for: Plan.identifier(.write, day: today)) == nil,
          "#17 点开：日程回时辰卷那一周、那年今日回今日洞府、周复盘翻七日小卷；落笔与旧周复盘不走这里")

    // 2. 日程开始前：只排今天与明天有钟点、提醒时刻还没过的；正文写时刻、标题、还有几分钟、地点
    let items: [Plan.EventItem] = [
        .init(day: today, startMinute: 15 * 60, title: "组会", location: "图书馆 3 楼"),
        .init(day: today, startMinute: 11 * 60, title: "已开始的"),
        .init(day: today, startMinute: 12 * 60 + 5, title: "提醒时刻已过"),
        .init(day: today, startMinute: nil, title: "全天的"),
        .init(day: today.adding(days: 1), startMinute: 9 * 60, title: "明早晨读"),
        .init(day: today.adding(days: 2), startMinute: 9 * 60, title: "后天的"),
        .init(day: today.adding(days: -1), startMinute: 23 * 60, title: "昨天的"),
    ]
    let events = Plan.eventSlots(today: today, nowMinute: noon, lead: 10, items: items)
    check(events.map(\.body) == ["15:00 组会 · 还有 10 分钟 · 图书馆 3 楼", "09:00 明早晨读 · 还有 10 分钟"]
          && events.map(\.identifier) == ["apt.event.2026-10-22.1500.0", "apt.event.2026-10-23.0900.0"]
          && events[0].fireDay == today && events[0].minute == 14 * 60 + 50
          && events[1].fireDay == today.adding(days: 1) && events[1].minute == 8 * 60 + 50
          && events.allSatisfy { $0.title == "时辰将至" && $0.kind == .event },
          "#17 日程：只排今天与明天有钟点的（全天、已过、后天、昨天的不排），正文“\(events.first?.body ?? "")”")
    let midnight = Plan.eventSlots(today: today, nowMinute: 22 * 60, lead: 30,
                                   items: [.init(day: today.adding(days: 1), startMinute: 10, title: "子时观星")])
    check(midnight.first.map { $0.fireDay == today && $0.minute == 23 * 60 + 40 && $0.day == today.adding(days: 1)
                               && $0.body == "00:10 子时观星 · 还有 30 分钟" } == true,
          "#17 日程：明天 00:10 的提前 30 分钟，今天 23:40 发，点开仍跳到明天那一周")
    check(Plan.eventSlots(today: today, nowMinute: noon, lead: 7, items: [items[0]]).first?.minute == 14 * 60 + 50
          && Plan.clampLead(30) == 30 && Plan.eventLeadOptions == [5, 10, 15, 30],
          "#17 日程：提前量只有 5 / 10 / 15 / 30，认不出的按 10 分钟")
    let many = (0..<20).map { Plan.EventItem(day: today.adding(days: 1), startMinute: 8 * 60 + $0 * 30, title: "第\($0)项") }
        + [Plan.EventItem(day: today.adding(days: 1), startMinute: 8 * 60, title: "同刻另一项")]
    let capped = Plan.eventSlots(today: today, nowMinute: noon, lead: 10, items: many.reversed())
    check(capped.count == 12 && capped.first?.body == "08:00 同刻另一项 · 还有 10 分钟" && capped[1].body == "08:00 第0项 · 还有 10 分钟"
          && capped.last?.body.hasPrefix("13:00 第10项") == true && Set(capped.map(\.identifier)).count == 12
          && capped[0].identifier == "apt.event.2026-10-23.0800.0" && capped[1].identifier == "apt.event.2026-10-23.0800.1",
          "#17 日程：最多 12 条、按提醒先后取；同一刻的几项标识不重（按标题排、末尾编号）")

    // 3. 那年今日：每天 9:00，那天正好有一年 / 半年 / 一月 / 一周前写下的话才排，先远后近；摘前 30 字
    let keys = Plan.lookbackKeys(today: today)
    check(["2025-10-22", "2026-04-22", "2026-09-22", "2026-10-15", "2025-10-28", "2026-10-21"].allSatisfy(keys.contains) && keys.count <= 28
          && !keys.contains("2025-10-21"),
          "#17 那年今日：只查 7 天里各自正好一年 / 半年 / 一月 / 一周前的那几天（不放宽，共 \(keys.count) 天）")
    let written = ["2025-10-22": "一年前的秋夜，读完了那本书。", "2026-10-15": "一周前也写过", "2026-10-16": "对明天来说是一周前",
                   "2026-04-25": "  \n "]
    let lookback = Plan.lookbackSlots(today: today, nowMinute: 8 * 60, written: written)
    check(lookback.map(\.day) == [today, today.adding(days: 1)]
          && lookback[0].body == "一年前的今天，你写下：「一年前的秋夜，读完了那本书。」"
          && lookback[1].body == "一周前的今天，你写下：「对明天来说是一周前」"
          && lookback.allSatisfy { $0.minute == 9 * 60 && $0.fireDay == $0.day && $0.title == "旧笔新读" }
          && lookback[0].identifier == "apt.lookback.2026-10-22",
          "#17 那年今日：今天先取一年前（不取一周前）、明天取一周前，空白的那篇当没写（10月25日不排）")
    check(Plan.lookbackSlots(today: today, nowMinute: 9 * 60, written: written).map(\.day) == [today.adding(days: 1)]
          && Plan.lookbackSlots(today: today, nowMinute: 0, written: [:]).isEmpty,
          "#17 那年今日：过了 9:00 不排今天；往年那几天都没写过，一条也不排")
    check(Plan.lookbackBody(label: "半年前", text: String(repeating: "云", count: 40) + "\n山")
          == "半年前的今天，你写下：「" + String(repeating: "云", count: 30) + "……」",
          "#17 那年今日：正文摘前 30 字")
    // 复盘正文：去掉【所得】等小标题、〔本期素材〕段（到空行为止）与列表记号，只摘自己写的；全是模板的那篇当没写
    let review = "【所得】\n读完两章\n\n【所失】\n拖延了一下午\n\n【所悟】\n先做最难的\n\n【下一步】\n"
    let material = "【所得】\n〔本期素材 · 10月19日–25日〕\n· 功课：冥想 7/7 天\n· 落笔 5 篇\n\n跑完了第一个十公里\n\n【所失】\n\n【所悟】\n\n【下一步】\n"
    let template = "【所得】\n\n【所失】\n\n【所悟】\n\n【下一步】\n"
    let reviewSlots = Plan.lookbackSlots(today: day("2026-11-01"), nowMinute: 0, written: ["2026-10-25": review])
    check(reviewSlots.map(\.body) == ["一周前的今天，你写下：「读完两章 拖延了一下午 先做最难的」"]
          && Plan.lookbackBody(label: "一周前", text: material) == "一周前的今天，你写下：「跑完了第一个十公里」"
          && Plan.lookbackBody(label: "一年前", text: "- 早起\n- 读书 20 页") == "一年前的今天，你写下：「早起 读书 20 页」"
          && Plan.lookbackSlots(today: day("2026-11-01"), nowMinute: 0, written: ["2026-10-25": template]).isEmpty
          && !copyHasTemplate(reviewSlots.map(\.body) + [Plan.lookbackBody(label: "一周前", text: material)]),
          "#17 那年今日：复盘的【所得】小标题、〔本期素材〕段与列表记号不进摘句：\(reviewSlots.map(\.body))")
    // 前一个月没有这一天（截到月底）的不提：3月28–31日不会连推四天2月28日那一句；5、7、10、12 月 31 日，8月29–31日的“半年前”同理
    let endOfFeb = Plan.lookbackSlots(today: day("2027-03-28"), nowMinute: 0, written: ["2027-02-28": "二月末的一句"])
    let endOfApril = Plan.lookbackSlots(today: day("2027-05-25"), nowMinute: 0, written: ["2027-04-30": "四月末的一句"])
    let halfYear = Plan.lookbackSlots(today: day("2027-08-27"), nowMinute: 0, written: ["2027-02-28": "二月末的一句"])
    check(endOfFeb.map(\.day.key) == ["2027-03-28"] && endOfFeb.first?.body == "一月前的今天，你写下：「二月末的一句」"
          && endOfApril.map(\.day.key) == ["2027-05-30"] && halfYear.map(\.day.key) == ["2027-08-28"]
          && halfYear.first?.body.hasPrefix("半年前的今天") == true
          && Plan.lookbackSpans(today: day("2027-03-30")).map(\.label) == ["一年前", "半年前", "一周前"]
          && Plan.lookbackSpans(today: day("2026-10-22")).map(\.label) == ["一年前", "半年前", "一月前", "一周前"],
          "#17 那年今日：截到月底的“一月前 / 半年前”不算，同一句只在正好那天提一次：\(endOfFeb.map(\.day.key)) \(endOfApril.map(\.day.key)) \(halfYear.map(\.day.key))")

    // 4. 周复盘：接下来 12 次各一条（12 周内不打开应用也照响），第一次写本周实数（只取一次、截到今天），以后几次用通用句；
    //    功课完成率只在那一周排程时已过完、或提醒就在今明两天时写（应用中途没开时，到点发的不是排程那天的旧数）
    var asked: [String] = []
    let weekly = Plan.weeklySlots(today: today, nowMinute: noon, weekday: 1, minute: 21 * 60) { first, last in
        asked.append("\(first.key)~\(last.key)")
        return Plan.WeekNumbers(entries: 9, habitRate: 0.714)
    }
    check(weekly.map(\.day.key) == (0..<12).map { day("2026-10-25").adding(days: 7 * $0).key } && weekly.last?.day.key == "2027-01-10"
          && weekly[0].body == "这一周落笔 9 篇，翻看七日小卷。" && weekly.dropFirst().allSatisfy { $0.body == Plan.weeklyGeneric }
          && asked == ["2026-10-19~2026-10-22"] && weekly[0].identifier == "apt.weekly.2026-10-25"
          && weekly.allSatisfy { $0.title == "该写周复盘了" && $0.minute == 21 * 60 && $0.fireDay == $0.day },
          "#17 周复盘：周日 21:00 排 12 次（到 1月10日），第一次写“\(weekly.first?.body ?? "")”（本周一到今天，只取一次；离提醒还有 3 天，功课先不写）")
    check(Plan.weeklyHorizon == 12 && Plan.horizonDays * 3 + Plan.eventLimit + Plan.weeklyHorizon <= 64,
          "#17 周复盘：各类都开着时待发的通知合计 \(Plan.horizonDays * 3 + Plan.eventLimit + Plan.weeklyHorizon) 条，在系统 64 条的上限以内")
    func firstWeekly(_ key: String, _ nowMinute: Int, weekday: Int, minute: Int, _ numbers: Plan.WeekNumbers) -> String? {
        Plan.weeklySlots(today: day(key), nowMinute: nowMinute, weekday: weekday, minute: minute) { _, _ in numbers }.first?.body
    }
    let rich = Plan.WeekNumbers(entries: 9, habitRate: 0.714)
    check(firstWeekly("2026-10-24", noon, weekday: 1, minute: 21 * 60, rich) == "这一周落笔 9 篇、功课 71%，翻看七日小卷。"
          && firstWeekly("2026-10-25", noon, weekday: 1, minute: 21 * 60, rich) == "这一周落笔 9 篇、功课 71%，翻看七日小卷。"
          && firstWeekly("2026-10-21", noon, weekday: 1, minute: 21 * 60, rich) == "这一周落笔 9 篇，翻看七日小卷。"
          && firstWeekly("2026-10-21", noon, weekday: 1, minute: 21 * 60, Plan.WeekNumbers(entries: 0, habitRate: 1)) == Plan.weeklyGeneric
          && firstWeekly("2026-10-26", 8 * 60, weekday: 2, minute: 9 * 60, Plan.WeekNumbers(entries: 3, habitRate: 0.5)) == "上一周落笔 3 篇、功课 50%，翻看七日小卷。"
          && Plan.weeklyRateFresh(range: (day("2026-10-19"), day("2026-10-25"), true), fireDay: day("2026-10-26"), today: day("2026-10-25"))
          && !Plan.weeklyRateFresh(range: (day("2026-10-19"), day("2026-10-25"), false), fireDay: day("2026-10-25"), today: day("2026-10-23")),
          "#17 周复盘：功课的数只在提醒前一天起、或那一周已过完时写；周三排周日的只写篇数（应用中途没开也不发旧数）")
    asked = []
    let passed = Plan.weeklySlots(today: today, nowMinute: noon, weekday: 5, minute: 8 * 60) { _, _ in
        asked.append("x")
        return Plan.WeekNumbers(entries: 1)
    }
    let later = Plan.weeklySlots(today: today, nowMinute: noon, weekday: 5, minute: 21 * 60) { _, _ in Plan.WeekNumbers(entries: 2) }
    check(passed.first?.day == today.adding(days: 7) && passed.first?.body == Plan.weeklyGeneric && asked.isEmpty
          && later.first?.day == today && later.first?.body == "这一周落笔 2 篇，翻看七日小卷。",
          "#17 周复盘：今天已过时刻排下周（那周还没开始，不取数、用通用句）；还没到点就排今天")
    let monday = Plan.weeklySlots(today: today, nowMinute: noon, weekday: 2, minute: 9 * 60) { first, last in
        asked.append("\(first.key)~\(last.key)")
        return Plan.WeekNumbers(entries: 3, habitRate: nil)
    }
    check(monday.first?.day.key == "2026-10-26" && monday.first?.body == "上一周落笔 3 篇，翻看七日小卷。" && asked.last == "2026-10-19~2026-10-22"
          && Plan.weeklyRange(fireDay: day("2026-10-26"), minute: 13 * 60) == (day("2026-10-26"), day("2026-10-26"), false),
          "#17 周复盘：周一 12:00 前提醒说上一整周（与七日小卷同一规矩），过了中午说这一周")
    check(Plan.weeklyBody(Plan.WeekNumbers(entries: 0, habitRate: 0.5), previous: false) == "这一周功课 50%，翻看七日小卷。"
          && Plan.weeklyBody(Plan.WeekNumbers(), previous: false) == Plan.weeklyGeneric
          && Plan.weeklyBody(Plan.WeekNumbers(entries: 0, habitRate: .nan), previous: true) == Plan.weeklyGeneric
          && (1...7).map(Plan.weekdayIndex) == [6, 0, 1, 2, 3, 4, 5] && Plan.weekdayIndex(0) == 6,
          "#17 周复盘：只有一样数就只写一样，都没有用通用句；星期换算周一为 0")

    // 5. 设置组摘要与文案
    check(Plan.summary(write: 21 * 60 + 30, habits: nil, events: 10, lookback: true, weekly: true, loginItem: true)
          == ["落笔 21:30", "日程前 10 分钟", "那年今日", "周复盘已开", "开机自启"]
          && Plan.summary(write: nil, habits: nil, events: nil, lookback: false, weekly: false, loginItem: false).isEmpty
          && Plan.summary(write: nil, habits: 20 * 60, events: nil, lookback: false, weekly: true, loginItem: false)
          == Plan.summary(write: nil, habits: 20 * 60, weekly: true, loginItem: false),
          "#17 设置摘要：开着的两行写进“景致与提醒”的摘要，没开的不写")
    let copy = [Plan.eventTitle, Plan.lookbackTitle, Plan.weeklyTitle, Plan.weeklyGeneric, events[0].body, lookback[0].body,
                Plan.weeklyBody(Plan.WeekNumbers(entries: 1, habitRate: 0), previous: false)]
    check(!copy.contains { t in ["失败", "中断", "漏打", "没写"].contains { t.contains($0) } }, "#17 提醒文案不说“失败 / 中断 / 漏打 / 没写”")
}

// MARK: e2-energy-ui
// #20 能耗（界面侧）：没人看时常驻动效视为关——满 3 分钟没操作、主窗口被完全挡住；开关本身的含义不变；金光呼吸的曲线
do {
    let G = MotionGate.self
    // 满 3 分钟才算闲着（差一秒不算），时钟被拨回不算
    check(!G.isIdle(now: 1179.9, lastActivity: 1000) && G.isIdle(now: 1180, lastActivity: 1000) && !G.isIdle(now: 900, lastActivity: 1000),
          "能耗：满 180 秒没操作才算闲着（179.9 秒不算，时钟拨回不算）")
    // 下一次检查：最长 30 秒；离 3 分钟不到 30 秒时正好在那一刻；最短 1 秒；闲着后不再定时
    let checks = [0, 100, 150, 170, 179.5, 180, 400].map { G.nextCheck(now: 1000 + $0, lastActivity: 1000) }
    check(checks == [30, 30, 30, 10, 1, nil, nil] && G.nextCheck(now: 900, lastActivity: 1000) == 30,
          "能耗：最长 30 秒看一次，3 分钟前不到 30 秒时正好在 3 分钟那一刻看，闲着后不再定时（\(checks)）")
    // 一路按检查节奏走下去：停在 180–181 秒之间，不会晚到 210 秒
    var clock = 1000.0, stops = 0
    while let delay = G.nextCheck(now: clock, lastActivity: 1000), stops < 50 { clock += delay; stops += 1 }
    check(clock >= 1180 && clock <= 1181 && stops <= 8, "能耗：按检查节奏走，3 分钟整停下（\(clock - 1000) 秒，看了 \(stops) 次）")
    // 遮挡：只在窗口已上屏（或最小化）且系统说一点都看不见时算
    check(G.isOccluded(onScreen: true, visibleFlag: false) && !G.isOccluded(onScreen: true, visibleFlag: true)
          && !G.isOccluded(onScreen: false, visibleFlag: false) && !G.isOccluded(onScreen: false, visibleFlag: true),
          "能耗：主窗口上屏且完全看不见才算挡住；还没上屏时按看得见算")
    // 开关组合：有人在看时与原定义（动效开关 && !减少动态效果 && 窗口在前台）逐一相同；闲着或挡住时一律关
    var same = true, quiet = true
    for bits in 0..<8 {
        let enabled = bits & 1 != 0, reduce = bits & 2 != 0, inactive = bits & 4 != 0
        if G.allows(enabled: enabled, reduceMotion: reduce, inactive: inactive, idle: false, occluded: false) != (enabled && !reduce && !inactive) { same = false }
        for (idle, occluded) in [(true, false), (false, true), (true, true)]
        where G.allows(enabled: enabled, reduceMotion: reduce, inactive: inactive, idle: idle, occluded: occluded) { quiet = false }
    }
    check(same && quiet, "能耗：有人在看时动效开关含义不变；闲着或被挡住时视为关")
    // RootView 分两样算：动效开关（悬停、转场、打卡圈、仪式看它）不带闲着与遮挡；常驻循环层 = 动效开关 && 有人在看。
    // 闲着、被挡住只停常驻层，动效开关不翻（指针下的卡片不会落下又弹起，闲置后第一下打卡照放仪式）
    var split = true
    for bits in 0..<32 {
        let enabled = bits & 1 != 0, reduce = bits & 2 != 0, inactive = bits & 4 != 0, idle = bits & 8 != 0, occluded = bits & 16 != 0
        let motion = G.allows(enabled: enabled, reduceMotion: reduce, inactive: inactive, idle: false, occluded: false)
        let ambient = G.allows(enabled: enabled, reduceMotion: reduce, inactive: inactive, idle: idle, occluded: occluded)
        if motion != (enabled && !reduce && !inactive) || ambient != (motion && !idle && !occluded) { split = false }
    }
    check(split, "能耗：动效开关不看闲着与遮挡；常驻循环层 = 动效开关 && 有人在看")
    // 金光呼吸：与原来逐帧算的公式同一条曲线；从 1 倍那一点开始
    let B = G.Breath.self
    check(abs(B.scale(at: 0) - 0.9) < 1e-9 && abs(B.scale(at: 1.2) - 1.15) < 1e-9 && abs(B.scale(at: 2.4) - 0.9) < 1e-9
          && abs(B.scale(at: B.restOffset) - 1) < 1e-9 && B.restOffset > 0 && B.restOffset < 1.2,
          "金光呼吸：0.9 ↔ 1.15、2.4 秒一个来回；起步落在 1 倍、正往上长（\(B.restOffset) 秒处）")
    // 25 个采样点平滑连起来：相邻两点差不超过 0.04 倍，首尾相接（循环不跳）
    let samples = (0...24).map { B.scale(at: B.period * Double($0) / 24) }
    let maxStep = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 1
    check(maxStep < 0.04 && abs(samples.first! - samples.last!) < 1e-9, "金光呼吸：采样点够密（相邻最多差 \(maxStep)），一圈首尾相接")
}

// MARK: e2-energy-bg（#21 能耗：传书巡查的节奏——前台 3 秒、后台靠门铃 60 秒兜底 / 没门铃 10 秒、等文件写稳、数据停稳再确认）
do {
    typealias P = CourierPace
    check(P.next(foreground: true, watching: true, unsettled: false) == P.Wait(seconds: 3, tolerance: 1)
          && P.next(foreground: true, watching: false, unsettled: false) == P.Wait(seconds: 3, tolerance: 1),
          "巡查节奏：前台每 3 秒（容差 1 秒），有没有门铃都一样")
    check(P.next(foreground: false, watching: true, unsettled: false) == P.Wait(seconds: 60, tolerance: 5),
          "巡查节奏：后台门铃装好时只靠门铃叫醒，另 60 秒兜底")
    check(P.next(foreground: false, watching: false, unsettled: false) == P.Wait(seconds: 10, tolerance: 2),
          "巡查节奏：后台门铃没装上（收件箱建不出来等）退回每 10 秒")
    check(P.next(foreground: false, watching: true, unsettled: true) == P.foreground
          && P.next(foreground: true, watching: true, unsettled: true) == P.foreground,
          "巡查节奏：数据刚变还没停稳，前后台都 3 秒后再确认一次（快照仍是停稳才重建）")
    // 等文件写稳：刚写 0.2 秒的传书再等约 0.9 秒；后台 60 秒兜底时也一样，不会干等一分钟
    let fresh = P.next(foreground: false, watching: true, unsettled: false, settlingAge: 0.2)
    check(abs(fresh.seconds - 0.9) < 0.001 && fresh.tolerance <= 0.1, "巡查节奏：刚写 0.2 秒的传书约 0.9 秒后再看（\(fresh.seconds)）")
    let almost = P.next(foreground: true, watching: true, unsettled: false, settlingAge: 0.95)
    check(almost.seconds < 0.2 && almost.seconds > 0, "巡查节奏：差一点写稳的，0.15 秒后再看（\(almost.seconds)）")
    // 投进来到收录：门铃当场响 + 等写稳，最晚约 1.1 秒（传书仍约 1–3 秒收录）
    let worst = (0...9).map { P.next(foreground: false, watching: true, unsettled: false, settlingAge: Double($0) / 10).seconds }.max() ?? 99
    check(worst <= 1.1 + 1e-9, "巡查节奏：门铃响后等写稳最多约 1.1 秒（\(worst)），传书仍约 1–3 秒收录")
    check(P.next(foreground: false, watching: true, unsettled: false, settlingAge: 1.5) == P.watched
          && P.next(foreground: false, watching: true, unsettled: false, settlingAge: -3) == P.watched,
          "巡查节奏：已写稳（交给本轮收录）或写入时刻在未来（钟面倒拨）的不另等")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    check(!P.due(since: t0, now: t0.addingTimeInterval(599), every: P.recheckEvery)
          && P.due(since: t0, now: t0.addingTimeInterval(600), every: P.recheckEvery)
          && P.due(since: t0, now: t0.addingTimeInterval(-5), every: P.recheckEvery),
          "巡查兜底：快照 10 分钟重算一次（按钟点，不再数轮次；钟面倒拨也算到点）")
    check(!P.due(since: t0, now: t0.addingTimeInterval(6 * 3600 - 1), every: P.cleanEvery)
          && P.due(since: t0, now: t0.addingTimeInterval(6 * 3600), every: P.cleanEvery),
          "巡查兜底：归档清理 6 小时一次")
    check(abs(P.gapLeft(since: t0, now: t0.addingTimeInterval(0.1)) - 0.4) < 1e-4 && P.gapLeft(since: t0, now: t0.addingTimeInterval(2)) == 0
          && P.gapLeft(since: .distantPast, now: t0) == 0 && P.gapLeft(since: t0, now: t0.addingTimeInterval(-1)) == 0,
          "巡查门铃：刚看完一轮又响，补足 0.5 秒再看；隔得够久、钟面倒拨都不等")
}

// MARK: r3-hooks（#14 首页回看入口；七日小卷与复盘素材的花费口径只写一份）
do {
    func day(_ key: String) -> LocalDay { LocalDay(key: key)! }
    let thu = day("2026-10-22")

    // 1. 七日小卷的“账单导到哪天 / 本周不全”与复盘素材“本期花费”同一组数据结论相同（规则只在 ReviewThread 写一份）
    func src(_ account: String, _ start: String, _ end: String) -> FinanceSource {
        FinanceSource(sha256: "hk\(account)\(end)", account: account, rawCsv: "", importedAt: "", rows: 0, start: start, end: end)
    }
    func tx(_ date: String, _ cents: Int, _ category: String, account: String = "CBA") -> FinanceTransaction {
        FinanceTransaction(id: "hk\(date)\(cents)\(category)", date: date, amountCents: -cents, balanceCents: 0, description: category, account: account,
                           category: category, kind: "消费", needsReview: false, reason: "", sourceLine: 0)
    }
    let rows = [tx("2026-10-12", 2000, "餐饮与外卖"), tx("2026-10-13", 5000, "购物"), tx("2026-10-19", 4000, "餐饮与外卖"),
                tx("2026-10-20", 4000, "交通出行"), tx("2026-10-21", 1850, "餐饮与外卖", account: ManualExpense.account)]
    let sourceSets: [[FinanceSource]] = [
        [],
        [src(ManualExpense.account, "2026-10-01", "2026-10-22")],
        [src("CBA", "2026-09-01", "2026-10-20")],
        [src("CBA", "2026-09-01", "2026-10-22"), src("ANZ", "2026-09-01", "2026-10-18")],
        [src("CBA", "2026-10-01", "2026-10-25"), src("旧卡", "2023-01-01", "2024-03-31")],
        [src("旧卡", "2023-01-01", "2024-03-31"), src("旧卡2", "2024-01-01", "2024-05-31")],
    ]
    var agree = true
    for sources in sourceSets {
        for week in [WeeklyDigest.Week(monday: thu.mondayOfWeek, today: thu), WeeklyDigest.Week(monday: thu.mondayOfWeek.adding(days: -7), today: thu)] {
            let since = week.monday.adding(days: -WeeklyDigest.activeAccountDays)
            let through = ReviewThread.bankThrough(sources: sources, activeSince: since)
            let covered = WeeklyDigest.coveredThrough(sources, activeSince: since)
            let spend = WeeklyDigest.spend(rows, sources: sources, week: week)
            let sum = ReviewThread.spending(rows, first: week.monday, last: week.last)
            let line = ReviewThread.spendingLine(rows: rows, first: week.monday, last: week.last, period: .week, bankThrough: through, today: thu)
            agree = agree && covered?.key == through
                && WeeklyDigest.bankThrough(sources.filter { $0.account != ManualExpense.account }.compactMap { s in s.range.map { (account: s.account, end: $0.1) } },
                                            activeSince: since) == through
                && spend?.cents == sum.cents && spend?.topCategory == sum.top?.category && spend?.topCents == sum.top?.cents
                && (spend?.incomplete ?? false) == (line?.contains("不全") ?? false)
        }
    }
    check(agree, "七日小卷与复盘素材：同一组账单（只有手记、导全、没导全、停用旧卡）同一周的花费、最多一类、“不全”结论都一样")

    // 2. 七日小卷纸笺：周日 18:00 起本周、周一 12:00 前上一周；其余时候不出
    let sun = day("2026-10-25"), mon = day("2026-10-26"), sat = day("2026-10-24")
    check(DashboardCues.stripWeek(today: sun, minute: 17 * 60 + 59) == nil
          && DashboardCues.stripWeek(today: sun, minute: 18 * 60)?.monday == day("2026-10-19")
          && DashboardCues.stripWeek(today: sun, minute: 23 * 60 + 59)?.last == sun
          && DashboardCues.stripWeek(today: mon, minute: 0)?.monday == day("2026-10-19")
          && DashboardCues.stripWeek(today: mon, minute: 11 * 60 + 59)?.sunday == sun
          && DashboardCues.stripWeek(today: mon, minute: 12 * 60) == nil
          && DashboardCues.stripWeek(today: sat, minute: 21 * 60) == nil
          && DashboardCues.stripWeek(today: thu, minute: 20 * 60) == nil,
          "纸笺时段：周日 18:00 起是本周、周一 12:00 前是上一周（与小卷默认打开的同一周），周六、周四都不出")
    let thisWeek = DashboardCues.stripWeek(today: sun, minute: 20 * 60)!
    let lastWeek = DashboardCues.stripWeek(today: mon, minute: 9 * 60)!
    let practiced = WeeklyDigest.HabitWeek(rate: 0.71, previousRate: nil, steadiest: nil, tending: nil,
                                           lines: [WeeklyDigest.HabitLine(title: "冥想", done: 5, expected: 7)])
    let idle = WeeklyDigest.HabitWeek(rate: 0, previousRate: nil, steadiest: nil, tending: nil,
                                      lines: [WeeklyDigest.HabitLine(title: "冥想", done: 0, expected: 7)])
    let strips = [DashboardCues.stripLine(week: thisWeek, entries: 9, habits: practiced),
                  DashboardCues.stripLine(week: lastWeek, entries: 9, habits: practiced),
                  DashboardCues.stripLine(week: thisWeek, entries: 2, habits: idle),
                  DashboardCues.stripLine(week: thisWeek, entries: 0, habits: practiced),
                  DashboardCues.stripLine(week: thisWeek, entries: 3, habits: nil)]
    check(strips == ["七日已过 · 这一周落笔 9 篇、功课 71%", "七日已过 · 上一周落笔 9 篇、功课 71%", "七日已过 · 这一周落笔 2 篇",
                     "七日已过 · 这一周功课 71%", "七日已过 · 这一周落笔 3 篇"]
          && DashboardCues.stripLine(week: thisWeek, entries: 0, habits: idle) == nil
          && DashboardCues.stripLine(week: thisWeek, entries: 0, habits: nil) == nil,
          "纸笺那一句：落笔与功课各报各的，一次卡都没打不写“功课 0%”，那一周什么都没有就不出：\(strips.map { $0 ?? "nil" })")

    // 3. 出关：最近一条记录在 3 天以前、今天还没记录；从没记录过、今天已有、只隔一两天、记录在“以后”的都不出
    check(DashboardCues.retreat(lastRecord: nil, today: thu) == nil
          && DashboardCues.retreat(lastRecord: thu, today: thu) == nil
          && DashboardCues.retreat(lastRecord: thu.adding(days: -2), today: thu) == nil
          && DashboardCues.retreat(lastRecord: thu.adding(days: -3), today: thu) == 3
          && DashboardCues.retreat(lastRecord: thu.adding(days: -5), today: thu) == 5
          && DashboardCues.retreat(lastRecord: thu.adding(days: 2), today: thu) == nil
          && DashboardCues.retreat(lastRecord: day("2025-10-22"), today: thu) == 365
          && DashboardCues.retreatLine(5) == "闭关 5 日，今日出关——从一句开始。",
          "出关：隔 3 天起才出，“闭关 5 日，今日出关——从一句开始。”；没记录过、今天已有的不出")

    // 4. 今日小结：20:00 起；没功课不写功课，没落笔写“尚未落笔”，记了心境写心境（几篇取平均）
    let tonights = [DashboardCues.tonightLine(habitsDone: 3, habitsDue: 5, entries: 1, moods: []),
                    DashboardCues.tonightLine(habitsDone: 3, habitsDue: 5, entries: 2, moods: [4, 5]),
                    DashboardCues.tonightLine(habitsDone: 0, habitsDue: 0, entries: 1, moods: [3]),
                    DashboardCues.tonightLine(habitsDone: 1, habitsDue: 3, entries: 0, moods: [])]
    check(!DashboardCues.showsTonight(minute: 19 * 60 + 59) && DashboardCues.showsTonight(minute: 20 * 60) && DashboardCues.showsTonight(minute: 23 * 60 + 59)
          && tonights == ["今日：功课 3/5 · 已落 1 篇 · 心境未记", "今日：功课 3/5 · 已落 2 篇 · 心境 \(Mood.label(5))",
                          "今日：已落 1 篇 · 心境 \(Mood.label(3))", "今日：功课 1/3 · 尚未落笔"]
          && DashboardCues.tonightLine(habitsDone: 0, habitsDue: 0, entries: 0, moods: []) == nil
          && tonights.allSatisfy { line in !["失败", "中断", "漏打", "没写"].contains { line?.contains($0) == true } },
          "今日小结：\(tonights.map { $0 ?? "nil" })")

    // 5. 小卷“上次许下的下一步”：这周一之前、或周一当天写的复盘；本周六日写的（许的是下一周）不算；35 天以前的不翻出来
    let wk = WeeklyDigest.Week(monday: day("2026-10-19"), today: sun)
    check(WeeklyDigest.promiseBefore(wk) == day("2026-10-20")
          && WeeklyDigest.promiseFresh(day("2026-10-18"), week: wk) && WeeklyDigest.promiseFresh(day("2026-10-19"), week: wk)
          && !WeeklyDigest.promiseFresh(day("2026-10-24"), week: wk)
          && WeeklyDigest.promiseFresh(day("2026-09-14"), week: wk) && !WeeklyDigest.promiseFresh(day("2026-09-13"), week: wk),
          "上次许下的下一步：取这周一（含）之前的，隔 35 天以上的不翻出来")
    // 只认周复盘：只写晚课日省的人，周一那篇日省（【下一步】是“明日第一件事”）不算；月复盘、没周期的也不算
    check(WeeklyDigest.promiseFits(period: "week", day: day("2026-10-18"), week: wk)
          && !WeeklyDigest.promiseFits(period: "day", day: day("2026-10-19"), week: wk)
          && !WeeklyDigest.promiseFits(period: "month", day: day("2026-09-30"), week: wk)
          && !WeeklyDigest.promiseFits(period: "", day: day("2026-10-18"), week: wk)
          && !WeeklyDigest.promiseFits(period: "week", day: day("2026-10-24"), week: wk),
          "上次许下的下一步：小卷只认周复盘，日省、月复盘不算")
}

// MARK: r3-mood：#15 心境月历——按当天日记心境的平均上色、写了没记心境画墨点、没写描边、还没到的不画；周一为首；翻月夹在最早一篇与本月之间；点同一格取消
do {
    let today = LocalDay(key: "2026-10-22")!   // 周四
    let earliest = LocalDay(key: "2025-11-03")!
    let rows: [(String, Int?)] = [
        ("2026-10-23", 5),                     // 明天（传书写错日期这类）：照画
        ("2026-10-22", 4), ("2026-10-22", 5), // 今天两篇：平均 4.5 → 霁
        ("2026-10-21", nil),                  // 写了没记心境
        ("2026-10-20", 2), ("2026-10-20", 3), ("2026-10-20", nil), // 阴、平各一 → 2.5 → 平；没记的那篇也算篇数
        ("2026-10-01", 1),
        ("2026-09-30", 5),                    // 跨月：不进十月
        ("2025-11-03", 3),
    ]
    let oct = MoodCalendar.month(year: 2026, month: 10, today: today, earliest: earliest, entries: rows)
    func cell(_ m: MoodCalendar.Month, _ d: Int) -> MoodCalendar.Cell { m.cells[d - 1] }
    check(oct.cells.count == 31 && oct.leading == 3 && oct.weeks.count == 4 && oct.weeks.allSatisfy { $0.count == 7 }
          && oct.weeks[0][3]?.day.key == "2026-10-01" && oct.weeks[0][0] == nil && oct.weeks[3][6]?.day.key == "2026-10-25",
          "心境月历：周一为首，2026年10月1日是周四，前空 3 格；26 日起整行还没到，不排，共 4 行 × 7 格")
    check(cell(oct, 22).mark == .mood(5) && cell(oct, 22).entries == 2 && cell(oct, 22).isToday
          && cell(oct, 21).mark == .ink && cell(oct, 21).entries == 1
          && cell(oct, 20).mark == .mood(3) && cell(oct, 20).entries == 3
          && cell(oct, 1).mark == .mood(1) && cell(oct, 2).mark == .blank && !cell(oct, 2).tappable,
          "心境月历：今天两篇平均 4.5 → 霁；只写没记心境 → 墨点；阴平各一 2.5 → 平，三篇都算；没写 → 描边、点不动")
    check(cell(oct, 23).mark == .mood(5) && cell(oct, 24).mark == .future && cell(oct, 31).mark == .future,
          "心境月历：还没到的日子不画；写在明天的那篇照画出来")
    check(oct.writtenDays == 5 && oct.moodDays == 4 && oct.subtitle(today: today) == "10月 · 落笔 5 日"
          && oct.emptyNote == nil && oct.isCurrent && oct.canGoBack && !oct.canGoForward,
          "心境月历：十月落笔 5 日（9 月 30 日那篇不算）；本月能往前、不能往后：\(oct.subtitle(today: today))")
    check(cell(oct, 22).hint == "今天 · 10月22日 · 霁 · 2 篇" && cell(oct, 21).hint == "10月21日 · 未记心境 · 1 篇"
          && cell(oct, 2).hint == "10月2日 · 未落笔" && cell(oct, 20).hint == "10月20日 · 平 · 3 篇",
          "心境月历：悬停写法“10月21日 · 晴 · 2 篇”：\(cell(oct, 22).hint) / \(cell(oct, 21).hint)")
    // 早于第一篇所在的月翻不过去；空月格子照画、下面一句
    let first = MoodCalendar.month(year: 2025, month: 11, today: today, earliest: earliest, entries: rows)
    let before = MoodCalendar.month(year: 2025, month: 6, today: today, earliest: earliest, entries: rows)
    let after = MoodCalendar.month(year: 2027, month: 2, today: today, earliest: earliest, entries: rows)
    check(!first.canGoBack && first.canGoForward && first.subtitle(today: today) == "2025年11月 · 落笔 1 日"
          && before.key == "2025-11" && after.key == "2026-10",
          "心境月历：最早一篇所在的 2025年11月 ‹ 禁用；要看更早、更晚的都夹回范围里")
    let empty = MoodCalendar.month(year: 2026, month: 3, today: today, earliest: earliest, entries: rows)
    check(empty.cells.count == 31 && empty.cells.allSatisfy { $0.mark == .blank } && empty.writtenDays == 0
          && empty.subtitle(today: today) == "3月" && empty.emptyNote == "这个月没有落笔。",
          "心境月历：一篇没有的月份格子照画，下面一句“这个月没有落笔。”")
    let fresh = MoodCalendar.month(year: 2026, month: 10, today: today, earliest: nil, entries: [(String, Int?)]())
    check(fresh.emptyNote == "这个月还没有落笔。" && !fresh.canGoBack && !fresh.canGoForward
          && fresh.cells[21].isToday && fresh.cells[21].mark == .blank && fresh.cells[22].mark == .future
          && fresh.cells[21].hint == "今天 · 10月22日 · 还没落笔",
          "心境月历：全新用户只看得到本月，今天金框、之后不画，“这个月还没有落笔。”")
    // 跨年翻月、天数、二月
    check(MoodCalendar.shift(year: 2026, month: 1, by: -1) == (2025, 12) && MoodCalendar.shift(year: 2025, month: 12, by: 1) == (2026, 1)
          && MoodCalendar.shift(year: 2026, month: 10, by: -22) == (2024, 12)
          && MoodCalendar.daysIn(year: 2028, month: 2) == 29 && MoodCalendar.daysIn(year: 2027, month: 2) == 28
          && MoodCalendar.daysIn(year: 2026, month: 12) == 31,
          "心境月历：跨年翻月、闰年二月")
    let feb = MoodCalendar.month(year: 2027, month: 2, today: LocalDay(key: "2027-03-05")!, earliest: earliest, entries: rows)
    let sunday = MoodCalendar.month(year: 2026, month: 3, today: today, earliest: earliest, entries: rows)
    let firstDay = MoodCalendar.month(year: 2026, month: 11, today: LocalDay(key: "2026-11-01")!, earliest: earliest, entries: rows)
    check(feb.leading == 0 && feb.weeks.count == 4 && sunday.leading == 6 && sunday.weeks.count == 6
          && firstDay.weeks.count == 1 && fresh.weeks.count == 4,
          "心境月历：2027年2月从周一起正好 4 行；2026年3月1日是周日，前空 6 格共 6 行；月初第一天只排一行")
    // 心境平均、越界的值
    check(MoodCalendar.level([]) == nil && MoodCalendar.level([9]) == 5 && MoodCalendar.level([0, 1]) == 1
          && MoodCalendar.level([3, 4]) == 4 && MoodCalendar.level([1, 2, 2]) == 2,
          "心境月历：平均四舍五入到 1–5，越界的先夹回")
    // 认不出的日期键略过；按新的在前、越过这个月就停的走法与整表走一遍结果相同
    let messy = rows + [("2026-10-xx", 5), ("2026-1-05", 4)]
    let sorted = rows.sorted { $0.0 > $1.0 }
    let viaBreak = MoodCalendar.month(year: 2026, month: 10, today: today, earliest: earliest, entries: sorted, newestFirst: true)
    check(MoodCalendar.month(year: 2026, month: 10, today: today, earliest: earliest, entries: messy) == oct && viaBreak == oct
          && MoodCalendar.month(year: 2025, month: 11, today: today, earliest: earliest, entries: sorted, newestFirst: true) == first,
          "心境月历：认不出的日期略过；倒序提前停下与整表走一遍一致")
    // 点同一格取消，点别的换
    check(MoodCalendar.toggled(selected: nil, tapped: "2026-10-21") == "2026-10-21"
          && MoodCalendar.toggled(selected: "2026-10-21", tapped: "2026-10-21") == nil
          && MoodCalendar.toggled(selected: "2026-10-20", tapped: "2026-10-21") == "2026-10-21",
          "心境月历：点一格只看那天，再点同一格回到全部")
    // 5 年数据：倒序摘要翻到最早那个月也只走到那里为止（这里核对结果相同，耗时在运行时自检里量）
    var long: [(String, Int?)] = []
    var walk = today
    for i in 0 ..< 1825 {
        if i % 3 != 2 { long.append((walk.key, i % 5 == 0 ? nil : i % 5 + 1)) }
        walk = walk.adding(days: -1)
    }
    let oldest = LocalDay(key: long.last!.0)!
    let firstMonth = MoodCalendar.month(year: oldest.year, month: oldest.month, today: today, earliest: oldest, entries: long, newestFirst: true)
    check(!firstMonth.canGoBack && firstMonth.writtenDays > 0
          && firstMonth == MoodCalendar.month(year: oldest.year, month: oldest.month, today: today, earliest: oldest, entries: long),
          "心境月历：5 年数据翻到最早的月份，倒序提前停下与整表结果一致")
    // 标题旁小字：今年的月份“落笔 N 日”；往年的翻月器里已写“2025年12月”，只写“N 日”（侧栏一行放得下）；一篇没有不写
    let lastDec = MoodCalendar.month(year: 2025, month: 12, today: today, earliest: earliest,
                                     entries: rows + [("2025-12-05", 3), ("2025-12-06", nil), ("2025-12-06", 4)])
    let nextJan = LocalDay(key: "2027-01-03")!
    check(oct.titleDetail(today: today) == "落笔 5 日" && lastDec.titleDetail(today: today) == "2 日"
          && first.titleDetail(today: today) == "1 日" && empty.titleDetail(today: today) == "" && fresh.titleDetail(today: today) == ""
          && oct.titleDetail(today: nextJan) == "5 日",
          "心境月历：标题旁今年写“落笔 5 日”，往年只写“2 日”，空月不写：\(oct.titleDetail(today: today)) / \(lastDec.titleDetail(today: today))")
    // 正只看的那天篇目删光（或改到别的日期）后格子空了：仍点得动，再点回到全部；没选中的空格点不动
    let afterDelete = MoodCalendar.month(year: 2026, month: 10, today: today, earliest: earliest,
                                         entries: rows.filter { $0.0 != "2026-10-21" })
    let emptied = cell(afterDelete, 21)
    check(emptied.mark == .blank && !emptied.tappable && emptied.canTap(selected: "2026-10-21")
          && emptied.tapHint(selected: "2026-10-21") == "再点回到全部"
          && MoodCalendar.toggled(selected: "2026-10-21", tapped: emptied.day.key) == nil
          && !cell(oct, 2).canTap(selected: "2026-10-21") && cell(oct, 2).tapHint(selected: nil) == nil
          && cell(oct, 21).tapHint(selected: nil) == "点一下只看这天" && cell(oct, 21).tapHint(selected: "2026-10-20") == "点一下只看这天",
          "心境月历：正只看的那天删光了，空格仍点得动、写“再点回到全部”，再点回到全部；别的空格点不动")
}


/// 草稿“是否为空”的老判定（以前的 JournalDraft.isBlankBody，只认复盘四段），对照用：老判定说空的，新判定也得说空
func journalDraftOldIsBlankBody(_ text: String) -> Bool {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty || body == ReviewPeriod.template.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 草稿“是否为空”的现行判定（Views/ChronicleSupport 的 JournalDraft.isBlankBody；CoreCheck 不编译 Views，照抄一份）：
/// 与“落笔入卷”同一个判定 JournalTemplates.isSkeleton，自存模板取偏好 templates.custom 里的（这里直接给 JSON）
func journalDraftIsBlankBodyMirror(_ text: String, customRaw: String = "") -> Bool {
    JournalTemplates.isSkeleton(text, custom: JournalTemplates.decode(customRaw))
}

// MARK: r3-templates（#18 落笔模板：内置四套、套用时空则放入有字接在末尾、骨架不算有内容、自存的存取 / 改名 / 删除）
do {
    let names = JournalTemplates.builtins.map(\.name)
    check(names == ["复盘四段", "晚课三省", "读书札记", "一事一记"] && JournalTemplates.builtins.allSatisfy(\.isBuiltin)
          && JournalTemplates.builtins[0].body == ReviewPeriod.template,
          "落笔模板：内置四套依次是复盘四段（就是原来的复盘模板）、晚课三省、读书札记、一事一记")
    check(JournalTemplates.builtins.map(\.menuTitle) == ["复盘四段（所得 · 所失 · 所悟 · 下一步）", "晚课三省（今日所成 · 卡在何处 · 明日第一件事）",
                                                         "读书札记（书名 · 摘句 · 所思）", "一事一记（事 · 感 · 下一步）"],
          "落笔模板：菜单里名称后面列段名：\(JournalTemplates.builtins.map(\.menuTitle))")
    let reading = JournalTemplates.builtins[2]
    let evening = JournalTemplates.builtins[1]

    // 套用：空的直接放入；空白、只有没动过的骨架也当空的换掉；写了字接在末尾、空一行
    let empty = JournalTemplates.applying(reading, to: "", custom: [])
    let spaces = JournalTemplates.applying(reading, to: "  \n\n ", custom: [])
    let overReview = JournalTemplates.applying(reading, to: ReviewPeriod.template, custom: [])
    check(empty == JournalTemplateApplication(text: reading.body, appended: false) && spaces.text == reading.body && !spaces.appended
          && overReview.text == reading.body && !overReview.appended,
          "落笔模板：正文空、只有空白、只有没动过的复盘四段时直接换成这套，不提示")
    let written = JournalTemplates.applying(reading, to: "今天读了三章。\n\n", custom: [])
    check(written.appended && written.text == "今天读了三章。\n\n【书名】\n\n【摘句】\n\n【所思】\n",
          "落笔模板：写了字接在末尾、空一行（原来末尾的空行收成一处）：\(written.text.debugDescription)")
    let twice = JournalTemplates.applying(evening, to: evening.body, custom: [])
    check(!twice.appended && twice.text == evening.body, "落笔模板：同一套连点两下不叠两份")
    let filled = JournalTemplates.applying(evening, to: "【书名】三体\n\n【摘句】\n\n【所思】\n", custom: [])
    check(filled.appended && filled.text.hasPrefix("【书名】三体\n\n【摘句】\n\n【所思】\n\n【今日所成】"),
          "落笔模板：骨架里写了一个字就算写过，新的一套接在后面")

    // 骨架判定（入卷按钮能不能点）：整套骨架首尾相接都算空；少一段、多一个字、单写一行段名都算写过
    let custom = [JournalTemplate(name: "周末小结", body: "这周最开心的事：\n\n下周想试试：\n")]
    check(JournalTemplates.isSkeleton("", custom: []) && JournalTemplates.isSkeleton(" \n ", custom: [])
          && JournalTemplates.isSkeleton(ReviewPeriod.template, custom: [])
          && JournalTemplates.isSkeleton("\n【今日所成】\n\n  【卡在何处】  \n【明日第一件事】", custom: [])
          && JournalTemplates.isSkeleton(ReviewPeriod.template + "\n\n" + reading.body, custom: [])
          && JournalTemplates.isSkeleton(custom[0].body, custom: custom),
          "落笔模板：空白、任一套没动过的骨架（行首尾空白不论）、几套骨架接在一起、自存的骨架，都还算没写东西")
    check(!JournalTemplates.isSkeleton("【书名】三体", custom: []) && !JournalTemplates.isSkeleton("【书名】\n【摘句】", custom: [])
          && !JournalTemplates.isSkeleton("【书名】", custom: []) && !JournalTemplates.isSkeleton("今天很好", custom: [])
          && !JournalTemplates.isSkeleton(custom[0].body, custom: [])
          && !JournalTemplates.isSkeleton(ReviewPeriod.template + "早睡", custom: []),
          "落笔模板：写了一个字、骨架缺一段、单写一行段名、普通一句、没存过的“模板”，都算写过（能入卷）")
    // 老判定说空的（只有复盘四段骨架），新判定也说空
    let oldBlank = ["", "  ", ReviewPeriod.template, "\n" + ReviewPeriod.template + "\n\n"]
    check(oldBlank.allSatisfy { journalDraftOldIsBlankBody($0) && journalDraftIsBlankBodyMirror($0) && JournalTemplates.isSkeleton($0, custom: []) },
          "落笔模板：只有复盘四段骨架的照旧算空，入卷按钮照旧点不动")

    // 存为模板：名称整理、不重名、不与内置同名、正文空不存、最多 20 套
    let added = JournalTemplates.adding(name: "  周末\n小结  ", body: "\n\n这周最开心的事：\n\n下周想试试：  \n\n", to: [])
    check(added == [JournalTemplate(name: "周末 小结", body: "这周最开心的事：\n\n下周想试试：\n")],
          "存为模板：名称去掉首尾空白、换行换成空格；正文去掉首尾空行、末尾留一个换行：\(String(describing: added))")
    check(JournalTemplates.nameProblem("", custom: []) == "起个名字" && JournalTemplates.nameProblem("晚课三省", custom: []) == "与内置模板同名，换一个"
          && JournalTemplates.nameProblem("周末小结", custom: custom) == "已有同名的模板，换一个"
          && JournalTemplates.nameProblem("周末小结", custom: custom, replacing: "周末小结") == nil
          && JournalTemplates.adding(name: "复盘四段", body: "x", to: []) == nil
          && JournalTemplates.adding(name: "空的", body: " \n ", to: []) == nil,
          "存为模板：没起名、与内置同名、与自存的同名都不存（改名时与自己同名不算），正文空不存")
    check(JournalTemplates.cleanName(String(repeating: "长", count: 30)).count == JournalTemplates.nameLimit,
          "存为模板：名称最多 \(JournalTemplates.nameLimit) 字")
    let full = (1...20).map { JournalTemplate(name: "模板\($0)", body: "第 \($0) 套\n") }
    check(JournalTemplates.isFull(full) && JournalTemplates.adding(name: "第二十一", body: "x", to: full) == nil
          && !JournalTemplates.isFull(Array(full.prefix(19))) && JournalTemplates.adding(name: "第二十", body: "x", to: Array(full.prefix(19)))?.count == 20,
          "存为模板：最多 20 套，满了不再存")

    // 存取：JSON 往返；读坏了当没有；名称空、正文空、重名、与内置同名的丢掉；多于 20 套只取前 20
    let pair = custom + [JournalTemplate(name: "读书", body: "【书】\n")]
    check(JournalTemplates.decode(JournalTemplates.encode(pair)) == pair
          && JournalTemplates.decode("") == [] && JournalTemplates.decode("{坏了") == [] && JournalTemplates.decode("[]") == [],
          "自存模板的 JSON：存进去读得回来，空的、读坏了当没有")
    let messy = JournalTemplates.encode([JournalTemplate(name: " ", body: "x"), JournalTemplate(name: "空正文", body: "\n"),
                                         JournalTemplate(name: "一事一记", body: "冒名"), JournalTemplate(name: "甲", body: "1"),
                                         JournalTemplate(name: "甲", body: "2")] + full)
    let cleaned = JournalTemplates.decode(messy)
    check(cleaned.count == 20 && cleaned.first == JournalTemplate(name: "甲", body: "1") && !cleaned.contains { $0.name == "一事一记" }
          && cleaned.last?.name == "模板19",
          "自存模板的 JSON：没名字、正文空、与内置同名、重名的丢掉，多于 20 套只取前 20：\(cleaned.map(\.name))")

    // 改名 / 删除：内置的改不了、删不到；新名字有问题不改；名字没变原样
    check(JournalTemplates.renaming("读书", to: " 读书笔记 ", in: pair)?.map(\.name) == ["周末小结", "读书笔记"]
          && JournalTemplates.renaming("读书", to: "读书", in: pair) == pair
          && JournalTemplates.renaming("读书", to: "周末小结", in: pair) == nil
          && JournalTemplates.renaming("读书", to: "读书札记", in: pair) == nil
          && JournalTemplates.renaming("读书札记", to: "札记", in: pair) == nil
          && JournalTemplates.renaming("读书", to: "", in: pair) == nil,
          "管理模板：改名去掉首尾空白；与别的同名、与内置同名、空名不改；内置的改不了")
    check(JournalTemplates.removing("读书", from: pair) == custom && JournalTemplates.removing("复盘四段", from: pair) == pair
          && JournalTemplates.all(custom: pair).map(\.name) == names + ["周末小结", "读书"],
          "管理模板：删掉一套自存的；内置的删不到；菜单里内置在前、自存的照存的先后")
    check(custom[0].summary == "这周最开心的事：" && !custom[0].isBuiltin
          && JournalTemplate(name: "长", body: String(repeating: "字", count: 20)).summary == String(repeating: "字", count: 14) + "…"
          && JournalTemplates.headings(in: "【 书名 】\n正文【所思】\n【】\n【下一步】做") == ["书名", "下一步"],
          "落笔模板：没有段名的取第一行（最多 14 字）；段名只认行首的【…】")

    // 修复 1：草稿“是否为空”与入卷按钮同一个判定——只套了晚课三省、读书札记、一事一记、自存的段名模板也是空草稿
    // （首页草稿挪得过来、进页复位补记日期与类型、周复盘提醒换得了类型、七日小卷存草稿不问也不叠两套段名）
    let headingOnlyRaw = JournalTemplates.encode([JournalTemplate(name: "晨跑", body: "【距离】\n\n【配速】\n")])
    check(JournalTemplates.builtins.allSatisfy { journalDraftIsBlankBodyMirror($0.body) && journalDraftIsBlankBodyMirror("\n" + $0.body + "\n\n") }
          && journalDraftIsBlankBodyMirror("【距离】\n\n【配速】\n", customRaw: headingOnlyRaw)
          && !journalDraftIsBlankBodyMirror("【距离】\n\n【配速】\n") && !journalDraftIsBlankBodyMirror("【书名】三体")
          && !journalDraftIsBlankBodyMirror("首页写的两句"),
          "落笔草稿：四套内置骨架、偏好里自存的段名模板骨架都算空草稿；写了一个字、没存过的“模板”不算")

    // 修复 3：自存的模板带实际内容（一句常记的话、一份打卡文字）不当骨架——原样套用、正好写出同一句都能入卷；
    // 只有段名（整行一个【…】）或引子（“……：”）的才当骨架；混着内容行的整套不当骨架
    let run = JournalTemplate(name: "跑步", body: "今天跑了 5 公里，配速 6'30\"\n")
    let morning = JournalTemplate(name: "早安", body: "早安\n")
    let mixed = JournalTemplate(name: "打卡", body: "【运动】\n跑步 5 公里\n【心情】\n")
    let headingOnly = JournalTemplate(name: "晨跑", body: "【距离】\n\n【配速】\n")
    let lead = JournalTemplate(name: "周末小结", body: "这周最开心的事：\n\n下周:\n")
    let mine = [run, morning, mixed, headingOnly, lead]
    check(!JournalTemplates.isSkeleton("今天跑了 5 公里，配速 6'30\"", custom: mine) && !JournalTemplates.isSkeleton(run.body, custom: mine)
          && !JournalTemplates.isSkeleton("早安", custom: mine) && !JournalTemplates.isSkeleton(mixed.body, custom: mine)
          && !JournalTemplates.isSkeleton("【运动】\n【心情】", custom: mine),
          "落笔模板：自存的带内容（“今天跑了 5 公里”“早安”、段名下面写了字的）原样套用后算写过，能入卷")
    check(JournalTemplates.isSkeleton(headingOnly.body, custom: mine) && JournalTemplates.isSkeleton(lead.body, custom: mine)
          && JournalTemplates.isSkeleton(headingOnly.body + "\n" + JournalTemplates.builtins[2].body, custom: mine)
          && mine.map(JournalTemplates.isSkeletonTemplate) == [false, false, false, true, true]
          && JournalTemplates.builtins.allSatisfy(JournalTemplates.isSkeletonTemplate)
          && !JournalTemplates.isSkeletonTemplate(JournalTemplate(name: "两段一行", body: "【甲】【乙】\n")),
          "落笔模板：自存的只有段名、或“……：”“……:”引子的照旧当骨架；内置四套都是骨架；一行两个【…】不算段名行")
    let runTwice = JournalTemplates.applying(run, to: run.body, custom: mine)
    let runAfterMorning = JournalTemplates.applying(run, to: morning.body, custom: mine)
    check(!runTwice.appended && runTwice.text == run.body
          && runAfterMorning.appended && runAfterMorning.text == "早安\n\n" + run.body
          && JournalTemplates.applying(JournalTemplates.builtins[2], to: run.body, custom: mine).appended,
          "落笔模板：带内容的自存模板连点两下不叠两份；正文是另一套带内容的就接在后面")

    // 修复 2：复盘四段后面接上一套模板（读书札记、一事一记、晚课三省），回访的【下一步】到下一套的段名为止
    let reviewBody = "【所得】早起两天\n\n【所失】熬夜\n\n【所悟】先睡够\n\n【下一步】23:30 前睡\n"
    func appended(_ index: Int, filled: [String: String] = [:]) -> String {
        var text = JournalTemplates.applying(JournalTemplates.builtins[index], to: reviewBody, custom: []).text
        for (head, value) in filled { text = text.replacingOccurrences(of: "【\(head)】\n", with: "【\(head)】\(value)\n") }
        return text
    }
    let readingFilled = appended(2, filled: ["书名": "三体", "摘句": "一句好话", "所思": "很震撼"])
    let readingBlank = appended(2)
    let oneThing = appended(3, filled: ["事": "组会"])
    let eveningAfter = appended(1, filled: ["今日所成": "写完一节"])
    let steps = [readingFilled, readingBlank, oneThing, eveningAfter].map(ReviewThread.nextSteps(from:))
    check(steps.allSatisfy { $0 == ["23:30 前睡"] },
          "复盘回访：复盘四段后接读书札记（填了 / 没填）、一事一记、晚课三省，“上次许下的下一步”只列原来那条：\(steps)")
    check(ReviewThread.nextSteps(from: "【所得】x\n【下一步】\n\n【事】组会\n【感】累\n【下一步】明天问导师\n") == ["明天问导师"]
          && ReviewThread.section("下一步", in: "【下一步】读完【三体】再说\n【书名】三体") == "读完【三体】再说"
          && ReviewThread.section("书名", in: readingFilled) == nil
          && ReviewThread.boundaryNames == ["今日所成", "卡在何处", "明日第一件事", "书名", "摘句", "所思", "事", "感"],
          "复盘回访：复盘的【下一步】空着时取一事一记里的【下一步】；正文里的“读完【三体】”不截断；书名、摘句……只当段界、不拿来取段")
    let insertedAfter = ReviewThread.insert([(text: "早睡", verdict: .changed)], into: readingBlank)
    check(insertedAfter.contains("【所悟】先睡够\n· 早睡 —— 改主意了\n\n【下一步】") && insertedAfter.hasSuffix("【书名】\n\n【摘句】\n\n【所思】\n"),
          "复盘回访：插回正文时也按段界走，接在【所悟】里，不落进后面那套模板：\(insertedAfter.debugDescription)")
}

// MARK: r3-courierui：传书摘要行里紧挨日期、数量的空格写成不换行空格；新旧两种写法都解析得出进度；
// 传书笺折叠时附注行留在最后、不算条数；警示行（“未收 · …”“未收录 · …”）；
// （修复）折叠只在多出 2 条以上时才折、整张不超过 6 行、几条未收并成一行；多封合并时“1 条未收”写在冒号前；撤销框清单附注不算条数
do {
    let base = LocalDay(key: "2026-10-21")!
    let nb = CourierLineDecor.nbsp
    func parsed(_ json: String) throws -> CourierItem {
        try CourierParser.parse(Data(json.utf8), relativeTo: base, latest: base).items[0]
    }
    func plain(_ s: String) -> String { s.replacingOccurrences(of: nb, with: " ") }
    // 1. 不换行空格只落在日期、数量紧挨的地方；换回普通空格就是原来的写法（行文本身没变）
    let weekly = try parsed(#"{"type":"habit","title":"读书","frequency":"weekly","times_per_week":3,"target":20,"unit":"页","start_date":"2027-01-04"}"#)
    let daily = try parsed(#"{"type":"habit","title":"早睡 早起","start_date":"2026-10-23"}"#)
    let created = try parsed(#"{"type":"goal","title":"完成 学位论文","target_date":"2027-02-17","progress":15}"#)
    let plan = try parsed(#"{"type":"goal","action":"update","title":"论文","progress":70,"target_date":"none","notes":"第三章 初稿"}"#)
    check(nb == "\u{00A0}"
          && weekly.summary == "功课 · 新立「读书」（每周\(nb)3\(nb)次，每次\(nb)20页，自\(nb)2027年1月4日\(nb)起）"
          && plain(weekly.summary) == "功课 · 新立「读书」（每周 3 次，每次 20页，自 2027年1月4日 起）"
          && daily.summary == "功课 · 新立「早睡 早起」（每天，自\(nb)10月23日\(nb)起）"
          && created.summary == "目标 · 新立「完成 学位论文」（期限\(nb)2027年2月17日，进度\(nb)15%）"
          && plan.summary == "目标 · 更新「论文」：进度\(nb)→\(nb)70%；期限\(nb)→\(nb)无；备注 +「第三章 初稿」",
          "摘要行：括注、期限、进度里紧挨日期与数量的空格是不换行空格，标题与备注里的空格不动：\(weekly.summary) / \(created.summary) / \(plan.summary)")
    let move = CourierLineDecor.goalUpdateLine(title: "论文 初稿", changes: [.progress(60, 65), .deadline("2026-12-19", "2027-01-15"), .note("a b")], today: base)
    check(move == "目标 · 论文 初稿：进度\(nb)60% →\(nb)65%；期限\(nb)12月19日 →\(nb)2027年1月15日；备注 +「a b」"
          && CourierLineDecor.progressMove(move) == .init(title: "论文 初稿", from: 60, to: 65, completed: false)
          && CourierLineDecor.progressMove(plain(move)) == CourierLineDecor.progressMove(move)
          && CourierLineDecor.progressMove("目标 · a：进度 80% → 100%；状态 进行中 → 已完成")?.completed == true
          && CourierLineDecor.progressMove(CourierLineDecor.goalUpdateLine(title: "a", changes: [.progress(80, 100)], today: base))?.completed == true,
          "进度行：箭头前可折行、箭头后不折；新写法与旧传书的普通空格写法都解析得出进度：\(move)")
    // 2. 传书笺折叠：附注行（“（相对日期按…）”）留在最末、占一行额度，不算进“另有 N 条”；没有附注时与原来一样
    let remark = "（相对日期按写入那天 10月21日 计算）"
    let kept = (1...6).map { "日记 · 10月21日 · \($0)" }
    let skip = CourierLineDecor.skippedLine("打卡「游泳」：没有这项功课")
    check(CourierLineDecor.cardLines(kept + [skip, remark]) == Array(kept.prefix(3)) + ["…… 另有 3 条", skip, remark]
          && CourierLineDecor.cardLines(kept + [remark]) == Array(kept.prefix(4)) + ["…… 另有 2 条", remark]
          && CourierLineDecor.cardLines(Array(kept.prefix(3)) + [skip, remark]) == Array(kept.prefix(3)) + [skip, remark]
          && CourierLineDecor.cardLines(kept + [skip]) == Array(kept.prefix(4)) + ["…… 另有 2 条", skip],
          "传书笺折叠：附注行留在最后、不算进“另有 N 条”；不超过 5 行时原样")
    // 3. 警示行：退回的打卡行、多封合并时整封没收录的那行（“未收录 · …”）；“另有 N 条”、附注、重复跳过的不是
    let rejected = CourierLineDecor.rejectedLine(file: "claude-x.json", message: "第 2 条：找不到习惯「游泳」")
    check(CourierLineDecor.isWarningLine(skip) && rejected == "未收录 · claude-x.json：第 2 条：找不到习惯「游泳」"
          && CourierLineDecor.isWarningLine(rejected)
          && !CourierLineDecor.isWarningLine("…… 另有 2 条") && !CourierLineDecor.isWarningLine(remark)
          && !CourierLineDecor.isWarningLine("已跳过 · claude-y.json：重复投递，已跳过")
          && !CourierLineDecor.isWarningLine("打卡 · 10月21日 · 运动")
          && CourierLineDecor.isRemark(remark) && !CourierLineDecor.isRemark(skip),
          "警示行只认“未收 · …”与“未收录 · …”")
    // 4.（修复）折叠：不超过 6 行原样全显示；超了才折，“另有 N 条”的 N ≥ 2，整张不超过 6 行；几条未收并成一行
    func items(_ n: Int) -> [String] { (0..<n).map { "日记 · 10月21日 · 第\($0 + 1)篇" } }
    func skips(_ n: Int, reason: (Int) -> String = { _ in "没有这项功课" }) -> [String] {
        (0..<n).map { CourierLineDecor.skippedLine("打卡「x\($0 + 1)」：\(reason($0))") }
    }
    check(CourierLineDecor.cardLines(items(5) + [remark]) == items(5) + [remark]
          && CourierLineDecor.cardLines(items(5) + skips(1)) == items(5) + skips(1)
          && CourierLineDecor.cardLines(items(3) + skips(3)) == items(3) + skips(3)
          && CourierLineDecor.cardLines(items(6)) == items(6),
          "折叠：只多 1 条时全显示，不拿“另有 1 条”换掉一条")
    check(CourierLineDecor.cardLines(items(4) + skips(3)) == items(4) + ["未收 · 打卡「x1」「x2」等 3 条：没有这项功课"]
          && CourierLineDecor.cardLines(items(6) + skips(3)) == items(4) + ["…… 另有 2 条", "未收 · 打卡「x1」「x2」等 3 条：没有这项功课"]
          && CourierLineDecor.cardLines(items(6) + skips(3) + [remark])
             == items(3) + ["…… 另有 3 条", "未收 · 打卡「x1」「x2」等 3 条：没有这项功课", remark]
          && CourierLineDecor.cardLines(items(5) + skips(2)) == items(5) + ["未收 · 打卡「x1」「x2」：没有这项功课"],
          "折叠：几条未收并成一行，只出现一种“另有”：\(CourierLineDecor.cardLines(items(4) + skips(3)))")
    var worst = ""
    for k in 0...12 { for n in 0...5 { for r in [false, true] {
        let input = items(k) + skips(n) + (r ? [remark] : [])
        let out = CourierLineDecor.cardLines(input)
        let hidden = out.compactMap { line -> Int? in
            guard line.hasPrefix("…… 另有 ") else { return nil }
            return Int(line.dropFirst("…… 另有 ".count).prefix { $0.isNumber })
        }
        let skipsShown = out.filter(CourierLineDecor.isSkipped).count
        let bad = out.count > 6 || (input.count <= 6 && out != input) || hidden.contains { $0 < 2 } || hidden.count > 1
            || (n > 0 && skipsShown == 0) || out.filter(CourierLineDecor.isRemark).count != (r ? 1 : 0)
            || (out.last.map(CourierLineDecor.isRemark) ?? false) != r
        if bad && worst.isEmpty { worst = "\(k) 条 + \(n) 条未收 + 附注 \(r)：\(out)" }
    } } }
    check(worst.isEmpty, "折叠：0–12 条 × 0–5 条未收 × 有无附注，整张不超过 6 行、只一种“另有”且 N ≥ 2、未收与附注都在：\(worst)")
    let mixed = CourierLineDecor.mergedSkippedLine(skips(3) { $0 == 1 ? "单位对不上（写的是“公里”）" : "没有这项功课" })
    let longName = CourierLineDecor.mergedSkippedLine([CourierLineDecor.skippedLine("打卡「每天晚上睡前读二十页书」：没有这项功课"),
                                                       CourierLineDecor.skippedLine("打卡「散步」：要写数量才记到「步数」")])
    check(mixed == "未收 · 打卡「x1」「x2」等 3 条：名字或数量单位对不上"
          && longName == "未收 · 打卡「每天晚上睡前读二…」「散步」：名字或数量单位对不上"
          && CourierLineDecor.mergedSkippedLine(["未收 · 别的写法", "未收 · 又一种"]) == "未收 · 2 条打卡没有写入"
          && CourierLineDecor.isSkipped(mixed),
          "并成一行：原因不同写“名字或数量单位对不上”，名字取前 8 字，认不出的写“N 条打卡没有写入”：\(mixed) / \(longName)")
    // 5.（修复）多封合并：“1 条未收”写在冒号前，首条摘要再长也在行首几个字里
    let longFirst = "日程 · 10月23日 15:00–16:00 · 和导师讨论论文第三章实验部分的修改意见与下一步计划和时间安排表"
    let batch = CourierLineDecor.batchLine(from: "ChatGPT", itemCount: 2,
                                           summary: [longFirst, "打卡 · 10月22日 · 运动", skip].joined(separator: "\n"))
    check(batch == "ChatGPT · 2 条 · 1 条未收：" + longFirst
          && CourierLineDecor.batchLine(from: "Claude", itemCount: 1, summary: "日记 · x\n" + remark) == "Claude · 1 条：日记 · x"
          && CourierLineDecor.unreceivedMark(3) == "3 条未收",
          "多封合并：“1 条未收”在冒号前，不跟在长摘要后面：\(batch)")
    // 6.（修复）撤销确认框清单：附注不加“· ”、不算条数、放最后；只多 1 条时全列；退回的打卡不列
    let undoSeven = CourierLineDecor.undoListing(items(7) + skips(1) + [remark])
    let undoNine = CourierLineDecor.undoListing(items(9) + [remark])
    check(undoSeven == items(7).map { "· " + $0 } + [remark]
          && undoNine == items(6).map { "· " + $0 } + ["…… 另有 3 条", remark]
          && CourierLineDecor.undoListing(items(2) + skips(1)) == items(2).map { "· " + $0 }
          && CourierLineDecor.undoListing(skips(1)).isEmpty,
          "撤销框清单：附注放最后不算条数，“另有 N 条”只数条目：\(undoNine)")
} catch {
    check(false, "r3-courierui 检查失败：\(error)")
}

// MARK: r3-tails：菜单栏小窗“+1”改用首页 DashboardRules（写法与原来一致）；长卷逐月柱刻度下标“未导全”
do {
    // 小窗签上的“3/8 杯”与“+1”直接用首页的 DashboardRules；MenuBarDigest 的 step / number / progress / stepLabel
    // 只剩一行转调（离屏渲染、旧自检还在用这几个名字）。这里逐个比对，以后谁在小窗里又另写一份规则会报出来
    let targets: [Double] = [0, 1, 8, 20, 21, 30, 120, 121, 2.5, 1.25, 1000, 8000, 10000, .nan]
    let quantities: [Double?] = [nil, 0, 1, 2.5, 3, 7.75, 1000, 8000]
    var differs: [String] = []
    for target in targets {
        let label = DashboardRules.stepLabel(DashboardRules.quantityStep(target: target))
        if DashboardRules.quantityStep(target: target) != MenuBarDigest.step(target: target) || label != MenuBarDigest.stepLabel(target: target) {
            differs.append("步长 \(target)")
        }
        for quantity in quantities where target.isFinite {
            let home = DashboardRules.quantityText(done: quantity ?? 0, target: target, unit: "杯")
            if home != MenuBarDigest.progress(quantity: quantity, target: target, unit: "杯") { differs.append("\(quantity ?? -1)/\(target)") }
        }
    }
    check(differs.isEmpty && DashboardRules.quantityText(done: 3, target: 8, unit: "杯") == "3/8 杯"
          && DashboardRules.stepLabel(DashboardRules.quantityStep(target: 8000)) == "+1000"
          && DashboardRules.quantityText(done: 2.5, target: 8, unit: "") == "2.5/8",
          "菜单栏小窗改用首页 DashboardRules：步长、按钮字、“3/8 杯”与原来的写法逐个相同\(differs.isEmpty ? "" : "（不同：\(differs)）")")

    // 长卷逐月柱的刻度下标：本月写“至今”；已过完又没导全的写传进来的小标（界面传灵石账簿的“未导全”）；只含手记的、导全的不写
    typealias FP = AnnalsReport.FinancePart
    let notes = [FP.monthNote(full: false, ongoing: false, manualOnly: false, partial: "未导全"),
                 FP.monthNote(full: true, ongoing: false, manualOnly: false, partial: "未导全"),
                 FP.monthNote(full: false, ongoing: true, manualOnly: false, partial: "未导全"),
                 FP.monthNote(full: true, ongoing: true, manualOnly: false, partial: "未导全"),
                 FP.monthNote(full: false, ongoing: false, manualOnly: true, partial: "未导全"),
                 FP.monthNote(full: false, ongoing: true, manualOnly: true, partial: "未导全")]
    check(notes == ["未导全", "", "至今", "至今", "", "至今"] && !notes.contains("部分"),
          "长卷逐月柱刻度下标：没导全的月份写“未导全”（不再写“部分”），本月写“至今”，只含手记的不标：\(notes)")
}

// MARK: r3-tails 修：长卷导出也写“（未导全）”、账簿与长卷同一条“未导全”判断、菜单栏不再自己留一份 +1 规则
do {
    // 1. 一个说法、一条判断：没导全、且账簿导入过银行账单才标；只记手记的账簿每个月都“没导全”，不标
    check(PartialMonthRule.label == "未导全" && PartialMonthRule.suffix == "（未导全）"
          && PartialMonthRule.flags(full: false, manualOnly: false) && !PartialMonthRule.flags(full: true, manualOnly: false)
          && !PartialMonthRule.flags(full: false, manualOnly: true) && !PartialMonthRule.flags(full: true, manualOnly: true)
          && AnnalsReport.FinancePart.monthNote(full: false, ongoing: false, manualOnly: false) == PartialMonthRule.label,
          "“未导全”：没导全且导入过银行账单才标，只记手记的不标；逐月柱下标默认就用这个说法")

    // 2. 导出（Markdown，PDF 走同一段文字）：有未导全月份时逐月表写“（未导全）”，不再写“（部分）”；只有手记的、导全的不写
    let today = LocalDay(key: "2026-10-20")!
    var ledger = FinanceLedger()
    for (i, day) in LocalDay.range(LocalDay(key: "2026-01-01")!, today).enumerated() where day.day % 5 == 1 {
        ledger.transactions.append(FinanceTransaction(id: "tf-t\(i)", date: day.key, amountCents: -(1000 + i), balanceCents: 0, description: "自检",
                                                      account: "CBA", category: "餐饮与外卖", kind: "消费", needsReview: false, reason: "", sourceLine: i))
    }
    func source(_ first: String, _ last: String) -> FinanceSource {
        FinanceSource(sha256: "tf\(first)", account: "CBA", rawCsv: "", importedAt: "", rows: 0, start: first, end: last,
                      statementPeriod: StatementPeriod(start: first, end: last))
    }
    func exported(_ sources: [FinanceSource]) -> (report: AnnalsReport, markdown: String) {
        var l = ledger
        l.sources = sources
        let report = AnnalsEngine.report(AnnalsPeriod.make(.year(2026), today: today)!,
                                         input: RecordInput(today: today, entries: [], history: [], habits: [], cultivation: CultivationConfig(), ledger: l))
        return (report, AnnalsRenderer.markdown(report))
    }
    // 9 月中间缺了一段（8月31日之后直到 9月10日才接上）：9 月未导全
    let gap = exported([source("2026-01-01", "2026-08-31"), source("2026-09-10", "2026-10-19")])
    let septRow = gap.markdown.split(separator: "\n").first { $0.hasPrefix("| 9月 |") }.map(String.init) ?? ""
    let augRow = gap.markdown.split(separator: "\n").first { $0.hasPrefix("| 8月 |") }.map(String.init) ?? ""
    check(gap.report.finance?.incompleteMonths == ["9月"] && septRow.hasSuffix("（未导全） |") && !augRow.contains("（未导全）")
          && !gap.markdown.contains("（部分）") && gap.markdown.contains("9月账单未导全，合计可能偏低"),
          "长卷导出：未导全的 9 月写“\(septRow)”（与页面同一个说法，不再写“（部分）”），导全的 8 月不标：\(augRow)")
    let manual = exported([])
    check(manual.report.finance?.manualOnly == true && manual.markdown.contains("| 月份 | 净消费 |")
          && !manual.markdown.contains("（未导全）") && !manual.markdown.contains("（部分）"),
          "长卷导出：只记手记的账簿逐月表不标“（未导全）”（与页面一样写“仅手记”那一路）")

    // 3. 菜单栏那几个名字只是转调首页的 DashboardRules：-0.001 也写“0”（首页一并改成不写“-0”），“3/8 杯”不带多余空格
    check(DashboardRules.number(-0.001) == "0" && MenuBarDigest.number(-0.001) == "0"
          && MenuBarDigest.progress(quantity: -1, target: 8, unit: " 杯 ") == DashboardRules.quantityText(done: -1, target: 8, unit: " 杯 ")
          && MenuBarDigest.progress(quantity: -1, target: 8, unit: " 杯 ") == "0/8 杯"
          && MenuBarDigest.stepLabel(target: 30) == DashboardRules.stepLabel(DashboardRules.quantityStep(target: 30)),
          "菜单栏的步长与数量写法都转调 DashboardRules：-0.001 写“0”，“0/8 杯”")
}

// MARK: 终审：随心随手记遇到订单号这类超长数字不崩溃
do {
    let today = LocalDay(key: "2026-10-22")!
    let ctx = QuickParse.Context(today: today, nowMinute: 12 * 60, habits: [])
    let longs = ["订单号 4200001234202610221234567890", "交易单号4200001234202610221234567890", "订单号 12345678901234567890",
                 "4200001234202610221234567890", "今天2026年真好 12345678901234567890123", "订单号 9300000000000000000"]
    let results = longs.map { QuickParse.parse($0, context: ctx) }
    check(results.count == longs.count && results.allSatisfy { $0.intent != .expense },
          "随心：19 位以上的长数字（订单号、交易号）不当金额、不当年份，也不会让应用崩溃（\(results.map { "\($0.intent)" }.joined(separator: "、")))")
}

// MARK: f-polish
// 收尾小毛病之三：筑基三关第三关在全局热键 ⌥⌘J 没注册上时改说菜单栏的笔形小图标（热键正常时一字不改）。
// 纸笺到点出现 / 收起的过渡、删光那天后自动去掉“只看这天”在视图文件里，由 SelfTest+Polish2 逐条核对
do {
    let ok = Onboarding.todo(.quick), failed = Onboarding.todo(.quick, hotKeyFailed: true)
    check(ok == "在任何地方按 ⌥⌘J 写一句；或在 Claude Code 里打开「yunshan-journal」文件夹，说：“\(Onboarding.askExample)”。"
          && Onboarding.todo(.quick, hotKeyFailed: false) == ok
          && Onboarding.quickTryLabel(hotKeyFailed: false) == "试一下 ⌥⌘J"
          && Onboarding.quickTryHelp(hotKeyFailed: false) == "弹出随手记浮窗：写一句、⌘↩ 记下（在别的应用里也能按 ⌥⌘J）",
          "筑基三关：热键好好的时第三关说明、按钮、悬停说明与原来一字不差")
    check(failed.hasPrefix("点菜单栏的笔形小图标随手记一句；") && !failed.contains("⌥⌘J")
          && failed.contains(Onboarding.folderName) && failed.contains(Onboarding.askExample)
          && Onboarding.quickTryLabel(hotKeyFailed: true) == "试一下随手记"
          && Onboarding.quickTryHelp(hotKeyFailed: true).contains("菜单栏的笔形小图标"),
          "筑基三关：⌥⌘J 没注册上时第三关改说“点菜单栏的笔形小图标随手记一句”，按钮写“试一下随手记”，AI 那半句照旧：\(failed)")
    check(Onboarding.Gate.allCases.filter { $0 != .quick }.allSatisfy { Onboarding.todo($0, hotKeyFailed: true) == Onboarding.todo($0) },
          "筑基三关：热键没注册上只改第三关，一关、二关的说明不变")
    check(Onboarding.folderName.replacingOccurrences(of: "\u{00A0}", with: " ") == "「yunshan-journal」"
          && !Onboarding.folderName.contains(" ") && !failed.contains("「② "),
          "筑基三关：热键没注册上时文件夹名「yunshan-journal」不含普通空格，窄窗口折行时整段折下去，不把“「②”单独挂在行尾")
    let copy = [failed, Onboarding.quickTryLabel(hotKeyFailed: true), Onboarding.quickTryHelp(hotKeyFailed: true)]
    check(!copy.contains { $0.contains("失败") || $0.contains("中断") || $0.contains("漏") || $0.contains("没写") },
          "筑基三关：热键没注册上的那几句也不出现“失败 / 中断 / 漏 / 没写”")
}

print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
