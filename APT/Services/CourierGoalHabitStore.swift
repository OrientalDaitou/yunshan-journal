import Foundation
import SwiftData

// 飞剑传书 goal / habit 的写入、找回、去重与撤销（要碰 SwiftData 的部分）。
// 解析、预检、摘要行、值快照这些纯逻辑在 Core/CourierGoalHabit.swift（文件名不能相同：同一 target 里不能有两个同名 .swift）。
//
// 打标与引用（refsJSON 里的 Ref）：
// - 新立的目标：`legacyID = "courier:<UUID>"`，`Ref(t: "goal", r: legacyID, after: GoalValues 指纹)`；
// - 更新目标：每个改了的字段一条 `Ref(t: "goalset", r: "<目标 legacyID>#<字段>", before: 旧值, after: 新值)`，
//   字段是 progress / status / target_date / notes；用户在应用里建的目标没有 legacyID，先补一个 `apt-goal:<UUID>`（只写一次，撤销也不清）；
// - 新建的习惯：`legacyID = "courier:<UUID>"`，`Ref(t: "habit", r: legacyID, after: HabitValues 指纹)`。
// 撤销 goalset 用“后写优先”：与档案字段相同（CourierService 里只管档案的 profilePlan / relink），代码在这里另写一份。

@MainActor
extension CourierService {
    // MARK: 写入

    struct GoalHabitPlan {
        /// 第 i 条打卡 → 现有习惯或本封新建的习惯
        var checkinHabits: [Int: Habit] = [:]
        /// 已构造、尚未 insert（insertNewHabits 在主循环前统一插入，排在它前面的打卡也能挂上）
        var newHabits: [(index: Int, habit: Habit)] = []
        /// 第 i 条 update → 目标
        var goalTargets: [Int: Goal] = [:]
        var notices: [String] = []
        /// 第 i 条打卡换算过单位：按功课的单位记的数量（“1 小时”→ 60 分钟）
        var checkinQuantities: [Int: Double] = [:]
        /// 第 i 条打卡按条退回（只在 partial 时有）：这一条不写，其余照收
        var skipped: [Int: CourierRoster.Skip] = [:]
    }

    /// 写入前的整封预检（取全部习惯与目标 → CourierRoster.resolve → 映射回模型对象）。不通过就抛错，整封不写。
    /// partial：打卡的习惯名 / 单位对不上时只退回那一条（收件箱收录用）；为假时与原来一样整封拒收。
    /// 没有打卡、习惯、目标条目时什么都不取
    static func goalHabitPlan(_ payload: CourierPayload, context: ModelContext, partial: Bool = false) throws -> GoalHabitPlan {
        var needsHabits = false, needsGoals = false
        for item in payload.items {
            switch item {
            case .checkin, .habit: needsHabits = true
            case .goal: needsGoals = true
            default: break
            }
        }
        guard needsHabits || needsGoals else { return GoalHabitPlan() }

        // 只取 ID 再拿已登记的对象：不重新取习惯，不让打卡关系变冷（见 ModelContext.allHabits）
        let allHabits = needsHabits ? context.allHabits() : []
        let active = allHabits.filter { !$0.archived }.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        let archived = allHabits.filter(\.archived).sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        // 目标按创建先后（与小抄 goals、修士名帖同状态内的顺序一致）
        let goals = needsGoals ? context.all(Goal.self).sorted { $0.createdAt < $1.createdAt } : []
        let roster = CourierRoster(habits: active.map(\.title), archivedHabits: archived.map(\.title),
                                   goals: goals.map { .init(title: $0.title, status: $0.status, progress: $0.progress) },
                                   habitUnits: active.map(\.unit),
                                   habitTargets: active.map { $0.targetValue.flatMap { $0 > 0 ? $0 : nil } ?? 0 })
        let resolution = try roster.resolve(payload.items, units: payload.checkinUnits, partial: partial)

        var plan = GoalHabitPlan()
        plan.notices = resolution.notices
        plan.checkinQuantities = resolution.quantities
        plan.skipped = resolution.skipped
        // 新习惯排在全部习惯（含已归档，与「每日功课」新建习惯的 nextSortOrder 同口径）的最后，同封建多个时依次 +1
        var nextOrder = (allHabits.map(\.sortOrder).max() ?? 0) + 1
        var created: [Int: Habit] = [:]
        for (index, item) in payload.items.enumerated() {
            guard case let .habit(h) = item else { continue }
            let habit = Habit(title: h.title)
            habit.category = h.category
            habit.symbol = h.symbol
            habit.frequencyKind = h.frequency
            habit.targetPerWeek = h.frequency == .weekly ? h.timesPerWeek : 1
            habit.weekdays = h.frequency == .weekdays ? h.weekdays : []
            habit.targetValue = h.target
            habit.unit = h.target == nil ? "" : h.unit
            habit.startDate = h.startDay.key
            habit.notes = h.notes
            habit.sortOrder = nextOrder
            habit.legacyID = "courier:" + UUID().uuidString
            nextOrder += 1
            created[index] = habit
            plan.newHabits.append((index: index, habit: habit))
        }
        for (index, target) in resolution.checkins {
            switch target {
            case .existing(let at): plan.checkinHabits[index] = active[at]
            case .new(let itemIndex): plan.checkinHabits[index] = created[itemIndex]
            }
        }
        for (index, at) in resolution.goalUpdates { plan.goalTargets[index] = goals[at] }
        return plan
    }

