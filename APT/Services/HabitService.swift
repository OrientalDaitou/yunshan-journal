import Foundation
import SwiftData

// 习惯的打卡、数量与修为预估：只碰数据，不画界面（界面在 HabitsView、Shared 的 HabitCheckIn）。
//
// 这里找打卡一律不读 `habit.logs`：SwiftData 里每次保存、每次重新取习惯（功课页的 @Query 每次保存都会重取）之后，
// 打卡关系都会变“冷”，再读要把这个习惯的打卡逐条从库里补回来（5 年数据一个习惯约 0.1–0.2 秒，全部习惯约 1.3 秒）。
// 改为按日期 / 按习惯用 #Predicate 直接取（约 1 毫秒）；统计读修为模型（CultivationModel）按习惯缓存好的。

// MARK: - 按日期 / 按习惯取打卡

/// 某一天的打卡：#Predicate 一次取出这天的全部打卡（含未保存的），按习惯分组，代替逐个习惯读 habit.logs。
/// 结果与原来的写法完全相同。同一习惯这天有不止一条记录时（旧数据才可能出现），仍按原来的写法从它自己的打卡关系里取，
/// 保持原来“以哪条为准”的规则：找“这天那条”取关系里的第一条（Habit.log(on:)）；算修为取这天的全部、以最后一条为准
/// （先后同 Habit.logValues，见 HabitStats）。取数出错时整个退回原来的写法。
struct HabitDayLogs {
    let day: LocalDay
    /// 习惯 ID → 这天它的打卡；nil 表示取数出错
    private let byHabit: [PersistentIdentifier: [HabitLog]]?

    init(day: LocalDay, context: ModelContext) {
        self.day = day
        let key = day.key
        guard let fetched = try? context.fetch(FetchDescriptor<HabitLog>(predicate: #Predicate<HabitLog> { $0.dateKey == key })) else {
            byHabit = nil
            return
        }
        var map: [PersistentIdentifier: [HabitLog]] = [:]
        for log in fetched where !log.isDeleted {
            if let owner = log.habit { map[owner.persistentModelID, default: []].append(log) }
        }
        byHabit = map
    }

    /// 这天它的那条打卡（= habit.log(on: day)）
    func log(of habit: Habit) -> HabitLog? {
        guard let byHabit else { return habit.log(on: day) }
        let logs = byHabit[habit.persistentModelID] ?? []
        return logs.count > 1 ? habit.log(on: day) : logs.first
    }

    /// 这天它的打卡值（与 Habit.logValues 的换算相同，保留打卡当时的目标等字段）：按天算修为差用
    func values(of habit: Habit) -> [HabitLogValue] {
        guard let byHabit else { return scanned(habit) }
        let logs = byHabit[habit.persistentModelID] ?? []
        if logs.count > 1 { return scanned(habit) }
        return logs.map { HabitLogValue(day: day, completed: $0.completed, quantity: $0.quantity, target: $0.targetAtLog) }
    }

    /// 原来的写法：从这个习惯自己的打卡关系里找这一天的
    private func scanned(_ habit: Habit) -> [HabitLogValue] {
        habit.log(on: day) == nil ? [] : habit.logValues.filter { $0.day == day }
    }
}

/// 按习惯直接取打卡（#Predicate 交给数据库），不读 habit.logs（理由见本文件开头）。功课详情页用。
/// 习惯还没放进任何 context、或取数出错时退回原来的写法。
enum HabitLogQuery {
    /// 这个习惯有没有带数量、时长或备注的打卡（与 `habit.logs.contains { 有数量 || 有时长 || 有备注 }` 相同）
    static func hasDetails(_ habit: Habit) -> Bool {
        func scanned() -> Bool { (habit.logs ?? []).contains { $0.quantity != nil || $0.durationMinutes != nil || !$0.notes.isEmpty } }
        guard let context = habit.modelContext else { return scanned() }
        let id = habit.persistentModelID
        var descriptor = FetchDescriptor<HabitLog>(predicate: #Predicate<HabitLog> {
            $0.habit?.persistentModelID == id && ($0.quantity != nil || $0.durationMinutes != nil || $0.notes != "")
        })
        descriptor.fetchLimit = 1
        guard let count = try? context.fetchCount(descriptor) else { return scanned() }
        return count > 0
    }

