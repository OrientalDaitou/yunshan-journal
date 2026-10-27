import Foundation

/// 每日提醒（落笔时辰、功课时辰）与周复盘提醒的排程规则：纯函数，不碰系统通知（CoreCheck 逐条核对）。
///
/// - 一次排未来 7 天、每天一条一次性的请求（标识 `apt.write.2026-10-22`、`apt.habits.2026-10-22`），不用“每天重复”：
///   Mac 合盖错过了也只是那一天的一条，过期的不补；今天写过了、功课圆满了，只撤今天那一条。
/// - 今天不排：时刻已过、今天已经提醒过（改了时刻也不再来第二条）、已经回应过；落笔另加“今天已写过”，功课另加“都圆满了”。
/// - 退避：提醒过的一天，当天既没写、也没回应 → 记一次“没理会”；连续 3 次 → 从那天起每 3 天一问；
///   之后一次回应或一次落笔即清零、回到每天。只管落笔提醒，功课提醒照每天（只在还有未圆满的功课时才发）。
/// - 只算提醒真到了眼前的日子：到点那一刻 Mac 睡着或关着（`away` / `back` 记下这段）、没有通知权限，都不算没理会；
///   一次结算了两天以上（中间应用没在跑、又没留下睡眠记录），这一批最多算 1 次。
enum ReminderPlan {
    enum Kind: String, Codable, CaseIterable {
        case write, habits
    }

    /// 一次排几天
    static let horizonDays = 7
    /// 连续几次没理会改成隔几天一问
    static let backoffAfter = 3
    static let backoffEvery = 3

    static let defaultWriteMinute = 21 * 60 + 30
    static let defaultHabitsMinute = 20 * 60
    /// 周复盘：星期按系统日历的写法，1 = 周日 … 7 = 周六（与原来固定的“周日 21:00”一致）
    static let defaultWeeklyWeekday = 1
    static let defaultWeeklyMinute = 21 * 60

    // MARK: 文案

    static let writeTitle = "落笔时辰"
    static let habitsTitle = "功课时辰"
    /// 落笔提醒的正文：按日期轮换
    static let writeLines = [
        "今日可有一事值得记下？一句即可。",
        "今天哪一刻最想留下？写一句就好。",
        "收卷之前，记一笔今日的心境。",
        "一日将尽，落一笔，明日好回看。",
        "今日所成、所卡，择一句记下。",
    ]
    /// 功课提醒：以后几天先排这句，到那天刷新时换成还没圆满的功课名
    static let habitsGeneric = "今日功课可都圆满了？"
    /// 设置里“落笔时辰”行下的说明（退避生效时）
    static let backoffNote = "近来提醒似扰清修，已改为三日一问"
    /// 刚改成三日一问后，主窗口下次出现时飘的一句
    static let backoffHint = "落笔提醒改为三日一问（洞府设置里可调回）"

    static func writeBody(on day: LocalDay) -> String {
        let n = writeLines.count
        return writeLines[((day.jdn % n) + n) % n]
    }

    /// “还有「冥想」「喝水」未圆满。”；超过 3 项写前三项和总数
    static func habitsBody(pending: [String]) -> String {
        guard !pending.isEmpty else { return habitsGeneric }
        let names = pending.prefix(3).map { "「\($0)」" }.joined()
        return pending.count > 3 ? "还有\(names)等 \(pending.count) 项未圆满。" : "还有\(names)未圆满。"
    }

    // MARK: 标识

    static func identifier(_ kind: Kind, day: LocalDay) -> String { "apt.\(kind.rawValue).\(day.key)" }

    static func prefix(_ kind: Kind) -> String { "apt.\(kind.rawValue)." }

    /// 认出自己排的请求：`apt.write.2026-10-22` → (.write, 10月22日)；周复盘（apt.weekly-review）等别的标识返回 nil
    static func parse(identifier: String) -> (kind: Kind, day: LocalDay)? {
        for kind in Kind.allCases where identifier.hasPrefix(prefix(kind)) {
            guard let day = LocalDay(key: String(identifier.dropFirst(prefix(kind).count))) else { return nil }
            return (kind, day)
        }
        return nil
    }

    // MARK: 状态（存在偏好设置里，JSON）

    /// 一个时刻：哪天（`YYYY-MM-DD`）的第几分钟；先比日子、再比分钟
    struct Moment: Codable, Equatable, Comparable {
        var day: String
        var minute: Int

