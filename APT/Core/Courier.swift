import Foundation

// 修行录的记录类型，以及“飞剑传书”收件格式的解析与校验（纯逻辑，不依赖 SwiftData）。

enum JournalKind: String, CaseIterable, Identifiable, Codable {
    case diary, note, review
    var id: String { rawValue }

    var label: String {
        switch self {
        case .diary: "日记"
        case .note: "灵感"
        case .review: "复盘"
        }
    }

    var symbol: String {
        switch self {
        case .diary: "book.closed"
        case .note: "lightbulb.max"
        case .review: "arrow.triangle.2.circlepath"
        }
    }

    var placeholder: String {
        switch self {
        case .diary: "今天发生了什么，心里在想什么……"
        case .note: "一闪而过的念头、学到的东西、值得记住的话……"
        case .review: "这段时间做成了什么、没做好什么、悟到了什么，下一步怎么走……"
        }
    }

    /// 落笔得到的修为（同日同类第 6 次起递减，受每日上限约束）
    var xp: Int {
        switch self {
        case .diary: 5
        case .note: 3
        case .review: 15
        }
    }
}

enum ReviewPeriod: String, CaseIterable, Identifiable {
    case day, week, month, event
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: "日省"
        case .week: "周复盘"
        case .month: "月复盘"
        case .event: "事后复盘"
        }
    }

    static let template = "【所得】\n\n【所失】\n\n【所悟】\n\n【下一步】\n"
    static func label(for raw: String) -> String { ReviewPeriod(rawValue: raw)?.label ?? "" }
}

/// 心境 1–5：雨、阴、平、晴、霁。
enum Mood {
    static let labels = ["", "雨", "阴", "平", "晴", "霁"]
    static let symbols = ["", "cloud.rain", "cloud", "cloud.sun", "sun.max", "sparkles"]
    static func label(_ value: Int?) -> String { value.map { labels[max(1, min(5, $0))] } ?? "" }
    static func symbol(_ value: Int?) -> String { value.map { symbols[max(1, min(5, $0))] } ?? "circle.dashed" }
}

enum TagText {
    /// “论文, 读书 #运动” → ["论文", "读书", "运动"]
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { ",，、;；#\n ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// 手记的一笔消费（手动或传书），与 CSV 导入的交易并存于灵石账簿；账户统一记为“手记”。
enum ManualExpense {
    static let account = "手记"

    static func transaction(id: String = "manual-" + UUID().uuidString, day: LocalDay, cents: Int, category: String,
                            description: String, note: String, reason: String) -> FinanceTransaction {
        let category = FinanceEngine.spendCategories.contains(category) ? category : "待分类消费"
        let pending = category == "待分类消费"
        return FinanceTransaction(id: id, date: day.key, amountCents: -abs(cents), balanceCents: 0, description: description,
                                  account: account, category: category, kind: "消费", needsReview: pending, reason: reason,
                                  note: note, sourceLine: 0, classification: pending ? "automatic" : "user")
    }
}

// MARK: - 飞剑传书

/// 收件箱里一份文件经过校验后的内容。
struct CourierPayload {
    var from: String
    var note: String
    var items: [CourierItem]
    /// 不影响收录的提醒（按别名理解的字段、忽略的字段、离今天很远的日期……），写进回执给 AI 看
    var warnings: [String] = []
    /// 日期用了相对写法（today / yesterday / tomorrow / 省略）的条数
    var relativeDates: Int = 0
    /// 打卡写了单位的（items 下标 → AI 写的单位原文，例如“小时”“公里”）：收录时与功课的单位核对、换算（CheckinUnit）。
    /// 不放进 CourierItem.checkin：那几处按三个值取打卡的写法就都不用改
    var checkinUnits: [Int: String] = [:]
}

enum CourierItem {
    case entry(kind: JournalKind, day: LocalDay, minute: Int?, title: String, body: String, mood: Int?, period: String, tags: [String])
    case expense(day: LocalDay, cents: Int, category: String, description: String, note: String)
    case event(day: LocalDay, start: Int?, end: Int?, title: String, location: String, category: String, notes: String)
    case checkin(habit: String, day: LocalDay, quantity: Double?)
    /// 个人档案：字段 key → 内容（只含有内容的字段）
    case profile(fields: [String: String])
    /// 目标：新立，或按名称更新进度、状态、期限并追加备注（见 CourierGoalHabit.swift）
    case goal(CourierGoal)
    /// 新建习惯（同一封里可以接着给它打卡）
    case habit(CourierHabit)

    /// 一条一行：传书摘要按换行切成一条条显示（传书笺、撤销确认框），内容里的换行都压成一行
    var summary: String {
        switch self {
        case let .entry(kind, day, _, title, body, _, _, _):
            let text = title.isEmpty ? String(Self.oneLine(body).prefix(24)) : Self.oneLine(title)
            return "\(kind.label) · \(day.shortLabel) · \(text)"
        case let .expense(day, cents, category, description, _):
            return "消费 · \(day.shortLabel) · \(Self.oneLine(description)) $\(String(format: "%.2f", Double(cents) / 100))［\(category)］"
        case let .event(day, start, end, title, _, _, _):
            return "日程 · \(day.shortLabel) \(ClockTime.range(start, end)) · \(Self.oneLine(title))"
        case let .checkin(habit, day, _):
            return "打卡 · \(day.shortLabel) · \(Self.oneLine(habit))"
        case let .profile(fields):
            return "档案 · " + ProfileCatalog.allFields.filter { fields[$0.key] != nil }.map(\.label).joined(separator: "、")
        case let .goal(g):
            return g.summary
        case let .habit(h):
            return h.summary
        }
    }

    /// 把多行文字压成一行（去掉空行与每行首尾空白）：多行的内容写进摘要会被拆成好几条，条数也会算错
    static func oneLine(_ text: String, separator: String = " ") -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: separator)
    }

