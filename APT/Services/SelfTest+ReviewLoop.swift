import Foundation
import SwiftData
import SwiftUI
import AppKit

// r2-review（#12）的运行时自检：复盘闭环。
// 纯函数（【下一步】拆条、回访插回正文、周一补写上周、本期花费的说法）在 CoreCheck；这里核对按库取数的那一半——
// “上次”取哪一篇、参悟时的决定、素材里的花费一行（账簿读缓存），以及修行录落笔框入卷时把没插进正文的回访补进去、入卷后清掉点过的签。
// 偏好用自检临时数据目录那一份（AppPreferences.defaults：自检一定设了 APT_STORE_DIR，是单独的偏好域），用过的键最后都清掉。

extension SelfTest {
    @MainActor
    static func reviewLoopChecks(_ check: (Bool, String) -> Void) throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        let today = LocalDay.today()

        func review(_ offset: Int, _ period: ReviewPeriod?, _ body: String, title: String = "") {
            let entry = JournalEntry(kind: .review, title: title, body: body, dateKey: today.adding(days: -offset).key)
            entry.period = period?.rawValue ?? ""
            context.insert(entry)
        }
        // 两周前的周复盘写了下一步；上周那篇没用模板（取不到下一步）；昨天的日省、三天前的月复盘各有下一步；今天的不算“上次”
        review(14, .week, "【所得】论文写了 6000 字。\n【所失】周三熬夜。\n【所悟】晚上效率低。\n【下一步】23:30 前收工；每天上午先写 90 分钟。", title: "两周前的周复盘")
        review(7, .week, "这周还行，就是有点累。")
        review(1, .day, "【所得】写完了\n【下一步】明早先改摘要")
        review(3, .month, "【下一步】\n1. 交初稿\n2. 定答辩日期")
        review(0, .week, "【下一步】今天写的这篇不算")
        let diary = JournalEntry(kind: .diary, title: "", body: "【下一步】日记里写的不算", dateKey: today.adding(days: -2).key)
        context.insert(diary)
        DataStore.save(context)

        // 1. “上次许下的下一步”：同周期里最近一篇写了的（跳过没模板的那篇）；没有同周期的取最近一篇任意复盘
        let week = ReviewThread.latest(before: today, period: .week, context: context)
        let day = ReviewThread.latest(before: today, period: .day, context: context)
        let event = ReviewThread.latest(before: today, period: .event, context: context)
        let none = ReviewThread.latest(before: today.adding(days: -20), period: .week, context: context)
        let twoWeeks = today.adding(days: -14)
        check(week?.steps == ["23:30 前收工", "每天上午先写 90 分钟"] && week?.day == twoWeeks && week?.title == "两周前的周复盘"
              && week?.label == ReviewThread.promiseLabel(period: "week", day: twoWeeks, today: today),
              "上次许下的下一步（周复盘）：跳过上周没用模板的那篇，取两周前那篇的 2 条，小标题“\(week?.label ?? "nil")”")
        check(day?.steps == ["明早先改摘要"] && event?.steps == ["明早先改摘要"] && none == nil
              && ReviewThread.latest(before: today, period: .month, context: context)?.steps == ["交初稿", "定答辩日期"],
              "日省取昨天那篇；事后复盘没有同周期的，取最近一篇任意复盘；月复盘取月复盘；再往前没有复盘时 nil（整块不显示）；日记里的【下一步】不算")

        // 2. 参悟时的决定：近 14 天里最近一条写了决定的（只取第一行）；没写决定的、20 天前的都不算
        let old = AdviceRecord(title: "很久以前", summary: "", response: "")
        old.decision = "二十天前的决定"
        old.createdAt = today.adding(days: -20).date(minutes: 9 * 60)
        context.insert(old)
        DataStore.save(context)
        let noDecision = ReviewThread.decision(near: today, context: context)
        let decided = AdviceRecord(title: "为什么总是拖到很晚", summary: "", response: "")
        decided.decision = "  上午先写 90 分钟\n下午再看文献"
        decided.createdAt = today.adding(days: -5).date(minutes: 10 * 60)
        context.insert(decided)
        let blank = AdviceRecord(title: "还没想好", summary: "", response: "")
        blank.createdAt = today.adding(days: -1).date(minutes: 10 * 60)
        context.insert(blank)
        DataStore.save(context)
        let decision = ReviewThread.decision(near: today, context: context)
        check(noDecision == nil && decision?.text == "上午先写 90 分钟" && decision?.day == today.adding(days: -5)
              && decision?.line == "上午先写 90 分钟（参悟时的决定）",
              "参悟时的决定：20 天前的不算；取 5 天前那条的第一行，跳过昨天没写决定的：\(decision?.text ?? "nil")")

