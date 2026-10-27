import Foundation

// 飞剑传书的两种新类型：goal（新立目标，或按名称更新进度、状态、期限、备注）、habit（新建习惯）。
// 这里只放纯逻辑：解析与校验、名称匹配、整封预检、撤销用的值快照、摘要行的生成与反解析、收录条数。
// 要碰 SwiftData 的写入、撤销、去重在 Services/CourierGoalHabitStore.swift（文件名不能与本文件相同：同一 target 里不能有两个同名 .swift）。

/// 目标的状态与优先级（与 Models 里 Goal.statusLabels / priorityLabels 一致，SelfTest 核对）
enum GoalCatalog {
    static let statuses = ["active", "paused", "completed", "cancelled"]
    static let statusLabels: [String: String] = ["active": "进行中", "paused": "暂停", "completed": "已完成", "cancelled": "已放弃"]
    static let priorities = ["must", "should", "could"]
    static let priorityLabels: [String: String] = ["must": "必须", "should": "应该", "could": "可以"]

    private static let statusWords: [String: String] = [
        "active": "active", "进行中": "active",
        "paused": "paused", "暂停": "paused",
        "completed": "completed", "已完成": "completed", "完成": "completed",
        "cancelled": "cancelled", "canceled": "cancelled", "已放弃": "cancelled", "放弃": "cancelled",
    ]
    private static let priorityWords: [String: String] = [
        "must": "must", "必须": "must", "should": "should", "应该": "should", "could": "could", "可以": "could",
    ]

    /// "completed" / "已完成" / "完成" … → "completed"；认不出 nil
    static func status(from text: String) -> String? { statusWords[text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }
    static func priority(from text: String) -> String? { priorityWords[text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }
    /// 状态的中文；认不出的原样返回
    static func statusLabel(_ status: String) -> String { statusLabels[status] ?? status }
}

/// 习惯图标（顺序与 HabitEditor.symbols 相同，SelfTest 核对）
enum HabitIcons {
    /// 每个图标的中文关键字：名称或 icon 里包含其中任何一个就算这个图标。按表的顺序匹配，第一个命中的生效
    /// （所以“论文写作”先命中“写”，得到 pencil.and.scribble）
    static let keywords: [(symbol: String, words: [String])] = [
        ("leaf", ["叶", "生活", "默认"]),
        ("book", ["书", "阅读", "读", "晨读"]),
        ("figure.run", ["跑", "运动", "步数", "散步"]),
        ("drop", ["水", "喝水"]),
        ("moon.zzz", ["睡", "早睡", "睡眠"]),
        ("brain.head.profile", ["冥想", "专注", "思考", "正念"]),
        ("pencil.and.scribble", ["写", "写作", "日记", "论文写作"]),
        ("dumbbell", ["健身", "力量", "举铁"]),
        ("fork.knife", ["饭", "做饭", "饮食", "早餐"]),
        ("cup.and.saucer", ["茶", "咖啡", "休息"]),
        ("music.note", ["琴", "音乐", "练琴", "唱"]),
        ("globe.asia.australia", ["单词", "外语", "英语", "语言"]),
        ("heart", ["心", "感恩", "健康"]),
        ("sun.max", ["早起", "晨", "阳光"]),
        ("graduationcap", ["学习", "课", "文献", "复习"]),
    ]
    static let all: [String] = keywords.map(\.symbol)
    /// 给 AI 看的中文名（README 与回执里列可用图标时用），与 all 一一对应
    static let labels: [String] = ["叶", "书", "跑步", "喝水", "睡眠", "冥想", "写作", "健身", "饮食", "茶", "音乐", "外语", "健康", "早起", "学习"]
    /// “leaf 叶、book 书、figure.run 跑步、…”
    static let choices: String = zip(all, labels).map { "\($0) \($1)" }.joined(separator: "、")

    /// 图标名或中文关键字 → 图标；认不出 nil
    static func resolve(_ text: String) -> String? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if all.contains(key) { return key }
        return match(key)
    }

    /// 按习惯名猜图标，猜不到 "leaf"
    static func guess(title: String) -> String { match(title.lowercased()) ?? "leaf" }

    private static func match(_ text: String) -> String? {
        keywords.first { entry in entry.words.contains { text.contains($0) } }?.symbol
    }
}

/// 名称匹配（打卡、习惯、目标共用；CourierService.matchIndex 改为调用 index）
enum NameMatch {
    /// 比较用的写法：去掉首尾空白（含全角空格），再转小写。与原来的 CourierService.matchIndex 相同
    static func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces).lowercased() }

    /// 先找完全相同的，再找唯一一个互相包含的（打卡找习惯用）
    static func index(_ name: String, titles: [String]) -> Int? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        let keys = titles.map(key)
        if let exact = keys.firstIndex(of: k) { return exact }
        let partial = contains(k, keys)
        return partial.count == 1 ? partial[0] : nil
    }

    /// 只认完全相同的（不分大小写、不计首尾空白）
    static func exact(_ name: String, titles: [String]) -> Int? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        return titles.firstIndex { key($0) == k }
    }

    /// 名字互相包含、但不完全相同的那些（新习惯与现有习惯“名字互相包含”的提醒用）
    static func related(_ name: String, titles: [String]) -> [Int] {
        let k = key(name)
        guard !k.isEmpty else { return [] }
        let keys = titles.map(key)
        return contains(k, keys).filter { keys[$0] != k }
    }

    enum GoalResult: Equatable { case found(Int), ambiguous([Int]), none }

    /// 找要更新的目标，依次四层：未放弃的完全相同 → 已放弃的完全相同 → 未放弃的唯一互相包含 → 已放弃的唯一互相包含。
    /// 某一层出现 2 个或以上就是“能对上多个”，四层都没有就是“找不到”
    static func goal(_ name: String, in goals: [(title: String, status: String)]) -> GoalResult {
        let k = key(name)
        guard !k.isEmpty else { return .none }
        let keys = goals.map { key($0.title) }
        let open = goals.indices.filter { goals[$0].status != "cancelled" }
        let dropped = goals.indices.filter { goals[$0].status == "cancelled" }
        let layers: [[Int]] = [
            open.filter { keys[$0] == k },
            dropped.filter { keys[$0] == k },
            open.filter { !keys[$0].isEmpty && (keys[$0].contains(k) || k.contains(keys[$0])) },
            dropped.filter { !keys[$0].isEmpty && (keys[$0].contains(k) || k.contains(keys[$0])) },
        ]
        for layer in layers where !layer.isEmpty {
            return layer.count == 1 ? .found(layer[0]) : .ambiguous(layer)
        }
        return .none
    }

    private static func contains(_ k: String, _ keys: [String]) -> [Int] {
        keys.indices.filter { !keys[$0].isEmpty && (keys[$0].contains(k) || k.contains(keys[$0])) }
    }
}

/// 目标期限：不改 / 改成某天 / 取消期限（只在 update 时出现）
enum GoalDeadline: Equatable { case keep, set(LocalDay), clear }

struct CourierGoal: Equatable {
    enum Action: String { case create, update }
    var action: Action
    var title: String
    var detail = ""
    var category = ""
    var priority = "should"            // 只在 create 时用
    var status: String?                // create：nil = active；update：nil = 不改
    var progress: Int?                 // create：nil = 0；status 为 completed 时解析阶段已置 100
    var deadline: GoalDeadline = .keep
    var notes = ""                     // create：备注原文；update：要追加的一段
    var noteDay: LocalDay              // 追加备注时写的日期 = 文件写入那天（不进 canonical）

