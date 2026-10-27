import Foundation
import SwiftData

// 所有属性都带默认值，方便以后 SwiftData 轻量迁移。注意：
// - 属性改名必须加 @Attribute(originalName:)，否则轻量迁移会把旧列整列清空；
// - 新属性的默认值只在迁移时算一次，对所有旧行是同一个常量（例如 UUID().uuidString、Date() 会让旧行全都相同）。
// 以后要上 VersionedSchema / MigrationPlan 时，先用 APT_STORE_DIR 在正式库的副本上验证（应用打开新构建前也会自动留“升级前”备份）。
// 日期统一存为 `YYYY-MM-DD` 字符串（与旧版一致，避免时区换算误差）；时间存为“当天第几分钟”。

// MARK: - 个人档案

@Model
final class Profile {
    var legacyID: String?
    /// 字段 key 与旧版 profile 完全一致（见 ProfileCatalog），未知字段也原样保存在这里。
    var fields: [String: String] = [:]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(fields: [String: String] = [:], legacyID: String? = nil) {
        self.fields = fields
        self.legacyID = legacyID
    }

    subscript(key: String) -> String {
        get { fields[key] ?? "" }
        set {
            fields[key] = newValue
            updatedAt = Date()
        }
    }

    var displayName: String {
        for key in ["preferred_name", "nickname", "name"] {
            let value = self[key].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return "道友"
    }
}

@Model
final class Goal {
    var legacyID: String?
    var title: String = ""
    var detail: String = ""
    var category: String = ""
    /// must / should / could
    var priority: String = "should"
    /// active / paused / completed / cancelled
    var status: String = "active"
    var targetDate: String?
    var progress: Int = 0
    var notes: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(title: String) { self.title = title }

    static let statusLabels = ["active": "进行中", "paused": "暂停", "completed": "已完成", "cancelled": "已放弃"]
    static let priorityLabels = ["must": "必须", "should": "应该", "could": "可以"]
    var statusLabel: String { Goal.statusLabels[status] ?? status }
    var priorityLabel: String { Goal.priorityLabels[priority] ?? priority }
}

// MARK: - 日程与作息

@Model
final class ScheduleEvent {
    var legacyID: String?
    var title: String = ""
    var dateKey: String = ""
    /// nil 表示全天
    var startMinute: Int?
    var endMinute: Int?
    var category: String = ""
    var location: String = ""
    var notes: String = ""
    var priority: String = "should"
    var timezoneID: String = TimeZone.current.identifier
    /// none / daily / weekly / custom
    var recurrence: String = "none"
    var interval: Int = 1
    var weekdays: [Int] = []
    var repeatUntil: String?
    var stopBefore: String?
    var excludedDates: [String] = []
    /// 单次改期：`{原日期: {title,date,start_time,end_time,location,notes}}` 的 JSON
    var overridesJSON: String = ""
    /// 新版暂未使用的旧版字段，原样保留
    var extraJSON: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(title: String, dateKey: String) {
        self.title = title
        self.dateKey = dateKey
    }

    var startDay: LocalDay { LocalDay(key: dateKey) ?? .today() }
    var recurrenceKind: RecurrenceKind {
        get { RecurrenceKind(rawValue: recurrence) ?? .none }
        set { recurrence = newValue.rawValue }
    }
    var isAllDay: Bool { startMinute == nil }

    var rule: RecurrenceRule {
        RecurrenceRule(start: startDay, kind: recurrenceKind, interval: interval, weekdays: weekdays,
                       repeatUntil: repeatUntil.flatMap(LocalDay.init(key:)),
                       stopBefore: stopBefore.flatMap(LocalDay.init(key:)),
                       excluded: Set(excludedDates), overrides: OccurrencePatch.decodeMap(overridesJSON))
    }
}

@Model
final class RoutineBlock {
    var legacyID: String?
    var title: String = ""
    /// sleep / meal / study / work / exercise / rest / focus / other
    var kind: String = "other"
    /// 0 = 周一 … 6 = 周日
    var weekday: Int = 0
    var startMinute: Int = 0
    var endMinute: Int = 60
    var note: String = ""
    var createdAt: Date = Date()

