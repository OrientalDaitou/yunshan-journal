import Foundation

/// 心境月历（修行录左栏，卷中气象之后）：某个月每天写了几篇、当天日记心境平均几档。
/// 只吃（日期键、心境）两样——页面上借修行录摘要（JournalDigest）已缓存的行，不另取全表。纯函数，CoreCheck 逐条核对。
enum MoodCalendar {
    /// 一格的样子
    enum Mark: Equatable {
        /// 当天记了心境：几篇的平均，四舍五入到 1–5（与七日小卷“心境七日”同一个口径）
        case mood(Int)
        /// 写了，没记心境：中间一个墨点
        case ink
        /// 没写：极淡描边
        case blank
        /// 还没到：不画
        case future
    }

    struct Cell: Equatable {
        let day: LocalDay
        let mark: Mark
        /// 当天篇数
        let entries: Int
        let isToday: Bool

        /// 写过的日子才能点（点了时间线只看那天）
        var tappable: Bool { entries > 0 }

        /// 点得动：写过的日子；时间线正只看这天时也点得动——那天的篇目删光或改到别的日期后格子空了，
        /// 玉色圈还在，再点照样回到全部（toggled 正好给 nil）
        func canTap(selected: String?) -> Bool { tappable || day.key == selected }

        /// 悬停那行行尾的小字：正只看这天“再点回到全部”，别的写过的日子“点一下只看这天”，点不动的没有
        func tapHint(selected: String?) -> String? {
            guard canTap(selected: selected) else { return nil }
            return day.key == selected ? "再点回到全部" : "点一下只看这天"
        }

        /// 悬停那一行：`10月21日 · 晴 · 2 篇`；没写 `10月20日 · 未落笔`
        var hint: String {
            let head = isToday ? "今天 · \(day.shortLabel)" : day.shortLabel
            switch mark {
            case .mood(let value): return "\(head) · \(Mood.label(value)) · \(entries) 篇"
            case .ink: return "\(head) · 未记心境 · \(entries) 篇"
            case .blank: return isToday ? "\(head) · 还没落笔" : "\(head) · 未落笔"
            case .future: return "\(head) · 还没到"
            }
        }
    }

    struct Month: Equatable {
        let year: Int
        let month: Int
        /// 月初之前空几格（周一为一周之始：1 日是周三就空 2 格）
        let leading: Int
        /// 这个月每一天（含还没到的，标成 .future）
        let cells: [Cell]
        /// 这个月落笔的天数（同一天几篇算一日）
        let writtenDays: Int
        /// 这个月记了心境的天数
        let moodDays: Int
        /// ‹：最早一篇所在的月（没有记录时就是本月）之前不能再翻
        let canGoBack: Bool
        /// ›：本月之后不能再翻
        let canGoForward: Bool
        let isCurrent: Bool

        /// `YYYY-MM`
        var key: String { String(format: "%04d-%02d", year, month) }
        /// 按周切好的格子：每行 7 个，月初前、月末后补 nil；末尾整行都还没到的不排（本月下面不留一截空行）
        var weeks: [[Cell?]] {
            var flat: [Cell?] = Array(repeating: nil, count: leading) + cells.map(Optional.some)
            while flat.count % 7 != 0 { flat.append(nil) }
            var rows = stride(from: 0, to: flat.count, by: 7).map { Array(flat[$0 ..< $0 + 7]) }
            while rows.count > 1, let tail = rows.last, tail.allSatisfy({ $0 == nil || $0?.mark == .future }) { rows.removeLast() }
            return rows
        }

        /// 标题旁的小字：`10月 · 落笔 12 日`；不是今年的带年份；这个月一篇没有时只写月份
        func subtitle(today: LocalDay) -> String {
            let name = MonthKey.label(year: year, month: month, relativeTo: today)
            return writtenDays == 0 ? name : "\(name) · 落笔 \(writtenDays) 日"
        }

        /// 标题“心境月历”旁的小字：今年的月份写“落笔 12 日”；往年的月份翻月器里已是“2025年12月”，
        /// 只写“12 日”，侧栏卡内 272pt 宽标题行才放得下一行（不折行、卡头不跳）；一篇没有时不写
        func titleDetail(today: LocalDay) -> String {
            guard writtenDays > 0 else { return "" }
            return year == today.year ? "落笔 \(writtenDays) 日" : "\(writtenDays) 日"
        }