    /// create：CourierLineDecor.goalCreateLine（“目标 · 新立「T」（期限 …，必须）”）；
    /// update（还不知道旧值）：“目标 · 更新「T」：进度 → 70%；状态 → 已完成；期限 → 12月31日；备注 +「…」”。--add 打印它
    var summary: String {
        action == .create ? CourierLineDecor.goalCreateLine(self, today: noteDay) : CourierLineDecor.goalPlanLine(self, today: noteDay)
    }

    /// 判重复用（CourierItem.canonical 前面再加 "goal"）：空白折叠、标题小写、空值写 ""。不放 noteDay：
    /// 备注前的日期是应用加的，同一段备注 7 天内隔天重投也应按重复跳过
    var canonicalParts: [String] {
        let day: String
        switch deadline {
        case .keep: day = ""
        case .set(let d): day = d.key
        case .clear: day = "none"
        }
        return [action.rawValue, folded(title).lowercased(), folded(detail), folded(category), priority, status ?? "",
                progress.map(String.init) ?? "", day, folded(notes)]
    }

    /// 追加进目标备注的那一段：“2026年10月21日：内容”（一律带年份：备注会一直留着，跨年后不带年份分不清）
    var notePrefix: String { "\(noteDay.year)年\(noteDay.shortLabel)：" }
}

struct CourierHabit: Equatable {
    var title: String
    var frequency: HabitFrequency
    var timesPerWeek: Int              // weekly 时 1–7，其余 1
    var weekdays: [Int]                // 0 = 周一 … 6 = 周日，升序去重；非 weekdays 为空
    var target: Double?
    var unit: String                   // 没有 target 时为空
    var startDay: LocalDay
    var category: String
    var symbol: String
    var notes: String
    /// = CourierLineDecor.habitCreateLine(self, today: 文件写入那天)：“功课 · 新立「冥想」（每天，每次 10分钟，自 10月21日 起）”。
    /// 解析时填好（日期写不写年份要看写入那天，结构体里没存那天）
    var summary = ""

    /// 计算属性，不存：HabitSpec 不是 Equatable，存成属性会让本结构体的 Equatable 合成不了
    var spec: HabitSpec { HabitSpec(frequency: frequency, targetPerWeek: timesPerWeek, weekdays: weekdays, targetValue: target, startDay: startDay) }
    /// “每天，每次 10分钟”（写法同 SummaryCollector.targetText）
    var scheduleText: String { spec.scheduleSummary + (target.map { "，每次 \(plainNumber($0))\(unit)" } ?? "") }
    var canonicalParts: [String] {
        [folded(title).lowercased(), frequency.rawValue, String(timesPerWeek), weekdays.map(String.init).joined(separator: ","),
         target.map(plainNumber) ?? "", folded(unit), startDay.key, folded(category), symbol, folded(notes)]
    }
}

