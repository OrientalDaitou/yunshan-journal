import SwiftUI
import SwiftData
import AppKit

// 今日洞府首页结构（R1 #5）的运行时自检：真 SwiftData、内存库，不写偏好、不碰正式数据目录。
// 规矩本身（步长与写法、收起已圆满、最多多拉 160、旧笔新读取哪几天与眉题、摘句、落款）在 Tools/CoreCheck 的 r1-home 一节；
// 这里测要用到数据库与界面布局的部分：
// 1. 数量型“+1”真的在今天已记的数量上加一步（连点不少算、备注不丢、达标后修为照常、不是数量型的不动）；
// 2. 旧笔新读取到的篇目与次序（与修行录“往日回看”同几天；珍藏、旧笔兜底；只在近 7 天写过时为空），5 年量级的取数够快；
// 3. 两栏不再强行等高（较矮那栏最后一张最多多拉 160）、整张不出的卡不留卡距、窄时上下排的次序；
// 4. 修复轮：旧笔新读里删除给 8 秒撤销、删后按当天重取（候选删光了照样往下找），数量行悬停提示与点圈的实际行为一致，
//    从数量框打满的一项同样“留一会儿”（收起规则按已圆满的前后对比，不靠哪个按钮报信）。

/// 布局自检里记下各张卡最后摆在哪（GeometryReader 在排版时写进来）
@MainActor
private final class DashboardFrameBox {
    var frames: [String: CGRect] = [:]
    func record(_ name: String, _ frame: CGRect) { frames[name] = frame }
}

/// 布局自检里“有时整张不出”的卡：与旧笔新读同一种写法（body 里 if，外面 .equatable().overviewSlot）
private struct DashboardHiddenProbe: View, Equatable {
    var show: Bool
    var box: DashboardFrameBox

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.show == rhs.show }

    var body: some View {
        if show {
            Color.clear.frame(height: 50)
                .background(GeometryReader { geo in
                    let _ = box.record("旧笔", geo.frame(in: .named(DashboardFrameSpace.name)))
                    Color.clear
                })
        }
    }
}

private enum DashboardFrameSpace {
    static let name = "dashboard-selftest-columns"
}

