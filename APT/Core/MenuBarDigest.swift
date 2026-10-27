import Foundation

/// 菜单栏小窗上半段“今日”的取舍与说法：列哪几项功课、“+1”一步加多少、签下方写哪一行“功课圆满”、
/// 记完自动收起前点过上半段就不收、下一项日程与倒计时、标题行那一句。
/// 只是纯函数（不碰数据库、不画界面），界面在 Views/MenuBarPanel，核对在 Tools/CoreCheck（// MARK: r1-menubar）。
enum MenuBarDigest {
    // MARK: 功课

    /// 一项未归档的功课今天的样子（调用方从修为模型的统计里取）
    struct HabitItem: Equatable {
        var title: String
        /// 今天要做（或今天已经记过）：与首页“今日功课”同一口径
        var due: Bool
        /// 今天已达标
        var achieved: Bool
        /// 今天已记的数量（没记为 nil）
        var quantity: Double? = nil
        /// 今天适用的数量目标（不是数量型为 nil）
        var target: Double? = nil
        var unit: String = ""
        /// 小窗这次打开时已经列成签的：在小窗里刚打上卡也留在原位（圈变实心、迸一下灵光，再点一下能取消），
        /// 不当场挪进“已圆满”那一行——签不会在指针底下跳走；下次打开小窗才收进去
        var keepShown = false
    }

    struct HabitPlan: Equatable {
        enum State: Equatable {
            /// 一项功课都还没立
            case noHabits
            /// 有功课，但今天没有要打卡的（每周 N 次已够数、不在指定星期）
            case restDay
            /// 今天要做的都圆满了，也没有留在原位的签
            case allDone
            /// 有要列成签的（还没圆满的，或这次刚在小窗里打上卡、留在原位的）
            case chips
        }

        var state: State
        /// 列成签的（输入里的下标，保持原来的次序），最多 limit 项
        var chips: [Int]
        /// 还没圆满、但没列出来的项数（“另有 3 项”）
        var overflow: Int
        /// 已圆满、不在签里的名字（保持原来的次序）
        var doneTitles: [String]
        var done: Int
        var due: Int
        /// 今天要做的都圆满了（签还留着时也算：这时签下方写“功课圆满”）
        var allDone: Bool { due > 0 && done == due }
    }

    /// 小窗一行半放得下 6 枚功课签，多了只写“另有 N 项”
    static let chipLimit = 6

    static func plan(_ items: [HabitItem], limit: Int = chipLimit) -> HabitPlan {
        let due = items.indices.filter { items[$0].due }
        let done = due.filter { items[$0].achieved }
        let candidates = due.filter { !items[$0].achieved || items[$0].keepShown }
        let chips = Array(candidates.prefix(max(0, limit)))
        let open = due.filter { !items[$0].achieved }
        let doneTitles = done.filter { !chips.contains($0) }.map { items[$0].title }
        let state: HabitPlan.State = items.isEmpty ? .noHabits : due.isEmpty ? .restDay : chips.isEmpty ? .allDone : .chips
        return HabitPlan(state: state, chips: chips, overflow: open.filter { !chips.contains($0) }.count,
                         doneTitles: doneTitles, done: done.count, due: due.count)
    }

    /// 已圆满的一行：“已圆满：运动、早睡”；多于 shown 项时“已圆满：运动、早睡、读书、冥想 等 6 项”；一项都没有时 nil
    static func doneLine(_ titles: [String], shown: Int = 4) -> String? {
        guard !titles.isEmpty else { return nil }
        let names = titles.prefix(max(1, shown)).joined(separator: "、")
        return "已圆满：" + names + (titles.count > max(1, shown) ? " 等 \(titles.count) 项" : "")
    }

    // 数量型功课的“3/8 杯 +1”：小窗不再自己写一份规则，下面四个只是转调首页的 DashboardRules
    // （留着这几个名字，旧的自检与离屏渲染照常能用；改步长、写法只改 DashboardRules 一处）

    /// “+1”一步加多少：目标不超过 20 → 1；不超过 120 → 5；更大 → 目标的 1/8 取整（8000 步 → 1000）
    static func step(target: Double) -> Double { DashboardRules.quantityStep(target: target) }

    /// 数量写法：整数不带小数点；小数最多两位、去掉末尾的 0（2.5 杯、1.25 升）
    static func number(_ value: Double) -> String { DashboardRules.number(value) }

    /// 功课签上的进度：“3/8 杯”（没记过写 0）
    static func progress(quantity: Double?, target: Double, unit: String) -> String {
        DashboardRules.quantityText(done: quantity ?? 0, target: target, unit: unit)
    }

    /// “+1”按钮上的字（写实际步长：+5、+1000；半角加号）
    static func stepLabel(target: Double) -> String { DashboardRules.stepLabel(step(target: target)) }

    // MARK: 功课圆满

    /// 功课签下方写哪一行“功课圆满”（只写在签的下方，不插在签的上方：签在这次打开期间不挪位）
    enum Consummation: Equatable {
        /// 不写
        case none
        /// 今天要做的都圆满了：金字“功课圆满”；bonus 为真时（修为规则里也算圆满）另写今日额外所得
        case full(bonus: Bool)
        /// 还剩每周 N 次的签没打，但修为规则只看每天 / 指定星期的功课、已算圆满（刚飘过“功课圆满”、加了修为）：
        /// 签下方一行金色小字，与首页同一说法
        case bonusOnly
    }

