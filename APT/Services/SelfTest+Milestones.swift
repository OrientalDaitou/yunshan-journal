import SwiftUI
import SwiftData
import AppKit

// MARK: - r2-seals：印谱的运行时自检（#16）
// 八枚的条件、第一次运行静默补记、一天最多庆一枚、存取写法在 Tools/CoreCheck 的 r2-seals 一节逐条核对；
// 这里测要用到数据库与偏好的部分（真 SwiftData、内存库；偏好用一个用完即删的独立域，不碰正式偏好）：
// 1. 全新用户：第一次看记下一本空印谱；落第一篇 → 庆“山门”、名帖印谱待亮起；同天立功课 → 留到明天；次日补庆；
// 2. 老用户升级：第一次看把已达成的 8 枚全部静默记下（得印日是各自达成那天），不庆、不亮；再看不动；
// 3. 印谱集齐后不再取数（不碰修行录摘要）；删光记录印照旧在；
// 4. 名帖印谱真画得出来：刚得的那枚出现时从偏好里取走（亮过即清）；
// 5. 检测器等应用在前台：后台保存（例如传书收录）不看、不飘、不记“今天已庆”，回到前台约 1 秒后才看、才飘；
// 6. 同一次保存既“所向功成”又得“功成”印：两句并成一句，不叠两行（先后颠倒也一样），并句后重新计时。