    /// 最近的 count 条打卡（= habit.recentLogs(count)：按日期从新到旧，同一天的保持关系里原来的先后）。
    /// 只让数据库按日期倒序取 count + 1 条：这几条的日期互不相同时，前 count 条就是唯一的答案；
    /// 有同一天两条的（旧数据才可能有），同一天谁先谁后要按关系里的次序，退回原来的写法
    static func recent(_ habit: Habit, _ count: Int) -> [HabitLog] {
        guard count > 0 else { return [] }
        guard let context = habit.modelContext else { return habit.recentLogs(count) }
        let id = habit.persistentModelID
        var descriptor = FetchDescriptor<HabitLog>(predicate: #Predicate<HabitLog> { $0.habit?.persistentModelID == id },
                                                   sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
        descriptor.fetchLimit = count + 1
        guard let logs = try? context.fetch(descriptor) else { return habit.recentLogs(count) }
        let keys = logs.map(\.dateKey)
        // 日期互不相同，且按 Swift 的字符串比较也是从新到旧（与 recentLogs 的比较方式一致）
        guard zip(keys, keys.dropFirst()).allSatisfy({ $0 > $1 }) else { return habit.recentLogs(count) }
        return Array(logs.prefix(count))
    }

    /// 这个习惯的全部打卡值（= habit.logValues，同一天不止一条的旧数据先后可能不同）：修为模型里还没有这个习惯时，
    /// 打卡后判断新纪录用。习惯还没放进 context、或取数出错时退回原来的写法
    static func values(_ habit: Habit) -> [HabitLogValue] {
        guard let context = habit.modelContext else { return habit.logValues }
        let id = habit.persistentModelID
        guard let logs = try? context.fetch(FetchDescriptor<HabitLog>(predicate: #Predicate<HabitLog> { $0.habit?.persistentModelID == id }))
        else { return habit.logValues }
        return logs.compactMap { log in
            guard !log.isDeleted, let day = LocalDay(key: log.dateKey) else { return nil }
            return HabitLogValue(day: day, completed: log.completed, quantity: log.quantity, target: log.targetAtLog)
        }
    }
}

// MARK: - 打卡

/// 打卡相关操作，同时负责“+修为”反馈。
@MainActor
enum HabitActions {
    enum ToggleResult {
        /// 已打卡或已取消
        case toggled
        /// 没有改动：这天已记了未达标的真实数量（不会改写成目标值），请让用户填写数量（例如打开数量输入）
        case needsQuantity
        /// 没有改动（未来的日子不能打卡）
        case ignored
    }

    /// 切换某天的打卡：已达成 → 取消；没有记录（或只记了完成、没记数量）→ 记为达成。
    /// 数量型习惯这天已记了未达标的数量时不改写（返回 .needsQuantity，并飘一行提示），由调用方打开数量输入。
    @discardableResult
    static func toggle(_ habit: Habit, on day: LocalDay, context: ModelContext, effects: EffectsCenter,
                       allHabits: [Habit], config: CultivationConfig) -> ToggleResult {
        guard day <= .today() else { return .ignored }
        // 这天的打卡按日期一次取出（不读 habit.logs）：找这个习惯的那条、算当天修为差共用
        let dayLogs = HabitDayLogs(day: day, context: context)
        let existing = dayLogs.log(of: habit)
        // 这条打卡当时的数量目标（约定第 3 条）：targetAtLog > 0 用它；== 0 表示当时没有数量目标；nil 用习惯当前目标
        let target = HabitQuantity.target(habit, atLog: existing?.targetAtLog)
        let wasAchieved: Bool = {
            guard let existing else { return false }
            if let target { return (existing.quantity ?? 0) >= target }
            return existing.completed
        }()
        if !wasAchieved, let target, let quantity = existing?.quantity, quantity > 0 {
            let unit = habit.unit.isEmpty ? "" : " \(habit.unit)"
            effects.hint("已记 \(quantity.formatted()) / \(target.formatted())\(unit)，未达标：请填写实际数量")
            return .needsQuantity
        }
        let newValue: HabitLogValue?
        if wasAchieved {
            newValue = nil
        } else {
            var value = existing.map { currentValue(of: $0, on: day) } ?? HabitLogValue(day: day, completed: true, quantity: nil)
            value.completed = true
            value.quantity = target ?? existing?.quantity
            newValue = value
        }
        apply(habit, day: day, dayLogs: dayLogs, existing: existing, newValue: newValue, context: context, effects: effects,
              allHabits: allHabits, config: config)
        return .toggled
    }

    /// 设置数量（数量型习惯）。quantity 为 nil 或 0 时删除当天记录。
    static func setQuantity(_ habit: Habit, on day: LocalDay, quantity: Double?, context: ModelContext, effects: EffectsCenter,
                            allHabits: [Habit], config: CultivationConfig) {
        let dayLogs = HabitDayLogs(day: day, context: context)
        let existing = dayLogs.log(of: habit)
        var value: HabitLogValue?
        if let quantity, quantity > 0 {
            value = existing.map { currentValue(of: $0, on: day) } ?? HabitLogValue(day: day, completed: true, quantity: nil)
            value?.completed = true
            value?.quantity = quantity
        }
        apply(habit, day: day, dayLogs: dayLogs, existing: existing, newValue: value, context: context, effects: effects,
              allHabits: allHabits, config: config)
    }

    /// 这天现有的打卡值（与 Habit.logValues 的换算相同，保留打卡当时的目标等字段）。
    /// log 就是这一天它的那条：直接换算这一条，不必把全部打卡都换算一遍再找
    private static func currentValue(of log: HabitLog, on day: LocalDay) -> HabitLogValue {
        HabitLogValue(day: day, completed: log.completed, quantity: log.quantity, target: log.targetAtLog)
    }

    /// dayLogs：调用方已取好的这一天的全部打卡（改动之前的样子）；existing：其中这个习惯的那条（= habit.log(on: day)）
    private static func apply(_ habit: Habit, day: LocalDay, dayLogs: HabitDayLogs, existing: HabitLog?, newValue: HabitLogValue?,
                              context: ModelContext, effects: EffectsCenter, allHabits: [Habit], config: CultivationConfig) {
        // 同日递减、每日上限都按天计算，“功课圆满”也只看当天，所以修为的变化 = 这一天修为的变化：
        // 只用这一天的打卡与落笔算前后两次，不必把全部记录各算一遍
        let today = LocalDay.today()
        let key = day.key
        let entries = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate<JournalEntry> { $0.dateKey == key })))
            ?? context.all(JournalEntry.self).filter { $0.dateKey == key }
        let journal = CultivationService.journalSources(entries, today: today)
        // 每个习惯这一天的打卡值（与 allHabits 一一对应）：取自上面一次取出的当天打卡，不必把每个习惯的全部打卡各读一遍
        let base: [(habit: Habit, spec: HabitSpec, logs: [HabitLogValue], archived: Bool)] =
            allHabits.map { h in (h, h.spec, dayLogs.values(of: h), h.archived) }
        func dayXP(replacing: [HabitLogValue]?) -> Int {
            let inputs = base.map { item in
                (spec: item.spec, logs: item.habit === habit ? (replacing ?? item.logs) : item.logs, archived: item.archived)
            }
            return CultivationEngine.compute(sources: CultivationEngine.sources(habits: inputs, today: today) + journal,
                                             config: config, today: today).totalXP
        }
        let before = dayXP(replacing: nil)
        let after = dayXP(replacing: newValue.map { [$0] } ?? [])
        // “功课圆满”的仪式：与修为引擎、首页那行“功课圆满”同一判定，比较这次打卡前后
        let inputsBefore = base.map { (spec: $0.spec, logs: $0.logs, archived: $0.archived) }
        let inputsAfter = base.map { (spec: $0.spec, logs: $0.habit === habit ? (newValue.map { [$0] } ?? []) : $0.logs, archived: $0.archived) }
        let wasPerfect = CultivationEngine.isPerfectDay(day, habits: inputsBefore)
        let isPerfect = CultivationEngine.isPerfectDay(day, habits: inputsAfter)
        // 新纪录：只看今天，且这次让今天由未达标变为达标时才算（改之前先取好统计，改完模型就刷新了）
        let record = day == today && habit.spec.achieved(newValue) && !habit.spec.achieved(existing.map { currentValue(of: $0, on: day) })
            ? brokenRecord(habit, day: day, existing: existing, newValue: newValue, context: context, today: today) : nil

        if let log = existing {
            if let newValue {
                log.completed = newValue.completed
                log.quantity = newValue.quantity
                log.updatedAt = Date()
            } else {
                // 先从习惯上摘下来再删（与原来 habit.logs?.removeAll { $0 === log } 的结果相同：保存前关系里就没有它了），
                // 但只改打卡这一头：关系冷的时候整个改写 habit.logs 要把这个习惯的打卡逐条补回来（约 0.2 秒），这样约 5 毫秒
                log.habit = nil
                context.delete(log)
            }
        } else if let newValue {
            let log = HabitLog(dateKey: day.key, completed: newValue.completed, quantity: newValue.quantity)
            context.insert(log)
            log.habit = habit
        }
        habit.updatedAt = Date()
        DataStore.save(context)
        // 修为模型当场看一眼（只按 ID 取回这一条、重算这一个习惯，约 10 毫秒）：功课页、今日洞府接着刷新时读到的就是新统计，
        // 不必等保存通知的下一轮
        CultivationModel.existing(for: context)?.refresh()
        effects.gain(after - before)
        effects.perfectDayChanged(day: day, wasPerfect: wasPerfect, isPerfect: isPerfect)
        if let record {
            recordHinted[habit.persistentModelID] = (day, record.count)
            effects.hint(HabitRecord.brokenText(title: habit.title, record), icon: "rosette")
        }
    }

