import Foundation
import SwiftData

// MARK: - r1-habits：功法谱一键立好、数量型“＋1”累计、打破纪录的那一下
// 十二式的写法、步长、纪录口径在 Tools/CoreCheck 里逐条核对；这里测要用到数据库的部分：
// HabitTemplateInstaller 立好的功课字段对得上模板、不重复立；HabitActions 打卡 / 改数量之后的新纪录提示
// （修为模型在与不在两条取数路线都测）、取消再打回来不重复提示、传书等不经 HabitActions 的不提示。

extension SelfTest {
    static func habitTemplateChecks(_ check: (Bool, String) -> Void) throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let c = ModelContext(container)
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        DataStore.save(c)
        let today = LocalDay.today()
        let config = CultivationConfig()

        // 1. 十二式都能一键立好：名称、类别（组名）、图标、频率、数量、备注照模板，开始日期今天
        var installed: [Habit] = []
        for (index, template) in HabitTemplates.all.enumerated() {
            installed.append(HabitTemplateInstaller.install(template, context: c, sortOrder: index))
        }
        let mismatched = zip(HabitTemplates.all, installed).filter { template, habit in
            habit.title != template.title || habit.category != template.group || habit.symbol != template.symbol
                || habit.frequencyKind != template.frequency || habit.targetValue != template.targetValue || habit.unit != template.unit
                || habit.notes != template.notes || habit.startDate != today.key
                || habit.weekdays != (template.frequency == .weekdays ? template.weekdays : [])
                || (template.frequency == .weekly && habit.targetPerWeek != template.targetPerWeek)
        }.map(\.0.title)
        check(c.all(Habit.self).count == 12 && mismatched.isEmpty && installed.map(\.sortOrder) == Array(0..<12) && !c.hasChanges,
              "功法谱一键立好：十二式的名称、类别、图标、频率、数量、备注都照模板，开始日期今天，已保存" + (mismatched.isEmpty ? "" : "（不对：\(mismatched)）"))
        check(HabitTemplates.all.allSatisfy { HabitEditor.symbols.contains($0.symbol) },
              "功法谱的图标都在新建功课弹窗的图标格里（立好后再编辑，图标格里有选中的那枚）")
        let water = installed[3]
        let focus = installed.first { $0.title == "专注" }
        check(water.title == "喝水" && water.targetValue == 8 && water.unit == "杯" && water.spec.scheduleSummary == "每天"
              && focus?.spec.scheduleSummary == "每周一、二、三、四、五" && installed[4].spec.scheduleSummary == "每周 3 次",
              "立好的功课：喝水每天 8 杯、专注周一至周五（列表写“每周一、二、三、四、五”）、运动每周 3 次")
        let again = HabitTemplateInstaller.install(HabitTemplates.named("喝水")!, context: c, sortOrder: 99)
        check(again === water && c.all(Habit.self).count == 12, "再立一次喝水（连点两下）：交回原来那项，不重复立")
        water.archived = true
        water.archivedAt = today.key
        DataStore.save(c)
        let fresh = HabitTemplateInstaller.install(HabitTemplates.named("喝水")!, context: c, sortOrder: 12)
        check(fresh !== water && !fresh.archived && c.all(Habit.self).count == 13 && fresh.sortOrder == 12,
              "同名的只剩已归档的那项时照常新立一项（排在最后）")
        check(HabitTemplates.isInstalled(HabitTemplates.named("冥想")!, titles: c.all(Habit.self).map(\.title))
              && !HabitTemplates.isInstalled(HabitTemplate(group: "心神", title: "站桩", symbol: "leaf"), titles: c.all(Habit.self).map(\.title)),
              "已立：现有功课里有同名的才算")

        // 2. 新纪录：冥想（每天 10 分钟）旧纪录 5 天（20–16 天前），5–1 天前又连了 5 天（追平），今天记满 → 6 天
        //    这时还没有修为模型：改之前的统计按习惯直接取打卡
        let meditate = installed[7]
        meditate.startDate = today.adding(days: -30).key
        func log(_ habit: Habit, _ offsets: ClosedRange<Int>, quantity: Double?) {
            for offset in offsets {
                let entry = HabitLog(dateKey: today.adding(days: -offset).key, completed: true, quantity: quantity)
                c.insert(entry)
                entry.habit = habit
            }
        }
        log(meditate, 16...20, quantity: 10)
        log(meditate, 1...5, quantity: 10)
        DataStore.save(c)
        check(CultivationModel.existing(for: c) == nil, "（自检前提：这个库还没有修为模型）")
        let effects = EffectsCenter()
        func texts() -> [String] { effects.toasts.map(\.text) }
        func allHabits() -> [Habit] { c.all(Habit.self) }
        HabitActions.setQuantity(meditate, on: today, quantity: 4, context: c, effects: effects, allHabits: allHabits(), config: config)
        check(!texts().contains { $0.hasPrefix("新纪录") }, "只记了 4 / 10 分钟（未达标）：不提示新纪录")
        HabitActions.setQuantity(meditate, on: today, quantity: 4 + HabitStepRule.step(forTarget: 10) * 6,
                                 context: c, effects: effects, allHabits: allHabits(), config: config)
        let record = "新纪录 · 「冥想」连续 6 天"
        check(texts().filter { $0 == record }.count == 1 && effects.toasts.first { $0.text == record }?.icon == "rosette"
              && HabitDayLogs(day: today, context: c).log(of: meditate)?.quantity == 10,
              "＋1 累计到 10 / 10 分钟、今天达标：飘“\(record)”（带小勋章）：\(texts())")
        HabitActions.setQuantity(meditate, on: today, quantity: 12, context: c, effects: effects, allHabits: allHabits(), config: config)
        HabitActions.setQuantity(meditate, on: today, quantity: nil, context: c, effects: effects, allHabits: allHabits(), config: config)
        HabitActions.toggle(meditate, on: today, context: c, effects: effects, allHabits: allHabits(), config: config)
        check(texts().filter { $0 == record }.count == 1,
              "已达标再加、清除后再记满：同一天同一个连续数不重复提示（只飘过一次）")