/// 空白折叠（与 CourierItem.canonical 里的一样）
private func folded(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

/// 数量的写法：整数不带小数点（与 CourierService.format 相同；Core 不能引用 Services，这里另写一份）
private func plainNumber(_ value: Double) -> String {
    value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
}

// MARK: - 解析

extension CourierParser {
    static let goalFields = ["action", "title", "detail", "category", "priority", "status", "progress", "target_date", "notes"]
    static let habitFields = ["title", "frequency", "times_per_week", "weekdays", "target", "unit", "start_date", "category", "icon", "notes"]
    static let goalAliases: [String: String] = [
        "name": "title", "goal": "title", "description": "detail", "desc": "detail",
        "deadline": "target_date", "due": "target_date", "due_date": "target_date", "targetDate": "target_date",
        "note": "notes", "memo": "notes", "state": "status", "percent": "progress", "mode": "action",
    ]
    static let habitAliases: [String: String] = [
        "name": "title", "habit": "title", "freq": "frequency",
        "per_week": "times_per_week", "times": "times_per_week", "timesPerWeek": "times_per_week", "days": "weekdays",
        "target_value": "target", "quantity": "target", "amount": "target", "goal": "target",
        "start": "start_date", "startDate": "start_date", "start_day": "start_date", "symbol": "icon", "note": "notes",
    ]
    static let goalTitleLimit = 60
    static let goalTextLimit = 500
    static let habitTitleLimit = 30
    static let habitUnitLimit = 10
    static let habitCategoryLimit = 20

    /// d 已经过 normalized（别名已换成正式名）；label 把正式字段名换成“AI 实际写的字段（按 x 理解）”
    static func goal(_ d: [String: Any], base: LocalDay, label: (String) -> String,
                     notes: inout [String]) throws -> (item: CourierGoal, relative: Bool) {
        let action: CourierGoal.Action
        switch string(d["action"]).lowercased() {
        case "", "create", "new", "add", "新立", "新建": action = .create
        case "update", "edit", "更新": action = .update
        default: throw CourierError.invalid("\(label("action")) 应为 create（新立）或 update（更新），收到「\(string(d["action"]))」")
        }
        let creating = action == .create
        let title = CourierItem.oneLine(string(d["title"]))
        guard !title.isEmpty else { throw CourierError.invalid("goal 需要 title（目标名称，例如“完成学位论文初稿”）") }
        // update 的 title 只用来找目标：用户在应用里起的名字可能更长，不设上限
        if creating, title.count > goalTitleLimit {
            throw CourierError.invalid("\(label("title")) 太长（\(title.count) 字，上限 \(goalTitleLimit)）：细节请写进 detail")
        }
        if d["date"] != nil { notes.append("goal 不用 date（期限请写 target_date），已忽略") }

        var status: String?
        let statusText = string(d["status"])
        if !statusText.isEmpty {
            guard let value = GoalCatalog.status(from: statusText) else {
                throw CourierError.invalid("\(label("status")) 应为 active / paused / completed / cancelled（进行中 / 暂停 / 已完成 / 已放弃）")
            }
            if creating, value == "cancelled" { throw CourierError.invalid("新立的目标不能是 cancelled（已放弃）") }
            status = value
        }
        var progress = try goalProgress(d["progress"], field: label("progress"), notes: &notes)
        if status == "completed" {
            if let p = progress, p < 100 { notes.append("status 是 completed，进度已按 100% 记") }
            progress = 100
        } else if creating, status == nil, progress == 100 {
            // update 的同一句提醒要看目标现在的状态，由 CourierRoster.resolve 给
            notes.append(#"progress 是 100，但状态没改（仍是进行中）；要标记完成请写 "status": "completed""#)
        }
        let (deadline, relative) = try goalDeadline(d["target_date"], field: label("target_date"), creating: creating, base: base, notes: &notes)

        let noteText = string(d["notes"])
        guard noteText.count <= goalTextLimit else {
            throw CourierError.invalid("\(label("notes")) 太长（\(noteText.count) 字，上限 \(goalTextLimit)）：长的进展请另投一条 review 或 note")
        }
        let detail = string(d["detail"]), category = string(d["category"]), priorityText = string(d["priority"])
        var priority = "should"
        if creating {
            guard detail.count <= goalTextLimit else {
                throw CourierError.invalid("\(label("detail")) 太长（\(detail.count) 字，上限 \(goalTextLimit)）")
            }
            if !priorityText.isEmpty {
                guard let value = GoalCatalog.priority(from: priorityText) else {
                    throw CourierError.invalid("\(label("priority")) 应为 must / should / could（必须 / 应该 / 可以）")
                }
                priority = value
            }
        } else {
            guard progress != nil || status != nil || deadline != .keep || !noteText.isEmpty else {
                throw CourierError.invalid("update 至少要写 progress、status、target_date、notes 中的一项")
            }
            let ignored = [("detail", detail), ("category", category), ("priority", priorityText)].filter { !$0.1.isEmpty }.map { label($0.0) }
            if !ignored.isEmpty {
                notes.append("update 只改 progress / status / target_date / notes，\(ignored.joined(separator: "、")) 已忽略")
            }
        }
        let goal = CourierGoal(action: action, title: title, detail: creating ? detail : "", category: creating ? category : "",
                               priority: priority, status: status, progress: progress, deadline: deadline, notes: noteText, noteDay: base)
        return (goal, relative)
    }

    /// d 已经过 normalized；label 同 goal
    static func habit(_ d: [String: Any], base: LocalDay, label: (String) -> String,
                      notes: inout [String]) throws -> (item: CourierHabit, relative: Bool) {
        let title = CourierItem.oneLine(string(d["title"]))
        guard !title.isEmpty else { throw CourierError.invalid("habit 需要 title（习惯名称，例如“冥想”）") }
        guard title.count <= habitTitleLimit else {
            throw CourierError.invalid("\(label("title")) 太长（\(title.count) 字，上限 \(habitTitleLimit)）")
        }

        // 频率：没写时按写了的 weekdays / times_per_week 推断
        let frequencyText = string(d["frequency"])
        let inferred = frequencyText.isEmpty
        var frequency: HabitFrequency
        if inferred {
            frequency = present(d["weekdays"]) ? .weekdays : present(d["times_per_week"]) ? .weekly : .daily
            if frequency == .weekdays { notes.append("没写 frequency，按 weekdays 记为“指定星期”") }
        } else {
            guard let value = habitFrequency(frequencyText) else {
                throw CourierError.invalid("\(label("frequency")) 应为 daily / weekly / weekdays（每天 / 每周 N 次 / 指定星期），收到「\(frequencyText)」")
            }
            frequency = value
        }
        var timesPerWeek = 1
        if frequency == .weekly {
            guard present(d["times_per_week"]) else { throw CourierError.invalid("weekly 需要 times_per_week（每周几次，1–7）") }
            guard let value = try? number(d["times_per_week"], field: "times_per_week"), value >= 1, value <= 7, value.rounded() == value else {
                throw CourierError.invalid("\(label("times_per_week")) 应为 1–7 的整数")
            }
            timesPerWeek = Int(value)
            if inferred { notes.append("没写 frequency，按 times_per_week 记为“每周 \(timesPerWeek) 次”") }
        } else if present(d["times_per_week"]) {
            notes.append("frequency 是 \(frequency.rawValue)，\(label("times_per_week")) 已忽略")
        }
        var days: [Int] = []
        if frequency == .weekdays {
            guard present(d["weekdays"]) else { throw CourierError.invalid(#"weekdays 频率需要 weekdays，例如 ["周一", "周三", "周五"]"#) }
            days = try weekdays(d["weekdays"], field: label("weekdays"))
            if days.count == 7 {
                frequency = .daily
                days = []
                notes.append("weekdays 选了全部 7 天，已按 daily（每天）记")
            }
        } else if present(d["weekdays"]) {
            notes.append("frequency 是 \(frequency.rawValue)，\(label("weekdays")) 已忽略")
        }

        var target: Double?
        if present(d["target"]) {
            guard let value = try? number(d["target"], field: "target"), value > 0, value < 1_000_000 else {
                throw CourierError.invalid("\(label("target")) 应为正数（每次的数量目标，例如 30）")
            }
            target = value
        }
        var unit = string(d["unit"])
        if target == nil {
            if !unit.isEmpty { notes.append("没有 target，unit 已忽略") }
            unit = ""
        } else if unit.count > habitUnitLimit {
            throw CourierError.invalid("\(label("unit")) 太长（\(unit.count) 字，上限 \(habitUnitLimit)）")
        }

        // 开始日期：没写 start_date 却写了 date，就把 date 当作 start_date
        var startValue = d["start_date"], startField = label("start_date")
        if startValue == nil, let date = d["date"] {
            startValue = date
            startField = "date"
            notes.append("已把 date 当作 start_date")
        } else if startValue != nil, d["date"] != nil {
            notes.append("同时写了 start_date 和 date，已按 start_date，date 忽略")
        }
        let (startDay, relative) = try habitStart(startValue, field: startField, base: base)
        let ago = startDay.days(to: base)
        if ago > 0 {
            notes.append("start_date 早于今天\(ago > 60 ? "（\(ago) 天前）" : "")：此后没打卡的应做日会算漏打（用户可在热力图上补卡）")
        } else if -ago > 366 {
            notes.append("start_date \(startDay.key) 在一年以后，请确认年份没写错")
        }

        let category = string(d["category"])
        guard category.count <= habitCategoryLimit else {
            throw CourierError.invalid("\(label("category")) 太长（\(category.count) 字，上限 \(habitCategoryLimit)）")
        }
        let iconText = string(d["icon"])
        let symbol: String
        if iconText.isEmpty {
            symbol = HabitIcons.guess(title: title)
        } else if let value = HabitIcons.resolve(iconText) {
            symbol = value
        } else {
            symbol = "leaf"
            notes.append("\(label("icon"))「\(iconText)」认不出，已用 leaf（可用：\(HabitIcons.choices)）")
        }
        var habit = CourierHabit(title: title, frequency: frequency, timesPerWeek: frequency == .weekly ? timesPerWeek : 1, weekdays: days,
                                 target: target, unit: unit, startDay: startDay, category: category, symbol: symbol, notes: string(d["notes"]))
        habit.summary = CourierLineDecor.habitCreateLine(habit, today: base)
        return (habit, relative)
    }

    /// 星期：数组（也认用顿号、逗号隔开的一串），元素可写 周一 / 一 / 星期一 / mon / monday，或 1–7（1 = 周一，7 = 周日）。
    /// 0 一律拒收（有的写法 0 是周日、有的是周一）。返回 0 = 周一 … 6 = 周日，升序去重
    static func weekdays(_ value: Any?, field: String) throws -> [Int] {
        let raw: [Any]
        if let array = value as? [Any] {
            raw = array
        } else if let value, value is String || value is NSNumber {
            raw = [value]
        } else {
            throw CourierError.invalid(#"\#(field) 应为数组，例如 ["周一", "周三", "周五"]"#)
        }
        let zero = CourierError.invalid("\(field) 里的 0 有歧义（有的写法 0 是周日、有的是周一），请写 \"周日\" 或 7")
        func unknown(_ text: String) -> CourierError {
            CourierError.invalid("\(field) 里的「\(text)」认不出：请写 周一…周日、mon…sun，或 1–7（1 = 周一，7 = 周日）")
        }
        var result = Set<Int>()
        for element in raw {
            if let n = element as? NSNumber {
                guard !isBoolean(n) else { throw unknown(n.boolValue ? "true" : "false") }
                let v = n.doubleValue
                if v == 0 { throw zero }
                guard v >= 1, v <= 7, v.rounded() == v else { throw unknown(n.stringValue) }
                result.insert(Int(v) - 1)
            } else if let s = element as? String {
                for piece in s.split(whereSeparator: { ",，、;；/ ".contains($0) }) {
                    let text = piece.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let v = Int(text) {
                        if v == 0 { throw zero }
                        guard (1...7).contains(v) else { throw unknown(String(piece)) }
                        result.insert(v - 1)
                    } else if let index = weekdayWords[text] {
                        result.insert(index)
                    } else {
                        throw unknown(String(piece))
                    }
                }
            } else {
                throw unknown(element is [Any] ? "数组" : element is NSNull ? "null" : "对象")
            }
        }
        guard !result.isEmpty else { throw CourierError.invalid(#"weekdays 频率需要 weekdays，例如 ["周一", "周三", "周五"]"#) }
        return result.sorted()
    }

    /// 星期的各种写法 → 0 = 周一 … 6 = 周日
    private static let weekdayWords: [String: Int] = {
        var map: [String: Int] = [:]
        let english = [["mon", "monday"], ["tue", "tues", "tuesday"], ["wed", "wednesday"], ["thu", "thur", "thurs", "thursday"],
                       ["fri", "friday"], ["sat", "saturday"], ["sun", "sunday"]]
        for (index, short) in LocalDay.weekdayShortNames.enumerated() {
            for word in [short, "周" + short, "星期" + short, "礼拜" + short] + english[index] { map[word] = index }
        }
        for word in ["周天", "星期天", "礼拜天"] { map[word] = 6 }
        return map
    }()

    private static func habitFrequency(_ text: String) -> HabitFrequency? {
        switch text.lowercased() {
        case "daily", "每天", "每日": .daily
        case "weekly", "每周", "每周n次", "每周 n 次": .weekly
        case "weekdays", "指定星期": .weekdays
        default: nil
        }
    }

    /// 写了内容：空字符串、空数组都当没写
    private static func present(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let s = value as? String { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let array = value as? [Any] { return !array.isEmpty }
        return true
    }

    /// 进度：0–100，整数，也认 "70%"；小数四舍五入并提醒；超出范围、文字、true / false 一律拒收
    private static func goalProgress(_ value: Any?, field: String, notes: inout [String]) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        var number: Double?
        let shown: String
        if let n = value as? NSNumber {
            if isBoolean(n) {
                shown = n.boolValue ? "true" : "false"
            } else {
                shown = n.stringValue
                number = n.doubleValue
            }
        } else if let s = value as? String {
            var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            shown = s
            if text.hasSuffix("%") || text.hasSuffix("％") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
            number = Double(text)
        } else {
            shown = value is [Any] ? "数组" : "对象"
        }
        guard let number, number.isFinite, number >= 0, number <= 100 else {
            throw CourierError.invalid("\(field) 应为 0–100 的整数（可写 70 或 \"70%\"），收到「\(shown)」")
        }
        let rounded = Int(number.rounded())
        if Double(rounded) != number { notes.append("\(field) \(plainNumber(number)) 已取整为 \(rounded)") }
        return rounded
    }

    /// 期限：YYYY-MM-DD，也认 today / tomorrow / yesterday（按写入那天换算，算相对日期）；"none" / "无" 取消期限。
    /// 空字符串、null 等于没写——不调 date()：它把空串换算成今天，报错文案也是 date 的
    private static func goalDeadline(_ value: Any?, field: String, creating: Bool, base: LocalDay,
                                     notes: inout [String]) throws -> (GoalDeadline, relative: Bool) {
        guard let value, !(value is NSNull) else { return (.keep, false) }
        let invalid = { (text: String) in CourierError.invalid("\(field) 应为 YYYY-MM-DD（取消期限写 \"none\"），收到「\(text)」") }
        guard value is String else { throw invalid(string(value)) }
        let text = string(value), lower = text.lowercased()
        if text.isEmpty || lower == "null" { return (.keep, false) }
        // 新立时“没有期限”就是不写期限
        if ["none", "无", "没有", "不限"].contains(lower) { return (creating ? .keep : .clear, false) }
        let day: LocalDay
        var relative = false
        if let offset = relativeOffsets[lower] {
            day = base.adding(days: offset)
            relative = true
        } else if let parsed = LocalDay(key: text) {
            day = parsed
        } else {
            throw invalid(text)
        }
        if day < base { notes.append("\(field) \(day.key) 已经过去，请确认") }
        return (.set(day), relative)
    }

    /// 习惯的开始日期：没写就是写入那天（算相对日期）
    private static func habitStart(_ value: Any?, field: String, base: LocalDay) throws -> (LocalDay, relative: Bool) {
        guard let value, !(value is NSNull) else { return (base, true) }
        guard value is String else { throw CourierError.invalid("\(field) 应为 \"YYYY-MM-DD\" 形式的字符串") }
        let text = string(value)
        if let offset = relativeOffsets[text.lowercased()] { return (base.adding(days: offset), true) }
        guard let day = LocalDay(key: text) else { throw CourierError.invalid("\(field) 应为 YYYY-MM-DD，收到「\(text)」") }
        return (day, false)
    }
}

// MARK: - 整封预检

/// 整封预检：传书里的打卡、新建习惯、目标与现有数据对不对得上。应用收录和 --add 共用，报错原文相同。
struct CourierRoster {
    struct GoalRow: Equatable { var title: String; var status: String; var progress: Int }
    var habits: [String]               // 未归档，按 sortOrder
    var archivedHabits: [String]? = nil   // nil：不查
    var goals: [GoalRow]? = nil           // nil：不查目标
    /// 未归档习惯的单位（与 habits 一一对应，"" = 没设单位）。nil 或条数对不上（旧版小抄）：不核对现有习惯的单位
    var habitUnits: [String]? = nil
    /// 未归档习惯每次的数量目标（与 habits 一一对应，0 = 没有数量目标、打卡即完成）。
    /// nil 或条数对不上（旧版小抄）：不查“只是相关的同类说法没写数量”，由应用收录时再查
    var habitTargets: [Double]? = nil

    struct Resolution {
        enum HabitTarget: Equatable { case existing(Int), new(Int) }   // habits 的下标 / items 的下标
        var checkins: [Int: HabitTarget] = [:]
        var goalUpdates: [Int: Int] = [:]          // items 下标 → goals 下标
        var notices: [String] = []                 // 照收、只提醒
        /// 换算过单位的打卡：items 下标 → 按功课的单位记的数量（“1 小时”记到按分钟计的功课上是 60）
        var quantities: [Int: Double] = [:]
        /// 按条退回的打卡（只在 partial 时有）：items 下标 → 退回的原因。其余照收
        var skipped: [Int: Skip] = [:]
    }

    /// 一条退回的打卡：只有“找不到习惯”“单位对不上”这两类会按条退回（含只是相关的同类说法没写数量、换算后太小），
    /// 其余校验错误仍整封拒收
    struct Skip: Equatable {
        /// 整封拒收时的原因（不带“第 N 条：”）：找不到习惯时与原来一字不差，有候选再接一句
        var reason: String
        /// 部分收录时回执里那一行（不带“未收录 · 第 N 条：”）：原因 + 只重投这一条
        var receipt: String
        /// 传书笺上的短说法：“打卡「游泳」：没有这项功课”
        var short: String
    }

    /// “找不到目标”时列出的现有目标上限（不含已放弃）
    static let goalListLimit = 15

    /// 不通过时抛 CourierError.invalid("第 N 条：…")。打卡对不上习惯或单位时也整封拒收（直接调用 apply 的老路子）
    func resolve(_ items: [CourierItem]) throws -> Resolution {
        try resolve(items, units: [:], partial: false)
    }

    /// units：打卡写的单位（CourierPayload.checkinUnits）。
    /// partial 为真时（收件箱收录、--add 预检），打卡的“找不到习惯”“单位对不上”只退回这一条、记进 skipped，其余照收；
    /// 整封全是这类时仍整封拒收（各条原因逐行列出）。其余校验错误无论哪种都整封拒收，原文不变
    func resolve(_ items: [CourierItem], units: [Int: String], partial: Bool) throws -> Resolution {
        var result = Resolution()
        // 本封新建的习惯（打卡排在它前面也能挂上：写入时新习惯在主循环前统一插入）与本封新立的目标
        var newHabits: [(index: Int, title: String, unit: String, hasTarget: Bool)] = []
        var newGoals: [String] = []
        for (index, item) in items.enumerated() {
            if case let .habit(h) = item { newHabits.append((index, h.title, h.target == nil ? "" : h.unit, h.target != nil)) }
            if case let .goal(g) = item, g.action == .create { newGoals.append(g.title) }
        }
        let combined = habits + newHabits.map(\.title)
        // 现有习惯的单位、数量目标只在条数对得上时才用（小抄是旧版写的就不核对，由应用收录时再查）
        let existingUnits = habitUnits.flatMap { $0.count == habits.count ? $0 : nil }
        let existingTargets = habitTargets.flatMap { $0.count == habits.count ? $0 : nil }
        var createdHabits: [String] = []
        var createdGoals: [String] = []
        var updated: [Int: Int] = [:]   // goals 下标 → 第一次 update 的条目下标

        for (index, item) in items.enumerated() {
            func fail(_ message: String) -> CourierError { CourierError.invalid("第 \(index + 1) 条：\(message)") }
            func notice(_ message: String) { result.notices.append("第 \(index + 1) 条：\(message)") }
            switch item {
            case let .checkin(name, _, quantity):
                guard let found = Self.habitIndex(name, titles: combined) else {
                    let skip = Self.notFound(name, titles: combined)
                    if !partial { throw fail(skip.reason) }
                    result.skipped[index] = skip
                    continue
                }
                let at = found.index
                // 写了数量和单位：与功课的单位核对（功课没设单位、或旧版小抄不知道单位时不核对）
                if let quantity, let unit = units[index], !unit.isEmpty {
                    let habitUnit = at < habits.count ? existingUnits?[at] : newHabits[at - habits.count].unit
                    switch habitUnit.map({ CheckinUnit.reconcile(quantity, unit: unit, habitUnit: $0) }) ?? .same {
                    case .same:
                        break
                    case .converted(let value):
                        result.quantities[index] = value
                        notice("\(CourierParser.plainQuantity(quantity)) \(unit)按 \(CourierParser.plainQuantity(value)) \(habitUnit ?? "")记")
                    case .mismatch:
                        let skip = Self.unitMismatch(title: combined[at], habitUnit: habitUnit ?? "", written: unit)
                        if !partial { throw fail(skip.reason) }
                        result.skipped[index] = skip
                        continue
                    case .tooSmall:
                        let skip = Self.tooSmall(title: combined[at], quantity: quantity, written: unit, habitUnit: habitUnit ?? "")
                        if !partial { throw fail(skip.reason) }
                        result.skipped[index] = skip
                        continue
                    }
                }
                // 只是相关的同类说法（散步之于「步数 8000」、英语之于「背单词 30 个」）又没写数量：不替用户记满目标值，
                // 退回这一条请 AI 写上数量（与随手记同一规矩：说到「步数」但没写数量，先记成日记）。功课没有数量目标时照常打卡
                if quantity == nil, let via = found.via, !HabitAlias.fillsTarget(via: via, title: combined[at]) {
                    let hasTarget: Bool? = at < habits.count ? existingTargets.map { $0[at] > 0 } : newHabits[at - habits.count].hasTarget
                    if hasTarget == true {
                        let unit = at < habits.count ? existingUnits?[at] ?? "" : newHabits[at - habits.count].unit
                        let skip = Self.relatedOnly(name: name, title: combined[at], unit: unit)
                        if !partial { throw fail(skip.reason) }
                        result.skipped[index] = skip
                        continue
                    }
                }
                if found.via != nil {
                    notice("按「\(combined[at])」打卡（你写的是「\(name)」，属于同类说法）")
                }
                result.checkins[index] = at < habits.count ? .existing(at) : .new(newHabits[at - habits.count].index)
            case let .habit(h):
                if let at = NameMatch.exact(h.title, titles: habits) {
                    throw fail("已有同名习惯「\(habits[at])」。要打卡请用 checkin；要改它的设置请让用户在应用「每日功课」里改")
                }
                if let archived = archivedHabits, let at = NameMatch.exact(h.title, titles: archived) {
                    throw fail("已有同名的已归档习惯「\(archived[at])」。请让用户在「每日功课」里取消归档，或换个名字")
                }
                if NameMatch.exact(h.title, titles: createdHabits) != nil { throw fail("同一封里新建了两次「\(h.title)」") }
                createdHabits.append(h.title)
                let related = NameMatch.related(h.title, titles: habits)
                if !related.isEmpty {
                    let names = related.map { "「\(habits[$0])」" }.joined(separator: "、")
                    notice("新习惯「\(h.title)」和现有习惯\(names)名字互相包含，以后给它们打卡请写全称")
                }
            case let .goal(g):
                guard let goals else { continue }
                if g.action == .create {
                    let key = NameMatch.key(g.title)
                    let same = goals.indices.filter { NameMatch.key(goals[$0].title) == key }
                    if let at = same.first(where: { goals[$0].status != "cancelled" }) {
                        let row = goals[at]
                        throw fail(#"已有同名目标「\#(row.title)」（\#(GoalCatalog.statusLabel(row.status))，\#(row.progress)%）。要更新它请写 "action": "update""#)
                    }
                    if NameMatch.exact(g.title, titles: createdGoals) != nil { throw fail("同一封里新立了两次「\(g.title)」") }
                    createdGoals.append(g.title)
                    if let at = same.first { notice("另有一个已放弃的同名目标「\(goals[at].title)」，这次新立的是另一个") }
                    continue
                }
                if NameMatch.exact(g.title, titles: newGoals) != nil { throw fail("同一封里既新立又更新「\(g.title)」，请合成一条 create") }
                switch NameMatch.goal(g.title, in: goals.map { ($0.title, $0.status) }) {
                case .none:
                    throw fail("找不到目标「\(g.title)」。现有目标：\(goalList(goals))")
                case .ambiguous(let found):
                    throw fail("「\(g.title)」能对上多个目标：\(found.map { goals[$0].title }.joined(separator: "、"))。请写全称")
                case .found(let at):
                    let row = goals[at]
                    guard updated[at] == nil else { throw fail("同一封里对「\(row.title)」写了两条 update，请合成一条") }
                    updated[at] = index
                    result.goalUpdates[index] = at
                    if row.status == "cancelled", g.status == nil { notice("「\(row.title)」是已放弃的目标；要重新开始请写 status: active") }
                    if g.progress == 100, g.status == nil, row.status != "completed" {
                        notice(#"progress 是 100，但状态没改（仍是\#(GoalCatalog.statusLabel(row.status))）；要标记完成请写 "status": "completed""#)
                    }
                }
            default:
                continue
            }
        }
        // 整封全是对不上的打卡：一条都不收，整封拒收（各条原因逐行列出）
        if partial, !result.skipped.isEmpty, result.skipped.count == items.count {
            throw CourierError.invalid(result.skipped.keys.sorted().compactMap { i in
                result.skipped[i].map { "第 \(i + 1) 条：\($0.reason)" }
            }.joined(separator: "\n"))
        }
        return result
    }

    /// 打卡找习惯：先同名或唯一一个互相包含的（NameMatch.index），再查同类说法（HabitAlias.match，跑步 → 运动）。
    /// via 是同类对上时认出的那个说法；同名对上时为 nil
    static func habitIndex(_ name: String, titles: [String]) -> (index: Int, via: String?)? {
        if let at = NameMatch.index(name, titles: titles) { return (at, nil) }
        if let hit = HabitAlias.match(name, titles: titles) { return (hit.index, hit.via) }
        return nil
    }

    /// 找不到习惯：原因与原来一字不差（“找不到习惯「跑步」。现有习惯：…”）；名字能对上几项（互相包含、同类说法）时再接一句候选
    static func notFound(_ name: String, titles: [String]) -> Skip {
        let names = titles.joined(separator: "、")
        let head = "找不到习惯「\(name)」。现有习惯：\(names.isEmpty ? "（无）" : names)"
        let picks = Array(Set(NameMatch.related(name, titles: titles) + HabitAlias.candidates(name, titles: titles))).sorted()
        let quoted = picks.map { "「\(titles[$0])」" }
        let hint: String? = switch quoted.count {
        case 0: nil
        case 1: "若是给\(quoted[0])打卡，请把名字写成\(quoted[0])"
        default: "若是给\(quoted.joined(separator: "、"))中的一项打卡，请把名字写成那一项的全称"
        }
        let reason = head + (hint.map { "。" + $0 } ?? "")
        let receipt = head + "。" + (hint.map { $0 + "，只重投这一条。" } ?? "请向用户确认是哪项功课，再只重投这一条。")
        return Skip(reason: reason, receipt: receipt, short: "打卡「\(CourierItem.oneLine(name))」：没有这项功课")
    }

    /// 单位对不上：“单位对不上：「步数」按“步”计，这一条写的是“公里”。…”
    static func unitMismatch(title: String, habitUnit: String, written: String) -> Skip {
        let reason = "单位对不上：「\(title)」按“\(habitUnit)”计，这一条写的是“\(written)”。请换算成“\(habitUnit)”再写 quantity，或去掉 quantity 只打卡"
        return Skip(reason: reason, receipt: reason + "，只重投这一条。",
                    short: "打卡「\(CourierItem.oneLine(title))」：单位对不上（写的是“\(written)”）")
    }

    /// 换算后太小：“数量太小：「跑步」按“公里”计，1 米换算后不到 0.01 公里。…”
    static func tooSmall(title: String, quantity: Double, written: String, habitUnit: String) -> Skip {
        let amount = "\(CourierParser.plainQuantity(quantity)) \(written)"
        let reason = "数量太小：「\(title)」按“\(habitUnit)”计，\(amount)换算后不到 0.01 \(habitUnit)。请确认数量和单位没写错，或去掉 quantity 只打卡"
        return Skip(reason: reason, receipt: reason + "，只重投这一条。",
                    short: "打卡「\(CourierItem.oneLine(title))」：数量太小（\(amount)）")
    }

    /// 只是相关的同类说法没写数量：“「散步」和「步数」相关但不是一回事：请写 quantity（单位“步”）后只重投这一条。”
    static func relatedOnly(name: String, title: String, unit: String) -> Skip {
        let n = CourierItem.oneLine(name), t = CourierItem.oneLine(title)
        let ask = unit.isEmpty ? "请写 quantity" : "请写 quantity（单位“\(unit)”）"
        let head = "「\(n)」和「\(t)」相关但不是一回事，没写数量时不替用户记满目标"
        return Skip(reason: head + "：\(ask)后再投", receipt: "「\(n)」和「\(t)」相关但不是一回事：\(ask)后只重投这一条。",
                    short: "打卡「\(n)」：要写数量才记到「\(t)」")
    }

    /// “完成学位论文初稿（进行中 65%）、…”：不含已放弃，最多 15 个；一个都没有时提示去掉 action
    private func goalList(_ goals: [GoalRow]) -> String {
        let open = goals.filter { $0.status != "cancelled" }
        guard !open.isEmpty else { return "（暂无目标）；要新立请去掉 action" }
        let shown = open.prefix(Self.goalListLimit).map { "\($0.title)（\(GoalCatalog.statusLabel($0.status)) \($0.progress)%）" }
        return shown.joined(separator: "、") + (open.count > Self.goalListLimit ? " 等 \(open.count) 个" : "")
    }
}

// MARK: - 撤销用的值快照

/// 撤销时比较“用户改没改过”用的值快照。由 Services 侧用成员初始化从 Goal / Habit 填（模型不能进 Core）
struct GoalValues: Equatable {
    var title, detail, category, priority, status, targetDate: String   // targetDate "" = 无
    var progress: Int
    var notes: String

    init(title: String, detail: String, category: String, priority: String, status: String, targetDate: String, progress: Int, notes: String) {
        self.title = title
        self.detail = detail
        self.category = category
        self.priority = priority
        self.status = status
        self.targetDate = targetDate
        self.progress = progress
        self.notes = notes
    }

    /// 新立时写进 Goal 的值（与 CourierGoalHabitStore 的写法一致：status 默认 active，进度默认 0，没有期限为 ""）
    init(created g: CourierGoal) {
        var day = ""
        if case let .set(d) = g.deadline { day = d.key }
        self.init(title: g.title, detail: g.detail, category: g.category, priority: g.priority, status: g.status ?? "active",
                  targetDate: day, progress: g.progress ?? 0, notes: g.notes)
    }

    /// 各字段按固定顺序用 \u{1F} 连接；备注放最后，备注里就算有分隔符也能原样解析回来
    var fingerprint: String {
        [title, detail, category, priority, status, targetDate, String(progress), notes].joined(separator: "\u{1F}")
    }

    /// 认不出返回 nil（旧数据或被手改）
    init?(fingerprint: String) {
        let parts = fingerprint.split(separator: "\u{1F}", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 8, let progress = Int(parts[6]) else { return nil }
        self.init(title: parts[0], detail: parts[1], category: parts[2], priority: parts[3], status: parts[4], targetDate: parts[5],
                  progress: progress, notes: parts[7])
    }

    /// goalset 的字段：progress / status / target_date / notes；别的字段返回 ""
    static let fields = ["progress", "status", "target_date", "notes"]

    func value(of field: String) -> String {
        switch field {
        case "progress": String(progress)
        case "status": status
        case "target_date": targetDate
        case "notes": notes
        default: ""
        }
    }

    mutating func set(_ field: String, to value: String) {
        switch field {
        case "progress": progress = Int(value) ?? progress
        case "status": status = value
        case "target_date": targetDate = value
        case "notes": notes = value
        default: break
        }
    }

    /// 新立时的值，叠加之后（还没撤销的）传书对同一目标的写入（按收录先后），得到“没被用户动过时应有的样子”
    static func expected(created: GoalValues, laterWrites: [(field: String, after: String)]) -> GoalValues {
        var values = created
        for write in laterWrites { values.set(write.field, to: write.after) }
        return values
    }
}

/// 不含 sortOrder：用户拖动排序不算“改过”
struct HabitValues: Equatable {
    var title, category, symbol, frequency: String
    var timesPerWeek: Int; var weekdays: [Int]; var target: Double?; var unit, startDate: String
    var archived: Bool; var notes: String

    var fingerprint: String {
        [title, category, symbol, frequency, String(timesPerWeek), weekdays.map(String.init).joined(separator: ","),
         target.map(plainNumber) ?? "", unit, startDate, archived ? "1" : "0", notes].joined(separator: "\u{1F}")
    }
}

extension HabitValues {
    /// 新建时写进 Habit 的值（与 CourierGoalHabitStore 的写法一致：非 weekly 时每周次数为 1，非 weekdays 时星期为空，没有 target 时单位为空）
    init(created h: CourierHabit) {
        self.init(title: h.title, category: h.category, symbol: h.symbol, frequency: h.frequency.rawValue, timesPerWeek: h.timesPerWeek,
                  weekdays: h.weekdays, target: h.target, unit: h.unit, startDate: h.startDay.key, archived: false, notes: h.notes)
    }
}

// MARK: - 摘要行

/// 传书摘要行的生成与反解析（传书笺用；行由这里生成，所以一定解析得回来）
enum CourierLineDecor {
    struct ProgressMove: Equatable { var title: String; var from: Int; var to: Int; var completed: Bool }
    enum GoalChange: Equatable {
        case progress(Int, Int), status(String, String), deadline(String?, String?), note(String)   // deadline 存 YYYY-MM-DD，nil = 无
    }

    /// 备注在摘要里只露前 20 字
    static let notePreview = 20

    /// 不换行空格（U+00A0）：行文里日期、数量紧挨着的那几个空格用它（“期限 2027年2月17日”“每次 10分钟”“自 10月21日 起”
    /// “进度 60% → 65%”的箭头之后），传书笺放不下时整段换到下一行，不在“自 / 10月21日”“每次 / 10分钟”中间折开。
    /// 看上去与空格一样；解析（progressMove）两种空格都认，旧传书的摘要照样解析得回来
    static let nbsp = "\u{00A0}"

    /// “目标 · 新立「完成学位论文初稿」（期限 2027年2月17日，必须）”：括号里只写有的项
    static func goalCreateLine(_ g: CourierGoal, today: LocalDay) -> String {
        var parts: [String] = []
        if case let .set(day) = g.deadline { parts.append("期限\(nbsp)\(day.label(relativeTo: today))") }
        if g.priority == "must" { parts.append(GoalCatalog.priorityLabels["must"] ?? "必须") }
        if g.status == "completed" {
            parts.append(GoalCatalog.statusLabel("completed"))
        } else {
            if let p = g.progress, p > 0 { parts.append("进度\(nbsp)\(p)%") }
            if g.status == "paused" { parts.append(GoalCatalog.statusLabel("paused")) }
        }
        return "目标 · 新立「\(CourierItem.oneLine(g.title))」" + (parts.isEmpty ? "" : "（\(parts.joined(separator: "，"))）")
    }

    /// “目标 · 完成学位论文初稿：进度 60% → 65%；备注 +「第三章初稿完成」”：各段顺序固定（进度、状态、期限、备注）。
    /// 进度、期限两段：名目与旧值、箭头与新值之间是不换行空格，放不下时只在箭头前折行（“期限 12月19日 / → 2027年1月15日”）
    static func goalUpdateLine(title: String, changes: [GoalChange], today: LocalDay) -> String {
        func rank(_ change: GoalChange) -> Int {
            switch change {
            case .progress: 0
            case .status: 1
            case .deadline: 2
            case .note: 3
            }
        }
        let parts = changes.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map { item -> String in
            switch item.element {
            case let .progress(from, to): "进度\(nbsp)\(from)% →\(nbsp)\(to)%"
            case let .status(from, to): "状态 \(GoalCatalog.statusLabel(from)) → \(GoalCatalog.statusLabel(to))"
            case let .deadline(from, to): "期限\(nbsp)\(dayText(from, today: today)) →\(nbsp)\(dayText(to, today: today))"
            case let .note(text): "备注 +「\(preview(text))」"
            }
        }
        guard !parts.isEmpty else { return goalSkipLine(title: title) }
        return "目标 · \(CourierItem.oneLine(title))：" + parts.joined(separator: "；")
    }

    static func goalSkipLine(title: String) -> String { "目标 · \(CourierItem.oneLine(title))（已是这个内容，跳过）" }

    /// 收录前（还不知道旧值）的 update 摘要：“目标 · 更新「T」：进度 → 70%；状态 → 已完成；期限 → 12月31日；备注 +「…」”
    /// （进度、期限两段整段不折开）
    static func goalPlanLine(_ g: CourierGoal, today: LocalDay) -> String {
        var parts: [String] = []
        if let p = g.progress { parts.append("进度\(nbsp)→\(nbsp)\(p)%") }
        if let s = g.status { parts.append("状态 → \(GoalCatalog.statusLabel(s))") }
        switch g.deadline {
        case .keep: break
        case .set(let day): parts.append("期限\(nbsp)→\(nbsp)\(day.label(relativeTo: today))")
        case .clear: parts.append("期限\(nbsp)→\(nbsp)无")
        }
        if !g.notes.isEmpty { parts.append("备注 +「\(preview(g.notes))」") }
        return "目标 · 更新「\(CourierItem.oneLine(g.title))」：" + parts.joined(separator: "；")
    }

    /// “功课 · 新立「冥想」（每天，每次 10分钟，自 10月21日 起）”：括注里的空格（“每周 3 次”“每次 10分钟”“自 10月21日 起”）
    /// 都是不换行空格，放不下时只在“，”后折行
    static func habitCreateLine(_ h: CourierHabit, today: LocalDay) -> String {
        let schedule = h.scheduleText.replacingOccurrences(of: " ", with: nbsp)
        return "功课 · 新立「\(CourierItem.oneLine(h.title))」（\(schedule)，自\(nbsp)\(h.startDay.label(relativeTo: today))\(nbsp)起）"
    }

    /// 单行解析：“目标 · T：进度 a% → b%…”。标题里有“：”也能取对：标题之后紧跟的一定是“：进度 a% → b%”，
    /// 取第一处这样的写法（备注预览在行尾，就算备注里也写了“：进度 1% → 2%”也不会被当成标题的一部分）。
    /// completed：b == 100，或本行含“状态 … → 已完成”
    static func progressMove(_ line: String) -> ProgressMove? {
        let ns = line as NSString
        guard let match = progressPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let from = Int(ns.substring(with: match.range(at: 2))), let to = Int(ns.substring(with: match.range(at: 3))),
              from <= 100, to <= 100 else { return nil }
        let title = ns.substring(with: match.range(at: 1))
        // 状态段在备注段之前：只看备注之前的部分，免得备注里的字被当成状态
        let head = line.components(separatedBy: "；备注 +「").first ?? line
        let completed = to == 100 || head.contains("→ \(GoalCatalog.statusLabel("completed"))")
        return ProgressMove(title: title, from: from, to: to, completed: completed)
    }

    /// 空格处也认不换行空格（新写的行），普通空格（旧传书的摘要）照认
    private static let progressPattern = try! NSRegularExpression(pattern: "^目标 · (.+?)：进度[ \u{00A0}](\\d{1,3})%[ \u{00A0}]→[ \u{00A0}](\\d{1,3})%")

    /// 只看条目行（以“（”开头的附注行——相对日期说明、“撤销时保留了…”——不算）：
    /// 全是“目标 ·”行 → "flag"；全是“功课 ·”或“打卡 ·”行 → "leaf"；否则 nil
    static func symbol(_ lines: [String]) -> String? {
        switch kind(lines) {
        case .goals: "flag"
        case .habits: "leaf"
        case .mixed: nil
        }
    }

    /// 同上，对应 "profile" / "habits" / nil（AppSection.rawValue）
    static func page(_ lines: [String]) -> String? {
        switch kind(lines) {
        case .goals: "profile"
        case .habits: "habits"
        case .mixed: nil
        }
    }

    private enum Kind { case goals, habits, mixed }

    /// 传书摘要里退回的打卡那一行：“未收 · 打卡「游泳」：没有这项功课”（排在收下的各行之后；不是收下的条目）
    static let skippedPrefix = "未收 · "
    static func skippedLine(_ short: String) -> String { skippedPrefix + short }
    static func isSkipped(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix(skippedPrefix) }

    // 下面几个给传书笺与撤销确认框用（界面层接线见 Effects.courierArrived / courierBatch、Overlays、CourierPanel.undoMessage）：
    // 退回的那几行要看得见、要分得清，不能混进收下的条目里

    /// 摘要里退回的打卡有几行
    static func skippedCount(_ lines: [String]) -> Int { lines.filter(isSkipped).count }
    static func skippedCount(summary: String) -> Int { skippedCount(summary.split(separator: "\n").map(String.init)) }

    /// 传书笺副标题：“来自 Claude · 收录 2 条 · 1 条未收”（没有退回的与原来一样）
    static func cardDetail(from: String, itemCount: Int, lines: [String]) -> String {
        let n = skippedCount(lines)
        return "来自 \(from) · 收录 \(itemCount) 条" + (n > 0 ? " · \(n) 条未收" : "")
    }

    /// 传书笺显示的摘要行：整张最多 limit + 1 行（不超过就原样全显示——只多 1 条时不拿“另有 1 条”换掉一条内容）。
    /// 超了才折：退回的行总留在后面（收下的多时只折收下的，免得未收行被折进“另有 N 条”、看着像多收了几条），
    /// 退回的不止 1 行时并成一行（mergedSkippedLine）；末尾的附注行（“（相对日期按写入那天 … 计算）”，“（”开头）不是条目：
    /// 留在最末、占一行额度，不算进“另有 N 条”。收下的要藏就至少藏 2 条，“另有 N 条”的 N 总是 ≥ 2
    static func cardLines(_ lines: [String], limit: Int = 5) -> [String] {
        guard lines.count > limit + 1 else { return lines }
        let remarks = Array(lines.filter(isRemark).prefix(1))
        let skipped = lines.filter(isSkipped), kept = lines.filter { !isSkipped($0) && !isRemark($0) }
        let skipBlock = skipped.count > 1 ? [mergedSkippedLine(skipped)] : skipped
        let room = limit + 1 - skipBlock.count - remarks.count
        guard kept.count > room else { return kept + skipBlock + remarks }
        let shownKept = Array(kept.prefix(max(1, room - 1)))
        return shownKept + ["…… 另有 \(kept.count - shownKept.count) 条"] + skipBlock + remarks
    }

    /// 几条退回的打卡并成一行：原因相同写“未收 · 打卡「游泳」「弹琴」等 3 条：没有这项功课”（两条时不写“等 N 条”）；
    /// 原因不同写“…：名字或数量单位对不上”。名字各取前 8 字。仍以“未收 · ”开头（警示色、不算条目）
    static func mergedSkippedLine(_ lines: [String]) -> String {
        let parsed = lines.compactMap { line -> (name: String, reason: String)? in
            let short = String(line.trimmingCharacters(in: .whitespaces).dropFirst(skippedPrefix.count))
            let ns = short as NSString
            guard let match = skippedShort.firstMatch(in: short, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
        }
        guard parsed.count == lines.count, !parsed.isEmpty else { return skippedLine("\(lines.count) 条打卡没有写入") }
        let names = parsed.prefix(2).map { "「" + ($0.name.count > 8 ? String($0.name.prefix(8)) + "…" : $0.name) + "」" }.joined()
        let reasons = Set(parsed.map(\.reason))
        let reason = reasons.count == 1 ? parsed[0].reason : "名字或数量单位对不上"
        return skippedLine("打卡\(names)" + (parsed.count > 2 ? "等 \(parsed.count) 条" : "") + "：\(reason)")
    }

    /// 退回行的短说法“打卡「游泳」：没有这项功课”（名字取到最后一个“」：”为止）
    private static let skippedShort = try! NSRegularExpression(pattern: "^打卡「(.+)」：(.+)$")

    /// 一轮收到多封时，整封没收录（进了 AI/failed/）的那一行：“未收录 · claude-x.json：第 2 条：…”
    static let rejectedPrefix = "未收录 · "
    static func rejectedLine(file: String, message: String) -> String { rejectedPrefix + "\(file)：\(message)" }

    /// 传书笺上整行用警示色的行：退回的打卡行（“未收 · …”），和多封合并时整封没收录的那行（“未收录 · …”）
    static func isWarningLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return isSkipped(trimmed) || trimmed.hasPrefix(rejectedPrefix)
    }

    /// 附注行：“（”开头，不是条目（相对日期说明、“撤销时保留了…”）
    static func isRemark(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("（") }

    /// 一轮收到多封时每封那一行：“Claude · 2 条 · 1 条未收：记账 · 10月22日 · 午饭”。
    /// “1 条未收”写在冒号前：首条摘要再长、笺上从行尾截断时也截不到它
    static func batchLine(from: String, itemCount: Int, summary: String) -> String {
        let n = skippedCount(summary: summary)
        let first = summary.split(separator: "\n").first.map(String.init) ?? ""
        return "\(from) · \(itemCount) 条" + (n > 0 ? " · " + unreceivedMark(n) : "") + "：" + first
    }

    /// 多封合并时那封的“1 条未收”（传书笺上只这几个字警示色）
    static func unreceivedMark(_ n: Int) -> String { "\(n) 条未收" }

    /// 撤销确认框里列的摘要：退回的打卡没写入，不在撤销范围，不列
    static func undoLines(_ lines: [String]) -> [String] { lines.filter { !isSkipped($0) } }

    /// 撤销确认框里的摘要清单：条目前加“· ”，最多 limit 条（只多 1 条时全列，要藏就至少藏 2 条，写“…… 另有 N 条”）；
    /// 附注行（“（相对日期按…）”）不是条目：不加“· ”、不算条数，放在清单最后
    static func undoListing(_ lines: [String], limit: Int = 6) -> [String] {
        let all = undoLines(lines)
        let items = all.filter { !isRemark($0) }, remarks = all.filter(isRemark)
        let shown = items.count > limit + 1 ? Array(items.prefix(limit)) : items
        return shown.map { "· " + $0 } + (items.count > shown.count ? ["…… 另有 \(items.count - shown.count) 条"] : []) + remarks
    }

    private static func kind(_ lines: [String]) -> Kind {
        // 附注行（“（”开头）与退回的打卡行（“未收 ·”）不算：一封只有打卡、其中一条没收下，“查看”仍去每日功课
        let items = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("（") && !isSkipped($0) }
        guard !items.isEmpty else { return .mixed }
        if items.allSatisfy({ $0.hasPrefix("目标 ·") }) { return .goals }
        if items.allSatisfy({ $0.hasPrefix("功课 ·") || $0.hasPrefix("打卡 ·") }) { return .habits }
        return .mixed
    }

    private static func dayText(_ key: String?, today: LocalDay) -> String {
        guard let key, !key.isEmpty else { return "无" }
        return LocalDay(key: key)?.label(relativeTo: today) ?? key
    }

    /// 备注预览：压成一行（换行一律换成空格，免得一条拆成几行），只留前 20 字
    private static func preview(_ text: String) -> String {
        let line = CourierItem.oneLine(text)
        return line.count > notePreview ? String(line.prefix(notePreview)) + "…" : line
    }
}

/// 收录条数：goalset 按 r 里 “#” 前的目标标识合并计 1；hash 与 skip（按条退回的打卡的条号，没写入）不计；其余每条 1
enum CourierRefCount {
    static func items(_ refs: [(t: String, r: String)]) -> Int {
        var goals = Set<String>()
        var count = 0
        for ref in refs {
            switch ref.t {
            case "hash", "skip": continue
            case "goalset": goals.insert(ref.r.range(of: "#", options: .backwards).map { String(ref.r[..<$0.lowerBound]) } ?? ref.r)
            default: count += 1
            }
        }
        return count + goals.count
    }
}