    // MARK: 新纪录

    /// 今天已经提示过的新纪录（习惯 → 那天、那时的连续数）：取消再打回来不重复提示；只记在内存里
    private static var recordHinted: [PersistentIdentifier: (day: LocalDay, count: Int)] = [:]

    /// 这次打卡打破了旧纪录（当前这一段之前的最长连续 ≥ 3，见 HabitRecord.broken）时返回新的连续数。
    /// 改之前的统计取修为模型缓存好的（按习惯当前的设定），今天那条换成调用方刚取的；模型里还没有这个习惯时按习惯直接取打卡。
    /// 不读 habit.logs（理由见本文件开头）
    private static func brokenRecord(_ habit: Habit, day: LocalDay, existing: HabitLog?, newValue: HabitLogValue?,
                                     context: ModelContext, today: LocalDay) -> (count: Int, unit: String)? {
        let spec = habit.spec
        var values: [HabitLogValue]
        if let cached = CultivationModel.existing(for: context)?.stats(for: habit, today: today) {
            values = cached.logs.values.filter { $0.day != day }
        } else {
            values = HabitLogQuery.values(habit).filter { $0.day != day }
        }
        let beforeValues = values + (existing.map { [currentValue(of: $0, on: day)] } ?? [])
        values += newValue.map { [$0] } ?? []
        let before = HabitStats(spec: spec, logs: beforeValues, today: today)
        let after = HabitStats(spec: spec, logs: values, today: today)
        guard let record = HabitRecord.broken(before: before, after: after) else { return nil }
        if let hinted = recordHinted[habit.persistentModelID], hinted.day == day, hinted.count >= record.count { return nil }
        return record
    }
}

