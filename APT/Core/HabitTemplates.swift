import Foundation

// 功法谱（习惯模板库）与功课页的几样小件：数量型的“＋1”步长、个人纪录（最长连续、距纪录、新纪录）。
// 纯数据与纯函数，不依赖 SwiftData，CoreCheck 可测。界面在 Views/HabitsView（新建功课弹窗顶部的功法谱、
// 一键立好的 HabitTemplateInstaller），新纪录的提示在 Services/HabitService（HabitActions 打卡之后）。

/// 功法谱里的一式：点一下把名称、类别（组名）、图标、频率、数量、备注填进新建功课的表单（用户还能改）。
struct HabitTemplate: Equatable, Identifiable {
    /// 组名，也是立好之后的类别：起居 / 身体 / 心神 / 学业
    var group: String
    var title: String
    /// SF Symbols 名（都在新建功课弹窗的图标格里）
    var symbol: String
    var frequency: HabitFrequency = .daily
    /// 每周 N 次的 N（其余频率不用）
    var targetPerWeek: Int = 1
    /// 指定星期（0 = 周一 … 6 = 周日，与 LocalDay.weekdayIndex 相同）
    var weekdays: [Int] = []
    /// 数量目标；nil 表示打卡型
    var targetValue: Double? = nil
    var unit: String = ""
    /// 写进习惯备注：建议的锚点、口径
    var notes: String = ""

    var id: String { title }

    /// 胶囊上写的：“早睡”“喝水 · 8 杯”“运动 · 每周 3 次”“专注 · 90 分钟”
    var chipText: String {
        if let targetValue { return "\(title) · \(HabitTemplates.amount(targetValue)) \(unit)" }
        if frequency == .weekly { return "\(title) · 每周 \(targetPerWeek) 次" }
        return title
    }

    /// 悬停说明：频率、每次多少、备注，例如“周一至周五 · 每次 90 分钟 · 上午先做最难的一件”
    var detailText: String {
        var parts = [scheduleText]
        if let targetValue { parts.append("每次 \(HabitTemplates.amount(targetValue)) \(unit)") }
        if !notes.isEmpty { parts.append(notes) }
        return parts.joined(separator: " · ")
    }

    /// 频率的说法：每天 / 每周 3 次 / 周一至周五 / 每周一、三、五
    var scheduleText: String {
        switch frequency {
        case .daily: return "每天"
        case .weekly: return "每周 \(targetPerWeek) 次"
        case .weekdays:
            let days = weekdays.sorted()
            if days == [0, 1, 2, 3, 4] { return "周一至周五" }
            return "每周" + days.map { LocalDay.weekdayShortNames[$0] }.joined(separator: "、")
        }
    }
}

enum HabitTemplates {
    /// 四组，按这个次序排
    static let groups = ["起居", "身体", "心神", "学业"]

    /// 十二式（次序即胶囊的次序）
    static let all: [HabitTemplate] = [
        HabitTemplate(group: "起居", title: "早睡", symbol: "moon.zzz", notes: "23:30 前入睡 · 锚点：洗漱后"),
        HabitTemplate(group: "起居", title: "早起", symbol: "sun.max", notes: "7:30 前起床"),
        HabitTemplate(group: "起居", title: "睡前不刷手机", symbol: "moon.zzz", notes: "锚点：上床后"),
        HabitTemplate(group: "身体", title: "喝水", symbol: "drop", targetValue: 8, unit: "杯", notes: "锚点：每顿饭后一杯"),
        HabitTemplate(group: "身体", title: "运动", symbol: "figure.run", frequency: .weekly, targetPerWeek: 3, notes: "跑步、健身、游泳都算"),
        HabitTemplate(group: "身体", title: "步数", symbol: "figure.run", targetValue: 8000, unit: "步"),
        HabitTemplate(group: "身体", title: "拉伸", symbol: "heart", targetValue: 10, unit: "分钟", notes: "锚点：起床后"),
        HabitTemplate(group: "心神", title: "冥想", symbol: "brain.head.profile", targetValue: 10, unit: "分钟", notes: "锚点：早饭前"),
        HabitTemplate(group: "学业", title: "读书", symbol: "book", targetValue: 20, unit: "页", notes: "锚点：晚饭后"),
        HabitTemplate(group: "学业", title: "背单词", symbol: "globe.asia.australia", targetValue: 30, unit: "个"),
        HabitTemplate(group: "学业", title: "专注", symbol: "graduationcap", frequency: .weekdays, weekdays: [0, 1, 2, 3, 4],
                      targetValue: 90, unit: "分钟", notes: "上午先做最难的一件"),
        HabitTemplate(group: "学业", title: "写作", symbol: "pencil.and.scribble", targetValue: 300, unit: "字"),
    ]

    /// 筑基三关第一关列出的六式（首页新手卡用）：早睡、喝水 · 8 杯、运动 · 每周 3 次、冥想 · 10 分钟、读书 · 20 页、背单词 · 30 个
    static let starter: [HabitTemplate] = ["早睡", "喝水", "运动", "冥想", "读书", "背单词"].compactMap { HabitTemplates.named($0) }

