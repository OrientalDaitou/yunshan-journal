import Foundation

/// 时辰卷周视图里一天之内的日程怎么摆（#23）。纯函数，CoreCheck 直接测；ScheduleView 只按结果画。
/// - 互相重叠的一串日程算一组，组内按开始先后（同时开始的长的在前）分列，与原来并排的分法相同；
/// - 并排时每块宽 = 这一天的宽 ÷ 列数。窄到放不下“时间 + 标题”（块宽 < 64pt）时：3 列起改成错位叠放——
///   后一列的块右移一小步（14pt）、叠在前一列上面、一直伸到这天的右边（像系统日历）；2 列时只有叠放后
///   每块的标题都露得出来才叠，否则仍并排（只写一行标题）；
/// - 叠放时标题被上层压住的块，把标题挪到上层那块结束、露出来的地方；挪不出来就留在原处，
///   靠左边露出的一条色带、悬停浮到最上、悬停说明来认；
/// - 标题下面露出来的那一段有多高（labelRoom）：块里按这个高矮挑写法，不按整块高——
///   否则下层的长块会挑三四行的写法，后几行被上层压住，只剩半行字、左边露边里一个孤零零的字母；
/// - 鼠标停在哪里，浮起哪一块按原先的层次算（topmost），不看此刻谁浮在上面：
///   先浮起的大块不会把落在它里面的小块整个盖住、点不到。
enum WeekStack {
    /// 一块日程占的时段（分钟；结束已按“至少 20 分钟、没写结束算一小时”补好）
    struct Span: Equatable {
        var start: Int
        var end: Int
    }

    struct Slot: Equatable {
        var column: Int
        var columns: Int
        /// 错位叠放（这一组整组一起叠）
        var stacked: Bool
        /// 标题往下挪几分钟（被叠在上面的块压住时）；0 = 在块顶
        var labelOffset: Int
        /// 从标题顶（块顶 + labelOffset）往下露出来多少分钟：量到上层第一块开始处，没有压着的量到块底。
        /// 只有叠放时才可能比“块长 − labelOffset”短
        var labelRoom: Int = 0
    }

    /// 块宽低于这个就只写一行标题（时间、地点进悬停说明）
    static let compactWidth: Double = 64
    /// 叠放时后一块右移的步长；列多、天窄时收小，最上面那块至少留这一天宽的 55%
    static let stackStep: Double = 14

    /// spans 的先后随意；返回的 Slot 与 spans 一一对应。
    /// labelMinutes：标题（时间一行 + 标题一行）大约占几分钟高，用来判断标题露不露得出来
    static func layout(_ spans: [Span], dayWidth: Double, labelMinutes: Int) -> [Slot] {
        let order = spans.indices.sorted { a, b in
            (spans[a].start, -spans[a].end, a) < (spans[b].start, -spans[b].end, b)
        }
        var slots = spans.map { Slot(column: 0, columns: 1, stacked: false, labelOffset: 0, labelRoom: $0.end - $0.start) }
        var cluster: [Int] = []
        var columnEnds: [Int] = []
        var clusterEnd = Int.min

        /// 被更高一列（叠在上面）的块压住时，标题挪到哪里：从块顶起，碰到压着的就挪到它结束处，直到露出一段标题高
        func offset(_ i: Int) -> Int? {
            let span = spans[i]
            let above = cluster.filter { slots[$0].column > slots[i].column && spans[$0].start < span.end && spans[$0].end > span.start }
            var top = span.start
            var moved = true
            while moved {
                moved = false
                for j in above where spans[j].start < top + labelMinutes && spans[j].end > top {
                    top = spans[j].end
                    moved = true
                }
            }
            if top == span.start { return 0 }
            return top + labelMinutes <= span.end ? top - span.start : nil
        }

        /// 标题顶往下露出来的分钟数：碰到上层（更高一列）在它下面开始的第一块为止，没有就到块底；
        /// 标题顶本身被压住（挪不出来）时为 0
        func room(_ i: Int, offset: Int) -> Int {
            let span = spans[i]
            let top = span.start + offset
            var bottom = span.end
            for j in cluster where slots[j].column > slots[i].column && spans[j].end > top && spans[j].start < bottom {
                bottom = max(top, spans[j].start)
            }
            return bottom - top
        }

        func flush() {
            guard !cluster.isEmpty else { return }
            let columns = max(1, columnEnds.count)
            for i in cluster { slots[i].columns = columns }
            let sideBySide = max(0, dayWidth - 4) / Double(columns) - 2
            if columns >= 2, sideBySide < compactWidth {
                let offsets = cluster.map(offset)
                if columns >= 3 || !offsets.contains(nil) {
                    for (i, off) in zip(cluster, offsets) {
                        slots[i].stacked = true
                        slots[i].labelOffset = off ?? 0
                        slots[i].labelRoom = room(i, offset: off ?? 0)
                    }
                }
            }
            cluster = []
            columnEnds = []
        }

        for i in order {
            let span = spans[i]
            if span.start >= clusterEnd { flush() }
            let column = columnEnds.firstIndex { $0 <= span.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(span.end) } else { columnEnds[column] = span.end }
            slots[i].column = column
            cluster.append(i)
            clusterEnd = max(clusterEnd, span.end)
        }
        flush()
        return slots
    }

    /// 这一块在一天里的横向位置与宽（pt，左右各留 2pt）
    static func frame(_ slot: Slot, dayWidth: Double) -> (x: Double, width: Double) {
        let inner = max(0, dayWidth - 4)
        guard slot.stacked, slot.columns > 1 else {
            let column = inner / Double(max(1, slot.columns))
            return (2 + Double(slot.column) * column, max(10, column - 2))
        }
        let minTop = max(compactWidth * 0.875, inner * 0.55)
        let step = max(4, min(stackStep, (inner - minTop) / Double(slot.columns - 1)))
        let x = Double(slot.column) * step
        return (2 + x, max(10, inner - x))
    }

    /// 指针下面该浮起哪一块：按原先的层次（列号大的在上，同列不会重叠）取指针下最上面的那块，返回它在 spans 里的下标；
    /// 指针不在任何一块上为 nil。minute：指针在这一天里的分钟（可带小数）；x：指针离这一天左边的 pt。
    /// minMinutes：块最矮画成几分钟高（周视图里块至少 18pt），短块按画出来的高矮算
    static func topmost(at minute: Double, x: Double, spans: [Span], slots: [Slot], dayWidth: Double,
                        minMinutes: Double = 0) -> Int? {
        var best: Int?
        for i in spans.indices where i < slots.count {
            let start = Double(spans[i].start)
            guard minute >= start, minute < max(Double(spans[i].end), start + minMinutes) else { continue }
            let f = frame(slots[i], dayWidth: dayWidth)
            guard x >= f.x, x < f.x + f.width else { continue }
            if let b = best, slots[b].column > slots[i].column { continue }
            best = i
        }
        return best
    }

    /// 网格画哪几个钟点：这一周一项日程都没有时只画 08–20 点（格线也淡一半，见 ScheduleView）；
    /// 平时从 06:00 画到 24:00，有更早的日程就从那一小时开始
    static func hours(hasItems: Bool, earliestMinute: Int?) -> Range<Int> {
        guard hasItems else { return 8..<20 }
        let earliest = earliestMinute.map { $0 / 60 } ?? 6
        return max(0, min(6, earliest))..<24
    }
}