// MARK: - 数量型习惯

/// 数量输入的解析与显示，以及某天适用的数量目标。
enum HabitQuantity {
    /// 解析用户输入的数量：“8,500”“1,234,567.5”按千分位去掉逗号；只有一个逗号且不像千分位（“1,5”）时当小数点；
    /// 全角逗号、句点和空格都能识别。无法解析时返回 nil。
    static func parse(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "．", with: ".")
            .replacingOccurrences(of: "。", with: ".")
            .filter { !$0.isWhitespace }
        if text.range(of: #"^[1-9][0-9]*(,[0-9]{3})+(\.[0-9]+)?$"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: ",", with: "")
        } else if text.filter({ $0 == "," }).count == 1, !text.contains(".") {
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(text), value.isFinite, abs(value) < 1e12 else { return nil }
        return value
    }

    /// 整数（且不会溢出 Int）
    static func isWhole(_ value: Double) -> Bool { value.isFinite && abs(value) < 1e15 && value.rounded() == value }

    /// 填回输入框的文字：不丢精度（整数不带小数点）
    static func text(_ value: Double) -> String { isWhole(value) ? String(Int(value)) : String(value) }

    /// 详情页数量框旁的“＋1”在哪个数上加：框里改过、还没点“记录”的数（能读成大于 0 的数）优先，
    /// 点“＋1”不会把刚打的字冲掉；框里没改（与原本填进去的今天那条一样）或清空了，按点的这一刻今天已记的数（没记为 0）。
    /// 框里是读不懂的字或 ≤ 0 时返回 nil：不加，响一声（与“记录”按钮同一个规矩）。
    /// - typed：框里现在的字；shown：框里原本填的数（页面上今天那条的数量，没记为 nil）；stored：点的这一刻库里今天那条的数量
    static func stepBase(typed: String, shown: Double?, stored: Double?) -> Double? {
        let raw = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return stored ?? 0 }
        guard let value = parse(raw), value > 0 else { return nil }
        return value == shown ? (stored ?? 0) : value
    }

    /// 这一天适用的数量目标：打卡当时记下的目标优先（0 表示当时没有数量目标），没记就用习惯当前的目标。
    static func target(_ habit: Habit, on day: LocalDay) -> Double? { target(habit, atLog: habit.log(on: day)?.targetAtLog) }

    /// 同上，用调用方已取好的这天打卡（例如 stats.logs[day]，没有打卡时为 nil），不再把全部打卡扫一遍
    static func target(_ habit: Habit, log: HabitLogValue?) -> Double? { target(habit, atLog: log?.target) }

    /// 同上，atLog 是这天那条打卡记下的目标（HabitLog.targetAtLog；没有打卡或没记时为 nil）
    static func target(_ habit: Habit, atLog: Double?) -> Double? {
        if let atLog { return atLog > 0 ? atLog : nil }
        return habit.targetValue.flatMap { $0 > 0 ? $0 : nil }
    }

    /// 这一天点打卡时应该打开数量输入，而不是直接切换（习惯有数量目标，或这天按当时的目标记过数量）。
    static func usesInput(_ habit: Habit, on day: LocalDay) -> Bool {
        (habit.targetValue ?? 0) > 0 || target(habit, on: day) != nil
    }

    /// 同上，用调用方已取好的这天打卡（stats.logs[day]）
    static func usesInput(_ habit: Habit, log: HabitLogValue?) -> Bool {
        (habit.targetValue ?? 0) > 0 || target(habit, log: log) != nil
    }

    /// 同 usesInput(_:on:)，这天的打卡按日期直接取（点热力图格子时用，不读 habit.logs；结果相同）
    static func usesInput(_ habit: Habit, on day: LocalDay, context: ModelContext) -> Bool {
        (habit.targetValue ?? 0) > 0 || target(habit, atLog: HabitDayLogs(day: day, context: context).log(of: habit)?.targetAtLog) != nil
    }

    /// 修改数量目标之前调用：把今天之前、还没记目标的旧打卡补记成旧目标（旧目标为空或 ≤0 时记 0，表示当时没有数量目标），
    /// 这样改目标不会改写历史达标。今天的打卡不补记：新目标从改的当天起生效，今天的显示、达标判定、重新记录都按新目标。
    /// 目标没变时什么都不做。返回补记的条数。
    /// 这不是用户改了那条打卡，所以不动 updatedAt（撤销传书时仍按“未改过”处理）。调用方负责保存。
    /// 要补记的打卡用 #Predicate 按习惯直接取（还没记目标的），不读 habit.logs；保存后修为模型按保存通知里的 ID 取回这几条重算
    @discardableResult
    static func recordTargetsBeforeChange(_ habit: Habit, to newTarget: Double?) -> Int {
        let oldTarget = (habit.targetValue ?? 0) > 0 ? habit.targetValue : nil
        let normalizedNew = (newTarget ?? 0) > 0 ? newTarget : nil
        guard oldTarget != normalizedNew else { return 0 }
        var count = 0
        let todayKey = LocalDay.today().key
        var candidates: [HabitLog]?
        if let context = habit.modelContext {
            let id = habit.persistentModelID
            candidates = try? context.fetch(FetchDescriptor<HabitLog>(predicate: #Predicate<HabitLog> {
                $0.habit?.persistentModelID == id && $0.targetAtLog == nil
            }))
        }
        for log in candidates ?? habit.logs ?? [] where log.targetAtLog == nil && log.dateKey < todayKey {
            log.targetAtLog = oldTarget ?? 0
            count += 1
        }
        return count
    }

    /// 这天已有记录但还没达标（例如只记了 15 / 30）：直接切换会把真实数量改写成目标值，应改为打开数量输入。
    static func needsInput(_ habit: Habit, on day: LocalDay) -> Bool { needsInput(habit, existing: habit.log(on: day)) }

    /// 同上，这天的打卡按日期直接取（点打卡圈时用，不读 habit.logs；结果相同）
    static func needsInput(_ habit: Habit, on day: LocalDay, context: ModelContext) -> Bool {
        needsInput(habit, existing: HabitDayLogs(day: day, context: context).log(of: habit))
    }

    /// existing：这天它的那条打卡（= habit.log(on: day)）
    private static func needsInput(_ habit: Habit, existing log: HabitLog?) -> Bool {
        guard let log, let target = target(habit, atLog: log.targetAtLog) else { return false }
        return (log.quantity ?? 0) < target
    }

    /// 同上，用调用方已取好的这天打卡（stats.logs[day]），打卡圈的 body 里不再自己扫
    static func needsInput(_ habit: Habit, log: HabitLogValue?) -> Bool {
        guard let log, let target = target(habit, log: log) else { return false }
        return (log.quantity ?? 0) < target
    }
}

