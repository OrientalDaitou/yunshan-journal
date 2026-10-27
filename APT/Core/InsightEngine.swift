import Foundation

// 洞见：从记录里找几条统计规律（纯统计，纯逻辑）。修行录“卷中洞见”卡、岁月长卷“其七 · 洞见”、问道灵枢“统计洞察”共用。
// 每类都有最小样本与最小差距，不够就不出——绝不降低门槛去凑。
// 措辞铁律：只说“…的日子里，…平均…”“…最高 / 最低”，不作因果判断（CoreCheck 检查模板里不出现“因为 / 导致”等词）。
// 先报喜再提醒：显示顺序是先正向的几类（连续落笔、心境与功课、心境最好的星期、功课最稳的星期），花钱的居中，
// 功课“常歇”那条放最后；卡片只取前 3 条，有正向的第一条就一定是正向的。不说“中断 / 漏打 / 失败”。
// 文字只由模板、功课名、星期、心境、金额拼成，不读档案、正文和标签，所以不会带出姓名。

struct Insight: Codable, Equatable, Identifiable {
    /// case 的先后就是显示顺序（rawValue 不变，存过的照样认得）
    enum Kind: String, Codable, CaseIterable {
        case writingStreak, moodHabits, moodWeekday, habitWeekday, spendWeekday, moodSpend, fragileHabit

        /// 报喜的一类（排在最前）：连续落笔、心境与功课、心境最好的星期、功课最稳的星期
        var isEncouraging: Bool {
            switch self {
            case .writingStreak, .moodHabits, .moodWeekday, .habitWeekday: true
            case .spendWeekday, .moodSpend, .fragileHabit: false
            }
        }
    }

    /// 图标颜色的含义：心境 / 连续用金，功课用玉，花钱用青
    enum Tone { case mood, habit, spend }

    var kind: Kind
    var text: String
    /// “依据 64 天的心境与打卡”
    var basis: String
    /// 主要样本量（较小那组的天数 / 合格功课数 / 覆盖天数 / 连续天数），测试据此核对门槛
    var sample: Int

    var id: String { kind.rawValue }

    /// SF Symbol
    var symbol: String {
        switch kind {
        case .moodHabits: "sun.max"
        case .fragileHabit: "leaf"
        case .spendWeekday: "calendar"
        case .moodSpend: "creditcard"
        case .habitWeekday: "checkmark.circle"
        case .moodWeekday: "cloud.sun"
        case .writingStreak: "flame"
        }
    }

    var tone: Tone {
        switch kind {
        case .moodHabits, .moodWeekday, .writingStreak: .mood
        case .fragileHabit, .habitWeekday: .habit
        case .spendWeekday, .moodSpend: .spend
        }
    }

    /// 给 AI 的一行：“正文（依据）”
    var line: String { "\(text)（\(basis)）" }
}

enum InsightEngine {
    /// 门槛（CoreCheck 引用同一组常量）
    enum Rules {
        /// 心境对比：两组各至少几天
        static let groupDays = 10
        /// 功课完成率至少差几个百分点（0.10 = 10 点）
        static let rateGap = 0.10
        /// 按星期看花钱：已导全的覆盖天数、期内消费笔数、每个星期至少几天
        static let spendDays = 56, spendTransactions = 30, weekdayDays = 8
        /// 花钱对比：多的至少是少的几倍、至少差多少（分）
        static let spendRatio = 1.3, spendGapCents = 1000
        /// 易断功课：应打卡至少几次、漏打至少几次；最易断那项的完成率要低于多少
        static let fragileScheduled = 28, fragileMisses = 3, fragileMaxRate = 0.85
        /// 最稳的另一项：最长连续至少几天 / 次才提
        static let stableStreak = 7
        /// 按星期看心境：每个星期至少几天、最高最低至少差多少
        static let moodWeekdayDays = 6, moodWeekdayGap = 0.6
        /// 按星期看功课：最高最低至少差几个百分点
        static let habitWeekdayGap = 0.15
        /// 连续落笔至少几天
        static let streakDays = 5
        /// 晴霁日：心境日均值 ≥ 3.5；雨阴日：≤ 2.5
        static let brightMood = 3.5, dimMood = 2.5
    }

    /// 窗口内预先算好的东西，七类共用
    struct Window {
        var input: RecordInput
        var from: LocalDay
        var to: LocalDay
        /// 连续落笔数到哪天：调用方给的止日不早于今天时是今天（今天已写的落笔是定了的事，算进去，
        /// 与长卷其一的“最长连续 / 动笔天数”、修行录卷中气象的“连续落笔”同一个数），否则同 to
        var writingTo: LocalDay
        /// 最长连续落笔在窗口首日之前就开始时，是否往前照实写整段（修行录“近 90 日”是；岁月长卷不是，
        /// 只数段内，与其一的“最长连续”同一个数）
        var streakBeforeFrom = true
        /// 心境日（窗口内）
        var mood: [LocalDay: Double]
        var stats: [HabitStats]
        /// 当天功课完成率（窗口内，有应做功课的日子）
        var dayRates: [LocalDay: Double]
        /// 已导全月份里的消费日（窗口内）；没有账簿时为 nil
        var spend: (cents: [LocalDay: Int], covered: [LocalDay], transactions: Int)?

