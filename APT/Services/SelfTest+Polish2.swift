import Foundation
import SwiftData
import SwiftUI
import AppKit

// MARK: - f-polish：收尾小毛病三处的运行时自检
// 1. 七日小卷纸笺：从周六晚到周一下午逐分钟走一遍，到点出现（周日 18:00）、到点收起（周一 12:00）这两下才放过渡，
//    跨午夜同一周只换字不放；动效关着时一下都不放。那一格不出时量出来高 0（通栏不留卡距），出时有一条纸笺高；× 掉的那一周不出；
//    同一周从 0 条记录变 1 条（周日晚写下本周第一条）时纸笺也走带动画的那条路，并且真的跟着出现；
// 2. 修行录“只看这天”：删一篇后那天还有就照旧只看那天；删光了日期这一项去掉；删的是别的日子不动；撤销删除篇目回来、筛选不再恢复；
// 3. 筑基三关第三关读的热键标记，就是随手记注册 ⌥⌘J 没成时写下的那个键（说法在 CoreCheck 的 f-polish 一节）。

extension SelfTest {
    @MainActor
    static func polish2Checks(_ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()

        // 1. 纸笺到点出现 / 收起：从这周六 17:00 走到下周一 13:00（周日是这周最后一天，周一是下一周第一天）
        let saturday = today.mondayOfWeek.adding(days: 5)
        var moments: [(day: LocalDay, minute: Int)] = []
        for offset in 0 ..< 3 {
            let day = saturday.adding(days: offset)
            let range = offset == 0 ? (17 * 60 ..< 24 * 60) : offset == 1 ? (0 ..< 24 * 60) : (0 ..< 13 * 60)
            for minute in range { moments.append((day, minute)) }
        }
        let targets = moments.map { DashboardCues.stripWeek(today: $0.day, minute: $0.minute) }
        var animated: [String] = []
        var quietChanges = 0
        var stillAnimated = 0
        for i in 1 ..< targets.count where targets[i] != targets[i - 1] {
            if DashboardWeeklyStrip.animatesChange(from: targets[i - 1], to: targets[i], motion: true) {
                animated.append("\(moments[i].day.weekdayIndex == 6 ? "周日" : "周一") \(ClockTime.text(moments[i].minute))")
            } else {
                quietChanges += 1
            }
            if DashboardWeeklyStrip.animatesChange(from: targets[i - 1], to: targets[i], motion: false) { stillAnimated += 1 }
        }
        check(animated == ["周日 18:00", "周一 12:00"] && quietChanges == 1 && stillAnimated == 0,
              "七日小卷纸笺：逐分钟走一遍，到点出现、到点收起各放一次过渡（\(animated.joined(separator: "、"))），跨午夜同一周只换字不放（\(quietChanges) 次），关动效时一下都不放")

        // 那一格：不出时高 0、不留卡距；出时一条纸笺；× 掉的那一周不出
        let container = try DataStore.makeContainer(inMemory: true)
        let c = container.mainContext
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        let lastWeek = WeeklyDigest.Week(monday: today.mondayOfWeek.adding(days: -7), today: today)
        c.insert(JournalEntry(kind: .diary, body: "上周一写的一句", dateKey: lastWeek.monday.key))
        DataStore.save(c)
        let model = CultivationModel(context: c)
        func height(_ target: WeeklyDigest.Week?, dismissed: String = "") -> CGFloat {
            let host = NSHostingView(rootView: OverviewColumns {
                WeeklyStripSlot(target: target, dismissed: .constant(dismissed)).overviewSlot(.top, stacked: -1)
                Color.clear.frame(height: 100).overviewSlot(.left, stacked: 0)
                Color.clear.frame(height: 200).overviewSlot(.right, stacked: 1)
            }
            .frame(width: 1000)
            .environment(model)
            .environment(EffectsCenter())
            .environment(\.spiritMotion, false)
            .modelContainer(container)
            .defaultAppStorage(AppPreferences.defaults))
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let hidden = height(nil), shown = height(lastWeek), dismissed = height(lastWeek, dismissed: lastWeek.monday.key)
        check(abs(hidden - 200) < 1 && shown >= 200 + PageLayout.gutter + 40 && abs(dismissed - 200) < 1,
              "七日小卷纸笺：那一格不出时高 0、两栏不让位（\(Int(hidden))），出时两栏上面一条纸笺（\(Int(shown))），× 掉的那一周不出（\(Int(dismissed))）")

        // 纸笺由数据触发：同一周从 0 条记录变 1 条（周日晚写下或打下本周第一条），走的是带动画的那条路；
        // 刚出现时直接按当时的画、不放；没变不放；关动效时瞬间
        check(DashboardWeeklyStrip.paperAnimates(from: false, to: true, motion: true)
              && DashboardWeeklyStrip.paperAnimates(from: true, to: false, motion: true)
              && !DashboardWeeklyStrip.paperAnimates(from: nil, to: true, motion: true)
              && !DashboardWeeklyStrip.paperAnimates(from: true, to: true, motion: true)
              && !DashboardWeeklyStrip.paperAnimates(from: false, to: true, motion: false),
              "七日小卷纸笺：同一周从 0 条变 1 条（写下或打下本周第一条）时放过渡、删光时淡出，刚出现时直接画，关动效时瞬间")
        // 同一张首页：本周还没记录时那一格高 0；写下本周第一条后纸笺跟着出现（不卡在“没出”）
        let thisWeek = WeeklyDigest.Week(monday: today.mondayOfWeek, today: today)
        let live = NSHostingView(rootView: OverviewColumns {
            WeeklyStripSlot(target: thisWeek, dismissed: .constant("")).overviewSlot(.top, stacked: -1)
            Color.clear.frame(height: 100).overviewSlot(.left, stacked: 0)
            Color.clear.frame(height: 200).overviewSlot(.right, stacked: 1)
        }
        .frame(width: 1000)
        .environment(model)
        .environment(EffectsCenter())
        .environment(\.spiritMotion, false)
        .modelContainer(container)
        .defaultAppStorage(AppPreferences.defaults))
        live.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        func liveHeight() -> CGFloat {
            for _ in 0 ..< 4 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); live.layoutSubtreeIfNeeded() }
            return live.fittingSize.height
        }
        let beforeFirst = liveHeight()
        c.insert(JournalEntry(kind: .diary, body: "本周第一句", dateKey: today.key))
        DataStore.save(c)
        let afterFirst0 = liveHeight()
        check(abs(beforeFirst - 200) < 1 && afterFirst0 >= 200 + PageLayout.gutter + 40,
              "七日小卷纸笺：本周还没记录时那一格不占位（\(Int(beforeFirst))），写下本周第一条后纸笺跟着出现（\(Int(afterFirst0))）")