        // 3. 回访插回正文：素材插在【所悟】前，回访各进各段（同一次“插入”）
        let insertion = ReviewInsertion(block: ReviewMaterial.block(lines: ["落笔 3 篇。"], label: "10月19日—10月25日"),
                                        followups: [("23:30 前收工", .done), ("每天上午先写 90 分钟", .missed), ("上午先写 90 分钟（参悟时的决定）", .changed)])
        let inserted = insertion.applied(to: ReviewPeriod.template)
        check(inserted == "【所得】\n· 23:30 前收工 —— 做到了\n\n【所失】\n· 每天上午先写 90 分钟 —— 没做到\n\n"
              + "〔本期素材 · 10月19日—10月25日，仅供参考〕\n· 落笔 3 篇。\n\n【所悟】\n· 上午先写 90 分钟（参悟时的决定） —— 改主意了\n\n【下一步】\n",
              "插入复盘正文：做到的进【所得】、没做到的进【所失】（素材在它下面）、改主意的进【所悟】：\(inserted.debugDescription)")
        // 再点一枚签、再点“插入”：素材不再整段重复，只补新点的那条；改过签的换掉旧行
        let again = ReviewInsertion(block: ReviewMaterial.block(lines: ["落笔 3 篇。"], label: "10月19日—10月25日"),
                                    followups: [("23:30 前收工", .missed), ("早睡", .done)]).applied(to: inserted)
        check(again.components(separatedBy: ReviewThread.materialHead).count == 2
              && again.contains("【所得】\n· 早睡 —— 做到了\n") && !again.contains("23:30 前收工 —— 做到了")
              && again.contains("· 每天上午先写 90 分钟 —— 没做到\n· 23:30 前收工 —— 没做到\n"),
              "再插一次：〔本期素材〕只有一段，只补新点的回访，改了签的换掉旧行：\(again.debugDescription)")
        // 七日小卷存的周复盘草稿（模板里已插好素材）：点签后“插入复盘正文”只补回访
        let weekly = ReviewMaterial.insert(ReviewMaterial.block(lines: ["落笔 3 篇。"], label: "10月19日–25日"), into: ReviewPeriod.template)
        let weeklyAfter = ReviewInsertion(block: ReviewMaterial.block(lines: ["落笔 3 篇。"], label: "10月19日–25日"),
                                          followups: [("23:30 前收工", .done)]).applied(to: weekly)
        check(weeklyAfter.components(separatedBy: ReviewThread.materialHead).count == 2
              && weeklyAfter.hasPrefix("【所得】\n· 23:30 前收工 —— 做到了\n\n【所失】\n\n〔本期素材"),
              "七日小卷草稿里已有素材：插入时只补回访，不再插第二段：\(weeklyAfter.debugDescription)")
        // 素材只插在行首的【所悟】之前；日期范围与回访小标题同一种写法
        let ownWords = ReviewMaterial.insert("〔本期素材 · x，仅供参考〕", into: "【所得】那次【所悟】很重要\n【所悟】\n")
        let weekRange = ReviewMaterial.range(period: .week, anchor: LocalDay(key: "2026-10-22")!, today: LocalDay(key: "2026-10-22")!)
        check(ownWords == "【所得】那次【所悟】很重要\n\n〔本期素材 · x，仅供参考〕\n\n【所悟】\n" && weekRange.label == "10月19日–22日",
              "素材只插在行首【所悟】前；范围写“10月19日–22日”：\(ownWords.debugDescription) / \(weekRange.label)")

        // 4. 素材里的本期花费：一笔账都没有时不写；有手记时写在最后一行，比上一期（这一期没过完比同期）
        let range = ReviewMaterial.range(period: .week, anchor: today)
        let before = ReviewMaterial.lines(context: context, first: range.first, last: range.last)
        var ledger = FinanceLedger()
        ledger.transactions = [
            ManualExpense.transaction(day: range.first, cents: 4200, category: "餐饮与外卖", description: "午饭", note: "", reason: ""),
            ManualExpense.transaction(day: range.first.adding(days: -7), cents: 3000, category: "交通出行", description: "打车", note: "", reason: ""),
        ]
        try FinanceService.save(ledger, context: context)
        let after = ReviewMaterial.lines(context: context, first: range.first, last: range.last)
        let withPeriod = ReviewMaterial.lines(context: context, first: range.first, last: range.last, period: .week)
        let partial = range.last < range.first.adding(days: 6)
        // 这一期只有一类：写“全在 …”，不把总额再写一遍
        let expected = "灵石：本期花费 $42.00（较\(partial ? "上周同期" : "上周") +40%），全在 餐饮与外卖。"
        check(!before.contains { $0.hasPrefix("灵石") } && after.last == expected && withPeriod == after,
              "本期素材多一行花费（手记、按周比上周）：\(after.last ?? "nil")；没有账目时不写")