    /// 规范化后的内容（空白折叠、字段顺序固定），用来判断“同样的内容是不是已经收录过”
    var canonical: String {
        func t(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let parts: [String]
        switch self {
        case let .entry(kind, day, minute, title, body, mood, period, tags):
            parts = ["entry", kind.rawValue, day.key, minute.map(String.init) ?? "", t(title), t(body), mood.map(String.init) ?? "", period,
                     tags.joined(separator: ",")]
        case let .expense(day, cents, category, description, note):
            parts = ["expense", day.key, String(cents), category, t(description), t(note)]
        case let .event(day, start, end, title, location, category, notes):
            parts = ["event", day.key, start.map(String.init) ?? "", end.map(String.init) ?? "", t(title), t(location), t(category), t(notes)]
        case let .checkin(habit, day, quantity):
            parts = ["checkin", t(habit).lowercased(), day.key, quantity.map { String($0) } ?? ""]
        case let .profile(fields):
            parts = ["profile"] + fields.keys.sorted().map { "\($0)=\(t(fields[$0] ?? ""))" }
        case let .goal(g):
            parts = ["goal"] + g.canonicalParts
        case let .habit(h):
            parts = ["habit"] + h.canonicalParts
        }
        return parts.joined(separator: "\u{1F}")
    }
}

enum CourierError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

enum CourierParser {
    static let expenseCategories = FinanceEngine.spendCategories
    static let typeList = "diary / note / review / expense / event / checkin / profile / goal / habit"
    /// 档案单个字段的字数上限
    static let profileValueLimit = 4000

    /// 各类型认识的字段（另有公共字段 type、date）。给 AI 的 README 也照这份写。
    static let fields: [String: [String]] = [
        "entry": ["title", "body", "time", "mood", "period", "tags"],
        "expense": ["amount", "description", "category", "note"],
        "event": ["title", "start", "end", "location", "category", "notes"],
        "checkin": ["habit", "quantity", "unit"],
        "profile": ["fields"],
        "goal": goalFields,
        "habit": habitFields,
    ]
    /// 常见的别名 → 正式字段名。按别名理解时会在回执里注明（老早就支持的几个除外）。
    static let aliases: [String: [String: String]] = [
        "entry": ["content": "body", "text": "body", "tag": "tags"],
        "expense": ["title": "description", "desc": "description", "cost": "amount", "price": "amount", "notes": "note", "memo": "note"],
        "event": ["time": "start", "start_time": "start", "startTime": "start", "end_time": "end", "endTime": "end",
                  "place": "location", "note": "notes", "description": "notes"],
        "checkin": ["name": "habit", "title": "habit", "habit_name": "habit", "value": "quantity", "amount": "quantity", "count": "quantity",
                    "单位": "unit", "units": "unit"],
        "goal": goalAliases,
        "habit": habitAliases,
    ]
    /// 一直都认、不必提醒的别名
    private static let quietAliases: Set<String> = ["content", "text", "title", "note"]
    /// 无害的附加字段：不写入，也不提醒
    private static let ignorable: Set<String> = ["id", "uuid", "source"]
    /// 不用公共字段 date 的类型（日期写在各自的字段里，或者根本不分日子）
    private static let datelessGroups: Set<String> = ["profile", "goal", "habit"]
    /// 相对日期写法 → 相对“投递那天”的天数
    static let relativeOffsets: [String: Int] = ["": 0, "today": 0, "今天": 0, "yesterday": -1, "昨天": -1, "tomorrow": 1, "明天": 1]