        var days: [LocalDay] { LocalDay.range(from, to) }
    }

    /// 窗口一律止于昨天（今天还没过完）；只有连续落笔在止日不早于今天时把今天已写的也算上（见 Window.writingTo）。
    /// 显示顺序固定为 Kind.allCases 的顺序（先报喜、花钱居中、常歇的功课最后）。
    /// streakBeforeFrom：见 Window.streakBeforeFrom（岁月长卷传 false）
    static func insights(_ input: RecordInput, from: LocalDay, to: LocalDay, streakBeforeFrom: Bool = true) -> [Insight] {
        guard var w = window(input, from: from, to: to) else { return [] }
        w.streakBeforeFrom = streakBeforeFrom
        let found = [writingStreak(w), moodHabits(w), moodWeekday(w), habitWeekday(w), spendWeekday(w), moodSpend(w), fragileHabit(w)].compactMap { $0 }
        // 按 Kind.allCases 排一遍：上面那行的先后写错了也不会乱
        return found.sorted { Insight.Kind.allCases.firstIndex(of: $0.kind)! < Insight.Kind.allCases.firstIndex(of: $1.kind)! }
    }

    static func window(_ input: RecordInput, from: LocalDay, to rawTo: LocalDay) -> Window? {
        let to = min(rawTo, input.today.adding(days: -1))
        guard from <= to else { return nil }
        let stats = input.habitStats()
        var rates: [LocalDay: Double] = [:]
        if !input.habits.isEmpty {
            for day in LocalDay.range(from, to) {
                if let rate = RecordStats.dayHabitRate(input.habits, stats: stats, on: day) { rates[day] = rate }
            }
        }
        let mood = RecordStats.moodByDay(input.entries.filter { $0.day >= from && $0.day <= to })
        let spend = input.ledger.map { RecordStats.spendDays($0, from: from, to: to, today: input.today) }
        return Window(input: input, from: from, to: to, writingTo: min(rawTo, input.today), mood: mood, stats: stats, dayRates: rates, spend: spend)
    }

    // MARK: 七类

    /// 晴霁日与雨阴日的当天功课完成率（雨阴日不足时改比“其余写了心境的日子”）
    static func moodHabits(_ w: Window) -> Insight? {
        let pairs = w.days.compactMap { day -> (mood: Double, rate: Double)? in
            guard let mood = w.mood[day], let rate = w.dayRates[day] else { return nil }
            return (mood, rate)
        }
        let bright = pairs.filter { $0.mood >= Rules.brightMood }.map(\.rate)
        let dim = pairs.filter { $0.mood <= Rules.dimMood }.map(\.rate)
        guard bright.count >= Rules.groupDays else { return nil }
        let head = "心境「晴」「霁」的日子里，功课完成率平均 \(RecordStats.percent(average(bright)))；"
        if dim.count >= Rules.groupDays {
            guard atLeast(abs(average(bright) - average(dim)), Rules.rateGap) else { return nil }
            return Insight(kind: .moodHabits, text: head + "「雨」「阴」的日子里平均 \(RecordStats.percent(average(dim)))。",
                           basis: "依据 \(bright.count + dim.count) 天的心境与打卡", sample: min(bright.count, dim.count))
        }
        let others = pairs.filter { $0.mood < Rules.brightMood }.map(\.rate)
        guard others.count >= Rules.groupDays, atLeast(abs(average(bright) - average(others)), Rules.rateGap) else { return nil }
        return Insight(kind: .moodHabits, text: head + "其余写了心境的日子平均 \(RecordStats.percent(average(others)))。",
                       basis: "依据 \(pairs.count) 天的心境与打卡", sample: min(bright.count, others.count))
    }

