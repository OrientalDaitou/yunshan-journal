import Foundation

/// 固定作息的类别。
enum RoutineKind: String, CaseIterable, Identifiable {
    case sleep, meal, study, work, exercise, commute, rest, focus, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sleep: "睡眠"
        case .meal: "用餐"
        case .study: "学习 / 上课"
        case .work: "工作"
        case .exercise: "运动"
        case .commute: "通勤"
        case .rest: "休息"
        case .focus: "可安排时段"
        case .other: "其他"
        }
    }
    var symbol: String {
        switch self {
        case .sleep: "moon.zzz"
        case .meal: "fork.knife"
        case .study: "book"
        case .work: "briefcase"
        case .exercise: "figure.run"
        case .commute: "tram"
        case .rest: "cup.and.saucer"
        case .focus: "scope"
        case .other: "circle.dashed"
        }
    }
    static func of(_ raw: String) -> RoutineKind { RoutineKind(rawValue: raw) ?? .other }
}

/// 固定作息在某一天占的时段（当天第几分钟）。跨夜的作息（结束 ≤ 开始，例如 23:30–07:30）切成两段：
/// 开始那天从开始到 24:00，次日从 0:00 到结束（carried，“昨晚延续”；正好 0:00 结束的没有这一段）。
/// 今日洞府的今日行程、时辰卷周视图的作息底纹、起居有常的一周作息图都按它切段，三处切法一致。
enum RoutineSpan {
    struct Segment: Equatable {
        /// 在传入数组里的位置
        var index: Int
        var start: Int
        var end: Int
        /// 前一天开始、跨夜延续到这天的那段
        var carried: Bool
    }

    static func crossesMidnight(start: Int, end: Int) -> Bool { end <= start }

    /// weekday（0 = 周一 … 6 = 周日）这天的各段，按传入顺序
    static func segments(_ blocks: [(weekday: Int, start: Int, end: Int)], weekday: Int) -> [Segment] {
        let previous = (weekday + 6) % 7
        var result: [Segment] = []
        for (index, block) in blocks.enumerated() {
            let crosses = crossesMidnight(start: block.start, end: block.end)
            if block.weekday == weekday {
                result.append(Segment(index: index, start: block.start, end: crosses ? 24 * 60 : block.end, carried: false))
            } else if block.weekday == previous, crosses, block.end > 0 {
                result.append(Segment(index: index, start: 0, end: block.end, carried: true))
            }
        }
        return result
    }
}

enum EventPriority: String, CaseIterable, Identifiable {
    case must, should, could
    var id: String { rawValue }
    var label: String {
        switch self {
        case .must: "必须"
        case .should: "应该"
        case .could: "可以"
        }
    }
}

enum WeekdayText {
    /// [0,1,2,3,4] → “周一至周五”；[5,6] → “周末”；全部 → “每天”。
    static func summary(_ days: [Int]) -> String {
        let sorted = Array(Set(days)).sorted()
        if sorted.count == 7 { return "每天" }
        if sorted == [0, 1, 2, 3, 4] { return "工作日（周一至周五）" }
        if sorted == [5, 6] { return "周末" }
        if sorted.count >= 3, let first = sorted.first, let last = sorted.last, last - first == sorted.count - 1 {
            return "\(LocalDay.weekdayNames[first])至\(LocalDay.weekdayNames[last])"
        }
        return sorted.map { LocalDay.weekdayNames[$0] }.joined(separator: "、")
    }
}

/// 常用作息模板，一键套用后可再逐条修改。
enum RoutineTemplate {
    struct Item { var title: String; var kind: RoutineKind; var weekdays: [Int]; var start: Int; var end: Int }

    static let student: [Item] = [
        Item(title: "睡眠", kind: .sleep, weekdays: Array(0...6), start: 23 * 60 + 30, end: 7 * 60 + 30),
        Item(title: "早餐", kind: .meal, weekdays: Array(0...6), start: 7 * 60 + 45, end: 8 * 60 + 15),
        Item(title: "上午专注", kind: .study, weekdays: Array(0...4), start: 9 * 60, end: 12 * 60),
        Item(title: "午餐", kind: .meal, weekdays: Array(0...6), start: 12 * 60, end: 13 * 60),
        Item(title: "下午学习", kind: .study, weekdays: Array(0...4), start: 14 * 60, end: 17 * 60 + 30),
        Item(title: "晚餐", kind: .meal, weekdays: Array(0...6), start: 18 * 60 + 30, end: 19 * 60 + 15),
        Item(title: "运动", kind: .exercise, weekdays: [1, 3, 5], start: 17 * 60 + 30, end: 18 * 60 + 30),
    ]
}
