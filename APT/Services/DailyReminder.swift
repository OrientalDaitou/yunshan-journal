import AppKit
import SwiftData
import UserNotifications

/// 落笔时辰、功课时辰：每天一条系统通知，叫人回来写一句、打个卡。默认都关，在洞府设置 → 景致与提醒（或筑基三关）里打开。
///
/// - 落笔：今天还没写才发；通知里点“落一笔”直接打字回车即入卷（今天的日记，修为照常 +5）；“今日免”只算回应；
///   点通知本身弹出 ⌥⌘J 随手记浮窗，不开主窗口。连续 3 次没理会自动改三日一问（规则在 Core/ReminderPlan）；
///   到点那一刻 Mac 睡着或关着（AppHost 转来睡下 / 关机 / 醒来的时刻）、没有通知权限的日子不算没理会。
/// - 功课：还有未圆满的功课才发，正文写出前三项名字；“去打卡”开主窗口今日洞府，“随手记”弹出浮窗。
/// - 排程：一次排未来 7 天、每天一条一次性的请求；AppHost 在启动、数据保存（防抖 2 秒）、跨日、唤醒、改时区时重排，设置改动时也重排。
/// - 通知代理仍只有 ReviewReminder 一个：它按标识前缀把 apt.write. / apt.habits. 交给 `DailyReminder.handle(_:)`。
/// - #17 另三类也归这里排（规则在 ReminderPlan 末尾一节）：日程开始前 N 分钟（今天与明天有钟点的，最多 12 条，点开回时辰卷那一周）、
///   那年今日（每天 9:00，往年那天写过才提，点开回今日洞府）、周复盘（接下来 12 次各一条，正文写本周实数，点开到修行录、翻开七日小卷）。
///   这三类的标识 apt.event. / apt.lookback. / apt.weekly. 同样经 `handles` 交过来；以前那条每周重复的 apt.weekly-review 在重排时撤掉。
///
/// 调试实例（设了 APT_STORE_DIR）与离屏渲染绝不调用系统通知的 add / remove / requestAuthorization：
/// 和已安装的正式应用是同一个 bundle id，会改到你真正在用的提醒。这时只记开关（记在调试实例自己的偏好里）。
@MainActor
final class DailyReminder {
    static let shared = DailyReminder()

    // MARK: 偏好键（AppPreferences.defaults；设置页的 @AppStorage 读写的是同一份）

    nonisolated static let writeKey = "reminder.write"
    nonisolated static let writeMinuteKey = "reminder.write.minute"
    nonisolated static let habitsKey = "reminder.habits"
    nonisolated static let habitsMinuteKey = "reminder.habits.minute"
    /// 排程与退避的记录（ReminderPlan.State 的 JSON）
    nonisolated static let stateKey = "reminder.state"
    /// 日程开始前提醒（开关、提前几分钟）、那年今日；周复盘的开关仍是 ReviewReminder.enabledKey
    nonisolated static let eventsKey = "reminder.events"
    nonisolated static let eventsLeadKey = "reminder.events.lead"
    nonisolated static let lookbackKey = "reminder.lookback"

    // MARK: 通知类别与按钮

    nonisolated static let writeCategory = "apt.write"
    nonisolated static let habitsCategory = "apt.habits"
    nonisolated static let replyAction = "apt.action.write.reply"
    nonisolated static let skipAction = "apt.action.write.skip"
    nonisolated static let openAction = "apt.action.habits.open"
    nonisolated static let quickAction = "apt.action.habits.quick"

    static let debugNote = "调试数据目录：只记下开关，没有改动系统通知"
    static let deniedNote = "没有获得通知权限：请在 系统设置 → 通知 → 云山修习录 中允许通知"

    private var context: ModelContext?
    private var effects: EffectsCenter?
    private var pendingTask: Task<Void, Never>?
    private var running = false
    private var runAgain = false

    private init() {}

    // MARK: 开关与时刻