        /// 这个月一篇没有时格子照画，下面一行这句
        var emptyNote: String? {
            guard writtenDays == 0 else { return nil }
            return isCurrent ? "这个月还没有落笔。" : "这个月没有落笔。"
        }
    }

    /// 平均心境 → 1–5 档（四舍五入：阴、平各一篇平均 2.5 算“平”；越界的值先夹回 1–5）
    static func level(_ moods: [Int]) -> Int? {
        guard !moods.isEmpty else { return nil }
        let clamped = moods.map { max(1, min(5, $0)) }
        let average = Double(clamped.reduce(0, +)) / Double(clamped.count)
        return max(1, min(5, Int(average.rounded())))
    }

    /// 这个月有几天
    static func daysIn(year: Int, month: Int) -> Int {
        let next = month == 12 ? LocalDay(year: year + 1, month: 1, day: 1) : LocalDay(year: year, month: month + 1, day: 1)
        return next.adding(days: -1).day
    }

    /// 往前 / 往后翻 n 个月（跨年照常）
    static func shift(year: Int, month: Int, by months: Int) -> (year: Int, month: Int) {
        let index = year * 12 + (month - 1) + months
        let y = index >= 0 ? index / 12 : (index - 11) / 12
        return (y, index - y * 12 + 1)
    }

    /// 显示的月份夹在“最早一篇所在的月”与本月之间（没有记录时只能看本月）
    static func clamp(year: Int, month: Int, today: LocalDay, earliest: LocalDay?) -> (year: Int, month: Int) {
        let upper = today.year * 12 + today.month - 1
        let lower = min(upper, earliest.map { $0.year * 12 + $0.month - 1 } ?? upper)
        let index = min(upper, max(lower, year * 12 + month - 1))
        return (index / 12, index % 12 + 1)
    }

    /// 再点同一格取消（回到全部），点别的格换成那天
    static func toggled(selected: String?, tapped: String) -> String? { selected == tapped ? nil : tapped }

    /// 排出一个月。entries 是（日期键、心境）；newestFirst 为 true 时调用方保证日期键都规范、按新的在前排好，
    /// 这时越过这个月就停（与卷中气象的 stats 同一个办法），2 年、5 年数据翻到哪个月都只走到那个月为止。
    static func month<S: Sequence>(year: Int, month: Int, today: LocalDay, earliest: LocalDay?,
                                   entries: S, newestFirst: Bool = false) -> Month where S.Element == (String, Int?) {
        let (y, m) = clamp(year: year, month: month, today: today, earliest: earliest)
        let first = LocalDay(year: y, month: m, day: 1)
        let count = daysIn(year: y, month: m)
        let prefix = String(format: "%04d-%02d", y, m)
        let upperKey = prefix + "-99"
        var written = [Int](repeating: 0, count: count + 1)
        var moods = [[Int]](repeating: [], count: count + 1)
        for (key, mood) in entries {
            if newestFirst {
                if key > upperKey { continue }
                if key < prefix { break }
            }
            guard key.hasPrefix(prefix), let day = LocalDay(key: key), day.year == y, day.month == m else { continue }
            written[day.day] += 1
            if let mood { moods[day.day].append(mood) }
        }
        var cells: [Cell] = []
        cells.reserveCapacity(count)
        for d in 1 ... count {
            let day = first.adding(days: d - 1)
            let mark: Mark
            if day > today && written[d] == 0 {
                mark = .future
            } else if let value = level(moods[d]) {
                mark = .mood(value)
            } else {
                mark = written[d] > 0 ? .ink : .blank
            }
            cells.append(Cell(day: day, mark: mark, entries: written[d], isToday: day == today))
        }
        let index = y * 12 + m - 1
        let lower = min(today.year * 12 + today.month - 1, earliest.map { $0.year * 12 + $0.month - 1 } ?? Int.max)
        return Month(year: y, month: m, leading: first.weekdayIndex, cells: cells,
                     writtenDays: written.dropFirst().filter { $0 > 0 }.count,
                     moodDays: moods.dropFirst().filter { !$0.isEmpty }.count,
                     canGoBack: index > lower,
                     canGoForward: index < today.year * 12 + today.month - 1,
                     isCurrent: y == today.year && m == today.month)
    }

    /// 图例：`雨 阴 平 晴 霁 · 墨点＝写了没记心境`
    static let legendNote = "墨点＝写了没记心境"
}
