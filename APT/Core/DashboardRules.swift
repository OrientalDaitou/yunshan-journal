import Foundation

/// 今日洞府的几条小规矩（纯函数，Tools/CoreCheck 的 r1-home 一节逐条核对）：
/// 数量型功课行尾的“3/8 杯 +1”（步长与写法）、功课多时收起已圆满、两栏较矮那栏最多多拉 160pt、
/// “旧笔新读”取哪几天、眉题、摘句与落款。界面在 DashboardView / DashboardLookBack，取数在 DashboardLookBackLoader。
enum DashboardRules {
    // MARK: 数量型功课：“3/8 杯 +1”

    /// “+”一次加多少：目标 ≤ 20 加 1；≤ 120 加 5；更大加目标的八分之一（取整，8000 步 → 1000）。至少 1
    static func quantityStep(target: Double) -> Double {
        guard target.isFinite, target > 20 else { return 1 }
        if target <= 120 { return 5 }
        return max(1, (target / 8).rounded())
    }

    /// 按钮上写的字：“+1”“+5”“+1000”（半角加号：全角的“＋”在等宽数字旁会空出一大格，读成“+ 1”）
    static func stepLabel(_ step: Double) -> String { "+" + number(step) }

    /// 数量的写法：整数不带小数点；小数最多两位、去掉末尾的 0
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        // -0.001 这类四舍五入到 0 的负数写“0”，不写“-0”（菜单栏原来那份就是这样写的，并过来后照旧）
        return text == "-0" ? "0" : text
    }

    /// 行尾的“3/8 杯”（没有单位时只写“3/8”）
    static func quantityText(done: Double, target: Double, unit: String) -> String {
        let unit = unit.trimmingCharacters(in: .whitespaces)
        return "\(number(max(0, done)))/\(number(target))" + (unit.isEmpty ? "" : " \(unit)")
    }

    // MARK: 功课多时收起已圆满

    /// 今天要做的超过这么多项，就只列未圆满的
    static let foldThreshold = 6

    /// 要不要把已圆满的收成一行“已圆满 N 项 ›”：要做的超过 6 项、且至少圆满了一项
    static func foldsDone(due: Int, done: Int) -> Bool { due > foldThreshold && done > 0 }

    // MARK: 两栏不再强行等高

    /// 较矮那一栏的最后一张最多多拉这么高，剩下的留白（不再拉出一整块空卡）
    static let maxStretch = 160.0

    /// 这一栏的最后一张要多拉多少：比另一栏矮多少就拉多少，但不超过 maxStretch；不比另一栏矮时不拉
    static func stretch(column: Double, other: Double) -> Double {
        min(max(0, other - column), maxStretch)
    }

    // MARK: 旧笔新读

    /// 往前看的四个时点，按“先远后近”排：一年前、半年前、一月前、一周前（与修行录“往日回看”同几天）
    static func lookBackSpans(today: LocalDay) -> [(label: String, day: LocalDay)] {
        [("一年前", monthAgo(12, today: today)), ("半年前", monthAgo(6, today: today)),
         ("一月前", monthAgo(1, today: today)), ("一周前", today.adding(days: -7))]
    }

    /// N 个月前的同一天；那个月没有这一天时取月底（3月31日的一月前是2月28日）
    static func monthAgo(_ months: Int, today: LocalDay) -> LocalDay {
        var y = today.year, m = today.month - months
        while m <= 0 { m += 12; y -= 1 }
        let lastDay = LocalDay(year: m == 12 ? y + 1 : y, month: m == 12 ? 1 : m + 1, day: 1).adding(days: -1).day
        return LocalDay(year: y, month: m, day: min(today.day, lastDay))
    }

    /// 要查的全部日期：四个时点各自前后放宽一天（不必那天正好写过），共 12 个
    static func lookBackKeys(today: LocalDay) -> [String] {
        lookBackSpans(today: today).flatMap { span in [span.day, span.day.adding(days: -1), span.day.adding(days: 1)].map(\.key) }
    }

    /// 四个时点里写过的：每个时点先看正好那天，再看前一天、后一天（与往日回看的放宽次序相同）。
    /// written：这 12 天里写过的日期。exact 表示正好是“N 前的今天”
    static func lookBackFound(today: LocalDay, written: Set<String>) -> [(label: String, day: LocalDay, exact: Bool)] {
        lookBackSpans(today: today).compactMap { label, day in
            [day, day.adding(days: -1), day.adding(days: 1)].first { written.contains($0.key) }
                .map { (label, $0, $0 == day) }
        }
    }

    /// 只在 7 天以前（含第 7 天）的篇目里挑珍藏、挑旧笔：这一天的 dateKey 是上界
    static func olderCutoff(today: LocalDay) -> LocalDay { today.adding(days: -7) }

    /// 眉题：“一年前的今天 · 周三”；放宽了一天的写“一年前 · 周二”
    static func spanEyebrow(_ label: String, day: LocalDay, exact: Bool) -> String {
        (exact ? label + "的今天" : label) + " · " + day.weekdayName
    }

    /// 珍藏的眉题：“珍藏 · 3 个月前”
    static func pinnedEyebrow(day: LocalDay, today: LocalDay) -> String { "珍藏 · " + age(from: day, to: today) }

    /// 别的旧笔的眉题：“10 日前 · 周一”
    static func olderEyebrow(day: LocalDay, today: LocalDay) -> String { age(from: day, to: today) + " · " + day.weekdayName }

    /// 隔了多久：30 天以内写“N 日前”，一年以内写“N 个月前”，再久写“N 年前”
    static func age(from day: LocalDay, to today: LocalDay) -> String {
        let days = max(0, day.days(to: today))
        if days < 30 { return "\(days) 日前" }
        if days < 365 { return "\(days / 30) 个月前" }
        return "\(days / 365) 年前"
    }

    /// 正文摘句：去掉首尾空白，换行并成一个空格，超过 limit 字取前 limit 字加“……”
    static func excerpt(_ body: String, limit: Int = 60) -> String {
        let flat = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "……"
    }

    /// 落款：“心境 晴 · 2025年10月22日”；没记心境只写日期。kind 不是日记时在前面写类型（“灵感 · …”）
    static func signature(kindLabel: String?, mood: Int?, day: LocalDay) -> String {
        var parts: [String] = []
        if let kindLabel, !kindLabel.isEmpty { parts.append(kindLabel) }
        if let mood, (1...5).contains(mood) { parts.append("心境 " + Mood.label(mood)) }
        parts.append("\(day.year)年\(day.month)月\(day.day)日")
        return parts.joined(separator: " · ")
    }

    /// 按日期固定地挑一个位置（同一天总是同一个，换一天顺延）：珍藏、旧笔从这里起取
    static func dailyIndex(_ day: LocalDay, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((day.jdn % count) + count) % count
    }

    /// 从 start 起绕一圈取最多 limit 个位置（珍藏、旧笔“换一篇”的次序）
    static func rotation(count: Int, start: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        return (0..<min(count, limit)).map { (start + $0) % count }
    }

    /// 写过，但都在近 7 天里（还没有可以“旧笔新读”的）：卡里只写这一行
    static let waitingLine = "写满七日，这里会浮现你写过的话。"
}