        try latestChecks(check, today: today)
        try composerChecks(check, container: container, today: today)
    }

    /// “上次”取哪一篇的两种边角：每天写日省（同周期那篇不在最近 60 篇里）、上次那篇落在正在写的这一期里（小标题不与这期同名）
    @MainActor
    private static func latestChecks(_ check: (Bool, String) -> Void, today: LocalDay) throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        // 五周前的周一写了一篇周复盘；之后 30 天每天两篇日省（共 60 多篇），都写了【下一步】
        let monday = today.mondayOfWeek.adding(days: -35)
        let week = JournalEntry(kind: .review, title: "", body: "【下一步】早睡；跑三次步", dateKey: monday.key)
        week.period = ReviewPeriod.week.rawValue
        context.insert(week)
        for offset in 1...32 {
            for n in 0..<2 {
                let daily = JournalEntry(kind: .review, title: "", body: "【下一步】明早先改摘要 \(n)", dateKey: today.adding(days: -offset).key)
                daily.period = ReviewPeriod.day.rawValue
                context.insert(daily)
            }
        }
        DataStore.save(context)
        let found = ReviewThread.latest(before: today, period: .week, context: context, today: today)
        check(found?.day == monday && found?.steps == ["早睡", "跑三次步"],
              "每天写日省（60 多篇）时周复盘仍取到五周前那篇周复盘：\(found?.label ?? "nil")")
        // 那一周的周日补写这周的周复盘：上次那篇（同一周的周一写的）小标题写“X月X日写的周复盘”
        let sunday = monday.adding(days: 6)
        let same = ReviewThread.latest(before: sunday, period: .week, context: context, today: today)
        check(same?.day == monday && same?.label == "\(monday.label(relativeTo: today))写的周复盘",
              "上次那篇落在正在写的同一周里：小标题“\(same?.label ?? "nil")”，不与这周同名")
        // 入卷前补插：签对不上现在这几条（别的那篇的键）不插；对得上的照签插
        let raw = ReviewThread.toggled(ReviewThread.toggled("", key: "\(monday.key) 早睡", verdict: .done),
                                       key: "1999-01-01 早睡", verdict: .missed)
        let saved = ReviewMaterial.withFollowups(raw, into: ReviewPeriod.template, period: .week, anchor: today, context: context)
        check(saved == "【所得】\n· 早睡 —— 做到了\n\n【所失】\n\n【所悟】\n\n【下一步】\n",
              "入卷前补插：只插对得上这一篇的签：\(saved.debugDescription)")
    }

    /// 修行录落笔框：复盘入卷后清掉回访点过的签（草稿 draft.<页面>.followups）
    @MainActor
    private static func composerChecks(_ check: (Bool, String) -> Void, container: ModelContainer, today: LocalDay) throws {
        let defaults = AppPreferences.suiteName != nil ? AppPreferences.defaults : UserDefaults(suiteName: "io.github.orientaldaitou.yunshan.selftest-review")!
        let page = "selftest-review"
        let fields = ["title", "text", "tags", "mood", "period", "day", "kind", "followups"]
        defer { for field in fields { defaults.removeObject(forKey: JournalDraft.key(page, field)) } }
        let context = container.mainContext
        let effects = EffectsCenter()
        effects.motionEnabled = false
        let followupsKey = JournalDraft.key(page, "followups")
        defaults.set(ReviewPeriod.week.rawValue, forKey: JournalDraft.key(page, "period"))
        defaults.set("【所得】\n· 23:30 前收工 —— 做到了\n\n【所失】\n\n【所悟】\n\n【下一步】\n周末去爬山", forKey: JournalDraft.key(page, "text"))
        // 23:30 那条插过“做到了”后改成了“没做到”，参悟时的决定点了“改主意了”、没点插入：入卷时都要照签进正文
        defaults.set(ReviewThread.toggled(ReviewThread.toggled("", key: "\(today.adding(days: -14).key) 23:30 前收工", verdict: .missed),
                                          key: "\(today.adding(days: -5).key) 决定 上午先写 90 分钟", verdict: .changed), forKey: followupsKey)

        final class Box { var kind: JournalKind = .review }
        let box = Box()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: JournalComposer(kind: Binding(get: { box.kind }, set: { box.kind = $0 }), draftPage: page)
            .environment(effects)
            .environment(\.spiritMotion, false)
            .modelContainer(container)
            .defaultAppStorage(defaults)
            .frame(width: 580))
        view.frame = CGRect(x: 0, y: 0, width: 620, height: 900)
        window.contentView = view
        func settle() {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            view.layoutSubtreeIfNeeded()
        }
        settle()
        let mounted = defaults.string(forKey: followupsKey)?.isEmpty == false
        var pressed = false
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
            pressed = view.performKeyEquivalent(with: event)
        }
        settle()
        window.contentView = nil
        window.close()
        let saved = context.all(JournalEntry.self).first { $0.body.hasSuffix("周末去爬山") }
        check(mounted && pressed && saved?.kindValue == .review && saved?.period == "week"
              && (defaults.string(forKey: followupsKey) ?? "").isEmpty,
              "修行录复盘入卷（⌘↩）：回访点过的签随草稿一起清空（挂上时还在 \(mounted)、按下 \(pressed)、入卷 \(saved != nil)）")
        check(saved?.body == "【所得】\n\n【所失】\n· 23:30 前收工 —— 没做到\n\n【所悟】\n· 上午先写 90 分钟（参悟时的决定） —— 改主意了\n\n【下一步】\n周末去爬山",
              "没点“插入”就入卷：点过的签照签补进正文（改过的签换掉旧行），不会悄悄丢掉：\(saved?.body.debugDescription ?? "nil")")
        if let saved {
            context.delete(saved)
            DataStore.save(context)
        }
    }
}
