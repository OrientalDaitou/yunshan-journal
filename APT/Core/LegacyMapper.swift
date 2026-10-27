import Foundation

/// 把旧版快照转换为新版可直接写入的中间结构（纯值类型，不依赖 SwiftData）。
/// 无法映射的字段不会丢：原始 JSON 另存为 `LegacyRecord`，结构化记录也保留 legacyID 对应关系。
enum LegacyMapper {
    struct ProfileDTO { var legacyID: String; var fields: [String: String]; var createdAt: Date?; var updatedAt: Date? }
    struct GoalDTO {
        var legacyID: String; var title: String; var detail: String; var category: String
        var priority: String; var status: String; var targetDate: String?; var progress: Int; var notes: String
        var createdAt: Date?
    }
    struct EventDTO {
        var legacyID: String; var title: String; var dateKey: String
        var startMinute: Int?; var endMinute: Int?
        var category: String; var location: String; var notes: String; var priority: String; var timezoneID: String
        var recurrence: RecurrenceKind; var interval: Int; var weekdays: [Int]
        var repeatUntil: String?; var stopBefore: String?; var excludedDates: [String]
        var overridesJSON: String
        /// 新版暂不使用的字段（project_id、task_id、external_uid、reminder_minutes…），原样保留。
        var extraJSON: String
        var createdAt: Date?
    }
    struct HabitDTO {
        var legacyID: String; var title: String; var category: String; var frequency: HabitFrequency
        var targetPerWeek: Int; var weekdays: [Int]; var targetValue: Double?; var unit: String
        var startDate: String; var archived: Bool; var notes: String; var createdAt: Date?
    }
    struct HabitLogDTO {
        var legacyID: String; var habitLegacyID: String; var dateKey: String
        var completed: Bool; var quantity: Double?; var durationMinutes: Int?; var notes: String
    }
    struct RoutineDTO { var weekday: Int; var startMinute: Int; var endMinute: Int; var title: String; var kind: String }
    struct SettingsDTO {
        var timezoneID: String?
        var cultivation: CultivationConfig?
        var motionEnabled: Bool?
        var bufferBefore: Int?
        var bufferAfter: Int?
    }

    struct Result {
        var profiles: [ProfileDTO] = []
        var goals: [GoalDTO] = []
        var events: [EventDTO] = []
        var habits: [HabitDTO] = []
        var habitLogs: [HabitLogDTO] = []
        var routine: [RoutineDTO] = []
        var settings = SettingsDTO()
        var warnings: [String] = []
    }