    static var isWriteEnabled: Bool { AppPreferences.defaults.bool(forKey: writeKey) }
    static var isHabitsEnabled: Bool { AppPreferences.defaults.bool(forKey: habitsKey) }
    static var writeMinute: Int { minute(writeMinuteKey, ReminderPlan.defaultWriteMinute) }
    static var habitsMinute: Int { minute(habitsMinuteKey, ReminderPlan.defaultHabitsMinute) }

    private static func minute(_ key: String, _ fallback: Int) -> Int {
        ReminderPlan.clampMinute((AppPreferences.defaults.object(forKey: key) as? Int) ?? fallback)
    }

    static var isEventsEnabled: Bool { AppPreferences.defaults.bool(forKey: eventsKey) }
    static var eventsLead: Int {
        ReminderPlan.clampLead((AppPreferences.defaults.object(forKey: eventsLeadKey) as? Int) ?? ReminderPlan.defaultEventLead)
    }
    static var isLookbackEnabled: Bool { AppPreferences.defaults.bool(forKey: lookbackKey) }
    static var isWeeklyEnabled: Bool { AppPreferences.defaults.bool(forKey: ReviewReminder.enabledKey) }
    /// 有没有哪一类开着（都关着时保存、跨日都不必去问系统）
    static var anyEnabled: Bool { isWriteEnabled || isHabitsEnabled || isEventsEnabled || isLookbackEnabled || isWeeklyEnabled }

    /// 点开周复盘提醒：先回到今日洞府、再调这个钩子翻开七日小卷，最后带出主窗口。
    /// AppHost.start 接的是 `openWeeklyInChronicle`：现在只有修行录接收 AppRouter.weeklyScroll（读到即打开、清零），
    /// 所以要再把页切到修行录，由它接住；等今日洞府也接这个标志（#14）后，AppHost 里改回只设 `weeklyScroll = true`。
    /// 没接钩子时退回以前的做法：直达修行录的复盘落笔
    static var openWeekly: (@MainActor () -> Void)?

    /// 切到修行录、请它翻开七日小卷（同一轮里先设的 .overview 被这里盖掉，RootView 只看到修行录这一次切页）。
    /// 修行录已在当前页时由它的 onChange 当场打开；不在时切过去、出现时读到标志打开；主窗口关着时窗口出现后补上
    static func openWeeklyInChronicle() {
        AppRouter.shared.page = .chronicle
        AppRouter.shared.weeklyScrollTarget = .chronicle
        AppRouter.shared.weeklyScroll = true
    }

    /// 会不会真的去改系统通知：正式使用时才会（调试数据目录、离屏渲染、命令行都只记开关）
    static var touchesSystem: Bool { DataStore.customDirectory == nil && !RenderMode.offscreen }