    init(title: String, kind: String, weekday: Int, startMinute: Int, endMinute: Int) {
        self.title = title
        self.kind = kind
        self.weekday = weekday
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// 跨夜（例如 23:00–07:00）的作息块按“结束分钟 < 开始分钟”表示。
    var crossesMidnight: Bool { RoutineSpan.crossesMidnight(start: startMinute, end: endMinute) }
    var durationMinutes: Int { crossesMidnight ? 24 * 60 - startMinute + endMinute : endMinute - startMinute }

    /// 这些作息在某天（0 = 周一）占的各段：跨夜的切成当天尾段与次日头段（carried），切法见 RoutineSpan
    static func segments(_ blocks: [RoutineBlock], weekday: Int) -> [(block: RoutineBlock, start: Int, end: Int, carried: Bool)] {
        RoutineSpan.segments(blocks.map { ($0.weekday, $0.startMinute, $0.endMinute) }, weekday: weekday)
            .map { (blocks[$0.index], $0.start, $0.end, $0.carried) }
    }
}

// MARK: - 习惯

@Model
final class Habit {
    var legacyID: String?
    var title: String = ""
    var category: String = ""
    var symbol: String = "leaf"
    /// daily / weekly / weekdays
    var frequency: String = "daily"
    var targetPerWeek: Int = 1
    var weekdays: [Int] = []
    var targetValue: Double?
    var unit: String = ""
    var startDate: String = LocalDay.today().key
    var archived: Bool = false
    /// 归档的那一天（`YYYY-MM-DD`）：此前的日子照常计入“功课圆满”；旧数据为 nil
    var archivedAt: String?
    var notes: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \HabitLog.habit)
    var logs: [HabitLog]? = []

    init(title: String) { self.title = title }

    var frequencyKind: HabitFrequency {
        get { HabitFrequency(rawValue: frequency) ?? .daily }
        set { frequency = newValue.rawValue }
    }

    var spec: HabitSpec {
        HabitSpec(frequency: frequencyKind, targetPerWeek: targetPerWeek, weekdays: weekdays,
                  targetValue: (targetValue ?? 0) > 0 ? targetValue : nil,
                  startDay: LocalDay(key: startDate) ?? LocalDay(date: createdAt),
                  createdDay: LocalDay(date: createdAt),
                  archivedDay: archived ? archivedAt.flatMap(LocalDay.init(key:)) : nil)
    }

    var logValues: [HabitLogValue] {
        (logs ?? []).compactMap { log in
            LocalDay(key: log.dateKey).map {
                HabitLogValue(day: $0, completed: log.completed, quantity: log.quantity, target: log.targetAtLog)
            }
        }
    }

    func stats(today: LocalDay = .today()) -> HabitStats { HabitStats(spec: spec, logs: logValues, today: today) }

    func log(on day: LocalDay) -> HabitLog? {
        // 日期字符串先算好：不在闭包里每比一条就重新拼一次
        let key = day.key
        return (logs ?? []).first { $0.dateKey == key }
    }

    /// 最近的 count 条打卡（按日期从新到旧，同一天的保持原来的先后）。
    /// 结果与“全部按日期排序再取前 count 条”相同，但每条只读一次日期、只留下最新的几条，不把全部打卡排序。
    func recentLogs(_ count: Int) -> [HabitLog] {
        guard count > 0 else { return [] }
        var top: [(key: String, log: HabitLog)] = []
        for log in logs ?? [] {
            let key = log.dateKey
            if top.count == count, let last = top.last, key <= last.key { continue }
            top.insert((key, log), at: top.firstIndex { $0.key < key } ?? top.count)
            if top.count > count { top.removeLast() }
        }
        return top.map(\.log)
    }
}

@Model
final class HabitLog {
    var legacyID: String?
    var dateKey: String = ""
    var completed: Bool = true
    var quantity: Double?
    var durationMinutes: Int?
    /// 打卡当时的数量目标（改目标前补记）：0 表示当时没有数量目标；nil 表示沿用习惯当前的目标
    var targetAtLog: Double?
    var notes: String = ""
    var habit: Habit?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(dateKey: String, completed: Bool = true, quantity: Double? = nil) {
        self.dateKey = dateKey
        self.completed = completed
        self.quantity = quantity
    }
}

// MARK: - 设置、AI 建议、旧版存档

@Model
final class AppSettings {
    var timezoneID: String = TimeZone.current.identifier
    var realms: [String] = CultivationConfig.defaultRealms
    var thresholds: [Int] = CultivationConfig.defaultThresholds
    var dailyCap: Int = 150
    var cultivationEnabled: Bool = true
    var motionEnabled: Bool = true
    var bufferBeforeMinutes: Int = 0
    var bufferAfterMinutes: Int = 0
    var aiPreamble: String = SummaryRenderer.defaultPreamble
    /// export（仅导出）；以后接入 API 时在这里记录所选服务
    var aiProvider: String = "export"
    var createdAt: Date = Date()

    init() {}