    static func map(_ snapshot: LegacySnapshot) -> Result {
        var result = Result()
        for row in snapshot.collections["profile"] ?? [] {
            var fields: [String: String] = [:]
            for (key, value) in row.object where !["id", "created_at", "updated_at"].contains(key) {
                fields[key] = stringValue(value)
            }
            result.profiles.append(ProfileDTO(legacyID: row.id, fields: fields,
                                              createdAt: timestamp(row.createdAt), updatedAt: timestamp(row.updatedAt)))
        }
        for row in snapshot.collections["goals"] ?? [] {
            let o = row.object
            result.goals.append(GoalDTO(
                legacyID: row.id, title: str(o["title"], "未命名目标"), detail: str(o["description"]),
                category: str(o["category"]), priority: str(o["priority"], "should"), status: str(o["status"], "active"),
                targetDate: optionalDay(o["target_date"]), progress: int(o["progress"]) ?? 0, notes: str(o["notes"]),
                createdAt: timestamp(row.createdAt)))
        }
        for row in snapshot.collections["calendar"] ?? [] {
            let o = row.object
            guard let date = optionalDay(o["date"]) else {
                result.warnings.append("日程「\(str(o["title"]))」日期无效，仅保留在旧版存档中")
                continue
            }
            let known: Set<String> = ["title", "date", "start_time", "end_time", "category", "location", "notes", "priority",
                                      "timezone", "recurrence", "weekdays", "interval", "repeat_until", "excluded_dates",
                                      "occurrence_overrides", "stop_before", "id", "created_at", "updated_at"]
            let extra = o.filter { !known.contains($0.key) && !($0.value is NSNull) }
            var overrides = ""
            if let raw = o["occurrence_overrides"] as? [String: Any], !raw.isEmpty { overrides = LegacyReader.jsonText(raw) }
            result.events.append(EventDTO(
                legacyID: row.id, title: str(o["title"], "未命名日程"), dateKey: date,
                startMinute: ClockTime.minutes(from: o["start_time"] as? String),
                endMinute: ClockTime.minutes(from: o["end_time"] as? String, allowEndOfDay: true),
                category: str(o["category"]), location: str(o["location"]), notes: str(o["notes"]),
                priority: str(o["priority"], "should"), timezoneID: str(o["timezone"], TimeZone.current.identifier),
                recurrence: RecurrenceKind(rawValue: str(o["recurrence"], "none")) ?? .none,
                interval: max(1, int(o["interval"]) ?? 1), weekdays: intArray(o["weekdays"]),
                repeatUntil: optionalDay(o["repeat_until"]), stopBefore: optionalDay(o["stop_before"]),
                excludedDates: (o["excluded_dates"] as? [String]) ?? [], overridesJSON: overrides,
                extraJSON: extra.isEmpty ? "" : LegacyReader.jsonText(extra), createdAt: timestamp(row.createdAt)))
        }
        for row in snapshot.collections["habits"] ?? [] {
            let o = row.object
            let created = timestamp(row.createdAt)
            let fallbackStart = created.map { LocalDay(date: $0).key } ?? LocalDay.today().key
            let target = double(o["target_value"])
            result.habits.append(HabitDTO(
                legacyID: row.id, title: str(o["title"], "未命名习惯"), category: str(o["category"]),
                frequency: HabitFrequency(rawValue: str(o["frequency"], "daily")) ?? .daily,
                targetPerWeek: min(7, max(1, int(o["target_per_week"]) ?? 1)), weekdays: intArray(o["weekdays"]),
                targetValue: (target ?? 0) > 0 ? target : nil, unit: str(o["unit"]),
                startDate: optionalDay(o["start_date"]) ?? fallbackStart, archived: o["archived"] as? Bool ?? false,
                notes: str(o["notes"]), createdAt: created))
        }
        for row in snapshot.collections["habit_logs"] ?? [] {
            let o = row.object
            guard let habitID = o["habit_id"] as? String, let date = optionalDay(o["date"]) else {
                result.warnings.append("一条打卡记录缺少习惯或日期，仅保留在旧版存档中")
                continue
            }
            result.habitLogs.append(HabitLogDTO(
                legacyID: row.id, habitLegacyID: habitID, dateKey: date, completed: o["completed"] as? Bool ?? false,
                quantity: double(o["quantity"]), durationMinutes: int(o["duration_minutes"]), notes: str(o["notes"])))
        }

        // 设置
        if let tz = snapshot.settingObject("timezone") as? String, TimeZone(identifier: tz) != nil {
            result.settings.timezoneID = tz
        }
        if let v2 = snapshot.settingObject("apt_v2") as? [String: Any] {
            if let c = v2["cultivation"] as? [String: Any] {
                var config = CultivationConfig()
                if let realms = c["realms"] as? [String] { config.realms = realms }
                if let thresholds = c["thresholds"] as? [Any] { config.thresholds = thresholds.compactMap(int) }
                if let cap = int(c["daily_cap"]) { config.dailyCap = cap }
                if let enabled = c["enabled"] as? Bool { config.enabled = enabled }
                if config.sanitized != config { result.warnings.append("旧版境界设置不完整，已使用默认九境") }
                result.settings.cultivation = config.sanitized
            }
            if let motion = v2["motion"] as? String { result.settings.motionEnabled = motion != "off" && motion != "reduced" }
        }
        if let planning = snapshot.settingObject("planning_preferences") as? [String: Any] {
            result.settings.bufferBefore = int(planning["buffer_before_minutes"])
            result.settings.bufferAfter = int(planning["buffer_after_minutes"])
            for (weekday, windows) in ((planning["week"] as? [Any]) ?? []).enumerated() where weekday < 7 {
                for window in (windows as? [[String: Any]]) ?? [] {
                    guard let s = ClockTime.minutes(from: window["start"] as? String),
                          let e = ClockTime.minutes(from: window["end"] as? String, allowEndOfDay: true), e > s else { continue }
                    result.routine.append(RoutineDTO(weekday: weekday, startMinute: s, endMinute: e, title: "可安排时段", kind: "focus"))
                }
            }
        }
        return result
    }

    // MARK: 小工具

    static func stringValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case is NSNull: return ""
        default: return LegacyReader.jsonText(value)
        }
    }

    private static func str(_ value: Any?, _ fallback: String = "") -> String {
        guard let s = value as? String else { return fallback }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : s
    }

    /// JSONSerialization 的 0 / 1 也能被当作 Bool；用 CoreFoundation 类型区分真正的布尔值。
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, !isBoolean(n) { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !isBoolean(n) { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func intArray(_ value: Any?) -> [Int] {
        ((value as? [Any]) ?? []).compactMap(int).filter { (0...6).contains($0) }
    }

    private static func optionalDay(_ value: Any?) -> String? {
        guard let s = value as? String, let day = LocalDay(key: s) else { return nil }
        return day.key
    }

    static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