    static func insertNewHabits(_ plan: GoalHabitPlan, context: ModelContext) {
        for item in plan.newHabits { context.insert(item.habit) }
    }

    /// 新立目标，或把 update 写进预检找到的目标（值不变的项不写；全都没变时只记一行“已是这个内容，跳过”）
    static func applyGoal(_ g: CourierGoal, index: Int, plan: GoalHabitPlan, context: ModelContext,
                          today: LocalDay, refs: inout [Ref], lines: inout [String]) {
        if g.action == .create {
            let goal = Goal(title: g.title)
            goal.detail = g.detail
            goal.category = g.category
            goal.priority = g.priority
            goal.status = g.status ?? "active"
            goal.progress = g.progress ?? 0     // completed 时解析阶段已置 100
            if case let .set(day) = g.deadline { goal.targetDate = day.key }
            goal.notes = g.notes
            goal.legacyID = "courier:" + UUID().uuidString
            context.insert(goal)
            refs.append(Ref(t: "goal", r: goal.legacyID ?? "", after: GoalValues(created: g).fingerprint))
            lines.append(CourierLineDecor.goalCreateLine(g, today: today))
            return
        }
        guard let goal = plan.goalTargets[index] else { return }
        var changes: [CourierLineDecor.GoalChange] = []
        var writes: [(field: String, before: String, after: String)] = []
        if let p = g.progress, p != goal.progress {
            changes.append(.progress(goal.progress, p))
            writes.append(("progress", String(goal.progress), String(p)))
            goal.progress = p
        }
        if let s = g.status, s != goal.status {
            changes.append(.status(goal.status, s))
            writes.append(("status", goal.status, s))
            goal.status = s
        }
        let oldDay = goal.targetDate ?? ""
        let newDay: String
        switch g.deadline {
        case .keep: newDay = oldDay
        case .set(let day): newDay = day.key
        case .clear: newDay = ""
        }
        if newDay != oldDay {
            changes.append(.deadline(oldDay.isEmpty ? nil : oldDay, newDay.isEmpty ? nil : newDay))
            writes.append(("target_date", oldDay, newDay))
            goal.targetDate = newDay.isEmpty ? nil : newDay
        }
        if !g.notes.isEmpty {
            // 追加到原备注末尾：原备注非空时先换行，再写“2026年10月21日：内容”（原备注末尾的空行不再叠一行）
            let old = goal.notes
            var kept = old
            while let last = kept.last, last.isWhitespace || last.isNewline { kept.removeLast() }
            let added = g.notePrefix + g.notes
            let new = kept.isEmpty ? added : kept + "\n" + added
            changes.append(.note(g.notes))
            writes.append(("notes", old, new))
            goal.notes = new
        }
        guard !writes.isEmpty else {
            lines.append(CourierLineDecor.goalSkipLine(title: goal.title))
            return
        }
        // 用户在应用里建的目标没有 legacyID：补一个稳定标识（只写一次，撤销时也不清）
        if (goal.legacyID ?? "").isEmpty { goal.legacyID = "apt-goal:" + UUID().uuidString }
        let id = goal.legacyID ?? ""
        for write in writes { refs.append(Ref(t: "goalset", r: id + "#" + write.field, before: write.before, after: write.after)) }
        goal.updatedAt = Date()
        lines.append(CourierLineDecor.goalUpdateLine(title: goal.title, changes: changes, today: today))
    }