        init(day: LocalDay, minute: Int) {
            self.day = day.key
            self.minute = minute
        }

        init(dayKey: String, minute: Int) {
            day = dayKey
            self.minute = minute
        }

        static func < (a: Moment, b: Moment) -> Bool { (a.day, a.minute) < (b.day, b.minute) }

        /// 到 other 隔了多少分钟（日子写坏了返回 nil）
        func minutes(to other: Moment) -> Int? {
            guard let a = LocalDay(key: day), let b = LocalDay(key: other.day) else { return nil }
            return a.days(to: b) * 24 * 60 + other.minute - minute
        }
    }

    struct State: Codable, Equatable {
        /// 落笔：排上了（或已到点）的那天 → 时刻（当天第几分钟）。到点后留着，过了那天再结算有没有理会
        var armedWrite: [String: Int] = [:]
        /// 功课：同上，只用来认“今天已经提醒过”
        var armedHabits: [String: Int] = [:]
        /// 回应过落笔提醒（点开、回复、今日免）的日子
        var answered: [String] = []
        /// 连续没理会的次数
        var ignored = 0
        /// 三日一问从哪天算起（`YYYY-MM-DD`）
        var backoffStart: String?
        /// 刚改成三日一问、还没在主窗口说过
        var noticePending = false
        /// 落笔提醒到点时 Mac 睡着或关着的日子：提醒没送到眼前，结算时不算没理会（也不清零）
        var unseen: [String] = []
        /// Mac 从这一刻起睡下（或关机、注销）、还没醒来；醒来或再启动时把这段里到点的落笔提醒记进 unseen
        var awaySince: Moment?

        var backingOff: Bool { ignored >= ReminderPlan.backoffAfter }
    }

    /// 过了到点的那天再结算：那天写了或回应了 → 清零；提醒确实到了眼前、却没理会 → 记一次没理会。今天写过也清零。
    /// - wrote：这几天里有落笔的日子（至少覆盖最早一个待结算的日子到今天）
    /// - canNotify：现在有没有通知权限（没有时这次结算的日子都不算没理会：提醒根本弹不出来）
    /// - 到点时 Mac 睡着或关着的日子（unseen）不算；一次结算了两天以上，这一批最多算 1 次——
    ///   平常应用开着、Mac 醒着时每跨一天就结算一天，攒下好几天说明中间应用没在跑或 Mac 没醒，不知道提醒到没到
    static func settle(_ state: State, today: LocalDay, wrote: Set<LocalDay>, canNotify: Bool = true) -> State {
        var s = state
        let due = s.armedWrite.keys.compactMap(LocalDay.init(key:)).filter { $0 < today }.sorted()
        let capped = due.count >= 2
        var counted = 0
        for day in due {
            if wrote.contains(day) || s.answered.contains(day.key) {
                s.ignored = 0
                counted = 0
            } else if canNotify && !s.unseen.contains(day.key) && !(capped && counted >= 1) {
                s.ignored += 1
                counted += 1
            }
            s.armedWrite[day.key] = nil
        }
        // 写坏的键直接丢掉，免得永远留着
        s.armedWrite = s.armedWrite.filter { LocalDay(key: $0.key) != nil }
        if wrote.contains(today) { s.ignored = 0 }
        // 过去的日子都结算完了：功课只看今天，回应记录、没送到的记录也只留今天起的
        s.armedHabits = s.armedHabits.filter { $0.key >= today.key }
        s.answered = s.answered.filter { $0 >= today.key }
        s.unseen = s.unseen.filter { $0 >= today.key }
        return enterOrLeaveBackoff(s, today: today)
    }

    /// Mac 要睡下、关机或注销：记下这一刻（已经记着更早的一刻就不改）
    static func away(_ state: State, at moment: Moment) -> State {
        var s = state
        if s.awaySince == nil { s.awaySince = moment }
        return s
    }

    /// 醒来或重新启动：从睡下那一刻到现在之间到点的落笔提醒都没送到眼前，记进 unseen；没有睡下的记录就不动
    static func back(_ state: State, at now: Moment) -> State {
        guard let since = state.awaySince else { return state }
        var s = state
        s.awaySince = nil
        for (key, minute) in s.armedWrite where LocalDay(key: key) != nil && !s.unseen.contains(key) {
            let moment = Moment(dayKey: key, minute: minute)
            if since <= moment && moment <= now { s.unseen.append(key) }
        }
        s.unseen.sort()
        return s
    }