// MARK: - 修为变化预估

/// 修改习惯设置（频率、星期、开始日期、归档）前后的总修为，用于改动会改写历史修为时先请用户确认。
struct HabitXPChange: Identifiable {
    var id = UUID()
    var before: Int
    var after: Int

    var deltaText: String { after >= before ? "+\(after - before)" : "\(after - before)" }

    /// 把 habit 的设定换成 spec / archived 后重算全部修为；没有变化时返回 nil。
    /// 界面已经建了修为模型时借它缓存的各习惯统计与落笔，只按新设定重算这一个习惯（约 5 毫秒）；
    /// 没有模型（或模型里还没有这个习惯）时全部取出来算（fullTotals）。两种算法结果相同（自检里对照）。
    @MainActor
    static func preview(_ habit: Habit, spec: HabitSpec, archived: Bool, context: ModelContext) -> HabitXPChange? {
        let totals = CultivationModel.existing(for: context)?.totals(replacing: habit, spec: spec, archived: archived)
            ?? fullTotals(habit, spec: spec, archived: archived, context: context)
        return totals.before == totals.after ? nil : HabitXPChange(before: totals.before, after: totals.after)
    }

    /// 全部取出来算：换设定前后各全量算一次修为（不重新取习惯本身，见 ModelContext.allHabits）
    @MainActor
    static func fullTotals(_ habit: Habit, spec: HabitSpec, archived: Bool, context: ModelContext) -> (before: Int, after: Int) {
        let today = LocalDay.today()
        let habits = context.allHabits()
        let config = context.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
        let journal = CultivationService.journalSources(context.all(JournalEntry.self), today: today)
        func total(swapped: Bool) -> Int {
            let inputs = habits.map { h in
                let isTarget = swapped && h.persistentModelID == habit.persistentModelID
                return (spec: isTarget ? spec : h.spec, logs: h.logValues, archived: isTarget ? archived : h.archived)
            }
            return CultivationEngine.compute(sources: CultivationEngine.sources(habits: inputs, today: today) + journal,
                                             config: config, today: today).totalXP
        }
        return (total(swapped: false), total(swapped: true))
    }
}