extension SelfTest {
    static func milestoneChecks(_ check: (Bool, String) -> Void) throws {
        let suite = "io.github.orientaldaitou.yunshan.selftest.milestones.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "印谱自检：建不出独立的偏好域") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let today = LocalDay.today()

        // 1. 全新用户
        let fresh = try DataStore.makeContainer(inMemory: true)
        let c = ModelContext(fresh)
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        DataStore.save(c)
        let first = MilestoneWatcher.check(context: c, defaults: defaults, today: today)
        check(first == nil && defaults.string(forKey: MilestoneKeys.ledger) == "" && defaults.string(forKey: MilestoneKeys.lastDay) == nil,
              "印谱：全新用户第一次看，记下一本空印谱（不庆）")
        c.insert(JournalEntry(kind: .diary, body: "今天第一次落笔。", dateKey: today.key))
        DataStore.save(c)
        let entry = MilestoneWatcher.check(context: c, defaults: defaults, today: today)
        check(entry == .firstEntry && defaults.string(forKey: MilestoneKeys.fresh) == "firstEntry"
              && defaults.string(forKey: MilestoneKeys.lastDay) == today.key
              && MilestoneLedger(encoded: defaults.string(forKey: MilestoneKeys.ledger))?.earned[.firstEntry] == today.key,
              "印谱：落第一篇 → 庆“初入山门”，得印日今天，名帖印谱里那枚待亮起")
        let habit = Habit(title: "冥想")
        c.insert(habit)
        DataStore.save(c)
        CultivationModel.shared(for: c).refresh()
        let sameDay = MilestoneWatcher.check(context: c, defaults: defaults, today: today)
        check(sameDay == nil && defaults.string(forKey: MilestoneKeys.pending) == "firstHabit"
              && MilestoneLedger(encoded: defaults.string(forKey: MilestoneKeys.ledger))?.earned[.firstHabit] == nil,
              "印谱：同一天又立第一项功课 → 今天不再庆，立功记为“印已成，明日盖印”")
        let tomorrow = today.adding(days: 1)
        let nextDay = MilestoneWatcher.check(context: c, defaults: defaults, today: tomorrow)
        check(nextDay == .firstHabit && defaults.string(forKey: MilestoneKeys.pending) == ""
              && defaults.string(forKey: MilestoneKeys.fresh) == "firstEntry,firstHabit"
              && MilestoneLedger(encoded: defaults.string(forKey: MilestoneKeys.ledger))?.earned[.firstHabit] == tomorrow.key,
              "印谱：次日补庆“初立功课”（得印日写次日）；两枚都等名帖印谱出现时亮起")
        check(MilestoneWatcher.check(context: c, defaults: defaults, today: tomorrow) == nil
              && MilestoneWatcher.check(context: c, defaults: defaults, today: tomorrow.adding(days: 1)) == nil,
              "印谱：每枚只庆一次——之后再看不再庆")

        // 1b. 第一封传书；目标以状态为准：进度满但仍是进行中的不算达成，改成“已完成”才得“功成”
        let delivery = CourierDelivery(fileName: "自检.json", from: "Claude", note: "")
        c.insert(delivery)
        let goal = Goal(title: "完成学位论文初稿")
        goal.progress = 100
        c.insert(goal)
        DataStore.save(c)
        let day3 = tomorrow.adding(days: 1)
        let courier = MilestoneWatcher.check(context: c, defaults: defaults, today: day3)
        let fullButActive = MilestoneWatcher.check(context: c, defaults: defaults, today: day3.adding(days: 1))
        goal.status = "completed"
        DataStore.save(c)
        let goalDone = MilestoneWatcher.check(context: c, defaults: defaults, today: day3.adding(days: 2))
        check(courier == .firstCourier && fullButActive == nil && goalDone == .goalDone,
              "印谱：收到第一封传书庆“飞剑初传”；目标进度 100% 但仍是进行中不算，改成已完成才庆“所向功成”（与名帖列表、首页所向条同一口径）")

        // 2. 老用户升级：120 天连续落笔 + 一篇复盘 + 功课 + 传书 + 已完成的目标，偏好里还没有印谱
        let veteran = try DataStore.makeContainer(inMemory: true)
        let v = ModelContext(veteran)
        DataStore.settings(in: v)
        DataStore.profile(in: v)
        let start = today.adding(days: -119)
        for offset in 0..<120 {
            v.insert(JournalEntry(kind: offset == 10 ? .review : .diary, body: "第 \(offset + 1) 天", dateKey: start.adding(days: offset).key))
        }
        let oldHabit = Habit(title: "读书")
        oldHabit.startDate = start.key
        v.insert(oldHabit)
        v.insert(CourierDelivery(fileName: "旧.json", from: "Claude", note: ""))
        let oldGoal = Goal(title: "跑完半马")
        oldGoal.status = "completed"
        oldGoal.progress = 100
        v.insert(oldGoal)
        DataStore.save(v)
        CultivationModel.shared(for: v).refresh()
        let upgradeSuite = suite + ".upgrade"
        guard let upgrade = UserDefaults(suiteName: upgradeSuite) else { return check(false, "印谱自检：建不出第二个偏好域") }
        defer { upgrade.removePersistentDomain(forName: upgradeSuite) }
        let seeded = MilestoneWatcher.check(context: v, defaults: upgrade, today: today)
        let ledger = MilestoneLedger(encoded: upgrade.string(forKey: MilestoneKeys.ledger))
        check(seeded == nil && ledger?.isComplete == true && (upgrade.string(forKey: MilestoneKeys.fresh) ?? "").isEmpty
              && upgrade.string(forKey: MilestoneKeys.lastDay) == nil,
              "印谱：老用户第一次运行，8 枚全部静默记下，一枚不庆、不亮")
        check(ledger?.earned[.firstEntry] == start.key && ledger?.earned[.sevenDays] == start.adding(days: 6).key
              && ledger?.earned[.thirtyDays] == start.adding(days: 29).key && ledger?.earned[.hundredDays] == start.adding(days: 99).key
              && ledger?.earned[.firstReview] == start.adding(days: 10).key && ledger?.earned[.firstHabit] == start.key,
              "印谱：静默补上的得印日是各自达成那天（第 7 / 30 / 100 个落笔日、第一篇复盘、功课开始日）")

        // 3. 集齐后不再取数；删光记录印照旧在
        // 让修行录摘要换到另一个库：集齐的那一库再看时若去取数，摘要就会被换回来、版本跟着变
        let before = JournalDigest.shared.sync(c).version
        for e in v.all(JournalEntry.self) { v.delete(e) }
        DataStore.save(v)
        let started = Date()
        let after = MilestoneWatcher.check(context: v, defaults: upgrade, today: today)
        let elapsed = Date().timeIntervalSince(started)
        check(after == nil && MilestoneLedger(encoded: upgrade.string(forKey: MilestoneKeys.ledger))?.isComplete == true
              && JournalDigest.shared.sync(c).version == before && elapsed < 0.05,
              "印谱集齐后：删光落笔印照旧在；再看不取修行录摘要（\(Int(elapsed * 1000)) ms）")

        // 4. 名帖印谱：刚得的那枚出现时从偏好里取走；已得 / 待明日 / 未得 三种都画得出
        defaults.set("firstEntry,firstHabit", forKey: MilestoneKeys.fresh)
        defaults.set("sevenDays", forKey: MilestoneKeys.pending)
        let host = NSHostingView(rootView: SealBook().frame(width: 820).environment(\.spiritMotion, false).defaultAppStorage(defaults))
        host.frame = CGRect(x: 0, y: 0, width: 820, height: 260)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        check(defaults.string(forKey: MilestoneKeys.fresh) == "" && host.fittingSize.height > 80 && host.fittingSize.height < 220,
              "名帖印谱：刚得的两枚出现时从偏好里取走（亮过即清）；一行八枚，卡高 \(Int(host.fittingSize.height)) pt")

        try probeForegroundChecks(check, today: today, suite: suite)
        goalToastMergeChecks(check)
    }