    /// 睡下后几分钟内不当作已经醒来
    static let awayGraceMinutes = 10

    /// 重排时还记着“睡下了、没收尾”：睡下才几分钟（系统入睡前留的那几秒里正好轮到重排）→ 这次先不结算，等醒来再算；
    /// 隔了好一阵（醒来时排在前头的重排抢在“醒来”通知之前跑了）或时钟往回拨了 → 当场收尾再结算
    static func resume(_ state: State, now: Moment) -> (state: State, settle: Bool) {
        guard let since = state.awaySince else { return (state, true) }
        if let gap = since.minutes(to: now), (0...awayGraceMinutes).contains(gap) { return (state, false) }
        return (back(state, at: now), true)
    }

    /// 回应了一条落笔提醒：清零、回到每天
    static func answered(_ state: State, day: LocalDay) -> State {
        var s = state
        if !s.answered.contains(day.key) { s.answered.append(day.key) }
        s.ignored = 0
        s.backoffStart = nil
        s.noticePending = false
        return s
    }

    /// 设置里点“恢复每日”
    static func restoreDaily(_ state: State) -> State {
        var s = state
        s.ignored = 0
        s.backoffStart = nil
        s.noticePending = false
        return s
    }

    /// 关掉某一类提醒：它的排程记录一并清掉（关掉落笔提醒也清掉退避，再打开就是每天）
    static func disabled(_ state: State, _ kind: Kind) -> State {
        var s = state
        switch kind {
        case .write:
            s.armedWrite = [:]
            s.answered = []
            s.unseen = []
            s.awaySince = nil
            s = restoreDaily(s)
        case .habits:
            s.armedHabits = [:]
        }
        return s
    }

    private static func enterOrLeaveBackoff(_ state: State, today: LocalDay) -> State {
        var s = state
        if s.backingOff {
            if s.backoffStart == nil {
                s.backoffStart = today.key
                s.noticePending = true
            }
        } else {
            s.backoffStart = nil
            s.noticePending = false
        }
        return s
    }

    /// 今天这一类是不是已经到点提醒过（排过、且那个时刻已过）
    static func firedToday(_ armed: [String: Int], today: LocalDay, nowMinute: Int) -> Bool {
        armed[today.key].map { $0 <= nowMinute } ?? false
    }

    // MARK: 排程

    struct Slot: Equatable {
        var kind: Kind
        var day: LocalDay
        var minute: Int
        var title: String
        var body: String
        var identifier: String { ReminderPlan.identifier(kind, day: day) }
    }

    struct Input {
        var today: LocalDay
        /// 现在是当天第几分钟
        var nowMinute: Int
        var write = false
        var writeMinute = ReminderPlan.defaultWriteMinute
        var habits = false
        var habitsMinute = ReminderPlan.defaultHabitsMinute
        /// 今天已经有一篇修行录
        var wroteToday = false
        /// 今天还没圆满的功课名（按功课的先后）
        var pendingHabits: [String] = []
        /// 这几天里有功课要做的日子（今天另看 pendingHabits）
        var habitDays: Set<LocalDay> = []
        var state = State()
    }

    /// 未来 7 天要排的请求（先落笔、再功课，各按日期）
    static func plan(_ input: Input) -> [Slot] {
        let today = input.today
        let state = input.state
        var slots: [Slot] = []
        if input.write {
            let minute = clampMinute(input.writeMinute)
            let skipToday = input.nowMinute >= minute || input.wroteToday || state.answered.contains(today.key)
                || firedToday(state.armedWrite, today: today, nowMinute: input.nowMinute)
            let start = state.backingOff ? (state.backoffStart.flatMap(LocalDay.init(key:)) ?? today) : nil
            for offset in 0..<horizonDays {
                let day = today.adding(days: offset)
                if offset == 0 && skipToday { continue }
                if let start {
                    let gap = start.days(to: day)
                    guard ((gap % backoffEvery) + backoffEvery) % backoffEvery == 0 else { continue }
                }
                slots.append(Slot(kind: .write, day: day, minute: minute, title: writeTitle, body: writeBody(on: day)))
            }
        }
        if input.habits {
            let minute = clampMinute(input.habitsMinute)
            for offset in 0..<horizonDays {
                let day = today.adding(days: offset)
                if offset == 0 {
                    guard input.nowMinute < minute, !input.pendingHabits.isEmpty,
                          !firedToday(state.armedHabits, today: today, nowMinute: input.nowMinute) else { continue }
                    slots.append(Slot(kind: .habits, day: day, minute: minute, title: habitsTitle, body: habitsBody(pending: input.pendingHabits)))
                } else if input.habitDays.contains(day) {
                    slots.append(Slot(kind: .habits, day: day, minute: minute, title: habitsTitle, body: habitsGeneric))
                }
            }
        }
        return slots
    }