    /// 平均连续最短、最常歇一歇的功课（只看每天 / 指定星期的），先说最稳的另一项：
    /// “最稳的是「冥想」，最长连续 21 天；「论文写作」平均连续 3.5 天会歇一次（共 7 次）。”没有够稳的另一项时只写后半句。
    /// 仍只说统计（门槛与挑法不变），不说“中断 / 漏打”
    static func fragileHabit(_ w: Window) -> Insight? {
        struct Candidate { var index: Int; var habit: RecordHabit; var runs: (achieved: Int, breaks: Int, longest: Int, scheduled: Int) }
        var candidates: [Candidate] = []
        for (index, (habit, s)) in zip(w.input.habits, w.stats).enumerated() where habit.spec.frequency != .weekly {
            guard let range = RecordStats.activeRange(habit, stats: s, from: w.from, to: w.to) else { continue }
            let runs = RecordStats.runs(s, from: range.first, to: range.last)
            if runs.scheduled >= Rules.fragileScheduled { candidates.append(Candidate(index: index, habit: habit, runs: runs)) }
        }
        let qualified = candidates.filter { $0.runs.scheduled - $0.runs.achieved >= Rules.fragileMisses }
        guard qualified.count >= 2 else { return nil }
        func averageRun(_ c: Candidate) -> Double { Double(c.runs.achieved) / Double(max(1, c.runs.breaks)) }
        guard let fragile = qualified.min(by: { a, b in
            averageRun(a) != averageRun(b) ? averageRun(a) < averageRun(b)
                : a.runs.breaks != b.runs.breaks ? a.runs.breaks > b.runs.breaks : a.index < b.index
        }), fragile.runs.breaks > 0, Double(fragile.runs.achieved) / Double(fragile.runs.scheduled) < Rules.fragileMaxRate else { return nil }
        func unit(_ habit: RecordHabit) -> String { habit.spec.frequency == .daily ? "天" : "次" }
        let rest = "「\(fragile.habit.title)」平均连续 \(RecordStats.decimal(averageRun(fragile))) \(unit(fragile.habit))会歇一次（共 \(fragile.runs.breaks) 次）。"
        let stable = candidates.filter { $0.index != fragile.index }
            .max { a, b in a.runs.longest != b.runs.longest ? a.runs.longest < b.runs.longest : a.index > b.index }
        var text = rest
        if let stable, stable.runs.longest >= Rules.stableStreak {
            text = "最稳的是「\(stable.habit.title)」，最长连续 \(stable.runs.longest) \(unit(stable.habit))；" + rest
        }
        return Insight(kind: .fragileHabit, text: text, basis: "依据 \(qualified.count) 项功课的打卡", sample: qualified.count)
    }

    /// 星期几花钱最多（只用已导全月份里的日子，按银行记账日期）
    static func spendWeekday(_ w: Window) -> Insight? {
        guard let spend = w.spend, spend.covered.count >= Rules.spendDays, spend.transactions >= Rules.spendTransactions else { return nil }
        var total = Array(repeating: 0, count: 7), count = Array(repeating: 0, count: 7)
        for day in spend.covered {
            total[day.weekdayIndex] += spend.cents[day] ?? 0
            count[day.weekdayIndex] += 1
        }
        guard count.allSatisfy({ $0 >= Rules.weekdayDays }) else { return nil }
        let averages = (0..<7).map { Double(total[$0]) / Double(count[$0]) }
        guard let top = (0..<7).max(by: { averages[$0] != averages[$1] ? averages[$0] < averages[$1] : $0 > $1 }) else { return nil }
        let rest = Double(total.reduce(0, +) - total[top]) / Double(spend.covered.count - count[top])
        guard rest > 0, atLeast(averages[top], rest * Rules.spendRatio) else { return nil }
        let name = LocalDay.weekdayNames[top]
        return Insight(kind: .spendWeekday,
                       text: "\(name)花钱最多：平均每个\(name)约 \(RecordStats.dollars(Int(averages[top].rounded())))，"
                           + "是其余日子日均（约 \(RecordStats.dollars(Int(rest.rounded())))）的 \(RecordStats.decimal(averages[top] / rest)) 倍。",
                       basis: "依据 \(spend.covered.count) 天已导全的账单（按银行记账日期）", sample: spend.covered.count)
    }

    /// 晴霁日与雨阴日的当天消费（只取已导全月份里的日子）
    static func moodSpend(_ w: Window) -> Insight? {
        guard let spend = w.spend else { return nil }
        let days = spend.covered.filter { w.mood[$0] != nil }
        let bright = days.filter { (w.mood[$0] ?? 0) >= Rules.brightMood }.map { Double(spend.cents[$0] ?? 0) }
        let dim = days.filter { (w.mood[$0] ?? 0) <= Rules.dimMood }.map { Double(spend.cents[$0] ?? 0) }
        guard bright.count >= Rules.groupDays, dim.count >= Rules.groupDays else { return nil }
        let b = average(bright), d = average(dim)
        let high = max(b, d), low = min(b, d)
        guard atLeast(high, low * Rules.spendRatio), atLeast(high - low, Double(Rules.spendGapCents)) else { return nil }
        let brightText = "「晴」「霁」的日子里", dimText = "「雨」「阴」的日子里"
        let (first, firstValue, second, secondValue) = d > b ? (dimText, d, brightText, b) : (brightText, b, dimText, d)
        return Insight(kind: .moodSpend,
                       text: "心境\(first)，当天平均花 \(RecordStats.dollars(Int(firstValue.rounded())))；"
                           + "\(second)平均 \(RecordStats.dollars(Int(secondValue.rounded())))。",
                       basis: "依据 \(days.count) 天同时有心境和完整账单的日子", sample: min(bright.count, dim.count))
    }

