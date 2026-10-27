import Foundation

enum RecurrenceKind: String, CaseIterable, Codable, Identifiable {
    case none, daily, weekly, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "不重复"
        case .daily: "每隔 N 天"
        case .weekly: "每隔 N 周（同一星期）"
        case .custom: "每隔 N 周（指定星期）"
        }
    }
}

/// 单次改期（旧版 `occurrence_overrides` 的一项），只允许修改这些字段。
struct OccurrencePatch: Codable, Equatable {
    var title: String?
    var date: String?
    var start_time: String?
    var end_time: String?
    var location: String?
    var notes: String?

    static func decodeMap(_ json: String) -> [String: OccurrencePatch] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: OccurrencePatch].self, from: data)) ?? [:]
    }
}

/// 日程重复规则。语义与旧版 `PersonalService._calendar_matches` 完全一致：
/// - daily：距开始日期的天数能被 interval 整除；
/// - weekly / custom：星期在 weekdays 中（为空时取开始日期的星期），且以“周一”为锚点的周差能被 interval 整除；
/// - repeat_until 为包含边界，stop_before 为排他边界，excluded_dates 跳过某一次。
struct RecurrenceRule {
    var start: LocalDay
    var kind: RecurrenceKind
    var interval: Int = 1
    var weekdays: [Int] = []
    var repeatUntil: LocalDay?
    var stopBefore: LocalDay?
    var excluded: Set<String> = []
    var overrides: [String: OccurrencePatch] = [:]

    func matches(_ day: LocalDay) -> Bool {
        if let stopBefore, day >= stopBefore { return false }
        if day < start { return false }
        if let repeatUntil, day > repeatUntil { return false }
        let step = max(1, interval)
        let delta = start.days(to: day)
        switch kind {
        case .none:
            return delta == 0
        case .daily:
            return delta % step == 0
        case .weekly, .custom:
            let weeks = start.mondayOfWeek.days(to: day.mondayOfWeek) / 7
            let days = weekdays.isEmpty ? [start.weekdayIndex] : weekdays
            return days.contains(day.weekdayIndex) && weeks % step == 0
        }
    }

    struct Occurrence: Hashable {
        /// 按规则计算出的原始日期（删除“本次”、单次改期都以它为键）。
        var sourceDay: LocalDay
        /// 实际显示日期（可能被单次改期改到别的日子）。
        var scheduledDay: LocalDay
        var isOverride: Bool
    }

    /// 返回在 [first, last] 内“显示日期”落入范围的所有发生（按原日期升序）。
    func occurrences(from first: LocalDay, to last: LocalDay) -> [Occurrence] {
        guard first <= last else { return [] }
        // 没有单次改期的发生显示在原日期，只需逐日检查 [first, last]；被改期挪进来（或挪出去）的发生，
        // 原日期一定是 overrides 的键，另外单独检查。“删除本次”与改期都以原日期的 `YYYY-MM-DD` 为键，
        // 先换成 LocalDay，免得每个候选日都拼一次字符串（只认规范写法，与按字符串比较的结果完全一致）。
        var skipped = Set<LocalDay>()
        for key in excluded { if let d = LocalDay(key: key), d.key == key { skipped.insert(d) } }
        var patches: [LocalDay: OccurrencePatch] = [:]
        var extra = Set<LocalDay>()
        for (key, patch) in overrides {
            guard let d = LocalDay(key: key) else { continue }
            extra.insert(d)
            if d.key == key { patches[d] = patch }
        }

        var span: ClosedRange<Int>?
        if kind == .none {
            extra.insert(start)
        } else {
            let lower = max(first, start)
            var upper = last
            if let repeatUntil { upper = min(upper, repeatUntil) }
            if lower <= upper { span = lower.jdn...upper.jdn }
        }
        if let span { extra = extra.filter { !span.contains($0.jdn) } }

        var result: [Occurrence] = []
        func visit(_ day: LocalDay) {
            guard matches(day), !skipped.contains(day) else { return }
            let patch = patches[day]
            let scheduled = patch?.date.flatMap(LocalDay.init(key:)) ?? day
            guard scheduled >= first, scheduled <= last else { return }
            result.append(Occurrence(sourceDay: day, scheduledDay: scheduled, isOverride: patch != nil))
        }
        let others = extra.sorted()
        var index = 0
        if let span {
            while index < others.count, others[index].jdn < span.lowerBound { visit(others[index]); index += 1 }
            for jdn in span { visit(LocalDay(jdn: jdn)) }
        }
        while index < others.count { visit(others[index]); index += 1 }
        return result
    }