    /// 支持三种写法：`{"from":…, "items":[…]}`，或者直接一条 `{"type":…}`，或者一个数组。
    /// 相对日期按 today 换算，也只能为 today 及以前打卡。
    static func parse(_ data: Data, today: LocalDay = .today()) throws -> CourierPayload {
        try parse(data, relativeTo: today, latest: today)
    }

    /// relativeTo：today / yesterday / tomorrow / 省略日期的基准日（文件写入那天，而不是收录那天）；
    /// latest：最晚允许打卡的日子（真实的今天）。
    static func parse(_ data: Data, relativeTo base: LocalDay, latest: LocalDay) throws -> CourierPayload {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            throw CourierError.invalid(syntaxMessage(error, data: data))
        }
        var from = "", note = ""
        var topLevel = false
        let rawItems: [Any]
        if let array = object as? [Any] {
            rawItems = array
        } else if let dict = object as? [String: Any] {
            from = string(dict["from"])
            note = string(dict["note"])
            if let items = dict["items"] {
                guard let items = items as? [Any] else { throw CourierError.invalid("items 应为数组") }
                rawItems = items
            } else if dict["type"] != nil {
                rawItems = [dict]
                topLevel = true
            } else {
                throw CourierError.invalid("缺少 items 数组或 type 字段")
            }
        } else {
            throw CourierError.invalid("顶层必须是对象或数组")
        }
        guard !rawItems.isEmpty else { throw CourierError.invalid("items 为空") }
        guard rawItems.count <= 200 else { throw CourierError.invalid("一次最多 200 条") }
        var warnings: [String] = []
        var relative = 0
        var units: [Int: String] = [:]
        let items = try rawItems.enumerated().map { index, raw -> CourierItem in
            guard let dict = raw as? [String: Any] else { throw CourierError.invalid("第 \(index + 1) 条不是对象") }
            do {
                var unit: String?
                let result = try item(dict, topLevel: topLevel, base: base, latest: latest, unit: &unit)
                warnings += result.notes.map { "第 \(index + 1) 条：\($0)" }
                if result.relative { relative += 1 }
                if let unit { units[index] = unit }
                return result.item
            } catch CourierError.invalid(let message) {
                throw CourierError.invalid("第 \(index + 1) 条：\(message)")
            }
        }
        return CourierPayload(from: from, note: note, items: items, warnings: warnings, relativeDates: relative, checkinUnits: units)
    }

    private static func group(of type: String) -> String? {
        switch type {
        case "diary", "note", "review", "日记", "灵感", "复盘", "笔记": "entry"
        case "expense", "消费": "expense"
        case "event", "日程": "event"
        case "checkin", "打卡": "checkin"
        case "profile", "档案": "profile"
        case "goal", "目标": "goal"
        case "habit", "习惯", "功课": "habit"
        default: nil
        }
    }