    /// 5. 检测器（真的 MilestoneProbe，挂在不显示的宿主视图里）：应用不在前台时保存，先不看、不飘、不占当天名额；
    /// 回到前台约 1 秒后才看、才飘。前台开关与“回到前台”的通知都换成自检自己的，不惊动应用里别的观察者
    private static func probeForegroundChecks(_ check: (Bool, String) -> Void, today: LocalDay, suite: String) throws {
        let probeSuite = suite + ".probe"
        guard let probeDefaults = UserDefaults(suiteName: probeSuite) else { return check(false, "印谱自检：建不出检测器用的偏好域") }
        defer { probeDefaults.removePersistentDomain(forName: probeSuite) }
        probeDefaults.set("", forKey: MilestoneKeys.ledger)   // 不是第一次运行：一本空印谱
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        final class ActiveSwitch { var on = false }
        let active = ActiveSwitch()
        let wake = Notification.Name("selftest.milestones.active.\(UUID().uuidString)")
        let effects = EffectsCenter()
        // 测完要把检测器从视图里拿掉：它听的是全局的保存通知，留着的话之后别的自检一保存（有的库那时已经释放）它也会去看
        let mounted = ProbeMount()
        let probe = ProbeMountView(mount: mounted) {
            MilestoneProbe(dayKey: today.key, defaults: probeDefaults, isActive: { active.on }, activation: wake)
                .modelContainer(container)
                .environment(effects)
        }
        let host = NSHostingView(rootView: probe)
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        // 应用在后台时，传书收录了第一篇
        context.insert(JournalEntry(kind: .diary, body: "后台收录的一篇。", dateKey: today.key))
        DataStore.save(context)
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        check(probeDefaults.string(forKey: MilestoneKeys.lastDay) == nil && (probeDefaults.string(forKey: MilestoneKeys.fresh) ?? "").isEmpty
              && probeDefaults.string(forKey: MilestoneKeys.ledger) == "" && effects.toasts.isEmpty,
              "得印检测：应用不在前台时保存，先不看、不飘，也不记“今天已庆”")
        // 用户切回来
        active.on = true
        NotificationCenter.default.post(name: wake, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let tooEarly = effects.toasts.isEmpty
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        check(tooEarly && probeDefaults.string(forKey: MilestoneKeys.lastDay) == today.key && probeDefaults.string(forKey: MilestoneKeys.fresh) == "firstEntry"
              && effects.toasts.map(\.text) == [Milestone.firstEntry.toast],
              "得印检测：切回前台约 1 秒后才看、才飘“\(Milestone.firstEntry.toast)”，印谱那枚待亮起")
        mounted.on = false
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        withExtendedLifetime((host, container)) {}
    }

    /// 6. 同一次保存既“所向功成”又得“功成”印：原地并成一句，不叠两行；先后颠倒也一样；别的印照常各飘各的；
    /// 并句后从那一刻重新计时（原来那句的计时到点不收）
    private static func goalToastMergeChecks(_ check: (Bool, String) -> Void) {
        let merged = GoalListRules.achievedToast("完成学位论文初稿", sealEarned: true)
        let goalFirst = EffectsCenter()
        goalFirst.goalAchieved("完成学位论文初稿")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        goalFirst.sealEarned(.goalDone)
        let sealFirst = EffectsCenter()
        sealFirst.sealEarned(.goalDone)
        sealFirst.goalAchieved("完成学位论文初稿")
        let other = EffectsCenter()
        other.goalAchieved("跑完半马")
        other.sealEarned(.sevenDays)
        check(goalFirst.toasts.map(\.text) == [merged] && sealFirst.toasts.map(\.text) == [merged]
              && goalFirst.toasts.first?.icon == "seal.fill" && sealFirst.toasts.first?.prominent == true,
              "目标功成 + 得“功成”印：并成一句“\(merged)”，不叠两行（先飘哪句都一样）")
        check(other.toasts.map(\.text) == [GoalListRules.achievedToast("跑完半马"), Milestone.sevenDays.toast],
              "目标功成时得的是别的印（七日不辍）：照常各飘各的")
        // 原来那句 2.8 秒到点（从 goalAchieved 算起）时并过的句子还在；并句后 3.4 秒才收
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        let kept = goalFirst.toasts.map(\.text) == [merged]
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        check(kept && goalFirst.toasts.isEmpty, "并句后重新计时：原来那句的计时到点不收，并句后约 3.4 秒才收")
    }
}

/// 自检用：能把挂着的检测器整个拿掉的外壳（拿掉后它的通知订阅随之取消）
private final class ProbeMount: ObservableObject {
    @Published var on = true
}

private struct ProbeMountView<Content: View>: View {
    @ObservedObject var mount: ProbeMount
    @ViewBuilder var content: () -> Content
    var body: some View {
        if mount.on { content() }
    }
}