    static func consummation(allDone: Bool, perfectToday: Bool) -> Consummation {
        if allDone { return .full(bonus: perfectToday) }
        return perfectToday ? .bonusOnly : .none
    }

    /// “功课圆满，今日额外 +20 修为”（与首页功课卡同一句）
    static func bonusLine(xp: Int = CultivationEngine.perfectDayXP) -> String { "功课圆满，今日额外 +\(xp) 修为" }

    // MARK: 记完自动收起

    /// 随手记记完到自动收起最多等多久（记账约 3 秒，入卷约 1 秒），再留一点余量
    static let autoCloseGrace: Double = 3.5

    /// 随手记要收起小窗时收不收：按 Esc 照常收起；自动收起（记完之后）前这一小会儿里点过上半段（打卡圈、+1）就不收，
    /// 免得小窗在两次点击之间收起、后一下落到下面别的应用上。sinceTopAction：离上半段最近一次操作几秒（这次打开还没点过为 nil）
    static func autoCloses(escape: Bool, sinceTopAction: Double?) -> Bool {
        guard !escape, let since = sinceTopAction, since >= 0 else { return true }
        return since > autoCloseGrace
    }

    // MARK: 标题行

    /// 左侧：“今日 · 申时”（时辰与首页问候同一套）
    static func heading(minute: Int) -> String { "今日 · " + SkyClock.shichen(minute: minute) }

    /// 右侧：“功课 2/5 · 已落 1 篇”；今天没有要做的功课时只写落笔；还没写时写“尚未落笔”（不说“没写”“漏了”）
    static func summary(done: Int, due: Int, entries: Int) -> String {
        var parts: [String] = []
        if due > 0 { parts.append("功课 \(min(done, due))/\(due)") }
        parts.append(entries > 0 ? "已落 \(entries) 篇" : "尚未落笔")
        return parts.joined(separator: " · ")
    }

    // MARK: 下一项日程

    /// 今天的一项日程（作息不算；与首页“下一项”同一口径）
    struct Slot: Equatable {
        var start: Int?
        var end: Int?
        var title: String
    }

    enum Next: Equatable {
        /// 今天还没开始的第一项：下标、离开始还有几分钟
        case upcoming(Int, minutes: Int)
        /// 后面没有了，但这一项正在进行：下标、离结束还有几分钟（没有结束时间为 nil）
        case running(Int, minutes: Int?)
        /// 今天只剩全天的日程
        case allDay(Int)
        case none
    }

    /// 先找今天还没开始的第一项（开始晚于现在，按开始时刻排，同时刻按原次序）；都开始了再看有没有正在进行的；
    /// 再没有就看全天的日程。“正在进行”与首页一样：开始不晚于现在、结束（没有结束时间的按开始后 1 分钟）晚于现在
    static func next(_ slots: [Slot], now: Int) -> Next {
        let timed = slots.indices.compactMap { i in slots[i].start.map { (index: i, start: $0) } }
            .sorted { ($0.start, $0.index) < ($1.start, $1.index) }
        if let first = timed.first(where: { $0.start > now }) { return .upcoming(first.index, minutes: first.start - now) }
        if let running = timed.first(where: { $0.start <= now && (slots[$0.index].end ?? $0.start + 1) > now }) {
            return .running(running.index, minutes: slots[running.index].end.map { $0 - now })
        }
        if let index = slots.indices.first(where: { slots[$0].start == nil }) { return .allDay(index) }
        return .none
    }

    /// 倒计时：“还有 20 分”“还有 1 时 20 分”“还有 2 时”（至少 1 分）
    static func countdown(_ minutes: Int, prefix: String = "还有") -> String {
        let m = max(1, minutes)
        if m < 60 { return "\(prefix) \(m) 分" }
        return "\(prefix) \(m / 60) 时" + (m % 60 == 0 ? "" : " \(m % 60) 分")
    }

    /// 下一项那一行：左侧小标签、中间“14:00–15:00 组会”、右侧倒计时（没有时为空）
    struct NextLine: Equatable {
        var label: String
        var text: String
        var detail: String
    }

    static func nextLine(_ slots: [Slot], now: Int) -> NextLine {
        func title(_ slot: Slot) -> String { slot.title.isEmpty ? "（未命名日程）" : slot.title }
        switch next(slots, now: now) {
        case let .upcoming(i, minutes):
            return NextLine(label: "下一项", text: "\(ClockTime.range(slots[i].start, slots[i].end)) \(title(slots[i]))",
                            detail: countdown(minutes))
        case let .running(i, minutes):
            return NextLine(label: "进行中", text: "\(ClockTime.range(slots[i].start, slots[i].end)) \(title(slots[i]))",
                            detail: minutes.map { countdown($0, prefix: "还剩") } ?? "")
        case let .allDay(i):
            return NextLine(label: "今日全天", text: title(slots[i]), detail: "")
        case .none:
            return NextLine(label: "", text: "今日已无安排", detail: "")
        }
    }
}