    /// 把别名换成正式字段名（正式字段优先），并列出不认识的字段。
    /// sources 记下“正式字段 ← AI 实际写的别名”，报错时用 AI 写的字段名。
    private static func normalized(_ raw: [String: Any], group: String, topLevel: Bool, notes: inout [String],
                                   sources: inout [String: String]) -> [String: Any] {
        let known = Set(fields[group] ?? []).union(["type", "date"])
        let aliasMap = aliases[group] ?? [:]
        var d = raw.filter { known.contains($0.key) && !($0.value is NSNull) }
        var unknown: [String] = []
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
            if let target = aliasMap[key] {
                if value is NSNull { continue }
                if d[target] == nil {
                    // 打卡的 value / count 写成 true / false 是“做了 / 没做”的意思，不是数量：当作没写，照旧按达标记
                    if group == "checkin", target == "quantity", isBoolean(value) {
                        notes.append("\(key) 是 true / false，不是数量，已忽略（按达标记；只做了一部分请写 quantity 实际数量）")
                        continue
                    }
                    d[target] = value
                    sources[target] = key
                    if !quietAliases.contains(key) { notes.append("已把 \(key) 当作 \(target)") }
                } else {
                    notes.append("同时写了 \(target) 和 \(key)，已按 \(target)，\(key) 忽略")
                }
            } else if !ignorable.contains(key), !(topLevel && (key == "from" || key == "note")) {
                unknown.append(key)
            }
        }
        if !unknown.isEmpty {
            // profile、goal、habit 不用 date：不列进“可用”，免得和“goal 不用 date”的提醒自相矛盾
            let available = (datelessGroups.contains(group) ? [] : ["date"]) + (fields[group] ?? [])
            notes.append("忽略了不认识的字段 \(unknown.joined(separator: "、"))（这一类可用：\(available.joined(separator: "、"))）")
        }
        return d
    }

    /// unit：打卡写了数量与单位时填上单位原文（其余类型不动）
    private static func item(_ raw: [String: Any], topLevel: Bool, base: LocalDay, latest: LocalDay, unit: inout String?) throws
        -> (item: CourierItem, notes: [String], relative: Bool) {
        let type = string(raw["type"]).lowercased()
        guard let group = group(of: type) else {
            throw CourierError.invalid(type.isEmpty ? "缺少 type（可用：\(typeList)）" : "未知 type「\(type)」，可用：\(typeList)")
        }
        var notes: [String] = []
        var sources: [String: String] = [:]
        let d = normalized(raw, group: group, topLevel: topLevel, notes: &notes, sources: &sources)
        /// 报错用的字段名：按别名理解的写成“value（按 quantity 理解）”，免得 AI 找不到自己没写过的字段
        func label(_ field: String) -> String { sources[field].map { "\($0)（按 \(field) 理解）" } ?? field }
        // 档案不分日子：不看 date，也不算相对日期
        if group == "profile" { return (try profile(d, notes: &notes), notes, false) }
        // 目标、习惯的日期写在各自的字段里（target_date、start_date），不解析公共的 date
        if group == "goal" {
            let result = try goal(d, base: base, label: label, notes: &notes)
            return (.goal(result.item), notes, result.relative)
        }
        if group == "habit" {
            let result = try habit(d, base: base, label: label, notes: &notes)
            return (.habit(result.item), notes, result.relative)
        }
        let (day, relative) = try date(d["date"], base: base)
        let offset = base.days(to: day)
        if offset < -60 { notes.append("date \(day.key) 是 \(-offset) 天前，请确认年份、月份没写错") }
        if offset > 366 { notes.append("date \(day.key) 在一年以后，请确认年份没写错") }

        let item: CourierItem
        switch group {
        case "entry":
            let kind: JournalKind = ["diary", "日记"].contains(type) ? .diary : ["review", "复盘"].contains(type) ? .review : .note
            let title = string(d["title"]), body = string(d["body"])
            guard !(title.isEmpty && body.isEmpty) else { throw CourierError.invalid("title 和 body 不能都为空") }
            var mood: Int?
            if kind != .diary {
                if d["mood"] != nil { notes.append("mood 只用于日记（diary），已忽略") }
            } else if let value = try number(d["mood"], field: "mood") {
                guard value.rounded() == value, (1...5).contains(Int(value)) else {
                    throw CourierError.invalid("mood 应为 1–5 的整数（1 雨 · 2 阴 · 3 平 · 4 晴 · 5 霁）")
                }
                mood = Int(value)
            }
            let period = string(d["period"]).lowercased()
            if kind == .review {
                if !period.isEmpty, ReviewPeriod(rawValue: period) == nil { throw CourierError.invalid("period 应为 day / week / month / event") }
            } else if !period.isEmpty {
                notes.append("period 只用于复盘（review），已忽略")
            }
            item = .entry(kind: kind, day: day, minute: try time(d["time"], field: "time"), title: title, body: body, mood: mood,
                          period: kind == .review ? period : "", tags: tags(d["tags"]))
        case "expense":
            guard let cents = try amountCents(d["amount"], field: label("amount")) else {
                throw CourierError.invalid("expense 需要 amount（单位：元，例如 12.5）")
            }
            let description = string(d["description"])
            guard !description.isEmpty else { throw CourierError.invalid("expense 需要 description（例如“午饭 拉面”）") }
            var category = string(d["category"])
            if !expenseCategories.contains(category) {
                if !category.isEmpty { notes.append("category「\(category)」不在消费类别里，已记为「待分类消费」") }
                category = "待分类消费"
            }
            item = .expense(day: day, cents: cents, category: category, description: description, note: string(d["note"]))
        case "event":
            let title = string(d["title"])
            guard !title.isEmpty else { throw CourierError.invalid("event 需要 title") }
            let start = try time(d["start"], field: label("start")), end = try time(d["end"], field: label("end"), isEnd: true)
            if let s = start, let e = end, e <= s {
                throw CourierError.invalid("end 必须晚于 start（日程不能跨夜：过了午夜请拆成两条，前一条的 end 写 24:00）")
            }
            if start == nil, end != nil { throw CourierError.invalid("有 end 时必须有 start") }
            item = .event(day: day, start: start, end: end, title: title, location: string(d["location"]),
                          category: string(d["category"]), notes: string(d["notes"]))
        case "checkin":
            let habit = string(d["habit"])
            guard !habit.isEmpty else { throw CourierError.invalid("checkin 需要 habit（习惯名称）") }
            guard day <= latest else { throw CourierError.invalid("不能为未来的日子（\(day.key)）打卡") }
            var quantity: Double?
            var written = string(d["unit"])
            var rawQuantity = d["quantity"]
            // “1 小时”“5公里”这样数和单位写在一起的：拆开。另写了 unit 时：两边是同一个单位就只取数；
            // quantity 里是认得的单位、又和 unit 不同（“1小时”配 unit“分钟”），按 quantity 自带的单位记并提醒（数和单位写在一起的更可信）
            if let text = rawQuantity as? String, Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) == nil,
               let split = CheckinUnit.split(text) {
                rawQuantity = split.value
                let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if written.isEmpty {
                    written = split.unit
                    notes.append("\(label("quantity"))「\(shown)」已拆成数量 \(plainQuantity(split.value)) 与单位“\(split.unit)”（下次请分开写 quantity 与 unit）")
                } else if CheckinUnit.isKnown(split.unit), !CheckinUnit.sameUnit(split.unit, written) {
                    notes.append("\(label("quantity"))「\(shown)」里的单位“\(split.unit)”和 \(label("unit"))“\(written)”不同，已按“\(split.unit)”记"
                                 + "（下次请分开写：quantity 只写数，单位写在 unit）")
                    written = split.unit
                }
            }
            if let value = try number(rawQuantity, field: label("quantity")) {
                guard value > 0, value < 1_000_000 else { throw CourierError.invalid("\(label("quantity")) 应为正数（本次完成的数量）") }
                quantity = value
            }
            if !written.isEmpty {
                if quantity == nil {
                    notes.append("\(label("unit")) 要和 quantity 一起写，只写单位已忽略（按达标记）")
                } else {
                    unit = written
                }
            }
            item = .checkin(habit: habit, day: day, quantity: quantity)
        default:
            // 新类型漏写了解析规则时直接报错，不再被当成打卡解析
            throw CourierError.invalid("内部错误：类型「\(type)」没有解析规则")
        }
        return (item, notes, relative)
    }

    /// 档案：fields 是“字段 key（或中文名）→ 内容”。只写有内容的字段，空白不会清掉已有内容；认不出的字段整份拒收。
    private static func profile(_ d: [String: Any], notes: inout [String]) throws -> CourierItem {
        if d["date"] != nil { notes.append("profile 不用 date，已忽略") }
        guard let raw = d["fields"] as? [String: Any], !raw.isEmpty else {
            throw CourierError.invalid(#"profile 需要 fields 对象，例如 {"career_goals": "……"}"#)
        }
        let byKey = Dictionary(uniqueKeysWithValues: ProfileCatalog.allFields.map { ($0.key, $0) })
        let byLabel = Dictionary(ProfileCatalog.allFields.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: String] = [:]
        var unknown: [String] = []
        for (name, value) in raw.sorted(by: { $0.key < $1.key }) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard let field = byKey[trimmed] ?? byLabel[trimmed] else {
                unknown.append(name)
                continue
            }
            if field.key != trimmed { notes.append("已把「\(name)」当作 \(field.key)") }
            guard value is NSNull || value is String || (value is NSNumber && !isBoolean(value)) else {
                throw CourierError.invalid("fields 里的 \(name) 应为字符串")
            }
            var text = string(value)
            if text.isEmpty {
                notes.append("\(field.key) 是空的，没有改动（不会用空白清掉已有内容）")
                continue
            }
            if !field.multiline, text.contains(where: \.isNewline) {
                text = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: "；")
                notes.append("\(field.key) 是单行字段，换行已改成“；”")
            }
            guard text.count <= profileValueLimit else {
                throw CourierError.invalid("\(field.key) 太长（\(text.count) 字，上限 \(profileValueLimit)）")
            }
            guard result[field.key] == nil else { throw CourierError.invalid("fields 里 \(field.key) 写了两次（含「\(name)」）") }
            result[field.key] = text
        }
        guard unknown.isEmpty else {
            let available = ProfileCatalog.allFields.map { "\($0.key)（\($0.label)）" }.joined(separator: "、")
            throw CourierError.invalid("档案没有字段 \(unknown.joined(separator: "、"))。可用：\(available)")
        }
        guard !result.isEmpty else { throw CourierError.invalid("fields 里没有要写的内容") }
        return .profile(fields: result)
    }

    /// 数量的写法：整数不带小数点（与 CourierService.format 相同）
    static func plainQuantity(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // string / isBoolean / number 三个工具函数 CourierGoalHabit.swift 里的解析也要用，所以不是 private
    static func string(_ value: Any?) -> String {
        switch value {
        case let s as String: s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    static func isBoolean(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// 数字字段：null 视同没写；true / false 不算数字；接受 "12.5" 这样的数字字符串（金额字符串另见 amountCents）。
    static func number(_ value: Any?, field: String) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber {
            if isBoolean(n) { throw CourierError.invalid("\(field) 应为数字，不能是 true / false") }
            guard n.doubleValue.isFinite else { throw CourierError.invalid("\(field) 应为数字") }
            return n.doubleValue
        }
        if let s = value as? String {
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            guard let number = Double(text), number.isFinite else { throw CourierError.invalid("\(field) 应为数字，收到「\(s)」") }
            return number
        }
        throw CourierError.invalid("\(field) 应为数字")
    }

    /// 金额（单位分，正数）：数字照收；字符串与手动记账同一套规则（FinanceEngine.manualCents）：
    /// 可带 $ / AUD / 元，"18,5"、"18，5" 当 18.50，只有标准千分位（1,234.50）才把逗号当千分位，其余带逗号的写法、0x10、1e2 一律拒收。
    private static func amountCents(_ value: Any?, field: String) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String {
            let text = s.replacingOccurrences(of: "AUD", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "元", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            do {
                return try FinanceEngine.manualCents(text)
            } catch {
                let reason = error.localizedDescription
                throw CourierError.invalid("\(field) 应写成数字，例如 18.5（\(reason)），收到「\(s)」")
            }
        }
        guard let amount = try number(value, field: field) else { return nil }
        let cents = Int((amount * 100).rounded())
        guard amount < 1_000_000, cents > 0 else { throw CourierError.invalid("\(field) 应为正数（单位：元，例如 12.5）") }
        return cents
    }

    private static func date(_ value: Any?, base: LocalDay) throws -> (LocalDay, relative: Bool) {
        if let value, !(value is String), !(value is NSNull) { throw CourierError.invalid("date 应为 \"YYYY-MM-DD\" 形式的字符串") }
        let text = string(value)
        if let offset = relativeOffsets[text.lowercased()] { return (base.adding(days: offset), true) }
        guard let day = LocalDay(key: text) else { throw CourierError.invalid("date 应为 YYYY-MM-DD，收到「\(text)」") }
        return (day, false)
    }

    private static func time(_ value: Any?, field: String, isEnd: Bool = false) throws -> Int? {
        let text = string(value)
        guard !text.isEmpty else { return nil }
        if !isEnd, ClockTime.minutes(from: text, allowEndOfDay: true) == 24 * 60 {
            throw CourierError.invalid("\(field) 不能是 24:00（24:00 只能用作日程的结束时间 end）")
        }
        guard let minutes = ClockTime.minutes(from: text, allowEndOfDay: isEnd) else {
            throw CourierError.invalid("\(field) 应为 HH:MM（24 小时制，例如 09:30），收到「\(text)」")
        }
        return minutes
    }

    private static func tags(_ value: Any?) -> [String] {
        if let array = value as? [Any] { return TagText.parse(array.map { string($0) }.joined(separator: ",")) }
        return TagText.parse(string(value))
    }

    /// JSON 语法错误：给出第几行第几个字附近、出错处的原文，以及最常见的原因。
    static func syntaxMessage(_ error: Error, data: Data) -> String {
        let ns = error as NSError
        let debug = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
        if data.isEmpty || debug.contains("empty data") { return "不是合法的 JSON：文件是空的" }
        if String(data: data, encoding: .utf8) == nil { return "不是合法的 JSON：文件不是 UTF-8 编码的文本，请用 UTF-8 保存" }
        let hints: [(String, String)] = [
            ("Unescaped control character", "字符串里有没转义的换行或制表符：正文里的换行要写成 \\n，制表符写成 \\t"),
            ("Unexpected end of file", "文件提前结束了：可能少了结尾的 } 或 ]，或者某个引号没有闭合"),
            ("Garbage at end", "JSON 结束后还有多余内容：可能多了一个 } 或 ]，或者一个文件里放了两份 JSON（多条请放进同一个 items 数组）"),
            ("No string key", "字段名必须用英文双引号括起来"),
            ("No value for key", "字段名后面缺少冒号或值"),
            ("Badly formed array", "数组格式不对：两条之间可能少了逗号"),
            ("Badly formed object", "对象格式不对：两个字段之间可能少了逗号"),
            ("Invalid escape", "反斜杠转义不对：反斜杠本身要写成 \\\\"),
            ("Invalid value", "这里不是合法的值：常见原因是用了中文引号“”或单引号，或者字符串没加引号"),
        ]
        let reason = hints.first { debug.contains($0.0) }?.1 ?? (debug.isEmpty ? ns.localizedDescription : debug)
        guard let index = ns.userInfo["NSJSONSerializationErrorIndex"] as? Int, index >= 0, index <= data.count else {
            return "不是合法的 JSON：\(reason)"
        }
        let before = String(decoding: data.prefix(index), as: UTF8.self)
        let after = String(decoding: data.dropFirst(index).prefix(60), as: UTF8.self)
        let line = before.unicodeScalars.filter { $0 == "\n" }.count + 1
        let column = (before.components(separatedBy: "\n").last ?? before).count + 1
        let snippet = (String(before.suffix(20)) + "⟪这里⟫" + String(after.prefix(12))).replacingOccurrences(of: "\n", with: "⏎")
        return "不是合法的 JSON（第 \(line) 行第 \(column) 个字附近）：\(reason)。出错处：…\(snippet)…"
    }
}

// MARK: - 打卡的单位

/// 传书打卡写的单位（checkin 的 unit）与功课的单位核对：相同直接用；能换算（小时↔分钟、公里↔米、千步↔步、升↔毫升）的换算并提醒；
/// 对不上的这一条退回（见 CourierRoster.resolve）。功课没设单位、或传书没写单位时不核对。
/// 写法与换算沿用随手记的单位表（QuickParse.unitSpellings / unitFamilies），这里只补传书常见的几种写法。
enum CheckinUnit {
    enum Outcome: Equatable {
        /// 同一个单位（或不必核对）：数量照用
        case same
        /// 换算成功课的单位后的数量
        case converted(Double)
        /// 对不上：这一条不收
        case mismatch
        /// 能换算，但换算后不到 0.01（“1 米”记到按公里计的功课上）：多半写错了数或单位，这一条不收
        case tooSmall
    }

    /// 随手记单位表之外的写法：写法 → (规范写法, 倍数)。“8 千步”就是 8000 步；“50 个单词”就是 50 个（功法谱「背单词」按“个”计）
    static let extraSpellings: [String: (unit: String, scale: Double)] = [
        "千步": ("步", 1000), "k步": ("步", 1000), "万步": ("步", 10_000),
        "steps": ("步", 1), "step": ("步", 1), "pages": ("页", 1), "page": ("页", 1),
        "cups": ("杯", 1), "cup": ("杯", 1), "glasses": ("杯", 1), "glass": ("杯", 1),
        "kilometers": ("公里", 1), "kilometres": ("公里", 1), "meters": ("米", 1), "metres": ("米", 1),
        "seconds": ("秒", 1), "secs": ("秒", 1), "sec": ("秒", 1), "words": ("字", 1), "word": ("字", 1), "times": ("次", 1),
        "分钟数": ("分钟", 1), "步数": ("步", 1),
        "个单词": ("个", 1), "单词": ("个", 1), "个词": ("个", 1), "词": ("个", 1), "个生词": ("个", 1), "生词": ("个", 1),
    ]

    /// 英文的 word(s)：对按“字”计的功课（写作）是字，对按“个”计的功课（背单词）是个
    static let pieceWords: Set<String> = ["word", "words"]

    private static func key(_ unit: String) -> String { unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// 认得的单位写法（随手记的单位表或上面补的几种）：quantity 里自带的单位只有认得时才拿来和 unit 比
    static func isKnown(_ unit: String) -> Bool {
        let k = key(unit)
        return extraSpellings[k] != nil || QuickParse.unitSpellings.contains { $0.0 == k }
    }

    /// 两种写法是不是同一个单位（“min”与“分钟”、“个单词”与“个”是；“小时”与“分钟”不是）
    static func sameUnit(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        return x.unit == y.unit && x.scale == y.scale
    }

    /// 对按“个”计的功课，“个句子”“个知识点”这类“个 + 名词”与 word(s) 也算“个”（认得的“个小时”“个月”不算）
    private static func countsAsPieces(_ unit: String) -> Bool {
        let k = key(unit)
        if pieceWords.contains(k) { return true }
        return k.hasPrefix("个") && k.count > 1 && !isKnown(k)
    }

    /// 规范写法与倍数：“千步”→（步, 1000）、“min”→（分钟, 1）、“个小时”→（小时, 1）；认不出的原样（小写、去空白）
    static func normalized(_ unit: String) -> (unit: String, scale: Double) {
        let k = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if k.isEmpty { return ("", 1) }
        if let extra = extraSpellings[k] { return extra }
        return (QuickParse.canonicalUnit(k), 1)
    }

    /// quantity（单位 unit）记到单位为 habitUnit 的功课上：哪一边没写单位都不核对
    static func reconcile(_ quantity: Double, unit: String, habitUnit: String) -> Outcome {
        let from = normalized(unit), to = normalized(habitUnit)
        guard !from.unit.isEmpty, !to.unit.isEmpty else { return .same }
        if from.unit == to.unit {
            return from.scale == to.scale ? .same : checked(quantity * from.scale / to.scale)
        }
        if to.unit == "个", to.scale == 1, countsAsPieces(unit) { return .same }
        guard let value = QuickParse.convert(quantity * from.scale, from: from.unit, to: to.unit), value.isFinite, value > 0 else { return .mismatch }
        return checked(value / to.scale)
    }

    /// 换算后的数：留两位小数后不到 0.01 的不记（“1 米”按公里是 0，不能记成 0 还算完成）
    private static func checked(_ value: Double) -> Outcome {
        let r = rounded(value)
        return r > 0 ? .converted(r) : .tooSmall
    }

    /// “1 小时”“5公里”“8 千步”“30min”：数在前、单位在后的字符串拆开；数不是正数、或后面没有单位时 nil
    static func split(_ text: String) -> (value: Double, unit: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(t)
        var end = 0
        while end < chars.count, chars[end].isASCII, chars[end].isNumber || chars[end] == "." { end += 1 }
        guard end > 0, let value = Double(String(chars[0..<end])), value.isFinite, value > 0 else { return nil }
        let unit = String(chars[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, unit.count <= 8, !unit.contains(where: { $0.isASCII && $0.isNumber }) else { return nil }
        return (value, unit)
    }

    /// 换算后的数留两位小数（1.1 小时是 66 分钟，不是 66.00000000000001）
    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