    var cultivation: CultivationConfig {
        get { CultivationConfig(realms: realms, thresholds: thresholds, dailyCap: dailyCap, enabled: cultivationEnabled) }
        set {
            realms = newValue.realms
            thresholds = newValue.thresholds
            dailyCap = newValue.dailyCap
            cultivationEnabled = newValue.enabled
        }
    }
}

@Model
final class AdviceRecord {
    var createdAt: Date = Date()
    var title: String = ""
    /// 发给 AI 的摘要原文
    var summary: String = ""
    /// AI 的回复（手动粘贴或由 API 返回）
    var response: String = ""
    var source: String = "manual"
    /// 用户自己的采纳笔记
    var decision: String = ""

    init(title: String, summary: String, response: String, source: String = "manual") {
        self.title = title
        self.summary = summary
        self.response = response
        self.source = source
    }
}

/// 旧版每一张表的每一行、每个设置项都原样存在这里（包括第一版还没有界面的财务账簿等）。
@Model
final class LegacyRecord {
    var kind: String = ""
    var legacyID: String = ""
    var json: String = ""
    var legacyCreatedAt: String = ""
    var legacyUpdatedAt: String = ""
    var importedAt: Date = Date()
    var receiptID: String = ""

    init(kind: String, legacyID: String, json: String, createdAt: String, updatedAt: String, receiptID: String) {
        self.kind = kind
        self.legacyID = legacyID
        self.json = json
        self.legacyCreatedAt = createdAt
        self.legacyUpdatedAt = updatedAt
        self.receiptID = receiptID
    }
}

@Model
final class ImportReceipt {
    var receiptID: String = UUID().uuidString
    var importedAt: Date = Date()
    var sourceKind: String = ""
    var sourcePath: String = ""
    var sha256: String = ""
    var summary: String = ""

    init(sourceKind: String, sourcePath: String, sha256: String, summary: String) {
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.sha256 = sha256
        self.summary = summary
    }
}

/// 灵石账簿：整本账以旧版同格式的 JSON 存放（FinanceLedger），读写时整体编解码，保证与旧版逐字段兼容。
@Model
final class FinanceStore {
    @Attribute(.externalStorage) var data: Data = Data()
    var updatedAt: Date = Date()

    init(data: Data) { self.data = data }
}

// MARK: - 修行录与飞剑传书

/// 修行录里的一条记录：日记、灵感或复盘。可以手动落笔，也可以由 AI 经“飞剑传书”送来。
@Model
final class JournalEntry {
    /// 稳定 ID：用于撤销传书、导出与去重
    var uid: String = UUID().uuidString
    /// diary / note / review
    var kind: String = "diary"
    var title: String = ""
    var body: String = ""
    var dateKey: String = LocalDay.today().key
    /// 可选时刻（当天第几分钟）
    var minute: Int?
    /// 心境 1–5（日记用）
    var mood: Int?
    /// 复盘周期：day / week / month / event
    var period: String = ""
    var tags: [String] = []
    /// manual / courier
    var source: String = "manual"
    /// 传书来源说明，例如“Claude”
    var sourceNote: String = ""
    var deliveryID: String = ""
    var pinned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(kind: JournalKind, title: String = "", body: String = "", dateKey: String = LocalDay.today().key) {
        self.kind = kind.rawValue
        self.title = title
        self.body = body
        self.dateKey = dateKey
    }

    var kindValue: JournalKind {
        get { JournalKind(rawValue: kind) ?? .note }
        set { kind = newValue.rawValue }
    }
    var day: LocalDay { LocalDay(key: dateKey) ?? LocalDay(date: createdAt) }
    var isFromCourier: Bool { source == "courier" }
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? kindValue.label : String(firstLine.prefix(28))
    }
}

/// 一次“飞剑传书”：AI 投进收件箱的一份文件，以及它写入了哪些记录（用于撤销）。
@Model
final class CourierDelivery {
    var deliveryID: String = UUID().uuidString
    var receivedAt: Date = Date()
    var fileName: String = ""
    var from: String = ""
    var note: String = ""
    /// 每条一行的人类可读摘要
    var summary: String = ""
    /// 写入的记录引用：`[{"type":"entry","ref":"…"}]`
    var refsJSON: String = "[]"
    var itemCount: Int = 0
    var undone: Bool = false

    init(fileName: String, from: String, note: String) {
        self.fileName = fileName
        self.from = from
        self.note = note
    }
}

enum APTSchema {
    static let models: [any PersistentModel.Type] = [
        Profile.self, Goal.self, ScheduleEvent.self, RoutineBlock.self, Habit.self, HabitLog.self,
        AppSettings.self, AdviceRecord.self, LegacyRecord.self, ImportReceipt.self, FinanceStore.self,
        JournalEntry.self, CourierDelivery.self,
    ]
}