        // 2. 修行录“只看这天”：甲日两篇、乙日一篇
        // 容器要留住：只留 context、容器先释放时 SwiftData 一插入就崩
        let dayContainer = try DataStore.makeContainer(inMemory: true)
        let d = dayContainer.mainContext
        let dayA = today.adding(days: -3).key, dayB = today.adding(days: -9).key
        let a1 = JournalEntry(kind: .diary, body: "甲日上午", dateKey: dayA)
        let a2 = JournalEntry(kind: .note, body: "甲日晚上", dateKey: dayA)
        let b1 = JournalEntry(kind: .diary, body: "乙日", dateKey: dayB)
        [a1, a2, b1].forEach { d.insert($0) }
        DataStore.save(d)
        check(ChronicleDayFilter.afterDelete(day: "2026-01-01", remaining: 0) == nil
              && ChronicleDayFilter.afterDelete(day: "2026-01-01", remaining: 2) == "2026-01-01"
              && ChronicleDayFilter.afterDelete(day: nil, remaining: 0) == nil && ChronicleDayFilter.afterDelete(day: nil, context: d) == nil,
              "修行录“只看这天”：那天还剩篇目时照旧，一篇不剩时去掉；没在只看某天时不动")
        _ = JournalActions.delete(a1, context: d, effects: nil)
        let afterFirst = ChronicleDayFilter.afterDelete(day: dayA, context: d)
        _ = JournalActions.delete(b1, context: d, effects: nil)
        let otherDay = ChronicleDayFilter.afterDelete(day: dayA, context: d)
        let last = JournalActions.delete(a2, context: d, effects: nil)
        let afterLast = ChronicleDayFilter.afterDelete(day: dayA, context: d)
        check(afterFirst == dayA && otherDay == dayA && afterLast == nil,
              "修行录“只看这天”：删一篇后那天还有一篇照旧只看那天；删的是别的日子不动；那天删光了日期这一项自动去掉")
        JournalActions.restore(last, context: d, effects: nil)
        let back = (try? d.fetchCount(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey == dayA }))) ?? 0
        let digest = JournalDigest.shared.sync(d)
        check(back == 1 && digest.matching(filter: "all", day: nil, tag: nil, month: nil, query: "").count == 1,
              "修行录“只看这天”：撤销删除后那篇回来了，时间线照“全部”列出（筛选不再恢复）")

        // 3. 筑基三关第三关看的就是随手记注册 ⌥⌘J 没成时写下的键
        let suite = "io.github.orientaldaitou.yunshan.selftest-polish2"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("全局快捷键 ⌥⌘J 没能注册（可能被其他应用占用），请从菜单栏的笔形图标随手记。", forKey: QuickCaptureKeys.hotKeyError)
        let failed = !(defaults.string(forKey: "quick.hotKeyError") ?? "").isEmpty
        check(QuickCaptureKeys.hotKeyError == "quick.hotKeyError" && failed
              && Onboarding.todo(.quick, hotKeyFailed: failed).hasPrefix("点菜单栏的笔形小图标随手记一句"),
              "筑基三关：第三关读的是随手记写热键出错的那个键（quick.hotKeyError），有值时改说菜单栏的笔形小图标")
    }
}
