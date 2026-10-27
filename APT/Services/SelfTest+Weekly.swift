import Foundation
import SwiftData
import SwiftUI
import AppKit

// r2-weekly（#11 七日小卷）的运行时自检：从内存库取一周的东西（只取两周的修行录、借修为模型的功课统计、账簿按日期筛），
// “存为周复盘草稿”写进修行录落笔框的草稿（替换 / 接在后面；同一周不叠两份；月复盘只接素材不改周期），
// 点开摘句后删除有撤销、重取后卷上不留，往前翻的下限，“写下一句”把光标放进落笔框，小卷挂进窗口不出错、路由标志默认是关的。
// 周边界、摘句、心境、功课口径、账单没导全这些纯函数在 CoreCheck。
// 草稿写进单独的偏好域（自检一定设了 APT_STORE_DIR；万一没设就用一个自检专用的套件），用过的键最后都还原。

extension SelfTest {
    @MainActor
    static func weeklyChecks(_ check: (Bool, String) -> Void) throws {
        let defaults = AppPreferences.suiteName != nil ? AppPreferences.defaults : UserDefaults(suiteName: "io.github.orientaldaitou.yunshan.selftest-weekly")!
        let fields = ["kind", "title", "text", "mood", "tags", "day", "period"]
        let saved = fields.map { defaults.object(forKey: JournalDraft.key(WeeklyDraft.page, $0)) }
        defer {
            for (field, value) in zip(fields, saved) {
                if let value { defaults.set(value, forKey: JournalDraft.key(WeeklyDraft.page, field)) }
                else { defaults.removeObject(forKey: JournalDraft.key(WeeklyDraft.page, field)) }
            }
        }
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        let today = LocalDay.today()
        let week = WeeklyDigest.Week(monday: today.mondayOfWeek, today: today)
        let previous = week.previous

        // 一项每天的功课：上周一起天天打卡（含今天）→ 本周、上周都是 100%
        let habit = Habit(title: "冥想")
        habit.startDate = previous.monday.adding(days: -10).key
        habit.createdAt = previous.monday.adding(days: -10).date()
        context.insert(habit)
        for day in LocalDay.range(previous.monday, today) {
            let log = HabitLog(dateKey: day.key)
            context.insert(log)
            log.habit = habit
        }
        // 修行录：本周一一条珍藏、今天一条心境「霁」；上周一一条；三周前一条珍藏（不在取数范围里，不该出现）
        func entry(_ body: String, _ day: LocalDay, mood: Int? = nil, pinned: Bool = false) -> JournalEntry {
            let e = JournalEntry(kind: .diary, title: "", body: body, dateKey: day.key)
            e.mood = mood
            e.pinned = pinned
            context.insert(e)
            return e
        }
        let pinnedEntry = entry("先完成再完美", week.monday, mood: 3, pinned: true)
        let bright = entry("今天读完了一章。后面还写了很多别的。", today, mood: 5)
        _ = entry("上周一的一篇", previous.monday, mood: 2)
        let old = entry("三周前的珍藏", previous.monday.adding(days: -14), pinned: true)
        // 账簿：本周一一笔手记午饭，上周日一笔（不算进本周）
        _ = try FinanceService.mutate(context) { ledger in
            ledger.transactions.append(ManualExpense.transaction(id: "weekly-lunch", day: week.monday, cents: 1850, category: "餐饮与外卖",
                                                                 description: "午饭", note: "", reason: ""))
            ledger.transactions.append(ManualExpense.transaction(id: "weekly-old", day: previous.sunday, cents: 9900, category: "购物",
                                                                 description: "上周日", note: "", reason: ""))
        }
        DataStore.save(context)

        // 1. 取数：摘句、心境、功课、花费
        let content = WeeklyScrollContent.load(week: week, context: context)
        let uids = Set(content.quotes.map(\.uid))
        check(uids.contains(pinnedEntry.uid) && uids.contains(bright.uid) && !uids.contains(old.uid)
              && content.entries[pinnedEntry.uid] === pinnedEntry && content.entries[old.uid] == nil && content.hasEntries,
              "七日小卷取数：摘句有本周的珍藏和心境最好那天的一篇，三周前的珍藏不取（只取两周）")
        let mondayMark = content.marks.first { $0.day == week.monday }?.mark
        let todayMark = content.marks.first { $0.day == today }?.mark
        // 今天就是周一时两篇同一天，心境取平均（平 3、霁 5 → 4）
        let sameDay = week.monday == today
        check(content.marks.count == 7 && mondayMark == .mood(sameDay ? 4 : 3) && todayMark == .mood(sameDay ? 4 : 5)
              && content.marks.filter { $0.day > today }.allSatisfy { $0.mark == .future },
              "七日小卷取数：心境七日一格一天，周一「平」、今天「霁」，今天以后的还没到")
        check(content.habits.map { abs($0.rate - 1) < 1e-9 && $0.previousRate.map { abs($0 - 1) < 1e-9 } == true && $0.steadiest?.title == "冥想" } == true,
              "七日小卷取数：功课借修为模型的统计，本周、上周都 100%，最稳是冥想")
        check(content.spend?.cents == 1850 && content.spend?.topCategory == "餐饮与外卖" && content.spend?.coveredThrough == nil
              && content.spend?.incomplete == false,
              "七日小卷取数：本周花费只算这周的（上周日那笔不算），只有手记时不写“账单不全”")

        // 2. 存为周复盘草稿：落笔框空着时直接写；类型复盘、周期周、补记日期是这周已过的最后一天
        for field in fields { defaults.removeObject(forKey: JournalDraft.key(WeeklyDraft.page, field)) }
        WeeklyDraft.write(week: week, quotes: content.quotes, context: context, mode: .replace, defaults: defaults)
        func draft(_ field: String) -> String { defaults.string(forKey: JournalDraft.key(WeeklyDraft.page, field)) ?? "" }
        let text = draft("text")
        let label = ReviewMaterial.range(period: .week, anchor: week.last, today: today).label
        let material = text.range(of: "〔本期素材 · \(label)")?.lowerBound
        let quotesAt = text.range(of: "〔本周摘句〕")?.lowerBound
        let insight = text.range(of: "【所悟】")?.lowerBound
        check(draft("kind") == "review" && draft("period") == "week" && draft("day") == week.last.key
              && draft("title") == WeeklyDigest.draftTitle(week) && text.hasPrefix("【所得】") && text.hasSuffix("【下一步】\n")
              && material != nil && quotesAt != nil && insight != nil && material! < quotesAt! && quotesAt! < insight!
              && text.contains("「先完成再完美」") && !JournalDraft.isBlank(page: WeeklyDraft.page, defaults: defaults),
              "存为周复盘草稿：类型复盘、周期周、补记 \(week.last.shortLabel)、标题「\(draft("title"))」，【所悟】之前插好本期素材与〔本周摘句〕")

        // 3. 落笔框已有没写完的草稿：接在后面（原标题空就补上本周标题）；替换则整篇换掉；原文只是空白模板时不叠两份模板
        defaults.set("写了一半的日记", forKey: JournalDraft.key(WeeklyDraft.page, "text"))
        defaults.set("", forKey: JournalDraft.key(WeeklyDraft.page, "title"))
        defaults.set("diary", forKey: JournalDraft.key(WeeklyDraft.page, "kind"))
        WeeklyDraft.write(week: week, quotes: content.quotes, context: context, mode: .append, defaults: defaults)
        let appended = draft("text")
        check(appended.hasPrefix("写了一半的日记\n\n【所得】") && appended.contains("〔本周摘句〕") && draft("kind") == "review"
              && draft("title") == WeeklyDigest.draftTitle(week),
              "存为周复盘草稿“接在后面”：原文留着、空一行接上本周素材，类型改为复盘，空标题补上本周标题")
        defaults.set("我自己的标题", forKey: JournalDraft.key(WeeklyDraft.page, "title"))
        defaults.set(ReviewPeriod.template, forKey: JournalDraft.key(WeeklyDraft.page, "text"))
        WeeklyDraft.write(week: week, quotes: [], context: context, mode: .append, defaults: defaults)
        let fromTemplate = draft("text")
        check(draft("title") == "我自己的标题" && fromTemplate.components(separatedBy: "【所得】").count == 2 && !fromTemplate.contains("〔本周摘句〕"),
              "存为周复盘草稿“接在后面”：已有标题不动；原文只是空白模板时不叠两份模板；没有摘句不写〔本周摘句〕")
        WeeklyDraft.write(week: previous, quotes: [], context: context, mode: .replace, defaults: defaults)
        check(draft("title") == WeeklyDigest.draftTitle(previous) && draft("day") == previous.sunday.key
              && !draft("text").contains("我自己的标题") && draft("tags").isEmpty,
              "存为周复盘草稿“替换”：标题、正文整篇换成上一周的，补记日期是上周日")
        // 再点一次同一周：落笔框认得出已是这一周的周复盘（不再问、不再叠一份）；换一周就认不出
        check(WeeklyDraft.holdsWeek(previous, defaults: defaults) && !WeeklyDraft.holdsWeek(week, defaults: defaults),
              "存为周复盘草稿：落笔框已是这一周的周复盘时认得出来，再点不叠第二份模板")
        // 落笔框里是写了一半的“复盘 · 月”：接在后面只接素材，周期、补记日期、标题都不改
        let monthEnd = today.firstOfMonth.adding(days: 40).firstOfMonth.adding(days: -1)
        defaults.set("review", forKey: JournalDraft.key(WeeklyDraft.page, "kind"))
        defaults.set(ReviewPeriod.month.rawValue, forKey: JournalDraft.key(WeeklyDraft.page, "period"))
        defaults.set(monthEnd.key, forKey: JournalDraft.key(WeeklyDraft.page, "day"))
        defaults.set("", forKey: JournalDraft.key(WeeklyDraft.page, "title"))
        defaults.set("月复盘写了一半", forKey: JournalDraft.key(WeeklyDraft.page, "text"))
        WeeklyDraft.write(week: week, quotes: content.quotes, context: context, mode: .append, defaults: defaults)
        check(draft("kind") == "review" && draft("period") == "month" && draft("day") == monthEnd.key && draft("title").isEmpty
              && draft("text").hasPrefix("月复盘写了一半\n\n【所得】") && draft("text").contains("〔本周摘句〕"),
              "存为周复盘草稿“接在后面”：原稿是月复盘时只接素材，周期仍是月、补记日期与标题不动（不悄悄改成周复盘）")

        // 4. 从小卷点开摘句后删掉这一篇：交给打开小卷的那一页删（修行录走自己的快照与撤销）；没交代时也先拍快照、给撤销，
        //    不会直接删了找不回；关掉阅读弹窗后重取，卷上不留已删的那句
        func exists(_ uid: String) -> Bool {
            ((try? context.fetchCount(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.uid == uid }))) ?? 0) > 0
        }
        let pinnedUid = pinnedEntry.uid
        var handed: String?
        WeeklyScrollSheet.delete(pinnedEntry, onDelete: { handed = $0.uid }, context: context, effects: nil)
        check(handed == pinnedUid && exists(pinnedUid), "七日小卷删除：有 onDelete 时交给打开小卷的那一页删（修行录：快照 + 底部撤销），小卷自己不删")
        let undo = DashboardLookBackUndo()
        WeeklyScrollSheet.delete(pinnedEntry, onDelete: nil, context: context, effects: nil, undo: undo)
        let afterDelete = WeeklyScrollContent.load(week: week, context: context)
        let goneFromScroll = !exists(pinnedUid) && !afterDelete.quotes.contains { $0.uid == pinnedUid } && afterDelete.entries[pinnedUid] == nil
        let restored = undo.offer.map { undo.restore($0, context: context, effects: nil) } ?? false
        let back = WeeklyScrollContent.load(week: week, context: context)
        check(goneFromScroll && restored && exists(pinnedUid) && back.quotes.contains { $0.uid == pinnedUid },
              "七日小卷删除：没交代时先拍快照再删、给“撤销删除”（与旧笔新读同一套），重取后卷上不留那句；撤销后原样回来")

        // 5. 往前翻的下限：最早一条记录（三周前那篇）所在的周；全新的库一条都没有，整卷空着、不能往前翻
        let earliest = WeeklyScrollContent.earliestDay(context: context)
        let emptyContainer = try DataStore.makeContainer(inMemory: true)
        DataStore.settings(in: emptyContainer.mainContext)
        let blank = WeeklyScrollContent.load(week: week, context: emptyContainer.mainContext)
        check(earliest == LocalDay(key: old.dateKey) && week.hasPrevious(earliest: earliest)
              && WeeklyScrollContent.earliestDay(context: emptyContainer.mainContext) == nil && blank.isBlank && blank.insight == nil
              && !content.isBlank,
              "七日小卷：“‹ 上一周”翻到最早一条记录（\(earliest?.shortLabel ?? "无")）所在的周为止；全新的库整卷空着（主按钮换“写下一句”）、不能往前翻")

        // 6. 写下一句：收起小卷后光标落进落笔框（落笔卡挂进一扇离屏窗口，按小卷的找法找到正文框并接住光标）
        var composerKind = JournalKind.diary
        let composer = NSHostingView(rootView: JournalComposer(kind: Binding(get: { composerKind }, set: { composerKind = $0 }), draftPage: "selftest-weekly")
            .environment(EffectsCenter())
            .environment(\.spiritMotion, false)
            .modelContainer(container)
            .defaultAppStorage(defaults)
            .frame(width: 520))
        composer.frame = CGRect(x: 0, y: 0, width: 560, height: 640)
        let window = NSWindow(contentRect: composer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = composer
        composer.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let focused = WeeklyCompose.focus(in: window)
        let responder = window.firstResponder as? NSTextView
        check(focused && responder != nil && responder?.isEditable == true && responder?.isFieldEditor == false,
              "七日小卷“写下一句”：在窗口里找到落笔框的正文框，光标落进去")
        window.contentView = nil
        window.close()
        for field in fields { defaults.removeObject(forKey: JournalDraft.key("selftest-weekly", field)) }

        // 7. 小卷挂进窗口：取数、各节不出错；路由标志默认是关的（谁在当前页谁打开，打开即清零）
        let host = NSHostingView(rootView: WeeklyScrollSheet(week: week, fullLength: true)
            .environment(EffectsCenter())
            .environment(\.spiritMotion, false)
            .modelContainer(container)
            .defaultAppStorage(defaults))
        host.frame = CGRect(x: 0, y: 0, width: 620, height: 900)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        check(host.fittingSize.height > 500 && !AppRouter.shared.weeklyScroll,
              "七日小卷挂进窗口：整卷铺开高 \(Int(host.fittingSize.height)) pt；AppRouter.weeklyScroll 平时是关的")
    }
}
