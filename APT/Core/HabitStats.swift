import Foundation

enum HabitFrequency: String, CaseIterable, Codable, Identifiable {
    case daily, weekly, weekdays
    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily: "每天"
        case .weekly: "每周 N 次"
        case .weekdays: "指定星期"
        }
    }
}

/// 习惯定义的值类型快照，便于纯逻辑计算与测试。
struct HabitSpec: Equatable {
    var frequency: HabitFrequency
    var targetPerWeek: Int = 1
    var weekdays: [Int] = []
    var targetValue: Double?
    var startDay: LocalDay
    /// 习惯创建的那一天：此前的日子只有补了卡才计入“功课圆满”，没做不算漏（见 CultivationEngine）。nil 表示不限。
    var createdDay: LocalDay? = nil
    /// 归档的那一天（只在已归档时有值）：此前的日子照常计入“功课圆满”。旧数据没有归档日，归档后完全不计。
    var archivedDay: LocalDay? = nil

    func isScheduled(_ day: LocalDay) -> Bool {
        guard day >= startDay else { return false }
        switch frequency {
        case .daily, .weekly: return true
        case .weekdays: return weekdays.contains(day.weekdayIndex)
        }
    }

    /// 某条打卡是否达标。数量目标优先用打卡当时记下的目标（log.target：>0 为当时的目标，0 表示当时没有数量目标），
    /// 没记的（nil）沿用习惯当前的目标——这样改数量目标不会改写历史。
    func achieved(_ log: HabitLogValue?) -> Bool {
        guard let log else { return false }
        let target = log.target.map { $0 > 0 ? $0 : nil } ?? targetValue
        if let target, target > 0 { return (log.quantity ?? 0) >= target }
        return log.completed
    }

    var scheduleSummary: String {
        switch frequency {
        case .daily: return "每天"
        case .weekly: return "每周 \(targetPerWeek) 次"
        case .weekdays: return "每周" + weekdays.sorted().map { LocalDay.weekdayShortNames[$0] }.joined(separator: "、")
        }
    }
}

struct HabitLogValue: Equatable {
    var day: LocalDay
    var completed: Bool
    var quantity: Double?
    /// 打卡当时的数量目标（HabitLog.targetAtLog）：>0 为当时的目标；0 表示当时没有数量目标；nil 表示沿用习惯当前的目标。
    var target: Double? = nil
}

enum HabitDayState { case done, partial, missed, rest, future, beforeStart }

/// 可比较：功课页把统计交给热力图等子视图，统计没变时子视图不必重画（见 HabitsView）。
struct HabitStats: Equatable {
    let spec: HabitSpec
    let logs: [LocalDay: HabitLogValue]
    let today: LocalDay

    init(spec: HabitSpec, logs: [HabitLogValue], today: LocalDay) {
        self.spec = spec
        self.today = today
        var map: [LocalDay: HabitLogValue] = [:]
        for log in logs { map[log.day] = log }
        self.logs = map
    }

    func isAchieved(_ day: LocalDay) -> Bool { spec.achieved(logs[day]) }

    func state(on day: LocalDay) -> HabitDayState {
        if day > today { return .future }
        if day < spec.startDay { return isAchieved(day) ? .done : .beforeStart }
        if isAchieved(day) { return .done }
        if logs[day] != nil { return .partial }
        if spec.frequency == .weekly { return .rest }
        return spec.isScheduled(day) ? (day == today ? .rest : .missed) : .rest
    }

    /// 最近 days 天（含今天）的完成率，0…1；没有应完成的机会时为 nil。
    /// 今天还没打卡不计入分母（当天仍有机会）。
    func completionRate(days: Int, endingAt end: LocalDay? = nil) -> Double? {
        let last = min(end ?? today, today)
        let first = last.adding(days: -(days - 1))
        return rate(from: first, to: last)
    }