    /// 按星期看当天功课完成率
    static func habitWeekday(_ w: Window) -> Insight? {
        guard let e = weekdayExtremes(w.dayRates, minDays: Rules.weekdayDays), atLeast(e.high.value - e.low.value, Rules.habitWeekdayGap)
        else { return nil }
        let (high, low) = (e.high, e.low)
        return Insight(kind: .habitWeekday,
                       text: "功课完成率\(LocalDay.weekdayNames[high.weekday])最高（平均 \(RecordStats.percent(high.value))），"
                           + "\(LocalDay.weekdayNames[low.weekday])最低（平均 \(RecordStats.percent(low.value))）。",
                       basis: "依据 \(w.dayRates.count) 天的打卡", sample: e.sample)
    }

    /// 按星期看心境日
    static func moodWeekday(_ w: Window) -> Insight? {
        guard let e = weekdayExtremes(w.mood, minDays: Rules.moodWeekdayDays), atLeast(e.high.value - e.low.value, Rules.moodWeekdayGap)
        else { return nil }
        let (high, low) = (e.high, e.low)
        return Insight(kind: .moodWeekday,
                       text: "心境\(LocalDay.weekdayNames[high.weekday])最好（平均 \(RecordStats.decimal(high.value))），"
                           + "\(LocalDay.weekdayNames[low.weekday])最低（平均 \(RecordStats.decimal(low.value))）。",
                       basis: "依据 \(w.mood.count) 天的日记心境（1 雨 … 5 霁）", sample: e.sample)
    }

    /// 窗口里的最长连续落笔。按窗口内的长短挑出这一段；它若在窗口首日之前就开始了，照实写出整段
    /// （“近 90 日”里写了半年的连续不该只算 90 天）；岁月长卷不往前延伸（streakBeforeFrom = false），与其一同一个数。窗口通到今天时今天已写的也算（数到 writingTo），依据的天数同样数到那天。
    /// “至今仍在延续”只在这一段写到今天或昨天时才说（今天还没写不算断）
    static func writingStreak(_ w: Window) -> Insight? {
        let end = w.writingTo
        let days = Set(w.input.history.map(\.day).filter { $0 <= end })
        guard let run = RecordStats.longestRun(days, from: w.from, to: end), run.count >= Rules.streakDays else { return nil }
        var first = run.first
        while w.streakBeforeFrom && days.contains(first.adding(days: -1)) { first = first.adding(days: -1) }
        let count = first.days(to: run.last) + 1
        let today = w.input.today
        var text = "最长连续落笔 \(count) 天（\(first.label(relativeTo: today))—\(run.last.label(relativeTo: today))）"
        if let start = days.min(), let best = RecordStats.longestRun(days, from: start, to: end), best.count == count {
            text += "，也是有记录以来最长的一次"
        }
        if run.last >= today.adding(days: -1) { text += "，至今仍在延续" }
        return Insight(kind: .writingStreak, text: text + "。",
                       basis: "依据 \(days.filter { $0 >= w.from }.count) 天的落笔", sample: run.count)
    }

    // MARK: 小工具

    private static func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    /// 浮点比较留一点余量：0.8 − 0.7 算出来是 0.0999…，“刚好差 10 个百分点”也要算过门槛
    private static func atLeast(_ value: Double, _ threshold: Double) -> Bool { value >= threshold - 1e-9 }

    /// 按星期分组求平均：每个星期都至少 minDays 天才比；返回最高、最低（一样高时取靠前的星期）与最少那组的天数
    private static func weekdayExtremes(_ values: [LocalDay: Double], minDays: Int)
        -> (high: (weekday: Int, value: Double), low: (weekday: Int, value: Double), sample: Int)? {
        var sums = Array(repeating: 0.0, count: 7), counts = Array(repeating: 0, count: 7)
        // 按日期先后累加：浮点加法与顺序有关，同样的输入每次得到同样的结果
        for (day, value) in values.sorted(by: { $0.key < $1.key }) {
            sums[day.weekdayIndex] += value
            counts[day.weekdayIndex] += 1
        }
        guard let fewest = counts.min(), fewest >= minDays else { return nil }
        let averages = (0..<7).map { sums[$0] / Double(counts[$0]) }
        guard let high = (0..<7).max(by: { averages[$0] != averages[$1] ? averages[$0] < averages[$1] : $0 > $1 }),
              let low = (0..<7).min(by: { averages[$0] != averages[$1] ? averages[$0] < averages[$1] : $0 < $1 }) else { return nil }
        return ((high, averages[high]), (low, averages[low]), fewest)
    }
}