    /// 排完之后记下排了哪些：今天已到点的留着（次日结算 / 不再排第二条），其余换成这次排上的
    static func arm(_ state: State, plan: [Slot], today: LocalDay, nowMinute: Int) -> State {
        var s = state
        func kept(_ armed: [String: Int]) -> [String: Int] {
            armed.filter { $0.key < today.key || ($0.key == today.key && $0.value <= nowMinute) }
        }
        s.armedWrite = kept(s.armedWrite)
        s.armedHabits = kept(s.armedHabits)
        for slot in plan {
            switch slot.kind {
            case .write: s.armedWrite[slot.day.key] = slot.minute
            case .habits: s.armedHabits[slot.day.key] = slot.minute
            }
        }
        return s
    }

    /// 待结算里最早的一天（取“这几天写没写”时从这天取起）
    static func earliestArmed(_ state: State, today: LocalDay) -> LocalDay {
        state.armedWrite.keys.compactMap(LocalDay.init(key:)).filter { $0 < today }.min() ?? today
    }

    static func clampMinute(_ minute: Int) -> Int { max(0, min(minute, 24 * 60 - 1)) }

    // MARK: 周复盘

    /// 设置里的星期次序：周一在前
    static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    /// 1 = 周日 … 7 = 周六；认不出的按周日
    static func weekdayName(_ weekday: Int) -> String {
        let names = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]
        return names[weekday] ?? "周日"
    }

    static func clampWeekday(_ weekday: Int) -> Int { (1...7).contains(weekday) ? weekday : defaultWeeklyWeekday }

    /// “每周日 21:00”
    static func weeklyLabel(weekday: Int, minute: Int) -> String {
        "每\(weekdayName(clampWeekday(weekday))) \(ClockTime.text(clampMinute(minute)))"
    }

    /// 周复盘通知的触发时刻（重复的日历触发器用）
    static func weeklyComponents(weekday: Int, minute: Int) -> DateComponents {
        let m = clampMinute(minute)
        var when = DateComponents()
        when.weekday = clampWeekday(weekday)
        when.hour = m / 60
        when.minute = m % 60
        return when
    }

    // MARK: 设置组摘要

    /// “景致与提醒”收起时摘要里提醒的部分：没开的不写
    static func summary(write: Int?, habits: Int?, weekly: Bool, loginItem: Bool) -> [String] {
        var parts: [String] = []
        if let write { parts.append("落笔 \(ClockTime.text(clampMinute(write)))") }
        if let habits { parts.append("功课 \(ClockTime.text(clampMinute(habits)))") }
        if weekly { parts.append("周复盘已开") }
        if loginItem { parts.append("开机自启") }
        return parts
    }
}

extension ReminderPlan.State {
    /// 读存着的 JSON：缺的字段（早先版本存下的记录没有 unseen / awaySince）按默认值，其余照读，不因少一个字段就整份作废
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        armedWrite = try c.decodeIfPresent([String: Int].self, forKey: .armedWrite) ?? [:]
        armedHabits = try c.decodeIfPresent([String: Int].self, forKey: .armedHabits) ?? [:]
        answered = try c.decodeIfPresent([String].self, forKey: .answered) ?? []
        ignored = try c.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
        backoffStart = try c.decodeIfPresent(String.self, forKey: .backoffStart)
        noticePending = try c.decodeIfPresent(Bool.self, forKey: .noticePending) ?? false
        unseen = try c.decodeIfPresent([String].self, forKey: .unseen) ?? []
        awaySince = try c.decodeIfPresent(ReminderPlan.Moment.self, forKey: .awaySince)
    }
}

// MARK: - 日程开始前、那年今日、周复盘的本周实数（#17）

