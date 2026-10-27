import Foundation

// MARK: - 印谱：八枚克制的里程碑
//
// 都从现有记录现算，不动数据模型；哪几枚已经得了、哪天得的记在偏好设置里（`milestones.celebrated`，见 MilestoneLedger）。
// 每枚只庆一次；一天最多庆一枚，同一天达成的其余几枚次日再补；第一次运行（偏好里还没有这一项）把已达成的全部静默记下，
// 2 年的老用户升级后不会一口气连放 8 次。这里只有纯函数（CoreCheck 逐条核对），取数在 Views/SealBook.swift 的 MilestoneWatcher。

/// 一枚印
enum Milestone: String, CaseIterable, Identifiable {
    case firstEntry, firstHabit, sevenDays, firstReview, thirtyDays, hundredDays, firstCourier, goalDone

    var id: String { rawValue }

    /// 印文（两字，朱印上的字）
    var seal: String {
        switch self {
        case .firstEntry: "山门"
        case .firstHabit: "立功"
        case .sevenDays: "不辍"
        case .firstReview: "初省"
        case .thirtyDays: "三旬"
        case .hundredDays: "百日"
        case .firstCourier: "飞剑"
        case .goalDone: "功成"
        }
    }

    /// 印名（印下的小字、得印时飘的那句）
    var name: String {
        switch self {
        case .firstEntry: "初入山门"
        case .firstHabit: "初立功课"
        case .sevenDays: "七日不辍"
        case .firstReview: "初省"
        case .thirtyDays: "三旬之功"
        case .hundredDays: "百日关"
        case .firstCourier: "飞剑初传"
        case .goalDone: "所向功成"
        }
    }

    /// 怎样得这枚印（白话一句）
    var condition: String {
        switch self {
        case .firstEntry: "落下第一篇"
        case .firstHabit: "立下第一项功课"
        case .sevenDays: "连续落笔七日"
        case .firstReview: "写下第一篇复盘"
        case .thirtyDays: "累计三十个落笔日"
        case .hundredDays: "累计一百个落笔日"
        case .firstCourier: "收到第一封传书"
        case .goalDone: "第一个目标达成"
        }
    }

    /// 未得时悬停的说明：“连续落笔七日可得”
    var requirement: String { condition + "可得" }

    /// 新得一枚时主窗口飘的那句：“得印 · 七日不辍：连续落笔七日”
    var toast: String { "得印 · \(name)：\(condition)" }

    /// 已得时悬停的说明：“10月22日得”；不是今年的带年份
    static func earnedHelp(_ dayKey: String, today: LocalDay) -> String {
        guard let day = LocalDay(key: dayKey) else { return "已得" }
        return "\(day.label(relativeTo: today))得"
    }
}

/// 算印要用的几样事实（都是现成记录里取得到的元数据）
struct MilestoneInput: Equatable {
    /// 每篇落笔（日记、灵感、复盘都算）的日期键，可重复、可乱序；认不出的写法当作今天落的
    var entryDays: [String] = []
    /// 每篇复盘的日期键
    var reviewDays: [String] = []
    /// 立下第一项功课的那天（没有功课为 nil）
    var firstHabit: LocalDay? = nil
    /// 收到第一封传书的那天
    var firstCourier: LocalDay? = nil
    /// 第一个达成的目标（状态“已完成”）那天；进度到了 100% 但状态仍是进行中的不算（与名帖列表、首页所向条、AI 传书同一口径）
    var firstGoalDone: LocalDay? = nil
}

enum Milestones {
    /// 连续落笔几日得“不辍”、累计几个落笔日得“三旬”“百日”
    static let streakGoal = 7
    static let thirtyGoal = 30
    static let hundredGoal = 100

    /// 已达成的印，及各自达成的那天（不晚于今天）。
    /// 落笔日只数今天及以前的（写在将来日期上的不算进连续与累计）；“第一篇”“第一篇复盘”只要有就算，日子晚于今天时记为今天
    static func reached(_ input: MilestoneInput, today: LocalDay) -> [Milestone: LocalDay] {
        var result: [Milestone: LocalDay] = [:]
        func clamp(_ day: LocalDay) -> LocalDay { min(day, today) }
        func earliest(_ keys: [String]) -> LocalDay? {
            guard !keys.isEmpty else { return nil }
            return clamp(keys.map { LocalDay(key: $0) ?? today }.min() ?? today)
        }
        if let day = earliest(input.entryDays) { result[.firstEntry] = day }
        if let day = earliest(input.reviewDays) { result[.firstReview] = day }
        if let day = input.firstHabit { result[.firstHabit] = clamp(day) }
        if let day = input.firstCourier { result[.firstCourier] = clamp(day) }
        if let day = input.firstGoalDone { result[.goalDone] = clamp(day) }
        // 落笔日：去重、只留今天及以前，按先后排
        let days = Set(input.entryDays.compactMap { LocalDay(key: $0) }).filter { $0 <= today }.sorted()
        if days.count >= thirtyGoal { result[.thirtyDays] = days[thirtyGoal - 1] }
        if days.count >= hundredGoal { result[.hundredDays] = days[hundredGoal - 1] }
        // 第一次连到 7 日的那天
        var run = 0
        var previous: LocalDay?
        for day in days {
            run = previous.map { $0.adding(days: 1) == day } == true ? run + 1 : 1
            previous = day
            if run >= streakGoal {
                result[.sevenDays] = day
                break
            }
        }
        return result
    }