    /// 存成 JSON 文字（不是 Data）：设置页的 @AppStorage 直接读它，离屏渲染也能用 APT_RENDER_DEFAULTS 预设
    static var state: ReminderPlan.State {
        get { decodeState(AppPreferences.defaults.string(forKey: stateKey) ?? "") }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                AppPreferences.defaults.set(String(decoding: data, as: UTF8.self), forKey: stateKey)
            }
        }
    }

    /// 读不出（没存过、写坏了）就当全新的
    nonisolated static func decodeState(_ text: String) -> ReminderPlan.State {
        (try? JSONDecoder().decode(ReminderPlan.State.self, from: Data(text.utf8))) ?? ReminderPlan.State()
    }

    /// 落笔提醒正处在三日一问
    static var isBackingOff: Bool { isWriteEnabled && state.backingOff }

    /// 打开或关闭落笔提醒；打开时先请求通知权限，返回是否成功（没给权限时开关回到关）。调试实例只记开关、返回 true
    func setWrite(enabled on: Bool) async -> Bool {
        await set(.write, on)
    }

    func setHabits(enabled on: Bool) async -> Bool {
        await set(.habits, on)
    }

    /// 日程开始前、那年今日：同样默认关，打开时先请求通知权限
    func setEvents(enabled on: Bool) async -> Bool {
        await setFlag(Self.eventsKey, on)
    }

    func setLookback(enabled on: Bool) async -> Bool {
        await setFlag(Self.lookbackKey, on)
    }

    /// 周复盘提醒也归这里排（接下来 12 次各一条、正文写本周实数）；ReviewReminder.setEnabled 以前排下的那条每周重复的请求在重排时撤掉
    func setWeekly(enabled on: Bool) async -> Bool {
        await setFlag(ReviewReminder.enabledKey, on)
    }

    /// 改日程提前量：记下后稍等再重排
    func setEventsLead(_ minutes: Int) {
        AppPreferences.defaults.set(ReminderPlan.clampLead(minutes), forKey: Self.eventsLeadKey)
        scheduleSoon(after: 0.8)
    }

    private func set(_ kind: ReminderPlan.Kind, _ on: Bool) async -> Bool {
        if !on { Self.state = ReminderPlan.disabled(Self.state, kind) }
        return await setFlag(kind == .write ? Self.writeKey : Self.habitsKey, on)
    }

    /// 记下开关，正式使用时打开先请求通知权限（没给权限时开关回到关），然后重排。调试实例只记开关、返回 true
    private func setFlag(_ key: String, _ on: Bool) async -> Bool {
        AppPreferences.defaults.set(on, forKey: key)
        guard Self.touchesSystem else { return true }
        if on {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
            guard granted else {
                // 等权限的这一会儿里又被关掉了，就不必再改回去
                if AppPreferences.defaults.bool(forKey: key) { AppPreferences.defaults.set(false, forKey: key) }
                await reschedule()
                return false
            }
        }
        await reschedule()
        return true
    }

    /// 改时刻：记下后稍等再重排（时刻格子连点几下只排一次）
    func setMinute(_ kind: ReminderPlan.Kind, _ minute: Int) {
        AppPreferences.defaults.set(ReminderPlan.clampMinute(minute), forKey: kind == .write ? Self.writeMinuteKey : Self.habitsMinuteKey)
        scheduleSoon(after: 0.8)
    }

    /// 设置里点“恢复每日”
    func restoreDaily() {
        Self.state = ReminderPlan.restoreDaily(Self.state)
        scheduleSoon(after: 0.3)
    }

    /// Mac 要睡下、关机或注销（AppHost 收到 willSleep / willPowerOff 时调用）：记下这一刻。
    /// 只是一笔偏好记录，不碰系统通知；落笔提醒关着时不必记
    func noteAway(now: Date = Date()) {
        guard Self.isWriteEnabled else { return }
        Self.state = ReminderPlan.away(Self.state, at: Self.moment(now))
    }

    /// 要关机或注销（willPowerOff）：同样记下这一刻，下次启动时收尾。注销被取消、应用还开着的话，两分钟后自己收掉
    /// （真关了机，进程已经不在，这一步不会跑）
    func notePowerOff(now: Date = Date()) {
        noteAway(now: now)
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.noteBack()
        }
    }

    /// 醒来（didWake）或启动时：这段里到点的落笔提醒记作没送到，结算时不算没理会；没有睡下的记录就不动
    func noteBack(now: Date = Date()) {
        let state = Self.state
        guard state.awaySince != nil else { return }
        Self.state = ReminderPlan.back(state, at: Self.moment(now))
    }

    private static func moment(_ date: Date) -> ReminderPlan.Moment {
        ReminderPlan.Moment(day: LocalDay(date: date), minute: ClockTime.minutes(of: date))
    }

    /// 刚改成三日一问、还没说过：取走这一句（只说一次）。主窗口出现时 AppHost 来取
    func takeBackoffNotice() -> String? {
        var state = Self.state
        guard Self.isWriteEnabled, state.noticePending else { return nil }
        state.noticePending = false
        Self.state = state
        return ReminderPlan.backoffHint
    }

    // MARK: 启动与重排

    /// AppHost 启动时调用一次：记下主 context（通知里回复的一句用它入卷），注册通知类别，稍后排一次
    func start(context: ModelContext, effects: EffectsCenter) {
        self.context = context
        self.effects = effects
        // 上次关机（或注销）前记下的那一刻到现在：这段里到点的落笔提醒没送到眼前
        noteBack()
        guard Self.touchesSystem else { return }
        UNUserNotificationCenter.current().setNotificationCategories(Self.categories)
        scheduleSoon(after: 6)
    }

    /// 通知的类别：落笔（文字输入“落一笔”、“今日免”）、功课（“去打卡”“随手记”）
    private static var categories: Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "落一笔", options: [],
                                                  textInputButtonTitle: "入卷", textInputPlaceholder: "写一句……")
        let skip = UNNotificationAction(identifier: skipAction, title: "今日免", options: [])
        let open = UNNotificationAction(identifier: openAction, title: "去打卡", options: [.foreground])
        let quick = UNNotificationAction(identifier: quickAction, title: "随手记", options: [.foreground])
        return [
            UNNotificationCategory(identifier: writeCategory, actions: [reply, skip], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: habitsCategory, actions: [open, quick], intentIdentifiers: [], options: []),
        ]
    }

    /// 稍后重排；这段时间里又来一次就重新计时（数据连着保存好几次只排一次）。
    /// 两样都关着时不排（关掉的那一刻 setWrite / setHabits 已当场撤干净），保存、跨日都不必再去问系统
    func scheduleSoon(after seconds: Double = 2) {
        guard Self.touchesSystem, context != nil, Self.anyEnabled else { return }
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.reschedule()
        }
    }

    /// 现在就重排。正在排的时候又被叫到：排完再排一遍（两次交错时，后一次的“撤掉”不会被前一次的“排上”盖掉）
    func reschedule() async {
        guard Self.touchesSystem, let context else { return }
        if running {
            runAgain = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            runAgain = false
            await apply(context: context, now: Date())
        } while runAgain
    }

    private func apply(context: ModelContext, now: Date) async {
        let today = LocalDay(date: now)
        let nowMinute = ClockTime.minutes(of: now)
        let write = Self.isWriteEnabled, habits = Self.isHabitsEnabled
        let center = UNUserNotificationCenter.current()
        // 只读地看一眼通知权限（不申请）：事后在系统设置里关掉了通知，这些天的提醒弹不出来，不算没理会
        let settings = await center.notificationSettings()
        let canNotify = settings.authorizationStatus == .authorized && settings.alertStyle != .none
        // 还记着“睡下了”：刚睡下（还没真睡）这次先不结算；早就醒了只是“醒来”通知还没轮到，就当场收尾
        let resumed = ReminderPlan.resume(Self.state, now: Self.moment(now))
        var state = resumed.state
        // 先结算到点过的日子（写了没有、理没理会），再排；两样都关着时计划是空的，下面只把以前排下、还挂着的撤掉
        let wrote = Self.writtenDays(from: ReminderPlan.earliestArmed(state, today: today), to: today, context: context)
        if resumed.settle { state = ReminderPlan.settle(state, today: today, wrote: wrote, canNotify: canNotify) }
        var input = ReminderPlan.Input(today: today, nowMinute: nowMinute, write: write, writeMinute: Self.writeMinute,
                                       habits: habits, habitsMinute: Self.habitsMinute, wroteToday: wrote.contains(today), state: state)
        if habits {
            let outlook = Self.habitOutlook(today: today, context: context)
            input.pendingHabits = outlook.pending
            input.habitDays = outlook.days
        }
        let plan = ReminderPlan.plan(input)
        state = ReminderPlan.arm(state, plan: plan, today: today, nowMinute: nowMinute)
        Self.state = state
        // #17 日程开始前、那年今日、周复盘：按库里现在的样子排（关着的那类是空的）
        let extras = Self.extraPlan(today: today, nowMinute: nowMinute, context: context)

        let pending = await center.pendingNotificationRequests()
        let ours = pending.filter { ReminderPlan.parse(identifier: $0.identifier) != nil }
        let wanted = Set(plan.map(\.identifier))
        let stale = ours.map(\.identifier).filter { !wanted.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for slot in plan {
            if let existing = ours.first(where: { $0.identifier == slot.identifier }), Self.matches(existing, slot) { continue }
            try? await center.add(Self.request(for: slot))
        }
        // 另三类同样只增删有变化的；以前那条每周重复的周复盘（apt.weekly-review）一并撤掉，改由这里一次排 12 条、第一条写本周实数
        let extraOurs = pending.filter { ReminderPlan.parseExtra(identifier: $0.identifier) != nil || $0.identifier == ReviewReminder.identifier }
        let extraWanted = Set(extras.map(\.identifier))
        let extraStale = extraOurs.map(\.identifier).filter { !extraWanted.contains($0) }
        if !extraStale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: extraStale) }
        for extra in extras {
            if let existing = extraOurs.first(where: { $0.identifier == extra.identifier }),
               Self.matches(existing, title: extra.title, body: extra.body, day: extra.fireDay, minute: extra.minute) { continue }
            try? await center.add(Self.request(for: extra))
        }
        // 已经发出、还留在通知中心里的：前几天的，今天已写过的落笔、今天已圆满的功课，一并收掉；
        // 日程（开始那天已过）、那年今日（前几天的）同样收掉，周复盘留着
        let habitsDone = !habits || input.pendingHabits.isEmpty
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let finished = delivered.filter { id in
            if let extra = ReminderPlan.parseExtra(identifier: id) { return extra.kind != .weekly && extra.day < today }
            guard let parsed = ReminderPlan.parse(identifier: id) else { return false }
            return parsed.day < today || (parsed.kind == .write && (input.wroteToday || !write)) || (parsed.kind == .habits && habitsDone)
        }
        if !finished.isEmpty { center.removeDeliveredNotifications(withIdentifiers: finished) }
    }

    private static func request(for slot: ReminderPlan.Slot) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = slot.title
        content.body = slot.body
        content.sound = .default
        content.categoryIdentifier = slot.kind == .write ? writeCategory : habitsCategory
        // 通知中心里同一类叠在一起
        content.threadIdentifier = ReminderPlan.prefix(slot.kind)
        let when = DateComponents(year: slot.day.year, month: slot.day.month, day: slot.day.day,
                                  hour: slot.minute / 60, minute: slot.minute % 60)
        return UNNotificationRequest(identifier: slot.identifier, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
    }

    /// 已经挂着的请求与这次要排的一样（标题、正文、时刻都没变）就不重排
    private static func matches(_ request: UNNotificationRequest, _ slot: ReminderPlan.Slot) -> Bool {
        matches(request, title: slot.title, body: slot.body, day: slot.day, minute: slot.minute)
    }

    private static func matches(_ request: UNNotificationRequest, title: String, body: String, day: LocalDay, minute: Int) -> Bool {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger, !trigger.repeats else { return false }
        let when = trigger.dateComponents
        return request.content.title == title && request.content.body == body
            && when.year == day.year && when.month == day.month && when.day == day.day
            && when.hour == minute / 60 && when.minute == minute % 60
    }

    /// 日程开始前、那年今日、周复盘：只点开，没有按钮（不设类别）；同一类在通知中心里叠在一起
    private static func request(for extra: ReminderPlan.Extra) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = extra.title
        content.body = extra.body
        content.sound = .default
        content.threadIdentifier = ReminderPlan.extraPrefix(extra.kind)
        let when = DateComponents(year: extra.fireDay.year, month: extra.fireDay.month, day: extra.fireDay.day,
                                  hour: extra.minute / 60, minute: extra.minute % 60)
        return UNNotificationRequest(identifier: extra.identifier, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
    }

    // MARK: 取数（只取这几天，不整表）

    /// 这几天里有修行录的日子（按 dateKey 取，最多十来天）
    static func writtenDays(from first: LocalDay, to last: LocalDay, context: ModelContext) -> Set<LocalDay> {
        let lo = first.key, hi = last.key
        let entries = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey >= lo && $0.dateKey <= hi }))) ?? []
        return Set(entries.compactMap { LocalDay(key: $0.dateKey) })
    }

    /// 今天还没圆满的功课（名字，按功课的先后），和未来几天里有功课要做的日子。借修为模型算好的统计，不读打卡关系
    static func habitOutlook(today: LocalDay, context: ModelContext) -> (pending: [String], days: Set<LocalDay>) {
        let model = CultivationModel.shared(for: context)
        model.refresh()
        let rows = model.rows.filter { $0.habit.modelContext != nil }
        let pending = rows.filter { row in
            let stats = model.today == today ? row.stats : (model.stats(for: row.habit, today: today) ?? row.stats)
            return stats.isDueToday && !stats.isAchieved(today)
        }.map(\.habit.title)
        var days = Set<LocalDay>()
        for offset in 1..<ReminderPlan.horizonDays {
            let day = today.adding(days: offset)
            if rows.contains(where: { $0.stats.spec.isScheduled(day) }) { days.insert(day) }
        }
        return (pending, days)
    }

    /// #17 这一次要排的另三类（开着的才取数；都按日期范围取，不整表）。不碰系统通知，自检直接调它看排了什么
    static func extraPlan(today: LocalDay, nowMinute: Int, context: ModelContext) -> [ReminderPlan.Extra] {
        var extras: [ReminderPlan.Extra] = []
        if isEventsEnabled {
            extras += ReminderPlan.eventSlots(today: today, nowMinute: nowMinute, lead: eventsLead, items: eventItems(today: today, context: context))
        }
        if isLookbackEnabled {
            extras += ReminderPlan.lookbackSlots(today: today, nowMinute: nowMinute, written: lookbackWritten(today: today, context: context))
        }
        if isWeeklyEnabled {
            extras += ReminderPlan.weeklySlots(today: today, nowMinute: nowMinute, weekday: ReviewReminder.weekday, minute: ReviewReminder.minute) {
                weekNumbers(from: $0, to: $1, today: today, context: context)
            }
        }
        return extras
    }

    /// 今天与明天的日程（重复的已展开、单次改期已套上）：只取可能落在这两天的
    static func eventItems(today: LocalDay, context: ModelContext) -> [ReminderPlan.EventItem] {
        let last = today.adding(days: 1)
        return Occurrences.list(events: Occurrences.events(in: context, from: today, to: last), from: today, to: last).map {
            ReminderPlan.EventItem(day: $0.day, startMinute: $0.startMinute, title: $0.title, location: $0.location)
        }
    }

    /// 那年今日要查的那几天里写过的：每天挑一篇（珍藏优先；再先日记、灵感后复盘——复盘多是统计句；同类取那天最早落笔的一篇；
    /// 去掉小标题与素材段后没有字的跳过）→ 正文。只按 dateKey 取这二十几天
    static func lookbackWritten(today: LocalDay, context: ModelContext) -> [String: String] {
        let keys = Array(ReminderPlan.lookbackKeys(today: today))
        let entries = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { keys.contains($0.dateKey) }))) ?? []
        var picked: [String: JournalEntry] = [:]
        func better(_ a: JournalEntry, than b: JournalEntry) -> Bool {
            if a.pinned != b.pinned { return a.pinned }
            let aReview = a.kindValue == .review, bReview = b.kindValue == .review
            if aReview != bReview { return !aReview }
            return (a.minute ?? 24 * 60, a.createdAt) < (b.minute ?? 24 * 60, b.createdAt)
        }
        for entry in entries where !ReminderPlan.lookbackText(entry.body).isEmpty {
            if let current = picked[entry.dateKey], !better(entry, than: current) { continue }
            picked[entry.dateKey] = entry
        }
        return picked.mapValues(\.body)
    }

    /// 周复盘的本周实数：这几天落笔几篇（按 dateKey 取）、功课完成率。完成率与点开后七日小卷的“本周完成 N%”同一算法、同一批功课：
    /// 借修为模型算好的统计，只算没归档的功课（model.rows），各项完成次数之和 / 应做次数之和（WeeklyDigest.habits），今天还没打的不算缺
    static func weekNumbers(from first: LocalDay, to last: LocalDay, today: LocalDay = .today(), context: ModelContext) -> ReminderPlan.WeekNumbers {
        let lo = first.key, hi = last.key
        let entries = (try? context.fetchCount(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey >= lo && $0.dateKey <= hi }))) ?? 0
        let model = CultivationModel.shared(for: context)
        model.refresh()
        let items = model.rows.filter { $0.habit.modelContext != nil }.map { row in
            (title: row.habit.title, stats: model.today == today ? row.stats : (model.stats(for: row.habit, today: today) ?? row.stats))
        }
        let week = WeeklyDigest.Week(monday: first, today: min(last, today))
        return ReminderPlan.WeekNumbers(entries: entries, habitRate: WeeklyDigest.habits(items, week: week)?.rate)
    }

    // MARK: 点开通知

    /// 通知代理（ReviewReminder）收到 apt.write. / apt.habits. 开头的通知时交过来；#17 的 apt.event. / apt.lookback. / apt.weekly. 同样。
    /// 以前那条每周重复的 apt.weekly-review 不归这里（已经发出的那几条，点开照旧进复盘落笔）
    nonisolated static func handles(_ identifier: String) -> Bool {
        identifier.hasPrefix(ReminderPlan.prefix(.write)) || identifier.hasPrefix(ReminderPlan.prefix(.habits))
            || ReminderPlan.parseExtra(identifier: identifier) != nil
    }

    nonisolated static func handle(_ response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run { shared.respond(identifier: identifier, action: action, text: text) }
    }

    /// 点了哪条通知的哪个按钮：落笔的回复入卷、“今日免”只记回应、点通知本身弹出随手记；功课的开主窗口或随手记
    func respond(identifier: String, action: String, text: String?) {
        // #17 日程、那年今日、周复盘：没有按钮，点开就去对应的地方
        if let route = ReminderPlan.route(for: identifier) {
            open(route)
            return
        }
        guard let parsed = ReminderPlan.parse(identifier: identifier) else { return }
        switch parsed.kind {
        case .write:
            Self.state = ReminderPlan.answered(Self.state, day: parsed.day)
            switch action {
            case Self.replyAction:
                if let context, let effects, Self.handleReply(text: text ?? "", context: context, effects: effects) != nil {
                    effects.hint("已入卷 · 来自落笔时辰", icon: "checkmark.circle")
                }
            case Self.skipAction:
                break
            default:
                QuickCapturePanel.shared.show()
            }
        case .habits:
            if action == Self.quickAction {
                QuickCapturePanel.shared.show()
            } else {
                AppRouter.shared.page = .overview
                AppRouter.showMainWindow()
            }
        }
        scheduleSoon()
    }

    /// 点开 #17 的提醒：日程 → 时辰卷那一周；那年今日 → 今日洞府；周复盘 → 今日洞府，再由 openWeekly 翻开七日小卷
    /// （现在接的是 openWeeklyInChronicle：切到修行录打开；没接时直达修行录的复盘落笔，与以前那条每周重复的通知一样）。
    /// bringWindow 为假时只改去向、不动窗口（自检用：命令行里不去激活应用）
    func open(_ route: ReminderPlan.Route, bringWindow: Bool = true) {
        switch route {
        case .schedule(let day):
            AppRouter.shared.scheduleDay = day
            AppRouter.shared.page = .schedule
        case .overview:
            AppRouter.shared.page = .overview
        case .weekly:
            AppRouter.shared.page = .overview
            if let openWeekly = Self.openWeekly {
                openWeekly()
            } else {
                AppRouter.shared.chronicleCompose = .review
                AppRouter.shared.page = .chronicle
            }
        }
        if bringWindow { AppRouter.showMainWindow() }
    }

    /// 通知里回复的一句：入卷为今天的日记（走 JournalActions.save，修为照常），时刻记现在。空的不入卷，返回 nil
    @discardableResult
    static func handleReply(text: String, context: ModelContext, effects: EffectsCenter, now: Date = Date()) -> JournalEntry? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let entry = JournalEntry(kind: .diary, body: body, dateKey: LocalDay(date: now).key)
        entry.minute = ClockTime.minutes(of: now)
        JournalActions.save(entry, context: context, effects: effects)
        return entry
    }
}
