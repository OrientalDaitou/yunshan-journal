import Foundation
import SwiftData

// MARK: - 打卡关系变冷：页面读修为模型的统计、按日期 / 按习惯直接取打卡

extension SelfTest {
    /// 可复现的随机数（与 cultivationChecks 同一种）
    private struct ColdLogsRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 19. SwiftData 里每次保存、每次重新取习惯之后，打卡关系都会变“冷”，再读 habit.logs 要把打卡逐条补回来。
    /// 功课页、今日洞府的打卡圈、打卡（HabitActions）、改设置前的修为预估、传书收录与快照，都改为读修为模型缓存的统计，
    /// 或按日期 / 按习惯直接取打卡。这里随机增删改，每一步之后先像功课页的 @Query 那样把习惯重新取一遍，
    /// 再逐项与“直接从打卡关系全量计算”（原来的写法）对照；对照时不替模型看一眼，确认它在打卡（当场）、
    /// 改设置（含只改打卡当时的目标、不动 updatedAt）、归档、新立与删除习惯、传书打卡与撤销之后都已自己刷新。
    /// 最后造同一天三条打卡的旧数据，确认“以哪条为准”与原来相同。
    static func coldLogsChecks(_ check: (Bool, String) -> Void) throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let c = ModelContext(container)
        let settings = DataStore.settings(in: c)
        settings.dailyCap = 90   // 上限小一些，打卡多的日子会顶到上限
        DataStore.profile(in: c)
        DataStore.save(c)
        let today = LocalDay.today()
        var rng = ColdLogsRandom(state: 20261021)
        func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }

        // 每天、指定星期、每周 N 次、数量型（每天 / 每周）、有归档日的归档、没有归档日的旧归档；第 2 个的打卡不带数量、时长、备注
        let plans: [(frequency: HabitFrequency, target: Double?)] = [
            (.daily, nil), (.weekdays, nil), (.weekly, nil), (.daily, 30), (.weekly, 20), (.daily, nil), (.daily, 45), (.weekdays, nil),
        ]
        for (index, plan) in plans.enumerated() {
            let habit = Habit(title: "冷关系自检\(index)")
            habit.frequencyKind = plan.frequency
            habit.weekdays = plan.frequency == .weekdays ? [0, 1, 3, 5] : []
            habit.targetPerWeek = 3
            habit.targetValue = plan.target
            habit.unit = plan.target == nil ? "" : "分钟"
            habit.startDate = today.adding(days: -int(20...40)).key
            habit.createdAt = today.adding(days: -int(0...45)).date()
            habit.sortOrder = index
            if index == 5 { habit.archived = true; habit.archivedAt = today.adding(days: -5).key }
            if index == 7 { habit.archived = true }
            c.insert(habit)
            for offset in 0...40 where chance(0.6) {
                let log = HabitLog(dateKey: today.adding(days: -offset).key, completed: chance(0.9),
                                   quantity: plan.target == nil ? nil : pick([10, 20, 30, 45, 60]))
                log.targetAtLog = plan.target == nil ? nil : pick([nil, nil, 0, 30, 45])
                if index != 2, chance(0.1) { log.notes = "补记" }
                if index != 2, chance(0.05) { log.durationMinutes = 25 }
                c.insert(log)
                log.habit = habit
            }
        }
        for _ in 0..<30 {
            c.insert(JournalEntry(kind: pick(JournalKind.allCases), body: "冷关系自检", dateKey: today.adding(days: int(-20...0)).key))
        }
        DataStore.save(c)

        // 与界面一样登记为这个库的那一份：打卡后当场看一眼、修为预估都借它
        let model = CultivationModel.shared(for: c)
        let effects = EffectsCenter()
        var notes: [String] = []
        func note(_ text: String) { if notes.count < 6 { notes.append(text) } }
        /// 保存通知的下一轮：让修为模型按通知自己看一眼（应用里主线程下一轮自动做）
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        /// 像功课页的 @Query 那样把习惯重新取一遍（打卡关系随之变冷）
        @discardableResult
        func refetch() -> [Habit] { (try? c.fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? [] }

        /// 重新取过习惯之后，各页面用的统计、打卡圈、打卡时找“这天那条”、详情页，都与直接从打卡关系算的相同；
        /// 修为、今日圆满、今日洞府功课卡与全量计算相同。不替模型看一眼：看它此刻是不是已经是新的
        var verifies = 0, mismatches = 0
        func verify(_ label: String) {
            verifies += 1
            let habits = refetch()
            var bad: [String] = []
            for habit in habits {
                let full = habit.stats(today: today)
                // 功课页左侧列表、详情（含已归档的）
                guard let stats = model.stats(for: habit, today: today) else { bad.append("\(habit.title) 模型里没有"); continue }
                if stats != full { bad.append("\(habit.title) 统计") }
                // 打卡圈（功课页、今日洞府）：今天是否达标、要不要弹数量输入
                if stats.isAchieved(stats.today) != full.isAchieved(today)
                    || HabitQuantity.needsInput(habit, log: stats.logs[stats.today]) != HabitQuantity.needsInput(habit, on: today) {
                    bad.append("\(habit.title) 打卡圈")
                }
                // 点打卡圈、点热力图格子、打卡时找“这天那条”，按天算修为差时这天的打卡
                for day in [today, today.adding(days: -int(1...5)), today.adding(days: -int(6...20)), today.adding(days: -int(21...42))] {
                    let dayLogs = HabitDayLogs(day: day, context: c)
                    if dayLogs.log(of: habit) !== habit.log(on: day) || dayLogs.values(of: habit) != habit.logValues.filter({ $0.day == day })
                        || HabitQuantity.needsInput(habit, on: day, context: c) != HabitQuantity.needsInput(habit, on: day)
                        || HabitQuantity.usesInput(habit, on: day, context: c) != HabitQuantity.usesInput(habit, on: day) {
                        bad.append("\(habit.title) \(day.key) 这天那条")
                    }
                }
                // 详情页：要不要显示“最近记录”、最近 10 条
                let details = (habit.logs ?? []).contains { $0.quantity != nil || $0.durationMinutes != nil || !$0.notes.isEmpty }
                if HabitLogQuery.hasDetails(habit) != details || !HabitLogQuery.recent(habit, 10).elementsEqual(habit.recentLogs(10), by: ===) {
                    bad.append("\(habit.title) 最近记录")
                }
            }
            // 今日洞府功课卡（未归档的，按 sortOrder）与打卡时用的全部习惯
            let expectedRows = habits.filter { !$0.archived }.map { "\($0.title)|\($0.stats(today: today).streak.count)" }
            if model.rows.map({ "\($0.habit.title)|\($0.stats.streak.count)" }) != expectedRows
                || model.habits.map(\.title) != habits.map(\.title) {
                bad.append("功课卡")
            }
            let config = c.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
            let perfect = config.enabled && CultivationEngine.isPerfectDay(today, habits: habits.map { ($0.spec, $0.logValues, $0.archived) })
            if model.state != CultivationService.fullState(context: c) || model.perfectToday != perfect { bad.append("修为") }
            if !bad.isEmpty {
                mismatches += 1
                note("\(label)：\(bad.prefix(3).joined(separator: "、"))")
            }
        }

        /// 原来的修为预估（HabitXPChange.preview 改动前的写法）：全部取出来，换设定前后各全量算一次
        func originalTotals(_ habit: Habit, spec: HabitSpec, archived: Bool) -> (before: Int, after: Int) {
            let habits = c.all(Habit.self)
            let config = c.all(AppSettings.self).first?.cultivation ?? CultivationConfig()
            let journal = CultivationService.journalSources(c.all(JournalEntry.self), today: today)
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
        var previews = 0, previewMismatches = 0, previewChanges = 0
        func comparePreview(_ habit: Habit, spec: HabitSpec, archived: Bool, _ label: String) {
            previews += 1
            let original = originalTotals(habit, spec: spec, archived: archived)
            if original.before != original.after { previewChanges += 1 }
            let preview = HabitXPChange.preview(habit, spec: spec, archived: archived, context: c)
            guard let viaModel = model.totals(replacing: habit, spec: spec, archived: archived),
                  viaModel.before == original.before, viaModel.after == original.after,
                  (preview == nil) == (original.before == original.after),
                  preview.map({ $0.before == original.before && $0.after == original.after }) ?? true else {
                previewMismatches += 1
                note("\(label)：修为预估与全量计算不同")
                return
            }
        }

        verify("初建")
        var kinds: [String: Int] = [:]
        var deleteRebuilds = 0
        var duplicateCheckins = 0, duplicateLeaks = 0
        /// 改设置、归档刚保存、模型还没看到时，功课页取到的统计与全量计算不同的次数
        var early = 0
        for step in 0..<120 {
            let habits = refetch()
            let live = habits.filter { !$0.archived }
            switch int(0...11) {
            case 0, 1, 2:
                // 打卡（功课页、今日洞府的打卡圈、热力图格子都走这里）：打完不等下一轮，修为模型当场就是新的，所以这里不 settle
                guard let habit = live.randomElement(using: &rng) else { continue }
                let day = today.adding(days: -int(0...15))
                if HabitQuantity.usesInput(habit, on: day, context: c) {
                    HabitActions.setQuantity(habit, on: day, quantity: pick([nil, 10, 30, 60]), context: c, effects: effects,
                                             allHabits: habits, config: settings.cultivation)
                } else {
                    HabitActions.toggle(habit, on: day, context: c, effects: effects, allHabits: model.habits, config: settings.cultivation)
                }
                kinds["打卡", default: 0] += 1
                verify("第 \(step) 步打卡")
                continue
            case 3:
                // 改频率 / 星期 / 开始日期（与 HabitEditor.requestSave、save 相同的写法）：先预估修为，再保存
                guard let habit = habits.randomElement(using: &rng) else { continue }
                var spec = habit.spec
                spec.frequency = pick(HabitFrequency.allCases)
                spec.weekdays = spec.frequency == .weekdays ? pick([[0, 2, 4], [1, 3], [5, 6]]) : []
                spec.targetPerWeek = int(1...4)
                spec.startDay = today.adding(days: -int(5...45))
                comparePreview(habit, spec: spec, archived: habit.archived, "第 \(step) 步改设置")
                habit.frequencyKind = spec.frequency
                habit.weekdays = spec.weekdays
                habit.targetPerWeek = spec.targetPerWeek
                habit.startDate = spec.startDay.key
                habit.updatedAt = Date()
                DataStore.save(c)
                // 模型还没看到这次保存（保存通知的下一轮才看）时，功课页取到的统计也已按新设置算
                if model.stats(for: habit, today: today) != habit.stats(today: today) { early += 1 }
                kinds["改设置", default: 0] += 1
            case 4:
                // 改数量目标（与 HabitEditor.save 相同：先给旧打卡补记当时的目标；补记不动打卡的 updatedAt）
                guard let habit = habits.randomElement(using: &rng) else { continue }
                let target: Double? = pick([nil, 20, 30, 50])
                HabitQuantity.recordTargetsBeforeChange(habit, to: target)
                habit.targetValue = target
                habit.unit = target == nil ? "" : "分钟"
                habit.updatedAt = Date()
                DataStore.save(c)
                kinds["改数量目标", default: 0] += 1
            case 5:
                // 只改打卡当时的目标、不动 updatedAt（打卡条数、最新修改时间都不变，指纹看不出来）：模型要按保存通知认出来
                guard let habit = habits.randomElement(using: &rng),
                      let log = HabitLogQuery.recent(habit, 6).randomElement(using: &rng) else { continue }
                log.targetAtLog = pick([nil, 0, 15, 40, 90])
                DataStore.save(c)
                kinds["只改 targetAtLog", default: 0] += 1
            case 6:
                // 归档 / 取消归档（与 HabitDetail.setArchived 相同的写法；取消归档前先预估）
                guard let habit = habits.randomElement(using: &rng) else { continue }
                if habit.archived {
                    var spec = habit.spec
                    spec.archivedDay = nil
                    comparePreview(habit, spec: spec, archived: false, "第 \(step) 步取消归档")
                }
                habit.archived.toggle()
                habit.archivedAt = habit.archived ? LocalDay.today().key : nil
                habit.updatedAt = Date()
                DataStore.save(c)
                if model.stats(for: habit, today: today) != habit.stats(today: today) { early += 1 }
                kinds["归档", default: 0] += 1
            case 7, 8:
                // 飞剑传书：一封两条打卡（有时同一习惯同一天：后一条要认出前一条还没保存的、跳过），之后多半撤销
                guard let a = live.randomElement(using: &rng), let b = chance(0.4) ? a : live.randomElement(using: &rng) else { continue }
                let dayA = today.adding(days: -int(0...10))
                let dayB = a === b || chance(0.5) ? dayA : today.adding(days: -int(0...10))
                let json = """
                {"from":"冷关系自检","items":[
                  {"type":"checkin","date":"\(dayA.key)","habit":"\(a.title)"},
                  {"type":"checkin","date":"\(dayB.key)","habit":"\(b.title)","quantity":\(pick([5, 30, 60]))}
                ]}
                """
                guard let delivery = try? CourierService.apply(try CourierParser.parse(Data(json.utf8)), fileName: "冷关系自检\(step).json", context: c) else {
                    note("第 \(step) 步传书没有收录")
                    continue
                }
                kinds["传书打卡", default: 0] += 1
                if a === b {
                    duplicateCheckins += 1
                    let key = dayA.key, id = a.persistentModelID
                    let count = (try? c.fetchCount(FetchDescriptor<HabitLog>(predicate: #Predicate { $0.dateKey == key && $0.habit?.persistentModelID == id }))) ?? -1
                    if count != 1 { duplicateLeaks += 1 }
                }
                settle()
                verify("第 \(step) 步传书")
                guard chance(0.7) else { continue }
                _ = CourierService.undo(delivery, context: c, refresh: false)
                kinds["撤销传书", default: 0] += 1
            case 9:
                // 新立一项功课（与 HabitEditor.save 相同：插入后、保存前补记目标——还没保存的新习惯，什么都不用补）
                guard habits.count < 11 else { continue }
                let habit = Habit(title: "冷关系自检新\(step)")
                habit.sortOrder = (habits.map(\.sortOrder).max() ?? 0) + 1
                habit.startDate = today.adding(days: -int(0...10)).key
                c.insert(habit)
                let target: Double? = pick([nil, 30])
                if HabitQuantity.recordTargetsBeforeChange(habit, to: target) != 0 { note("第 \(step) 步新习惯补记了打卡") }
                habit.targetValue = target
                habit.updatedAt = Date()
                DataStore.save(c)
                kinds["新立功课", default: 0] += 1
            case 10:
                // 落笔（修为里修行录的那部分）
                JournalActions.save(JournalEntry(kind: pick(JournalKind.allCases), body: "冷关系自检 \(step)",
                                                 dateKey: today.adding(days: -int(0...10)).key), context: c, effects: effects)
                kinds["落笔", default: 0] += 1
            default:
                // 删除一项功课（连同打卡，与 HabitEditor 的删除相同）：模型按习惯去掉它的打卡，不把全部打卡整表重取
                guard habits.count > 6, let habit = habits.randomElement(using: &rng) else { continue }
                let rebuilds = model.work.logRebuilds
                c.delete(habit)
                DataStore.save(c)
                settle()
                deleteRebuilds += model.work.logRebuilds - rebuilds
                kinds["删除功课", default: 0] += 1
            }
            settle()
            verify("第 \(step) 步")
        }
        let covered = ["打卡", "改设置", "改数量目标", "只改 targetAtLog", "归档", "传书打卡", "撤销传书", "新立功课", "删除功课"]
            .allSatisfy { (kinds[$0] ?? 0) > 0 }
        check(mismatches == 0 && covered && verifies > 100,
              "重新取过习惯之后，功课页统计、打卡圈、找“这天那条”、详情页、今日洞府功课卡与修为，都与直接从打卡关系全量计算相同；"
                + "修为模型在打卡（当场）与改设置、只改 targetAtLog、归档、新立与删除功课、传书打卡与撤销之后都已自己刷新（\(verifies) 次对照，"
                + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "、") + "）"
                + (notes.isEmpty ? "" : "：\(notes)"))
        check(early == 0, "改设置、归档刚保存、修为模型还没看到这次保存时，功课页取到的统计已按新设置算，与全量计算相同")
        check(previewMismatches == 0 && previews >= 5 && previewChanges > 0,
              "改设置 / 取消归档前的修为预估借修为模型，与全部取出来全量计算相同（\(previews) 次，其中 \(previewChanges) 次修为有变化）")
        check(deleteRebuilds == 0 && (kinds["删除功课"] ?? 0) > 0,
              "删除功课后修为模型按习惯去掉它的打卡，不整表重取（\(kinds["删除功课"] ?? 0) 次）")
        check(duplicateCheckins > 0 && duplicateLeaks == 0,
              "一封传书里同一习惯同一天两条打卡：按日期直接取也认得出前一条还没保存的，只记一条（\(duplicateCheckins) 次）")

        // 只取 ID 再拿已登记的对象：与整取是同样的对象、同样的次序。有未保存的增删时照原来整取
        // （那时连整取两次的次序都不一样，只能比是不是同样的那几个）
        let savedSame = !c.hasChanges && c.allHabits().elementsEqual(c.all(Habit.self), by: ===)
        let pending = Habit(title: "未保存的功课")
        c.insert(pending)
        var doomed: Habit?
        if let first = c.all(Habit.self).first(where: { $0 !== pending }) {
            doomed = first
            c.delete(first)
        }
        let unsaved = c.allHabits()
        let unsavedSame = Set(unsaved.map(ObjectIdentifier.init)) == Set(c.all(Habit.self).map(ObjectIdentifier.init))
            && unsaved.contains { $0 === pending } && !unsaved.contains { $0 === doomed }
        c.rollback()
        check(savedSame && unsavedSame && c.allHabits().elementsEqual(c.all(Habit.self), by: ===),
              "ModelContext.allHabits（只取 ID，不让打卡关系变冷）与 all(Habit.self) 是同样的对象与次序；有未保存的增删时同样是那几个")

        // 传书快照、AI 摘要：借修为模型的结果与没有模型的 context（原来的全量写法）相同
        settle()
        let other = ModelContext(container)
        func habitLines(_ summary: PlannerSummary) -> [String] {
            summary.habits.map { "\($0.title)|\($0.schedule)|\($0.completion7d ?? -1)|\($0.completion30d ?? -1)|\($0.streak)|\($0.weeklyTrend)|\($0.recent)" }
        }
        let viaModel = SummaryCollector.build(context: c, options: .init(), today: today)
        let viaFull = SummaryCollector.build(context: other, options: .init(), today: today)
        check(CultivationModel.existing(for: other) == nil && habitLines(viaModel) == habitLines(viaFull) && !viaModel.habits.isEmpty
              && viaModel.cultivation?.totalXP == viaFull.cultivation?.totalXP
              && CourierService.readme(context: c) == CourierService.readme(context: other),
              "传书快照与 AI 摘要的习惯一节、修为、投递说明的习惯表：借修为模型与原来的全量写法相同")

        // 同一习惯同一天三条（旧数据才可能有）：统计、修为“以最后一条为准”，找“这天那条”取第一条，先后都与原来一样按打卡关系
        let candidates = refetch().filter { !$0.archived }
        guard let dup = candidates.first(where: { ($0.targetValue ?? 0) > 0 }) ?? candidates.first else {
            check(false, "同一天多条打卡：没有可用的习惯")
            return
        }
        let dupDay = today.adding(days: -3)
        let target = dup.targetValue ?? 0
        if target <= 0 { dup.targetValue = 30 }
        for quantity in [10.0, 80, 20] {   // 以哪条为准，这天达标与否就不同
            let log = HabitLog(dateKey: dupDay.key, completed: true, quantity: quantity)
            c.insert(log)
            log.habit = dup
        }
        DataStore.save(c)
        settle()
        let reads = model.work.relationshipReads
        refetch()
        let dupLogs = dup.logValues.filter { $0.day == dupDay }   // 原来的先后
        let full = dup.stats(today: today)
        let dayLogs = HabitDayLogs(day: dupDay, context: c)
        let fullState = CultivationService.fullState(context: c)
        let dupOK = dupLogs.count >= 3 && full.logs[dupDay] == dupLogs.last
            && model.stats(for: dup, today: today) == full
            && dayLogs.log(of: dup) === dup.log(on: dupDay) && dayLogs.values(of: dup) == dupLogs
            && model.state == fullState
            && CultivationService.dayXP(dupDay, habits: model.habits, context: c, config: settings.cultivation, today: today) == (fullState.perDay[dupDay] ?? 0)
            && HabitLogQuery.recent(dup, 10).elementsEqual(dup.recentLogs(10), by: ===)
            && reads > 0
        let before = mismatches
        verify("同一天三条")
        check(dupOK && mismatches == before,
              "同一习惯同一天有多条打卡时，统计与修为仍以打卡关系里的最后一条为准、找“这天那条”取第一条，与原来相同（这样的习惯模型从关系里读了 \(reads) 次）")
    }
}