    /// 一次检测的结果
    struct Step: Equatable {
        /// 记下之后的印谱
        var ledger: MilestoneLedger
        /// 这次要庆的那一枚（一天最多一枚）
        var celebrate: Milestone?
        /// 已达成、还没庆的（今天已经庆过一枚，等明天补）
        var pending: [Milestone]
        /// 印谱有没有变（没变就不必写回偏好）
        var changed: Bool
    }

    /// 拿已记下的印谱（第一次运行为 nil）、上次庆祝的那天、这次算出的已达成，决定记下哪些、庆哪一枚。
    /// - 第一次运行：已达成的全部静默记下（得印日写它达成的那天），一枚也不庆；
    /// - 之后：新达成的按印谱次序，今天还没庆过就庆第一枚（得印日写今天），其余留到明天；
    /// - 已记下的永不收回（删了那篇落笔，印照旧在）。
    static func step(ledger: MilestoneLedger?, lastCelebrated: String?, reached: [Milestone: LocalDay], today: LocalDay) -> Step {
        guard var ledger else {
            var seeded = MilestoneLedger()
            for (milestone, day) in reached { seeded.earned[milestone] = day.key }
            return Step(ledger: seeded, celebrate: nil, pending: [], changed: true)
        }
        var pending = Milestone.allCases.filter { reached[$0] != nil && ledger.earned[$0] == nil }
        guard !pending.isEmpty, lastCelebrated != today.key else {
            return Step(ledger: ledger, celebrate: nil, pending: pending, changed: false)
        }
        let first = pending.removeFirst()
        ledger.earned[first] = today.key
        return Step(ledger: ledger, celebrate: first, pending: pending, changed: true)
    }
}

/// 已得的印：印 → 得印那天（YYYY-MM-DD）。存成一行字：“firstEntry@2026-10-22,sevenDays@2026-10-29”；
/// 认不出的段落略过（以后加了新印、或偏好被手改坏了，也不会让整本印谱读不出来）
struct MilestoneLedger: Equatable {
    var earned: [Milestone: String] = [:]

    init() {}