/// 另三类提醒，同样是一次性请求、标识里带日期（一次排几天，到点前每次重排都按库里现在的样子刷新）：
/// - 日程开始前（默认 10 分钟，可选 5 / 10 / 15 / 30）：只排今天与明天有钟点的日程，全天的不排，最多 12 条；点开回到时辰卷那一周。
/// - 那年今日（每天 9:00）：那天正好有一年 / 半年 / 一月 / 一周前写下的话才排（某月没有那一天、被截到月底的不算），
///   先远后近取一处，正文去掉复盘的【所得】小标题、〔本期素材〕段与列表记号后摘前 30 字；点开回到今日洞府。
/// - 周复盘：接下来 12 次各排一条（不再用每周重复的那一条，正文才能写本周实数；12 周内不打开应用也照响）；
///   第一次写“这一周落笔 9 篇、功课 71%”（功课的数只在那一周已过完、或提醒就在今明两天时才写，免得应用中途没开、
///   到点发出排程那天的旧数），以后几次先用通用句，轮到时刷新。周一 12:00 之前提醒的说上一整周（与七日小卷同一规矩）。
///   点开翻到修行录、打开七日小卷。
extension ReminderPlan {
    enum ExtraKind: String, CaseIterable {
        case event, lookback, weekly
    }

    struct Extra: Equatable {
        var kind: ExtraKind
        var identifier: String
        /// 归哪一天：日程是它开始的那天（点开跳到那一周、过了这天收掉已发的），那年今日、周复盘是提醒那天
        var day: LocalDay
        /// 哪天的第几分钟发（明天 00:10 的日程提前 30 分钟，发在今天 23:40）
        var fireDay: LocalDay
        var minute: Int
        var title: String
        var body: String
    }

    static func extraPrefix(_ kind: ExtraKind) -> String { "apt.\(kind.rawValue)." }

    /// 认出这三类的标识：`apt.event.2026-10-22.1500.0`、`apt.lookback.2026-10-22`、`apt.weekly.2026-10-25` → (类, 日子)。
    /// 以前每周重复的那条周复盘（apt.weekly-review）不认：它仍由 ReviewReminder 打开复盘落笔
    static func parseExtra(identifier: String) -> (kind: ExtraKind, day: LocalDay)? {
        for kind in ExtraKind.allCases where identifier.hasPrefix(extraPrefix(kind)) {
            let rest = identifier.dropFirst(extraPrefix(kind).count)
            let key = String(rest.prefix(10))
            guard let day = LocalDay(key: key), day.key == key else { return nil }
            let tail = rest.dropFirst(10)
            switch kind {
            case .event: guard tail.hasPrefix("."), tail.count > 1 else { return nil }
            case .lookback, .weekly: guard tail.isEmpty else { return nil }
            }
            return (kind, day)
        }
        return nil
    }

    /// 点开通知去哪：日程 → 时辰卷那一周；那年今日 → 今日洞府；周复盘 → 七日小卷（DailyReminder.open 现在交给修行录打开）
    enum Route: Equatable {
        case schedule(LocalDay)
        case overview
        case weekly
    }

    static func route(for identifier: String) -> Route? {
        guard let parsed = parseExtra(identifier: identifier) else { return nil }
        switch parsed.kind {
        case .event: return .schedule(parsed.day)
        case .lookback: return .overview
        case .weekly: return .weekly
        }
    }

    // MARK: 日程开始前

    static let eventLeadOptions = [5, 10, 15, 30]
    static let defaultEventLead = 10
    /// 一次最多排几条日程提醒
    static let eventLimit = 12
    static let eventTitle = "时辰将至"

    /// 认不出的提前量回到 10 分钟
    static func clampLead(_ minutes: Int) -> Int { eventLeadOptions.contains(minutes) ? minutes : defaultEventLead }

    /// 一项日程（重复规则已展开、单次改期已套上）
    struct EventItem: Equatable {
        var day: LocalDay
        /// nil 是全天
        var startMinute: Int?
        var title: String
        var location: String = ""
    }