    /// 新习惯已在主循环前插入，这里只登记引用与摘要行
    static func applyHabit(_ h: CourierHabit, index: Int, plan: GoalHabitPlan,
                           today: LocalDay, refs: inout [Ref], lines: inout [String]) {
        guard let habit = plan.newHabits.first(where: { $0.index == index })?.habit else { return }
        refs.append(Ref(t: "habit", r: habit.legacyID ?? "", after: HabitValues(created: h).fingerprint))
        lines.append(CourierLineDecor.habitCreateLine(h, today: today))
    }

    // MARK: 找回

    struct GoalHabitWritten {
        var goals: [(ref: Ref, goal: Goal)] = []        // t == "goal"
        var goalFields: [(ref: Ref, goal: Goal)] = []   // t == "goalset"
        var habits: [(ref: Ref, habit: Habit)] = []     // t == "habit"
        var isEmpty: Bool { goals.isEmpty && goalFields.isEmpty && habits.isEmpty }
    }

    /// 一封传书新立 / 更新的目标与新建的习惯里，现在还在的。只按 legacyID 取（#Predicate），不整表取；查询出错时退回整表过滤
    static func goalHabitWritten(_ refs: [Ref], context: ModelContext) -> GoalHabitWritten {
        var w = GoalHabitWritten()
        let goalRefs = refs.filter { $0.t == "goal" }
        let fieldRefs = refs.filter { $0.t == "goalset" }
        let habitRefs = refs.filter { $0.t == "habit" }
        // legacyID 是可选的，ID 数组也写成可选：写成 `$0.legacyID ?? ""` 的话 SwiftData 生成不了 SQL，会直接崩溃
        let goalIDs: [String?] = Set(goalRefs.map(\.r) + fieldRefs.map { goalKey($0.r) }).filter { !$0.isEmpty }.map { $0 }
        if !goalIDs.isEmpty {
            let goals = (try? context.fetch(FetchDescriptor<Goal>(predicate: #Predicate { goalIDs.contains($0.legacyID) })))
                ?? context.all(Goal.self).filter { goalIDs.contains($0.legacyID) }
            var byID: [String: Goal] = [:]
            for goal in goals { if let id = goal.legacyID, byID[id] == nil { byID[id] = goal } }
            w.goals = goalRefs.compactMap { ref in byID[ref.r].map { (ref: ref, goal: $0) } }
            w.goalFields = fieldRefs.compactMap { ref in byID[goalKey(ref.r)].map { (ref: ref, goal: $0) } }
        }
        let habitIDs: [String?] = Set(habitRefs.map(\.r)).filter { !$0.isEmpty }.map { $0 }
        if !habitIDs.isEmpty {
            let habits = (try? context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { habitIDs.contains($0.legacyID) })))
                ?? context.all(Habit.self).filter { habitIDs.contains($0.legacyID) }
            var byID: [String: Habit] = [:]
            for habit in habits { if let id = habit.legacyID, byID[id] == nil { byID[id] = habit } }
            w.habits = habitRefs.compactMap { ref in byID[ref.r].map { (ref: ref, habit: $0) } }
        }
        return w
    }

    /// 去重用：“写入的东西还在”——新立的目标仍在，或任一 goalset 的当前值仍等于写进去的值，或新建的习惯仍在
    static func goalHabitStillPresent(_ w: GoalHabitWritten) -> Bool {
        if !w.goals.isEmpty || !w.habits.isEmpty { return true }
        return w.goalFields.contains { goalValues($0.goal).value(of: fieldName($0.ref.r)) == ($0.ref.after ?? "") }
    }

    /// 目标现在的值（撤销比较“改没改过”用）
    static func goalValues(_ g: Goal) -> GoalValues {
        GoalValues(title: g.title, detail: g.detail, category: g.category, priority: g.priority, status: g.status,
                   targetDate: g.targetDate ?? "", progress: g.progress, notes: g.notes)
    }

    /// 习惯现在的设置（不含 sortOrder：拖动排序不算改过）
    static func habitValues(_ h: Habit) -> HabitValues {
        HabitValues(title: h.title, category: h.category, symbol: h.symbol, frequency: h.frequency, timesPerWeek: h.targetPerWeek,
                    weekdays: h.weekdays, target: h.targetValue, unit: h.unit, startDate: h.startDate, archived: h.archived, notes: h.notes)
    }

    /// goalset 的 r = "<目标 legacyID>#<字段>"：取 “#” 前的目标标识（与 CourierRefCount 一样按最后一个 “#” 切）
    nonisolated static func goalKey(_ r: String) -> String {
        r.range(of: "#", options: .backwards).map { String(r[..<$0.lowerBound]) } ?? r
    }

    nonisolated static func fieldName(_ r: String) -> String {
        r.range(of: "#", options: .backwards).map { String(r[$0.upperBound...]) } ?? ""
    }

    private static let fieldLabels = ["progress": "进度", "status": "状态", "target_date": "期限", "notes": "备注"]

    // MARK: 撤销

    /// 与 CourierUndoPreview / CourierUndoReport 的新字段一一对应（设计稿 P2 §1.4）
    struct GoalHabitUndoCount {
        var records = 0, editedRecords = 0        // 新立的目标、新建的习惯（“有别的打卡而保留”的不计）
        var goals = 0, editedGoals = 0            // 目标更新（每个目标 1 项；被后来的传书改过的不计）
        var removed = 0, restoredGoals = 0, kept = 0
        var keptGoals = 0                         // kept 里有几个是目标更新（其余是新立的目标、新建的习惯）
        var notes: [String] = []                  // 保留原因，最多 3 条
    }

    /// 后写优先（§1.4）：goalset 各项是恢复、算改过，还是被后来的传书 next 盖过
    enum GoalFieldAction { case restore, edited, superseded(next: CourierDelivery) }

    /// 预览与撤销共用的一份判断：提示与实际结果才一致
    private struct GoalHabitUndoPlan {
        /// 同一个目标的几项按整个目标算（预览、撤销都只看 counted / edited）：
        /// 只要有一项被用户改过，“保留改过的”时整个目标都不动、计入保留（没改过的那几项也不恢复）；“全部撤销”时几项一起恢复。
        /// 被后来的传书盖过的几项不计，无论哪种都不恢复
        struct FieldGroup {
            var goal: Goal
            var fields: [(ref: Ref, action: GoalFieldAction)]
            /// 计入撤销的几项（去掉被后来的传书盖过的）；为空时这个目标不算进预览和结果
            var counted: [(ref: Ref, action: GoalFieldAction)] { fields.filter { if case .superseded = $0.action { false } else { true } } }
            var edited: Bool { counted.contains { if case .edited = $0.action { true } else { false } } }
        }
        var fieldGroups: [FieldGroup] = []
        var goals: [(goal: Goal, edited: Bool)] = []
        /// others：这个习惯下不是本封写的打卡条数（> 0 时无论怎么撤都保留）
        var habits: [(habit: Habit, others: Int, edited: Bool)] = []
        var notes: [String] = []
    }

    /// 比 D 晚、还没撤销的传书（按收录先后），各带解好的引用
    private static func laterWriters(than delivery: CourierDelivery, context: ModelContext) -> [(next: CourierDelivery, refs: [Ref])] {
        let received = delivery.receivedAt
        let later = (try? context.fetch(FetchDescriptor<CourierDelivery>(predicate: #Predicate { !$0.undone && $0.receivedAt > received },
                                                                         sortBy: [SortDescriptor(\.receivedAt)])))
            ?? context.all(CourierDelivery.self).filter { !$0.undone && $0.receivedAt > received }.sorted { $0.receivedAt < $1.receivedAt }
        return later.compactMap { next -> (next: CourierDelivery, refs: [Ref])? in
            let goalRefs = refs(of: next).filter { $0.t == "goalset" }
            return goalRefs.isEmpty ? nil : (next: next, refs: goalRefs)
        }
    }

    private static func undoPlan(_ delivery: CourierDelivery, refs: [Ref], context: ModelContext) -> GoalHabitUndoPlan {
        var plan = GoalHabitUndoPlan()
        let w = goalHabitWritten(refs, context: context)
        guard !w.isEmpty else { return plan }
        let later = w.goals.isEmpty && w.goalFields.isEmpty ? [] : laterWriters(than: delivery, context: context)

        // 目标更新：按目标分组（一个目标的几项合计 1 项）
        var order: [ObjectIdentifier] = []
        var groups: [ObjectIdentifier: GoalHabitUndoPlan.FieldGroup] = [:]
        for (ref, goal) in w.goalFields {
            let action: GoalFieldAction
            if let next = later.first(where: { $0.refs.contains { $0.r == ref.r } })?.next {
                action = .superseded(next: next)
            } else {
                action = goalValues(goal).value(of: fieldName(ref.r)) == (ref.after ?? "") ? .restore : .edited
            }
            let key = ObjectIdentifier(goal)
            if groups[key] == nil { order.append(key); groups[key] = .init(goal: goal, fields: []) }
            groups[key]?.fields.append((ref: ref, action: action))
        }
        plan.fieldGroups = order.compactMap { groups[$0] }
        for group in plan.fieldGroups {
            // 同一封后来的传书盖过的几项写成一句
            var bySender: [(next: CourierDelivery, fields: [String])] = []
            for field in group.fields {
                guard case let .superseded(next) = field.action else { continue }
                let label = fieldLabels[fieldName(field.ref.r)] ?? fieldName(field.ref.r)
                if let i = bySender.firstIndex(where: { $0.next === next }) { bySender[i].fields.append(label) } else { bySender.append((next: next, fields: [label])) }
            }
            for item in bySender {
                plan.notes.append("目标「\(CourierItem.oneLine(group.goal.title))」的\(item.fields.joined(separator: "、"))后来又被 \(DateText.display(item.next.receivedAt)) 的传书改过，"
                                  + "以后来的为准，\(item.fields.count > 1 ? "这几项" : "这一项")不恢复")
            }
        }

        // 新立的目标：现值 ≠ 期望值（新立时的值，叠加之后还没撤销的传书对它的写入）才算用户改过
        for (ref, goal) in w.goals {
            let writes = later.flatMap { item in
                item.refs.filter { goalKey($0.r) == ref.r }.map { (field: fieldName($0.r), after: $0.after ?? "") }
            }
            let edited = GoalValues(fingerprint: ref.after ?? "").map { GoalValues.expected(created: $0, laterWrites: writes) != goalValues(goal) } ?? true
            plan.goals.append((goal: goal, edited: edited))
        }

        // 新建的习惯：设置指纹变了，或本封给它打的卡收录后被改过，都算改过；下面有别的打卡（不是本封写的）就一律保留
        let ownLogs = Set(refs.filter { $0.t == "checkin" }.map(\.r))
        for (ref, habit) in w.habits {
            let logs = habit.logs ?? []
            let others = logs.filter { !ownLogs.contains($0.legacyID ?? "") }.count
            let ownEdited = logs.contains { ownLogs.contains($0.legacyID ?? "") && $0.updatedAt.timeIntervalSince(delivery.receivedAt) > editedAfter }
            let edited = habitValues(habit).fingerprint != (ref.after ?? "") || ownEdited
            plan.habits.append((habit: habit, others: others, edited: edited))
            if others > 0 {
                plan.notes.append("习惯「\(CourierItem.oneLine(habit.title))」已有 \(others) 条打卡，撤销时保留（要删请到「每日功课」里删）")
            }
        }
        plan.notes = Array(plan.notes.prefix(3))
        return plan
    }

    /// 撤销预览里目标与新习惯的几项（由 undoPreviewDetail 并入，界面不另查数据库）
    static func goalHabitPreview(_ delivery: CourierDelivery, refs: [Ref], context: ModelContext) -> GoalHabitUndoCount {
        let plan = undoPlan(delivery, refs: refs, context: context)
        var c = GoalHabitUndoCount()
        for group in plan.fieldGroups where !group.counted.isEmpty {
            c.goals += 1
            if group.edited { c.editedGoals += 1 }
        }
        for goal in plan.goals {
            c.records += 1
            if goal.edited { c.editedRecords += 1 }
        }
        for habit in plan.habits where habit.others == 0 {
            c.records += 1
            if habit.edited { c.editedRecords += 1 }
        }
        c.notes = plan.notes
        return c
    }

    /// 撤销目标与新习惯：goalset 恢复原值（被后来的传书盖过的不动、接回 before）；新立的目标、新建的习惯删掉，
    /// 改过的在 keepEdited 时保留；新习惯下面有别的打卡时一律保留。由 CourierService.undo 在撤完打卡之后调用。
    /// 目标更新按整个目标算（见 FieldGroup）：有一项被用户改过时，keepEdited 下这个目标的几项都不恢复、计 1 个保留，
    /// 与预览“保留你改过的 N 个目标”一致
    static func undoGoalHabit(_ delivery: CourierDelivery, refs: [Ref], context: ModelContext, keepEdited: Bool) -> GoalHabitUndoCount {
        let plan = undoPlan(delivery, refs: refs, context: context)
        var c = GoalHabitUndoCount()
        for group in plan.fieldGroups {
            for field in group.fields {
                if case let .superseded(next) = field.action { relinkGoalField(next, over: field.ref) }
            }
            guard !group.counted.isEmpty else { continue }
            if group.edited, keepEdited {
                c.kept += 1
                c.keptGoals += 1
                continue
            }
            for field in group.counted { restore(field.ref, in: group.goal) }
            group.goal.updatedAt = Date()
            c.restoredGoals += 1
            c.removed += 1
        }
        for goal in plan.goals {
            if goal.edited, keepEdited { c.kept += 1; continue }
            context.delete(goal.goal)
            c.removed += 1
        }
        for habit in plan.habits where habit.others == 0 {
            if habit.edited, keepEdited { c.kept += 1; continue }
            // 级联删掉它下面的打卡：走到这里时只剩本封写的、而且这次也该删的（改过而保留的只出现在上面的保留分支）
            context.delete(habit.habit)
            c.removed += 1
        }
        c.notes = plan.notes
        return c
    }

    /// 只看这封里的目标更新：各项恢复 / 算改过 / 被后来的传书盖过
    static func goalFieldPlan(_ delivery: CourierDelivery, refs: [Ref], context: ModelContext) -> [(ref: Ref, action: GoalFieldAction)] {
        undoPlan(delivery, refs: refs.filter { $0.t == "goalset" }, context: context).fieldGroups.flatMap(\.fields)
    }

    /// 撤销的这封夹在中间、后一封直接写在它的内容之上（后一封记的“改写前”正是这封写进去的）：
    /// 把后一封的“改写前”接回这封之前的值，以后撤销那封时恢复成最初的样子。中间被用户改过的不接
    static func relinkGoalField(_ next: CourierDelivery, over ref: Ref) {
        var nextRefs = refs(of: next)
        guard let i = nextRefs.firstIndex(where: { $0.t == "goalset" && $0.r == ref.r }), (nextRefs[i].before ?? "") == (ref.after ?? "") else { return }
        nextRefs[i].before = ref.before
        if let json = try? String(data: JSONEncoder().encode(nextRefs), encoding: .utf8) { next.refsJSON = json }
    }

    /// 恢复 goalset 的 before：progress 用 Int(before)，期限 "" 表示无，status 与 notes 原样
    private static func restore(_ ref: Ref, in goal: Goal) {
        let before = ref.before ?? ""
        switch fieldName(ref.r) {
        case "progress": goal.progress = Int(before) ?? goal.progress
        case "status": if !before.isEmpty { goal.status = before }
        case "target_date": goal.targetDate = before.isEmpty ? nil : before
        case "notes": goal.notes = before
        default: break
        }
    }

    // MARK: 命令行小抄

    /// 读 .courier-state.json 构造 CourierRoster；读不到（或没有习惯清单）返回 nil。
    /// 缺 archivedHabits、goals、habitUnits 或 habitTargets（旧版小抄）时对应字段为 nil：那一项不查，由应用收录时再查
    nonisolated static func cliRoster() -> CourierRoster? {
        guard let data = FileManager.default.contents(atPath: stateURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let habits = object["habits"] as? [String] else { return nil }
        let goals = (object["goals"] as? [[String: Any]]).map { rows in
            rows.compactMap { row -> CourierRoster.GoalRow? in
                guard let title = row["title"] as? String, !title.isEmpty else { return nil }
                return .init(title: title, status: row["status"] as? String ?? "active", progress: (row["progress"] as? NSNumber)?.intValue ?? 0)
            }
        }
        return CourierRoster(habits: habits, archivedHabits: object["archivedHabits"] as? [String], goals: goals,
                             habitUnits: object["habitUnits"] as? [String],
                             habitTargets: (object["habitTargets"] as? [NSNumber])?.map(\.doubleValue))
    }
}