    /// nil（偏好里还没有这一项）→ nil：表示第一次运行
    init?(encoded text: String?) {
        guard let text else { return nil }
        for part in text.split(separator: ",") {
            let pair = part.split(separator: "@", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let milestone = Milestone(rawValue: pair[0]), LocalDay(key: pair[1]) != nil else { continue }
            earned[milestone] = pair[1]
        }
    }

    /// 按印谱次序写出（同样的内容总是同一行字）
    var encoded: String {
        Milestone.allCases.compactMap { m in earned[m].map { "\(m.rawValue)@\($0)" } }.joined(separator: ",")
    }

    var isComplete: Bool { earned.count == Milestone.allCases.count }

    /// 印谱卡标题旁的“已得 3 / 8 枚”
    var countText: String { "已得 \(earned.count) / \(Milestone.allCases.count) 枚" }

    /// 逗号分隔的印名单（“刚得、待亮起”“已达成、待明日盖印”两张小单用）
    static func list(_ text: String) -> [Milestone] {
        text.split(separator: ",").compactMap { Milestone(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    static func listText(_ milestones: [Milestone]) -> String {
        Milestone.allCases.filter(milestones.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// 名帖目标列表的整理（M5）：进行中的在上面；已完成、暂停、已放弃收进一个折叠区。
/// 以状态为准：状态“已完成”才算达成；进度到了 100% 但状态仍是进行中的照旧在进行中那一列（与首页所向条、AI 传书同一口径）。
/// 编辑窗里把完成度拉到 100% 时状态会自动跟着改成“已完成”（GoalEditorLink），用户特意改回“进行中”的就照他的意思
enum GoalListRules {
    /// 目标算不算达成：状态“已完成”
    static func isDone(status: String) -> Bool { status == "completed" }

    /// 这次保存是不是“刚功成”：保存前没达成，保存后达成了（新建的目标保存前当作没达成）
    static func justAchieved(before: String?, after: String) -> Bool {
        !(before.map { isDone(status: $0) } ?? false) && isDone(status: after)
    }

    /// 折叠区里的次序：已完成 → 暂停 → 已放弃
    static let foldedOrder = ["completed", "paused", "cancelled"]

    /// 分两列：进行中的按原来的次序（创建先后）在上面，其余进折叠区（已完成 → 暂停 → 已放弃，同类保持原来的次序）。
    /// - keepShown：这次在进行中那一列里刚功成的，这次先留在那一列（原位不动，金光掠过时看得见），下次进页才收进折叠区；
    /// - foldedPlace：这次在折叠区里刚功成的（暂停、已放弃改成已完成），按改之前的状态排，留在折叠区原位，不跳到上面那一列。
    /// 两样都只在它仍是“已完成”时作数（之后又改成暂停、已放弃的，照常按现在的状态归位）。返回两列各自在 rows 里的下标
    static func partition<ID: Hashable>(_ rows: [(id: ID, status: String)], keepShown: Set<ID>, foldedPlace: [ID: String]) -> (shown: [Int], folded: [Int]) {
        var shown: [Int] = []
        var folded: [(rank: Int, index: Int)] = []
        for (index, row) in rows.enumerated() {
            let place = isDone(status: row.status) ? foldedPlace[row.id] : nil
            if row.status == "active" || (place == nil && isDone(status: row.status) && keepShown.contains(row.id)) {
                shown.append(index)
            } else {
                let sortedAs = place ?? row.status
                folded.append((foldedOrder.firstIndex(of: sortedAs) ?? foldedOrder.count, index))
            }
        }
        return (shown, folded.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.index))
    }

    /// 折叠区的标题：“已完成 · 2 项”；混着暂停、已放弃时一并写出（“已完成 · 暂停 · 3 项”）
    static func foldedLabel(statuses: [String]) -> String {
        let names = foldedOrder.filter(statuses.contains).map { statusName($0) }
        return (names.isEmpty ? "" : names.joined(separator: " · ") + " · ") + "\(statuses.count) 项"
    }

    /// 期限：今年的写“期限 2月17日”，不是今年的写“期限 2027年2月17日”
    static func deadlineText(_ key: String, today: LocalDay) -> String? {
        LocalDay(key: key).map { "期限 \($0.label(relativeTo: today))" }
    }

    /// 目标功成时飘的那句：“所向功成 · 完成学位论文初稿”（目标名超过 24 字截断）。
    /// 同时得了“功成”印（第一个目标达成）时并成一句：“所向功成 · 完成学位论文初稿 · 得「功成」印”，不再另飘一行“得印 · 所向功成：…”
    static func achievedToast(_ title: String, sealEarned: Bool = false) -> String {
        let name = title.count > 24 ? String(title.prefix(23)) + "…" : title
        return "\(Milestone.goalDone.name) · \(name)" + (sealEarned ? " · 得「\(Milestone.goalDone.seal)」印" : "")
    }

    /// 与 Goal.statusLabels 同一套说法（Core 里取不到数据模型，照抄一份）
    private static func statusName(_ status: String) -> String {
        switch status {
        case "completed": "已完成"
        case "paused": "暂停"
        case "cancelled": "已放弃"
        default: "进行中"
        }
    }
}

/// 目标编辑窗里“完成度”与“状态”联动：完成度 100% ⇔ 已完成（暂停、已放弃不跟着动）。
/// - 拖滑块：从不满拉到 100%、状态是进行中 → 改成已完成；从 100% 拉回去、状态是已完成 → 改回进行中；
/// - 点状态：改成已完成 → 完成度补到 100%（记下原来的数）；再改回别的状态 → 完成度还原成原来的数。
/// 改完仍可手动再改（例如拉到 100% 后特意点回“进行中”，就按进行中存，不算功成）
struct GoalEditorLink: Equatable {
    var status: String
    var progress: Int
    /// 点“已完成”把完成度补到 100 之前的数；拖了滑块就不再还原
    var progressBeforeDone: Int? = nil

    mutating func slide(to value: Int) {
        let old = progress
        progress = value
        progressBeforeDone = nil
        if value >= 100, old < 100, status == "active" {
            status = "completed"
        } else if value < 100, old >= 100, status == "completed" {
            status = "active"
        }
    }

    mutating func pick(_ value: String) {
        let old = status
        status = value
        if value == "completed" {
            if progress < 100 {
                progressBeforeDone = progress
                progress = 100
            }
        } else if old == "completed", let before = progressBeforeDone {
            progress = before
            progressBeforeDone = nil
        }
    }
}
