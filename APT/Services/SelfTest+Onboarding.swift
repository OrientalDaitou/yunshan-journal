import Foundation
import SwiftData

// MARK: - r2-onboard：#8 筑基三关、所向、本月落笔的运行时自检
// 判定、写法、落印只放一次、功成次日收起的规矩在 Tools/CoreCheck 的 r2-onboard 一节；这里测要用到数据库的部分（真 SwiftData、内存库）：
// 1. 三关的事实从库里取得对：点功法谱胶囊立的功课（修为模型马上看到）、第一篇修行录、随手记标记、任一封传书；
// 2. 有记录的日子按页取、数到 30 就停：29 天还出现、第 30 个打卡的日子起（2 年用户）不出现；缓存在库变了以后重数；
// 3. “本月落笔”按 dateKey 谓词只取本月；“所向”只取进行中的目标；
// 4. 调试实例（自检设了 APT_STORE_DIR）里卡上的“开启”两件事都不会碰系统通知与登录项。

extension SelfTest {
    static func onboardingChecks(_ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()
        func context() throws -> ModelContext {
            let c = ModelContext(try DataStore.makeContainer(inMemory: true))
            DataStore.settings(in: c)
            DataStore.profile(in: c)
            DataStore.save(c)
            return c
        }

        // 0. 偏好键与随手记写的是同一个
        check(Onboarding.quickUsedKey == QuickCommit.usedKey, "三关读的随手记标记就是随手记写的那个键（onboarding.quickUsed）")

        // 1. 三关的事实
        let c = try context()
        let model = CultivationModel.shared(for: c)
        model.refresh()
        func titles() -> [String] { model.rows.filter { $0.habit.modelContext != nil }.map(\.habit.title) }
        var facts = OnboardingLoader.facts(context: c, habitTitles: titles(), quickUsed: false)
        check(Onboarding.passed(facts).isEmpty && facts.entries == 0 && facts.letters == 0, "全新的库：三关都没过")

        let water = HabitTemplates.starter.first { $0.title == "喝水" }!
        let installed = HabitTemplateInstaller.install(water, context: c, sortOrder: 0)
        HabitTemplateInstaller.install(water, context: c, sortOrder: 1)
        facts = OnboardingLoader.facts(context: c, habitTitles: titles(), quickUsed: false)
        check(Onboarding.passed(facts) == [.habit] && facts.habitTitles == ["喝水"] && installed.targetValue == 8 && c.all(Habit.self).count == 1,
              "点“喝水 · 8 杯”：修为模型当场看到、一关过（连点两下不重复立）：\(facts.habitTitles)")
        check(HabitTemplates.starter.map(\.chipText) == ["早睡", "喝水 · 8 杯", "运动 · 每周 3 次", "冥想 · 10 分钟", "读书 · 20 页", "背单词 · 30 个"],
              "一关的六枚胶囊：早睡、喝水 · 8 杯、运动 · 每周 3 次、冥想 · 10 分钟、读书 · 20 页、背单词 · 30 个")

        c.insert(JournalEntry(kind: .diary, body: "第一笔", dateKey: today.key))
        DataStore.save(c)
        facts = OnboardingLoader.facts(context: c, habitTitles: titles(), quickUsed: false)
        check(Onboarding.passed(facts) == [.habit, .write] && Onboarding.doneText(.write, facts) == "已落 1 篇", "写一句入卷：二关过，“已落 1 篇”")

        facts = OnboardingLoader.facts(context: c, habitTitles: titles(), quickUsed: true)
        check(Onboarding.passed(facts).count == 3, "用过一次随手记：三关全过")
        c.insert(CourierDelivery(fileName: "selftest-onboarding.json", from: "自检", note: ""))
        DataStore.save(c)
        facts = OnboardingLoader.facts(context: c, habitTitles: titles(), quickUsed: false)
        check(Onboarding.passed(facts).count == 3 && facts.letters == 1, "收到一封传书（没用过随手记）：三关同样算过")

        installed.archived = true
        installed.archivedAt = today.key
        DataStore.save(c)
        model.refresh()
        check(!Onboarding.passed(OnboardingLoader.facts(context: c, habitTitles: titles(), quickUsed: false)).contains(.habit),
              "唯一的功课归档了：一关回到没过（印只落过一次，不会再落）")

        // 2. 有记录的日子：29 个落笔的日子还出现，再有一个打卡的日子就是老用户
        let v = try context()
        let vModel = CultivationModel.shared(for: v)
        for offset in 0..<29 {
            // 每天两篇：同一天只算一次
            v.insert(JournalEntry(kind: .diary, body: "第 \(offset) 天", dateKey: today.adding(days: -offset).key))
            v.insert(JournalEntry(kind: .note, body: "又一句", dateKey: today.adding(days: -offset).key))
        }
        DataStore.save(v)
        vModel.refresh()
        let days29 = OnboardingLoader.recordDays(context: v, cultivation: vModel, today: today)
        check(days29 == 29 && Onboarding.shows(dismissed: false, doneDay: "", today: today, recordDays: days29),
              "29 个落笔的日子（每天两篇）：数出 29，筑基卡还在：\(days29)")
        check(OnboardingLoader.recordDays(context: v, habitDays: [], page: 7) == 29, "按页取（每页 7 篇）数得一样：29")
        let habit = Habit(title: "晨跑")
        habit.startDate = today.adding(days: -60).key
        v.insert(habit)
        let log = HabitLog(dateKey: today.adding(days: -40).key, completed: true, quantity: nil)
        v.insert(log)
        log.habit = habit
        DataStore.save(v)
        vModel.refresh()
        let days30 = OnboardingLoader.recordDays(context: v, cultivation: vModel, today: today)
        check(days30 == 30 && !Onboarding.shows(dismissed: false, doneDay: "", today: today, recordDays: days30),
              "再有一个打卡的日子（库变了，缓存重数）：30 天，老用户不再出现：\(days30)")
        let many = OnboardingLoader.recordDays(context: v, habitDays: (0..<45).map { today.adding(days: -100 - $0) }, page: 5)
        check(many == Onboarding.veteranDays, "打卡的日子就够 30 天：不再去取修行录，数到 30 就停：\(many)")

        // 3. 本月落笔：与首页同一个谓词只取本月一日到今天
        let m = try context()
        let monthFirst = today.firstOfMonth
        for day in [monthFirst, monthFirst, monthFirst.adding(days: -1), today, today.adding(days: 1)] {
            m.insert(JournalEntry(kind: .diary, body: "本月", dateKey: day.key))
        }
        DataStore.save(m)
        let lo = monthFirst.key, hi = today.key
        let month = (try? m.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey >= lo && $0.dateKey <= hi }))) ?? []
        let expected = monthFirst == today ? 1 : 2
        check(Onboarding.monthDays(month.map(\.dateKey), today: today) == expected,
              "本月落笔：谓词只取本月一日到今天（上月最后一天、明天的不取），一日几篇算一日：\(expected) 日")

        // 4. 所向：只取进行中的目标
        let g = try context()
        for (title, status, priority, days) in [("论文初稿", "active", "must", 58), ("读书", "active", "should", 10),
                                                ("驾照", "cancelled", "must", 5), ("钢琴", "paused", "could", 3), ("应急金", "completed", "must", 1)] {
            let goal = Goal(title: title)
            goal.status = status
            goal.priority = priority
            goal.progress = 40
            goal.targetDate = today.adding(days: days).key
            g.insert(goal)
        }
        DataStore.save(g)
        let active = (try? g.fetch(FetchDescriptor<Goal>(predicate: #Predicate { $0.status == "active" }))) ?? []
        let picked = GoalStripRules.pick(active.map { GoalStripRules.Item(title: $0.title, priority: $0.priority, progress: $0.progress,
                                                                          targetDate: $0.targetDate, createdAt: $0.createdAt) })
        check(picked.shown.map(\.title) == ["论文初稿", "读书"] && picked.more == 0
              && GoalStripRules.deadline(picked.shown[0].targetDate, today: today).text == "还剩 58 天",
              "所向只列进行中的两个（暂停、已放弃、已完成的不出），必须的在前：“还剩 58 天”")

        // 5. 调试实例：卡上“每晚提醒落一笔”“登录时自动打开”的“开启”只记开关，不碰系统通知与登录项
        check(!DailyReminder.touchesSystem && LoginItem.isDebugInstance,
              "自检（设了 APT_STORE_DIR）：筑基卡上的两颗“开启”只记开关，不调用系统通知与 SMAppService")
    }
}