    /// 重复方式的一句话（“每周一、四，至 11月7日”），止日相对今天写：不是今年的带年份
    var summary: String { summary(relativeTo: .today()) }

    func summary(relativeTo today: LocalDay) -> String {
        let step = max(1, interval)
        var text: String
        switch kind {
        case .none:
            return "不重复"
        case .daily:
            text = step == 1 ? "每天" : "每 \(step) 天"
        case .weekly, .custom:
            // “每周一、四”，不写成“每周周一、周四”；连着三天以上写“每周一至五”，七天都有写“每天”
            let days = Array(Set(weekdays.isEmpty ? [start.weekdayIndex] : weekdays.filter { (0..<7).contains($0) })).sorted()
            let names = days.map { LocalDay.weekdayShortNames[$0] }
            let run = days.count >= 3 && days.last! - days.first! == days.count - 1
            let list = run ? "\(names.first!)至\(names.last!)" : names.joined(separator: "、")
            if step == 1, days.count == 7 {
                text = "每天"
            } else {
                text = (step == 1 ? "每周" : "每 \(step) 周的周") + list
            }
        }
        if let repeatUntil { text += "，至 \(repeatUntil.label(relativeTo: today))" }
        if let stopBefore { text += "（\(stopBefore.label(relativeTo: today)) 起停止）" }
        return text
    }
}

// MARK: - 单次改期与拆分系列

/// 单次改期的写入：按 JSON 合并写回，旧版改期里新版不认识的字段原样保留。
/// 纯字符串进出（不碰数据模型），CoreCheck 能直接测；界面里写进日程的那一层在 OccurrenceEditor.swift。
enum OccurrenceOverrides {
    /// 把某一次的单次改期合并进 overridesJSON，返回新的 JSON（patch 为 nil 或各字段都为空时删掉这一次；全删光时是空字符串）。
    /// key 是这一次按规则算出的原始日期。原 JSON 无法解析时返回 nil（调用方应不作改动）。
    static func write(_ patch: OccurrencePatch?, for key: String, into json: String) -> String? {
        var map: [String: Any] = [:]
        if !json.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
            map = object
        }
        let values: [(name: String, value: String?)] = [
            ("title", patch?.title), ("date", patch?.date), ("start_time", patch?.start_time),
            ("end_time", patch?.end_time), ("location", patch?.location), ("notes", patch?.notes),
        ]
        if values.allSatisfy({ $0.value == nil }) {
            map.removeValue(forKey: key)
        } else {
            var entry = map[key] as? [String: Any] ?? [:]
            for field in values {
                if let value = field.value { entry[field.name] = value } else { entry.removeValue(forKey: field.name) }
            }
            map[key] = entry
        }
        guard !map.isEmpty else { return "" }
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// “从这次起修改”把重复系列拆成两段：这一天（这一次的原定日期）之前留在原日程，这一天及以后归新日程。
enum SeriesSplit {
    /// 跳过 / 单次改期的键（原定日期）是否归新的一段；认不出的键留在原日程
    static func movesToNew(_ key: String, from day: LocalDay) -> Bool {
        guard let keyDay = LocalDay(key: key) else { return false }
        return keyDay >= day
    }

    /// 把单次改期的 JSON 按键（原定日期）切成两半，旧版不认识的字段原样保留。
    /// 原 JSON 无法解析时返回 nil（调用方应拒绝拆分、不作改动）。
    static func partitionOverrides(_ json: String, at day: LocalDay) -> (before: String, after: String)? {
        guard !json.isEmpty else { return ("", "") }
        guard let map = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        func encode(_ part: [String: Any]) -> String? {
            guard !part.isEmpty else { return "" }
            guard let data = try? JSONSerialization.data(withJSONObject: part, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        guard let before = encode(map.filter { !movesToNew($0.key, from: day) }),
              let after = encode(map.filter { movesToNew($0.key, from: day) }) else { return nil }
        return (before, after)
    }
}