extension SelfTest {
    static func dashboardChecks(_ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()
        let config = CultivationConfig()
        func context() throws -> ModelContext {
            let c = ModelContext(try DataStore.makeContainer(inMemory: true))
            DataStore.settings(in: c)
            DataStore.profile(in: c)
            DataStore.save(c)
            return c
        }

        // 1. 数量型“+1”
        let c = try context()
        func habit(_ title: String, target: Double?, unit: String) -> Habit {
            let h = Habit(title: title)
            h.targetValue = target
            h.unit = unit
            h.startDate = today.adding(days: -10).key
            c.insert(h)
            return h
        }
        let water = habit("首页自检喝水", target: 8, unit: "杯")
        let steps = habit("首页自检步数", target: 8000, unit: "步")
        let plain = habit("首页自检早睡", target: nil, unit: "")
        DataStore.save(c)
        let effects = EffectsCenter()
        func log(_ h: Habit) -> HabitLog? { HabitDayLogs(day: today, context: c).log(of: h) }
        func plus(_ h: Habit) -> Double? {
            HabitQuantityStep.add(h, context: c, effects: effects, allHabits: c.all(Habit.self), config: config)
        }
        HabitActions.setQuantity(water, on: today, quantity: 3, context: c, effects: effects, allHabits: c.all(Habit.self), config: config)
        log(water)?.notes = "首页自检备注"
        DataStore.save(c)
        let four = plus(water)
        check(four == 4 && log(water)?.quantity == 4 && log(water)?.notes == "首页自检备注" && !water.stats(today: today).isAchieved(today),
              "首页功课 +1：喝水 3/8 杯点一下变 4/8（这条打卡的备注不丢，还没达标）")
        let xpBefore = CultivationService.fullState(context: c).perDay[today] ?? 0
        for _ in 0..<4 { _ = plus(water) }
        let xpAfter = CultivationService.fullState(context: c).perDay[today] ?? 0
        check(log(water)?.quantity == 8 && water.stats(today: today).isAchieved(today) && xpAfter > xpBefore,
              "首页功课 +1：连点四下各加一步到 8/8，达标、修为照常加上（今日 \(xpBefore) → \(xpAfter)）")
        check(plus(steps) == 1000 && log(steps)?.quantity == 1000,
              "首页功课 +1：步数目标 8000，今天还没记时一下记 1000 步")
        check(plus(plain) == nil && log(plain) == nil, "首页功课 +1：不是数量型的功课不走 +1（不建打卡）")
        steps.archived = true
        DataStore.save(c)
        check(plus(steps) == nil && log(steps)?.quantity == 1000, "首页功课 +1：已归档的功课不动")

        // 2. 旧笔新读
        func journal() throws -> ModelContext { try context() }
        func entry(_ j: ModelContext, _ day: LocalDay, _ title: String, minute: Int, pinned: Bool = false, mood: Int? = nil) {
            let e = JournalEntry(kind: .diary, title: title, body: "首页自检正文：\(title)", dateKey: day.key)
            e.minute = minute
            e.pinned = pinned
            e.mood = mood
            e.createdAt = day.date(minutes: minute)
            e.updatedAt = e.createdAt
            j.insert(e)
        }
        let spans = DashboardRules.lookBackSpans(today: today)   // 一年前、半年前、一月前、一周前
        let yearDay = spans[0].day, halfDay = spans[1].day.adding(days: 1), weekDay = spans[3].day.adding(days: -1)
        let j = try journal()
        entry(j, yearDay, "一年前晚", minute: 21 * 60)
        entry(j, yearDay, "一年前早", minute: 9 * 60)
        entry(j, halfDay, "半年前次日", minute: 20 * 60, mood: 4)
        entry(j, weekDay, "一周前前一日", minute: 22 * 60)
        entry(j, today.adding(days: -100), "百日前珍藏", minute: 12 * 60, pinned: true)
        entry(j, today.adding(days: -3), "三日前珍藏", minute: 12 * 60, pinned: true)
        entry(j, today.adding(days: -40), "四十日前", minute: 12 * 60)
        DataStore.save(j)
        let picks = DashboardLookBackLoader.load(j, today: today)
        let titles = picks.map(\.entry.title)
        check(titles == ["一年前早", "一年前晚", "半年前次日", "一周前前一日", "百日前珍藏"],
              "旧笔新读：先远后近（一年前两篇按时间先后、半年前放宽一天、一周前放宽一天），再接 7 天以前的珍藏；近 3 天的珍藏、普通旧笔不在其中（\(titles.joined(separator: "、"))）")
        check(picks.count == 5
              && picks[0].eyebrow == "一年前的今天 · \(yearDay.weekdayName)"
              && picks[2].eyebrow == "半年前 · \(halfDay.weekdayName)"
              && picks[3].eyebrow == "一周前 · \(weekDay.weekdayName)"
              && picks[4].eyebrow == "珍藏 · 3 个月前",
              "旧笔新读：眉题写“一年前的今天 · 周X”，放宽一天的不写“的今天”，珍藏写隔了多久（\(picks.map(\.eyebrow).joined(separator: "｜"))）")
        let digestDays = Set(JournalDigest.shared.sync(j).lookBack(today: today).map(\.day))
        check(digestDays == Set(picks.prefix(4).map(\.day)), "旧笔新读：与修行录“往日回看”取的是同几天")

        // 兜底一：没有往年今日，只有珍藏（按日期固定从某一篇起，普通旧笔不混进来）
        let j2 = try journal()
        entry(j2, today.adding(days: -100), "珍藏甲", minute: 600, pinned: true)
        entry(j2, today.adding(days: -200), "珍藏乙", minute: 600, pinned: true)
        entry(j2, today.adding(days: -40), "旧笔丙", minute: 600)
        DataStore.save(j2)
        let pinnedPicks = DashboardLookBackLoader.load(j2, today: today).map(\.entry.title)
        let pinnedFirst = ["珍藏乙", "珍藏甲"][DashboardRules.dailyIndex(today, count: 2)]
        check(pinnedPicks.count == 2 && pinnedPicks.first == pinnedFirst && Set(pinnedPicks) == ["珍藏甲", "珍藏乙"],
              "旧笔新读：没有往年今日时取 7 天以前的珍藏，按日期固定从「\(pinnedFirst)」起（\(pinnedPicks.joined(separator: "、"))）")

        // 兜底二：没有往年今日、没有珍藏：7 天以前的任一篇，按日期固定、同一天取两次一样
        let j3 = try journal()
        entry(j3, today.adding(days: -10), "十日前", minute: 600)
        entry(j3, today.adding(days: -20), "二十日前", minute: 600)
        entry(j3, today.adding(days: -40), "四十日前", minute: 600)
        entry(j3, today.adding(days: -2), "前天", minute: 600)
        DataStore.save(j3)
        let older = DashboardLookBackLoader.load(j3, today: today)
        let olderAgain = DashboardLookBackLoader.load(j3, today: today)
        let olderFirst = ["四十日前", "二十日前", "十日前"][DashboardRules.dailyIndex(today, count: 3)]
        check(older.count == 3 && older.first?.entry.title == olderFirst && older.map(\.entry.title) == olderAgain.map(\.entry.title)
              && !older.contains { $0.entry.title == "前天" }
              && older.allSatisfy { $0.eyebrow == DashboardRules.olderEyebrow(day: $0.day, today: today) },
              "旧笔新读：没有往年今日和珍藏时取 7 天以前的任一篇，按日期固定从「\(olderFirst)」起、近 7 天的不取（\(older.map(\.eyebrow).joined(separator: "｜"))）")

        // 兜底三：只在近 7 天写过 → 空（卡里写“写满七日……”）；一篇没有 → 空（卡片整张不出）
        let j4 = try journal()
        entry(j4, today.adding(days: -2), "前天", minute: 600)
        entry(j4, today, "今天", minute: 600, pinned: true)
        DataStore.save(j4)
        let empty = try journal()
        check(DashboardLookBackLoader.load(j4, today: today).isEmpty && DashboardLookBackLoader.load(empty, today: today).isEmpty
              && EmptyCopy.isOneSentence(DashboardRules.waitingLine),
              "旧笔新读：只在近 7 天写过时没有可读的（卡里只写“\(DashboardRules.waitingLine)”），一篇没有时也是空")

        // 5 年量级：每天一篇、约 5% 珍藏，取一次要快（只按日期 / 珍藏谓词取，不整表取）
        let big = try journal()
        for offset in 1...1825 {
            entry(big, today.adding(days: -offset), "第\(offset)日", minute: 1200, pinned: offset % 20 == 0)
        }
        DataStore.save(big)
        let started = Date()
        let bigPicks = DashboardLookBackLoader.load(big, today: today)
        let elapsed = Date().timeIntervalSince(started)
        check(bigPicks.count == DashboardLookBackLoader.limit && bigPicks.first?.eyebrow.hasPrefix("一年前的今天") == true && elapsed < 0.15,
              String(format: "旧笔新读：5 年 1825 篇时取一次 %.0f 毫秒，取满 %d 篇、第一篇是一年前的今天", elapsed * 1000, bigPicks.count))

        // 3. 两栏布局
        let box = DashboardFrameBox()
        func card(_ name: String, _ height: CGFloat) -> some View {
            Color.clear
                .frame(minHeight: height, idealHeight: height, maxHeight: .infinity)
                .background(GeometryReader { geo in
                    let _ = box.record(name, geo.frame(in: .named(DashboardFrameSpace.name)))
                    Color.clear
                })
        }
        func layout(width: CGFloat, showHidden: Bool) -> [String: CGRect] {
            box.frames = [:]
            let view = OverviewColumns {
                card("落笔", 100).overviewSlot(.left, stacked: 0)
                DashboardHiddenProbe(show: showHidden, box: box).equatable().overviewSlot(.left, stacked: 3)
                card("修为", 100).overviewSlot(.left, stacked: 4)
                card("功课", 300).overviewSlot(.right, stacked: 1)
                card("行程", 500).overviewSlot(.right, stacked: 2)
            }
            .coordinateSpace(name: DashboardFrameSpace.name)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
            host.layoutSubtreeIfNeeded()
            return box.frames
        }
        let wide = layout(width: 1000, showHidden: false)
        let gutter = PageLayout.gutter
        check(wide["修为"].map { abs($0.minY - (100 + gutter)) < 0.5 && abs($0.height - (100 + DashboardRules.maxStretch)) < 0.5 } == true
              && wide["行程"].map { abs($0.height - 500) < 0.5 } == true,
              "首页两栏：左栏比右栏矮很多时最后一张只多拉 160（修为 \(Int(wide["修为"]?.height ?? -1)) pt，不再拉成一整块空卡）；整张不出的卡不留卡距（修为顶在 \(Int(wide["修为"]?.minY ?? -1))）")
        let withHidden = layout(width: 1000, showHidden: true)
        check(withHidden["旧笔"].map { abs($0.minY - (100 + gutter)) < 0.5 } == true
              && withHidden["修为"].map { abs($0.minY - (100 + gutter + 50 + gutter)) < 0.5 } == true,
              "首页两栏：旧笔新读在落笔与修为之间（左栏按书写先后）")
        let narrow = layout(width: 600, showHidden: true)
        let order = narrow.sorted { $0.value.minY < $1.value.minY }.map(\.key)
        check(order == ["落笔", "功课", "行程", "旧笔", "修为"] && narrow["修为"].map { abs($0.height - 100) < 0.5 } == true,
              "首页窄窗口上下排：落笔、今日功课、今日行程、旧笔新读、修为，不拉高（\(order.joined(separator: "、"))）")

        // 4a. 旧笔新读里删除：只有一年前那天的一篇（取数在第 1 步就停了），7 天以前另有一篇普通旧笔
        let jd = try journal()
        entry(jd, yearDay, "一年前唯一", minute: 600, mood: 4)
        entry(jd, today.adding(days: -40), "四十日前旧笔", minute: 600)
        DataStore.save(jd)
        let undo = DashboardLookBackUndo()
        let shown = DashboardLookBackLoader.load(jd, today: today)
        let xpShown = CultivationService.fullState(context: jd).totalXP
        check(shown.map(\.entry.title) == ["一年前唯一"], "旧笔新读删除（前提）：有一年前的今天时不往下取旧笔（\(shown.map(\.entry.title).joined(separator: "、"))）")
        if let first = shown.first {
            let offer = undo.delete(first.entry, context: jd, effects: effects)
            let afterDelete = DashboardLookBackLoader.load(jd, today: today)
            let xpDeleted = CultivationService.fullState(context: jd).totalXP
            check(undo.offer?.id == offer.id && offer.snapshot.title == "一年前唯一" && undo.revision == 1 && JournalActions.undoWindowOpen
                  && afterDelete.map(\.entry.title) == ["四十日前旧笔"] && xpDeleted < xpShown,
                  "旧笔新读删除：底部给“撤销删除”（约 8 秒内换日也先等），修为扣回 \(xpShown) → \(xpDeleted)；按当天重取，换成 7 天以前的旧笔，不误写“写满七日”（\(afterDelete.map(\.entry.title).joined(separator: "、"))）")
            let restored = undo.restore(offer, context: jd, effects: effects)
            let afterRestore = DashboardLookBackLoader.load(jd, today: today)
            check(restored && undo.offer == nil && undo.revision == 2 && !JournalActions.undoWindowOpen
                  && afterRestore.map(\.entry.title) == ["一年前唯一"] && afterRestore.first?.entry.mood == 4
                  && CultivationService.fullState(context: jd).totalXP == xpShown,
                  "旧笔新读撤销删除：原样找回（心境还在），修为恢复，重取后又是一年前的今天")
            check(!undo.restore(offer, context: jd, effects: effects) && undo.revision == 2 && jd.all(JournalEntry.self).count == 2,
                  "旧笔新读撤销删除：同一条提示再点一次不动（不会插回第二份）")
        }

        // 4b. 数量行悬停提示说的就是此刻点打卡圈会怎样（与 HabitCheckIn.tap 同一条判断）
        let med = habit("首页自检冥想", target: 10, unit: "分钟")
        DataStore.save(c)
        func hint(_ h: Habit) -> String {
            let stats = h.stats(today: today)
            let log = stats.logs[today]
            return HabitPlusStep.hint(done: log?.quantity ?? 0, target: HabitQuantity.target(h, log: log) ?? 0, unit: h.unit,
                                      achieved: stats.isAchieved(today), needsInput: HabitQuantity.needsInput(h, log: log))
        }
        let freshHint = hint(med)
        let freshTap = HabitQuantity.needsInput(med, on: today, context: c)
        _ = plus(med)
        let partHint = hint(med)
        let partTap = HabitQuantity.needsInput(med, on: today, context: c)
        check(!freshTap && freshHint.contains("点打卡圈记满") && partTap && partHint.contains("点打卡圈可改数量") && !partHint.contains("记满")
              && partHint.hasPrefix("今天已记 1 / 10 分钟") && hint(water) == "今天已达标",
              "首页数量行提示：还没记时说“点打卡圈记满”，点过 +1（1/10）后点圈弹数量框，提示改说“可改数量，或按目标记为达标”（\(partHint)）")

        // 4c. 收起已圆满：刚圆满的（不论从哪条路打满）在同一次重算里就留在原处，留一会儿后才收进去
        struct Row: Identifiable { var id: Int }
        let rows8 = (1...8).map(Row.init)
        func ids(_ list: [Row]) -> [Int] { list.map(\.id) }
        let opened = DashboardHabitFold.split(rows8, done: [1, 2, 3], seen: nil, lingering: [])
        let justNow = DashboardHabitFold.split(rows8, done: [1, 2, 3, 4], seen: [1, 2, 3], lingering: [])
        let lingered = DashboardHabitFold.split(rows8, done: [1, 2, 3, 4], seen: [1, 2, 3, 4], lingering: [4])
        let settled = DashboardHabitFold.split(rows8, done: [1, 2, 3, 4], seen: [1, 2, 3, 4], lingering: [])
        let few = DashboardHabitFold.split(Array(rows8.prefix(6)), done: [1, 2], seen: [], lingering: [])
        check(ids(opened.listed) == [4, 5, 6, 7, 8] && ids(opened.folded) == [1, 2, 3]
              && ids(justNow.listed) == [4, 5, 6, 7, 8] && ids(justNow.folded) == [1, 2, 3]
              && ids(lingered.listed) == [4, 5, 6, 7, 8]
              && ids(settled.listed) == [5, 6, 7, 8] && ids(settled.folded) == [1, 2, 3, 4]
              && ids(few.listed) == [1, 2, 3, 4, 5, 6] && few.folded.isEmpty,
              "首页功课收起：卡片刚出现时已圆满的直接收起；数量框里刚打满的一项当下就留在原处、留一会儿后才收进“已圆满”；6 项以内不收")
    }
}