    /// 按组排好：[(组名, 这一组的几式)]
    static var grouped: [(group: String, items: [HabitTemplate])] {
        groups.map { group in (group, all.filter { $0.group == group }) }
    }

    /// 按名称找一式（去掉首尾空白、不分大小写）
    static func named(_ title: String) -> HabitTemplate? {
        let key = normalized(title)
        return all.first { normalized($0.title) == key }
    }

    /// 这一式是否已立：现有功课里有同名的（去掉首尾空白、不分大小写；与飞剑传书认习惯名的“完全相同”一致）
    static func isInstalled(_ template: HabitTemplate, titles: [String]) -> Bool {
        let key = normalized(template.title)
        return titles.contains { normalized($0) == key }
    }

    static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 数量的写法：整数不带小数点，其余一位小数
    static func amount(_ value: Double) -> String {
        value.isFinite && abs(value) < 1e15 && value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - 数量型的“＋1”

/// 数量型功课一点“＋1”加多少：目标 ≤ 20 → 1；≤ 120 → 5；更大 → 目标的 1/8 取整（8000 步 → ＋1000）。
/// 首页、功课页同一个步长；按钮上写实际步长（“＋5”“＋1000”）。没有目标时按 1。
enum HabitStepRule {
    static func step(forTarget target: Double?) -> Double {
        guard let target, target.isFinite, target > 0 else { return 1 }
        if target <= 20 { return 1 }
        if target <= 120 { return 5 }
        return max(1, (target / 8).rounded())
    }

    /// 按钮上的字：“+1”“+5”“+1000”。按钮里用半角加号：全角“＋”两侧自带留白，在按钮的字距下读成“+ 1”
    static func label(forTarget target: Double?) -> String { "+" + HabitTemplates.amount(step(forTarget: target)) }
}

// MARK: - 个人纪录

/// 功课的个人纪录：最长连续与岁月长卷同一口径（RecordStats.longestStreak，从开始日到今天，今天没打不算断）；
/// 单位与当前连续相同（每天“天”、指定星期“次”、每周 N 次“周”）。
enum HabitRecord {
    /// 从开始日到今天的最长连续（含正在延续的这一段）
    static func longest(_ stats: HabitStats) -> (count: Int, unit: String) {
        RecordStats.longestStreak(stats, from: stats.spec.startDay, to: stats.today)
    }

    /// 当前这一段之前的最长连续（不含正在延续的这一段）：“旧纪录”。当前连续为 0 时就是整个的最长连续
    static func previousBest(_ stats: HabitStats) -> Int {
        let spec = stats.spec
        let current = stats.streak.count
        guard current > 0 else { return longest(stats).count }
        // 与 HabitStats.streak 同样往回数，数到第 current 个达标的应打卡日 / 达标的整周，就是这一段的起点
        var runStart = stats.today
        switch spec.frequency {
        case .daily, .weekdays:
            var count = 0
            var day = stats.today
            while day >= spec.startDay {
                if spec.isScheduled(day), stats.isAchieved(day) {
                    count += 1
                    if count == current {
                        runStart = day
                        break
                    }
                }
                day = day.adding(days: -1)
            }
        case .weekly:
            let target = max(1, spec.targetPerWeek)
            var count = 0
            var monday = stats.today.mondayOfWeek
            while monday.adding(days: 6) >= spec.startDay {
                if LocalDay.range(monday, monday.adding(days: 6)).filter(stats.isAchieved).count >= target {
                    count += 1
                    if count == current {
                        runStart = monday
                        break
                    }
                }
                monday = monday.adding(days: -7)
            }
        }
        let last = runStart.adding(days: -1)
        guard last >= spec.startDay else { return 0 }
        return RecordStats.longestStreak(stats, from: spec.startDay, to: last).count
    }

    /// 打破纪录的那一下：改之前的旧纪录（当前这一段之前的最长）≥ 3，改之后的当前连续第一次超过它。
    /// 返回改之后的当前连续（“新纪录 · 「冥想」连续 15 天”）；没破纪录时为 nil。
    /// 之后接着延续这段纪录的日子不再提示（详情页的数字格写“正在创纪录”）
    static func broken(before: HabitStats, after: HabitStats) -> (count: Int, unit: String)? {
        let old = previousBest(after)
        let was = before.streak.count
        let now = after.streak
        guard old >= 3, now.count > old, was <= old else { return nil }
        return now
    }

    /// 新纪录的提示语
    static func brokenText(title: String, _ streak: (count: Int, unit: String)) -> String {
        "新纪录 · 「\(title)」连续 \(streak.count) \(streak.unit)"
    }

    /// 详情数字格“当前连续”下的一行小字：正在创纪录（当前 = 最长且 ≥ 3）/ 距纪录还差 N 天（当前 ≥ 1 且比最长短）；
    /// 当前连续为 0 时不写（“最长连续”那一格就在旁边）
    static func note(current: Int, longest: Int, unit: String) -> String? {
        if current >= 3, current >= longest { return "正在创纪录" }
        if current >= 1, longest > current { return "距纪录还差 \(longest - current) \(unit)" }
        return nil
    }
}