    /// “15:00 组会 · 还有 10 分钟 · 图书馆 3 楼”（没写地点就不写）
    static func eventBody(_ item: EventItem, lead: Int) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = item.location.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = "\(ClockTime.text(item.startMinute)) \(title.isEmpty ? "日程" : title) · 还有 \(clampLead(lead)) 分钟"
        if !place.isEmpty { text += " · " + place }
        return text
    }

    /// 只排今天与明天有钟点的日程，提醒时刻 = 开始前 lead 分钟、且还没过；按提醒先后（同一刻按标题）最多 12 条。
    /// 标识 `apt.event.<日期>.<HHMM>.<同一刻的第几项>`：同一项日程每次重排都是同一个标识，没变就不重排
    static func eventSlots(today: LocalDay, nowMinute: Int, lead: Int, items: [EventItem]) -> [Extra] {
        let lead = clampLead(lead)
        var candidates: [(fire: Int, start: Int, item: EventItem)] = []
        for item in items {
            guard let start = item.startMinute, (0..<24 * 60).contains(start) else { continue }
            let offset = today.days(to: item.day)
            guard offset == 0 || offset == 1 else { continue }
            // 从今天零点算起的第几分钟发
            let fire = offset * 24 * 60 + start - lead
            guard fire > nowMinute else { continue }
            candidates.append((fire, start, item))
        }
        candidates.sort { ($0.fire, $0.item.title, $0.item.location) < ($1.fire, $1.item.title, $1.item.location) }
        var seen: [String: Int] = [:]
        return candidates.prefix(eventLimit).map { c in
            let base = extraPrefix(.event) + c.item.day.key + "." + String(format: "%02d%02d", c.start / 60, c.start % 60)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return Extra(kind: .event, identifier: "\(base).\(n)", day: c.item.day, fireDay: today.adding(days: c.fire / (24 * 60)),
                         minute: c.fire % (24 * 60), title: eventTitle, body: eventBody(c.item, lead: lead))
        }
    }

    // MARK: 那年今日

    static let lookbackTitle = "旧笔新读"
    static let lookbackMinute = 9 * 60
    /// 正文摘前几个字
    static let lookbackExcerpt = 30

    /// 那天的一年 / 半年 / 一月 / 一周前，只留正好是“同一天”的：那个月没有这一天、被截到月底的不算
    /// （3月28–31日的“一月前”都截成2月28日，不然同一句会连推四天，3月30日也不是2月的“今天”）
    static func lookbackSpans(today: LocalDay) -> [(label: String, day: LocalDay)] {
        let weekAgo = today.adding(days: -7)
        return DashboardRules.lookBackSpans(today: today).filter { $0.day == weekAgo || $0.day.day == today.day }
    }

    /// 要查的日子：今天起 7 天里每一天的一年 / 半年 / 一月 / 一周前（与首页旧笔新读同几天，只看正好那天，不放宽）
    static func lookbackKeys(today: LocalDay) -> Set<String> {
        Set((0..<horizonDays).flatMap { lookbackSpans(today: today.adding(days: $0)).map(\.day.key) })
    }

    /// 摘句用的正文：去掉复盘模板的【所得】等小标题、〔本期素材〕段、回访行与行首列表记号（与七日小卷的摘句同一套清理）
    static func lookbackText(_ body: String) -> String {
        DashboardRules.excerpt(WeeklyDigest.cleaned(body), limit: lookbackExcerpt)
    }

    /// “一年前的今天，你写下：「……」”
    static func lookbackBody(label: String, text: String) -> String {
        "\(label)的今天，你写下：「\(lookbackText(text))」"
    }

    /// 今天起 7 天，每天 9:00 一条（今天过了 9:00 不排）；那天正好有一年 / 半年 / 一月 / 一周前写下的话才排，先远后近取一处。
    /// written：要查的那几天里写过的 → 那天挑出的一篇的正文（空的当没写）
    static func lookbackSlots(today: LocalDay, nowMinute: Int, written: [String: String]) -> [Extra] {
        var slots: [Extra] = []
        for offset in 0..<horizonDays {
            if offset == 0 && nowMinute >= lookbackMinute { continue }
            let day = today.adding(days: offset)
            let found = lookbackSpans(today: day).lazy.compactMap { span -> (label: String, text: String)? in
                guard let text = written[span.day.key], !lookbackText(text).isEmpty else { return nil }
                return (span.label, text)
            }.first
            guard let found else { continue }
            slots.append(Extra(kind: .lookback, identifier: extraPrefix(.lookback) + day.key, day: day, fireDay: day,
                               minute: lookbackMinute, title: lookbackTitle, body: lookbackBody(label: found.label, text: found.text)))
        }
        return slots
    }

    // MARK: 周复盘的本周实数

    static let weeklyTitle = "该写周复盘了"
    /// 没有可说的数（这一周还没落笔、也没有功课）时，和以后几次先排的通用句
    static let weeklyGeneric = "这一周所得、所失、所悟，落笔成卷。"
    /// 一次排接下来几次：12 周内不打开应用也照响（以前是每周重复的一条，应用不开也响）。
    /// 待发的通知合计约 7 + 7 + 12 + 7 + 12 = 45 条，在系统每个应用 64 条的上限以内
    static let weeklyHorizon = 12

    /// 本周实数：落笔几篇、功课完成率（没有功课时为 nil）
    struct WeekNumbers: Equatable {
        var entries = 0
        var habitRate: Double?
    }

    /// 星期（1 = 周日 … 7 = 周六）→ LocalDay.weekdayIndex（0 = 周一 … 6 = 周日）
    static func weekdayIndex(_ weekday: Int) -> Int { (clampWeekday(weekday) + 5) % 7 }

    /// 那天提醒说的是哪一周：周一 12:00 之前提醒的说上一整周（previous），其余说这一周（周一到提醒那天）
    static func weeklyRange(fireDay: LocalDay, minute: Int) -> (first: LocalDay, last: LocalDay, previous: Bool) {
        let monday = fireDay.mondayOfWeek
        if fireDay == monday && minute < 12 * 60 { return (monday.adding(days: -7), monday.adding(days: -1), true) }
        return (monday, fireDay, false)
    }

    /// “这一周落笔 9 篇、功课 71%，翻看七日小卷。”；只有一样就只写一样，两样都没有用通用句
    static func weeklyBody(_ numbers: WeekNumbers, previous: Bool) -> String {
        var parts: [String] = []
        if numbers.entries > 0 { parts.append("落笔 \(numbers.entries) 篇") }
        // 与七日小卷“本周完成 71%”同一种取整
        if let rate = numbers.habitRate, rate.isFinite { parts.append("功课 \(RecordStats.percent(max(0, min(rate, 1))))") }
        guard !parts.isEmpty else { return weeklyGeneric }
        return (previous ? "上一周" : "这一周") + parts.joined(separator: "、") + "，翻看七日小卷。"
    }

    /// 第一条的功课完成率排程时就写死了：应用中途没开、没能重排，到点发的就是排程那天的数（之后几天排了没打的一次都没扣）。
    /// 所以只在那一周排程时已过完、或提醒就在今天明天发时才写；否则只写篇数（篇数只在应用开着时才会变，变了就重排）
    static func weeklyRateFresh(range: (first: LocalDay, last: LocalDay, previous: Bool), fireDay: LocalDay, today: LocalDay) -> Bool {
        range.last <= today || today.days(to: fireDay) <= 1
    }

    /// 接下来的 12 次（今天还没到点就从今天算起）。第一次写实数：numbers 只为它取一次，范围截到今天
    /// （那一周还没开始时不取、用通用句；功课完成率见 weeklyRateFresh）；以后几次先用通用句
    static func weeklySlots(today: LocalDay, nowMinute: Int, weekday: Int, minute: Int,
                            numbers: (_ first: LocalDay, _ last: LocalDay) -> WeekNumbers) -> [Extra] {
        let minute = clampMinute(minute)
        var offset = ((weekdayIndex(weekday) - today.weekdayIndex) % 7 + 7) % 7
        if offset == 0 && nowMinute >= minute { offset = 7 }
        return (0..<weeklyHorizon).map { n in
            let day = today.adding(days: offset + n * 7)
            var body = weeklyGeneric
            if n == 0 {
                let range = weeklyRange(fireDay: day, minute: minute)
                let last = min(range.last, today)
                if range.first <= last {
                    var found = numbers(range.first, last)
                    if !weeklyRateFresh(range: range, fireDay: day, today: today) { found.habitRate = nil }
                    body = weeklyBody(found, previous: range.previous)
                }
            }
            return Extra(kind: .weekly, identifier: extraPrefix(.weekly) + day.key, day: day, fireDay: day,
                         minute: minute, title: weeklyTitle, body: body)
        }
    }

    // MARK: 设置组摘要（含这两行）

    /// “落笔 21:30 · 日程前 10 分钟 · 那年今日 · 周复盘已开”：没开的不写
    static func summary(write: Int?, habits: Int?, events: Int?, lookback: Bool, weekly: Bool, loginItem: Bool) -> [String] {
        var parts = summary(write: write, habits: habits, weekly: false, loginItem: false)
        if let events { parts.append("日程前 \(clampLead(events)) 分钟") }
        if lookback { parts.append("那年今日") }
        if weekly { parts.append("周复盘已开") }
        if loginItem { parts.append("开机自启") }
        return parts
    }
}
