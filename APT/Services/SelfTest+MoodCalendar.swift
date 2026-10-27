import SwiftUI
import SwiftData

// MARK: - r3-mood：心境月历的运行时自检（#15）
// 排格子、上色、翻月范围、点同一格取消在 Tools/CoreCheck 的 r3-mood 一节逐条核对；
// 这里测要用到数据库的部分（真 SwiftData、内存库）：
// 1. 月历借修行录摘要（JournalDigest）取数，和直接拿全表的（日期、心境）排出的一样；跨月、改了心境之后跟着变；
// 2. 点一格走的是修行录原有的“只看某一天”筛选：那天时间线的篇数与格子上的篇数相同；
// 3. 2 年 / 5 年数据：摘要按新的在前、越过所看的月份就停，翻到最早的月份也很快；
// 4. 卡片真画得出来（全新、轻度两种）；翻到往年的月份（“2025年12月 · 30 日”）标题行仍是一行，卡头与本月一样高；
// 5. 正只看的那天篇目删光后，那格空了也点得动、再点回到全部。

extension SelfTest {
    static func moodCalendarChecks(_ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()
        let last = MoodCalendar.shift(year: today.year, month: today.month, by: -1)
        let lastFirst = LocalDay(year: last.year, month: last.month, day: 1)
        func day(_ d: Int) -> LocalDay { lastFirst.adding(days: d - 1) }

        // 1. 上个月：3 日两篇（阴、平）、10 日一篇没记心境、末日一篇晴；本月今天一篇霁；三个月前一篇（最早）
        let container = try DataStore.makeContainer(inMemory: true)
        let c = ModelContext(container)
        func add(_ d: LocalDay, _ mood: Int?, _ body: String) {
            let entry = JournalEntry(kind: .diary, body: body, dateKey: d.key)
            entry.mood = mood
            c.insert(entry)
        }
        let lastDay = MoodCalendar.daysIn(year: last.year, month: last.month)
        add(day(3), 2, "三日上午")
        add(day(3), 3, "三日晚上")
        add(day(10), nil, "十日")
        add(day(lastDay), 4, "月末")
        add(today, 5, "今天")
        let oldest = LocalDay(year: MoodCalendar.shift(year: today.year, month: today.month, by: -3).year,
                              month: MoodCalendar.shift(year: today.year, month: today.month, by: -3).month, day: 15)
        add(oldest, 3, "最早一篇")
        DataStore.save(c)

        let digest = JournalDigest.shared.sync(c)
        let month = digest.moodMonth(year: last.year, month: last.month, today: today)
        let all = (try? c.fetch(FetchDescriptor<JournalEntry>())) ?? []
        let direct = MoodCalendar.month(year: last.year, month: last.month, today: today, earliest: all.compactMap { LocalDay(key: $0.dateKey) }.min(),
                                        entries: all.map { ($0.dateKey, $0.mood) })
        check(month == direct && digest.earliestDay == oldest,
              "心境月历：借修行录摘要排出的上个月与直接取全表的一样，最早一篇认得出")
        check(month.cells[2].mark == .mood(3) && month.cells[2].entries == 2 && month.cells[9].mark == .ink
              && month.cells[lastDay - 1].mark == .mood(4) && month.writtenDays == 3 && month.canGoBack && month.canGoForward,
              "心境月历：上个月 3 日阴平平均 → 平（2 篇）、10 日墨点、月末晴；落笔 3 日，可往前也可往后翻")
        let now = digest.moodMonth(year: today.year, month: today.month, today: today)
        check(now.cells[today.day - 1].mark == .mood(5) && now.cells[today.day - 1].isToday && !now.canGoForward,
              "心境月历：本月今天那格是霁、金框；本月之后翻不过去")
        let first = digest.moodMonth(year: oldest.year, month: oldest.month, today: today)
        let tooEarly = digest.moodMonth(year: oldest.year - 1, month: oldest.month, today: today)
        check(!first.canGoBack && first.writtenDays == 1 && tooEarly.key == first.key,
              "心境月历：最早一篇所在的月 ‹ 禁用，再早的夹回那个月")

        // 改了心境、补了一篇：摘要只并入改动，月历跟着变
        if let tenth = all.first(where: { $0.dateKey == day(10).key }) {
            tenth.mood = 1
            tenth.updatedAt = Date()
        }
        add(day(12), nil, "补记十二日")
        DataStore.save(c)
        let after = JournalDigest.shared.sync(c).moodMonth(year: last.year, month: last.month, today: today)
        check(after.cells[9].mark == .mood(1) && after.cells[11].mark == .ink && after.writtenDays == 4,
              "心境月历：10 日补了心境“雨”、补记 12 日一篇，保存后月历跟着变")

        // 2. 点一格：修行录原有的“只看某一天”筛选，篇数与格子一致；再点同一格回到全部
        let snapshot = JournalDigest.shared.sync(c)
        let tapped = MoodCalendar.toggled(selected: nil, tapped: day(3).key)
        let filtered = snapshot.matching(filter: "all", day: tapped, tag: nil, month: nil, query: "")
        check(tapped == day(3).key && filtered.count == after.cells[2].entries && filtered.allSatisfy { $0.dateKey == day(3).key }
              && MoodCalendar.toggled(selected: tapped, tapped: day(3).key) == nil,
              "心境月历：点 3 日 → 时间线只看那天（2 篇，与格子上的篇数相同）；再点同一格回到全部")

        // 5. 正只看 10 日时把 10 日那篇删掉：格子变空，玉色圈还在，仍点得动，再点回到全部（悬停那行写“再点回到全部”）
        let watching = day(10).key
        for entry in (try? c.fetch(FetchDescriptor<JournalEntry>())) ?? [] where entry.dateKey == watching { c.delete(entry) }
        DataStore.save(c)
        let gone = JournalDigest.shared.sync(c).moodMonth(year: last.year, month: last.month, today: today).cells[9]
        check(gone.mark == .blank && gone.entries == 0 && !gone.canTap(selected: nil) && gone.tapHint(selected: nil) == nil
              && gone.canTap(selected: watching) && gone.tapHint(selected: watching) == "再点回到全部"
              && MoodCalendar.toggled(selected: watching, tapped: gone.day.key) == nil,
              "心境月历：正只看 10 日时删光那天的篇目，格子空了仍点得动，再点回到全部；没选中的空格点不动")

        // 3. 5 年数据：每天一篇，翻到最早的月份
        let big = try DataStore.makeContainer(inMemory: true)
        let b = ModelContext(big)
        for i in 0 ..< 1825 {
            let entry = JournalEntry(kind: .diary, body: "第 \(i) 天", dateKey: today.adding(days: -i).key)
            entry.mood = i % 4 == 0 ? nil : i % 5 + 1
            b.insert(entry)
        }
        DataStore.save(b)
        let long = JournalDigest.shared.sync(b)
        let earliest = today.adding(days: -1824)
        let started = Date()
        var months: [MoodCalendar.Month] = []
        let span = (today.year * 12 + today.month) - (earliest.year * 12 + earliest.month)
        for back in 0 ... span {
            let m = MoodCalendar.shift(year: today.year, month: today.month, by: -back)
            months.append(long.moodMonth(year: m.year, month: m.month, today: today))
        }
        let elapsed = Date().timeIntervalSince(started)
        check(long.ordered && long.earliestDay == earliest && months.last?.key == String(format: "%04d-%02d", earliest.year, earliest.month)
              && months.last?.canGoBack == false && months.dropLast().allSatisfy { $0.canGoBack } && elapsed < 0.5,
              "心境月历：5 年 1825 篇，从本月逐月翻到最早的月份共 \(months.count) 个月 \(String(format: "%.0f", elapsed * 1000)) ms（应 < 500 ms）")

        // 4. 卡片画得出来：全新（一篇没有）与有记录两种
        let empty = try DataStore.makeContainer(inMemory: true)
        let e = ModelContext(empty)
        for (label, context) in [("全新", e), ("有记录", c)] {
            let card = MoodCalendarCard(digest: JournalDigest.shared.sync(context), selected: day(3).key, onPick: { _ in })
                .frame(width: PageLayout.side)
                .environment(\.spiritMotion, false)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 1
            let size = renderer.nsImage?.size ?? .zero
            check(size.width >= PageLayout.side - 1 && size.height > 200,
                  "心境月历：\(label)时卡片画得出来（\(Int(size.width))×\(Int(size.height))）")
        }

        // 往年的月份翻月器写“2025年12月”：标题旁只写“30 日”、箭头 18 宽，侧栏卡里仍是一行，卡头与本月一样高（不折行、不跳）
        func filled(_ year: Int, _ month: Int, days: Int, today: LocalDay) -> MoodCalendar.Month {
            let rows = (1 ... days).map { (LocalDay(year: year, month: month, day: $0).key, Optional(3)) }
            return MoodCalendar.month(year: year, month: month, today: today, earliest: LocalDay(year: year, month: month, day: 1), entries: rows)
        }
        func headerHeight(_ month: MoodCalendar.Month, today: LocalDay) -> CGFloat {
            let renderer = ImageRenderer(content: MoodCalendarCard.headerProbe(month, today: today)
                .frame(width: PageLayout.side).environment(\.spiritMotion, false))
            renderer.scale = 1
            return renderer.nsImage?.size.height ?? 0
        }
        let base = headerHeight(now, today: today)
        let decemberEnd = LocalDay(year: today.year, month: 12, day: 31)
        let probes: [(String, MoodCalendar.Month, LocalDay)] = [
            ("往年 12 月", filled(today.year - 1, 12, days: 30, today: today), today),
            ("往年 3 月", filled(today.year - 1, 3, days: 31, today: today), today),
            ("今年 12 月落笔 31 日", filled(today.year, 12, days: 31, today: decemberEnd), decemberEnd),
        ]
        let heights = probes.map { headerHeight($0.1, today: $0.2) }
        check(base > 40 && heights.allSatisfy { abs($0 - base) < 0.5 }
              && probes[0].1.titleDetail(today: today) == "30 日" && probes[2].1.titleDetail(today: decemberEnd) == "落笔 31 日",
              "心境月历：翻到往年的月份标题行仍是一行，卡头与本月同高（本月 \(Int(base))，"
              + zip(probes, heights).map { "\($0.0.0) \(Int($0.1))" }.joined(separator: "、") + "）")
    }
}