        // 3. 有修为模型时（界面里就是这样）：早睡旧纪录 4 天，今天打卡破纪录；补卡过去的日子、追平都不提示
        let sleep = installed[0]
        sleep.startDate = today.adding(days: -30).key
        log(sleep, 9...12, quantity: nil)
        log(sleep, 1...4, quantity: nil)
        DataStore.save(c)
        let model = CultivationModel.shared(for: c)
        model.refresh()
        HabitActions.toggle(sleep, on: today.adding(days: -6), context: c, effects: effects, allHabits: model.habits, config: config)
        check(!texts().contains { $0.contains("早睡") }, "在热力图上补过去的一天：不提示新纪录（只看今天）")
        HabitActions.toggle(sleep, on: today.adding(days: -6), context: c, effects: effects, allHabits: model.habits, config: config)
        HabitActions.toggle(sleep, on: today, context: c, effects: effects, allHabits: model.habits, config: config)
        check(texts().contains("新纪录 · 「早睡」连续 5 天"),
              "有修为模型时同样提示：早睡旧纪录 4 天、昨天追平，今天打卡 → “新纪录 · 「早睡」连续 5 天”：\(texts())")
        let stats = model.stats(for: sleep, today: today)
        check(stats.map { HabitRecord.longest($0).count } == 5 && stats?.streak.count == 5
              && stats.flatMap { HabitRecord.note(current: $0.streak.count, longest: HabitRecord.longest($0).count, unit: $0.streak.unit) } == "正在创纪录",
              "打卡后详情页的数字格：最长连续 5 天、当前 5 天，下面写“正在创纪录”")

        // 4. 头一段连续（之前没有 ≥3 天的旧纪录）、取消今天的打卡：不提示
        let rise = installed[1]
        rise.startDate = today.adding(days: -10).key
        log(rise, 1...6, quantity: nil)
        DataStore.save(c)
        model.refresh()
        HabitActions.toggle(rise, on: today, context: c, effects: effects, allHabits: model.habits, config: config)
        HabitActions.toggle(rise, on: today, context: c, effects: effects, allHabits: model.habits, config: config)
        check(!texts().contains { $0.contains("早起") }, "头一段连续 7 天（没有旧纪录）、再取消今天：都不提示新纪录")
        let riseStats = model.stats(for: rise, today: today)
        check(riseStats.flatMap { HabitRecord.note(current: $0.streak.count, longest: HabitRecord.longest($0).count, unit: $0.streak.unit) } == "正在创纪录"
              && riseStats?.streak.count == 6,
              "取消今天后当前 6 天仍是最长：数字格下写“正在创纪录”（今天没打不算断）")

        // 5. 详情页数量框旁的“＋1”以哪个数为底（HabitQuantity.stepBase）：框里改了还没点“记录”的数优先，不被冲掉
        let base = HabitQuantity.stepBase
        check(base("6", 3, 3) == 6 && base(" 6 ", 3, 3) == 6 && base("6", nil, nil) == 6 && base("8,500", 8000, 8000) == 8500,
              "＋1 的底：框里改成 6（今天已记 3、没点“记录”）→ 以 6 为底；今天还没记时打了 6 也一样；“8,500”按 8500")
        check(base("3", 3, 3) == 3 && base("3", 3, 5) == 5 && base("", 3, 3) == 3 && base("  ", nil, nil) == 0 && base("", nil, 4) == 4,
              "＋1 的底：框里没改（与原本填的一样）按点的这一刻库里今天那条（列表、传书刚改成 5 就按 5）；框清空了也按库里的，没记为 0")
        check(base("abc", 3, 3) == nil && base("0", 3, 3) == nil && base("-2", nil, nil) == nil && base("6个", 3, 3) == nil,
              "＋1 的底：框里是读不懂的字、0 或负数 → 不加（响一声，与“记录”同一个规矩），不悄悄改成库里的数再加")
        let cups = fresh
        HabitActions.setQuantity(cups, on: today, quantity: 3, context: c, effects: effects, allHabits: allHabits(), config: config)
        let shownCups = HabitDayLogs(day: today, context: c).log(of: cups)?.quantity
        if let from = base("6", shownCups, HabitDayLogs(day: today, context: c).log(of: cups)?.quantity) {
            HabitActions.setQuantity(cups, on: today, quantity: from + HabitStepRule.step(forTarget: cups.targetValue),
                                     context: c, effects: effects, allHabits: allHabits(), config: config)
        }
        check(shownCups == 3 && HabitDayLogs(day: today, context: c).log(of: cups)?.quantity == 7,
              "喝水今天已记 3 杯，框里改成 6 没点“记录”就点“＋1”：存成 7 杯（不是 4 杯）")
    }
}