    func rate(from first: LocalDay, to last: LocalDay) -> Double? {
        let first = max(first, spec.startDay)
        guard first <= last else { return nil }
        switch spec.frequency {
        case .daily, .weekdays:
            var expected = 0, done = 0
            for day in LocalDay.range(first, last) where spec.isScheduled(day) {
                let ok = isAchieved(day)
                if day == today && !ok { continue }
                expected += 1
                if ok { done += 1 }
            }
            return expected == 0 ? nil : Double(done) / Double(expected)
        case .weekly:
            let target = Double(max(1, spec.targetPerWeek))
            var quota = 0.0, credit = 0.0
            var monday = first.mondayOfWeek
            while monday <= last {
                let sunday = monday.adding(days: 6)
                let days = LocalDay.range(max(monday, first), min(sunday, last))
                let weekQuota = target * Double(days.count) / 7.0
                let count = Double(days.filter(isAchieved).count)
                let isCurrentWeek = monday == today.mondayOfWeek
                if !isCurrentWeek && (monday < first || last < sunday) {
                    // 窗口把一周截成半周（开头：近 7 天从上周四算起；结尾：月度复盘止于周三的月末、事后复盘止于上周三）：
                    // 这一周已经过完，按整周（自开始日期起）是否达标折算，权重仍是窗口内的天数。
                    // 否则落在窗口外那几天打的卡不算，配额却照摊，严格达标也只显示四成多，完成率取决于打卡落在星期几。
                    // 截到今天为止：未来的周没有可算的日子，记 0。
                    let active = LocalDay.range(max(monday, spec.startDay), min(sunday, today))
                    let activeQuota = target * Double(active.count) / 7.0
                    let done = Double(active.filter(isAchieved).count)
                    quota += weekQuota
                    credit += activeQuota > 0 ? weekQuota * min(1, done / activeQuota) : 0
                } else {
                    // 本周还没结束：只要已完成次数没超过配额，就按已完成的算，不惩罚剩余天数。
                    let effectiveQuota = isCurrentWeek ? max(min(weekQuota, count), 0) : weekQuota
                    quota += effectiveQuota
                    credit += min(count, effectiveQuota)
                }
                monday = monday.adding(days: 7)
            }
            return quota <= 0 ? nil : min(1, credit / quota)
        }
    }

    /// 当前连续：每天/指定星期按“应打卡日”计；每周 N 次按“达标的整周”计。
    /// 单位：每天的写“天”，指定星期的写“次”（数的是连续的应打卡日，写“天”会被当成日历上的天数），每周 N 次的写“周”，
    /// 与岁月长卷的 RecordStats.longestStreak、洞见“平均连续 N 次”同一说法（今日洞府、功课页、快照与问道灵枢摘要都用这里的单位）。
    var streak: (count: Int, unit: String) {
        switch spec.frequency {
        case .daily, .weekdays:
            var count = 0
            var day = today
            while day >= spec.startDay {
                if spec.isScheduled(day) {
                    if isAchieved(day) { count += 1 } else if day != today { break }
                }
                day = day.adding(days: -1)
            }
            return (count, spec.frequency == .daily ? "天" : "次")
        case .weekly:
            var count = 0
            var monday = today.mondayOfWeek
            let target = max(1, spec.targetPerWeek)
            while monday.adding(days: 6) >= spec.startDay {
                let achieved = LocalDay.range(monday, monday.adding(days: 6)).filter(isAchieved).count
                if achieved >= target { count += 1 } else if monday != today.mondayOfWeek { break }
                monday = monday.adding(days: -7)
            }
            return (count, "周")
        }
    }

    var totalAchieved: Int { logs.keys.filter { $0 <= today && isAchieved($0) }.count }

    /// 最近 weeks 周每周的完成率（周一开始），用于趋势图。
    func weeklyTrend(weeks: Int) -> [(weekStart: LocalDay, rate: Double?)] {
        let thisMonday = today.mondayOfWeek
        return (0..<weeks).reversed().map { offset in
            let monday = thisMonday.adding(days: -7 * offset)
            return (monday, rate(from: monday, to: min(monday.adding(days: 6), today)))
        }
    }

    /// 本周已完成次数（每周 N 次的习惯显示用）。
    var achievedThisWeek: Int {
        LocalDay.range(today.mondayOfWeek, today).filter(isAchieved).count
    }

    /// 今天是否需要（或可以）打卡。
    var isDueToday: Bool {
        switch spec.frequency {
        case .daily, .weekdays: return spec.isScheduled(today)
        case .weekly: return today >= spec.startDay && (achievedThisWeek < max(1, spec.targetPerWeek) || isAchieved(today))
        }
    }
}
