import Foundation
import SwiftData

// 落笔时辰 / 功课时辰 / 周复盘的星期与时刻 / 登录项（R1 #2 #3）：排程与退避的规则在 Core/ReminderPlan，逐条核对在 Tools/CoreCheck；
// 这里测要用到数据库与偏好设置的部分：通知里回复的一句入卷（修为照常）、今天写没写与未圆满的功课按库现取、
// 点通知后的回应记录，以及自检这种调试实例绝不碰系统通知和登录项（只记开关）。

extension SelfTest {
    static func reminderChecks(_ check: (Bool, String) -> Void) throws {
        // 0. 自检一定设了 APT_STORE_DIR：是调试实例，不碰系统通知、不碰登录项；偏好用的是它自己的那一份
        check(!DailyReminder.touchesSystem && LoginItem.isDebugInstance && AppPreferences.suiteName != nil,
              "提醒：自检是调试实例，不碰系统通知与登录项，偏好也是单独的一份")
        guard AppPreferences.suiteName != nil else { return }
        let defaults = AppPreferences.defaults
        let keys = [DailyReminder.writeKey, DailyReminder.writeMinuteKey, DailyReminder.habitsKey, DailyReminder.habitsMinuteKey,
                    DailyReminder.stateKey, ReviewReminder.weekdayKey, ReviewReminder.minuteKey, LoginItem.debugKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach(defaults.removeObject)

        /// 在主线程上等一个异步操作做完（自检本身是同步跑的）：最多等 3 秒
        func wait<T>(_ work: @escaping @MainActor () async -> T) -> T? {
            var result: T?
            Task { @MainActor in result = await work() }
            let deadline = Date().addingTimeInterval(3)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return result
        }

        // 1. 调试实例的开关：只记下，不排任何通知（排程记录始终是空的）
        let on = wait { await DailyReminder.shared.setWrite(enabled: true) }
        let habitsOn = wait { await DailyReminder.shared.setHabits(enabled: true) }
        _ = wait { await DailyReminder.shared.reschedule() }
        check(on == true && habitsOn == true && DailyReminder.isWriteEnabled && DailyReminder.isHabitsEnabled
              && DailyReminder.state == ReminderPlan.State(),
              "提醒：调试实例里打开落笔 / 功课时辰只记下开关，不排通知（排程记录为空）")
        check(DailyReminder.writeMinute == 21 * 60 + 30 && DailyReminder.habitsMinute == 20 * 60, "提醒：默认时刻 落笔 21:30、功课 20:00")
        DailyReminder.shared.setMinute(.write, 22 * 60 + 15)
        check(DailyReminder.writeMinute == 22 * 60 + 15, "提醒：改落笔时刻记在偏好里（22:15）")
        var backoff = ReminderPlan.State()
        backoff.ignored = 3
        backoff.backoffStart = LocalDay.today().key
        backoff.noticePending = true
        DailyReminder.state = backoff
        check(DailyReminder.isBackingOff && DailyReminder.shared.takeBackoffNotice() == ReminderPlan.backoffHint
              && DailyReminder.shared.takeBackoffNotice() == nil,
              "提醒：改成三日一问后，主窗口出现时只说一次“\(ReminderPlan.backoffHint)”")
        DailyReminder.shared.restoreDaily()
        check(!DailyReminder.isBackingOff && DailyReminder.state.ignored == 0, "提醒：点“恢复每日”回到每天")
        let off = wait { await DailyReminder.shared.setWrite(enabled: false) }
        check(off == true && !DailyReminder.isWriteEnabled, "提醒：调试实例里关掉落笔时辰同样只记开关")
        DailyReminder.shared.noteAway(now: Date())
        check(DailyReminder.state.awaySince == nil, "提醒：落笔提醒关着时，合盖不必记下")
        _ = wait { await DailyReminder.shared.setWrite(enabled: true) }

        // 1b. 合盖几天回来：睡下那一刻记下（只是偏好里的一笔，不碰系统通知），醒来时把这段里到点的落笔提醒记作没送到，结算时不算没理会
        let day0 = LocalDay.today()
        let writeAt = 21 * 60 + 30
        var armedState = ReminderPlan.State()
        armedState.armedWrite = [day0.adding(days: -2).key: writeAt, day0.adding(days: -1).key: writeAt, day0.key: writeAt]
        DailyReminder.state = armedState
        DailyReminder.shared.noteAway(now: day0.adding(days: -3).date(minutes: 23 * 60))
        DailyReminder.shared.noteAway(now: day0.adding(days: -2).date(minutes: 9 * 60))
        let slept = DailyReminder.state
        DailyReminder.shared.noteBack(now: day0.date(minutes: 8 * 60))
        let woke = DailyReminder.state
        DailyReminder.shared.noteBack(now: day0.date(minutes: 9 * 60))
        let settledAfter = ReminderPlan.settle(woke, today: day0, wrote: [])
        check(slept.awaySince == ReminderPlan.Moment(day: day0.adding(days: -3), minute: 23 * 60)
              && woke.awaySince == nil && woke.unseen == [day0.adding(days: -2).key, day0.adding(days: -1).key]
              && DailyReminder.state == woke && settledAfter.ignored == 0 && !settledAfter.backingOff
              && DailyReminder.decodeState(defaults.string(forKey: DailyReminder.stateKey) ?? "") == woke,
              "提醒：合盖三天回来，这几天到点的落笔提醒记作没送到（\(woke.unseen.joined(separator: "、"))），不算没理会")
        DailyReminder.state = ReminderPlan.State()

        // 2. 登录项：调试实例只记开关，返回的状态跟着开关走
        let loginOn = LoginItem.setEnabled(true)
        let statusOn = LoginItem.status
        let loginOff = LoginItem.setEnabled(false)
        check(loginOn == .on && statusOn == .on && loginOff == .off && LoginItem.status == .off && !LoginItem.Status.off.isOn
              && LoginItem.Status.needsApproval.isOn,
              "登录项：调试实例不登记（\(LoginItem.debugNote)），开关只记在自己的偏好里")

        // 3. 周复盘的星期与时刻：按偏好读，认不出的回到周日 21:00
        check(ReviewReminder.weekday == 1 && ReviewReminder.minute == 21 * 60, "周复盘：没改过时是周日 21:00")
        defaults.set(3, forKey: ReviewReminder.weekdayKey)
        defaults.set(8 * 60 + 15, forKey: ReviewReminder.minuteKey)
        let picked = ReviewReminder.weekday == 3 && ReviewReminder.minute == 8 * 60 + 15
        defaults.set(9, forKey: ReviewReminder.weekdayKey)
        check(picked && ReviewReminder.weekday == 1, "周复盘：可选星期与时刻（周二 08:15），写坏的星期按周日")

        // 4. 通知代理按标识前缀分派
        let today = LocalDay.today()
        check(DailyReminder.handles(ReminderPlan.identifier(.write, day: today)) && DailyReminder.handles(ReminderPlan.identifier(.habits, day: today))
              && !DailyReminder.handles(ReviewReminder.identifier),
              "通知代理：apt.write. / apt.habits. 交给 DailyReminder，周复盘照旧")

        // 5. 通知里回复一句：入卷为今天的日记，修为照常 +5；空的不入卷
        let container = try DataStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        let effects = EffectsCenter()
        effects.motionEnabled = false
        let now = Date()
        let before = CultivationService.state(context: context).totalXP
        let entry = DailyReminder.handleReply(text: "  晚饭后散步，想清楚了论文第二节 \n", context: context, effects: effects, now: now)
        let gained = CultivationService.state(context: context).totalXP - before
        check(entry?.kindValue == .diary && entry?.body == "晚饭后散步，想清楚了论文第二节" && entry?.dateKey == LocalDay(date: now).key
              && entry?.minute == ClockTime.minutes(of: now) && entry?.mood == nil && context.all(JournalEntry.self).count == 1 && gained == 5,
              "落笔时辰：通知里回复的一句入卷为今天的日记，时刻记现在，修为 +\(gained)")
        check(DailyReminder.handleReply(text: " \n ", context: context, effects: effects) == nil && context.all(JournalEntry.self).count == 1,
              "落笔时辰：空的回复不入卷")

        // 6. 今天写没写：按 dateKey 只取这几天
        let wrote = DailyReminder.writtenDays(from: today.adding(days: -3), to: today, context: context)
        context.insert(JournalEntry(kind: .note, body: "前天的灵感", dateKey: today.adding(days: -2).key))
        context.insert(JournalEntry(kind: .diary, body: "上月的", dateKey: today.adding(days: -40).key))
        DataStore.save(context)
        let wrote2 = DailyReminder.writtenDays(from: today.adding(days: -3), to: today, context: context)
        check(wrote == [today] && wrote2 == [today, today.adding(days: -2)], "落笔时辰：只取待结算的这几天里写过的日子（不整表）")

        // 7. 功课时辰：今天还没圆满的功课（按先后）、以后几天有没有功课要做
        func habit(_ title: String, order: Int, target: Double? = nil, weekdays: [Int]? = nil) -> Habit {
            let h = Habit(title: title)
            h.sortOrder = order
            h.targetValue = target
            h.startDate = today.adding(days: -10).key
            if let weekdays {
                h.frequencyKind = .weekdays
                h.weekdays = weekdays
            }
            context.insert(h)
            return h
        }
        let empty = DailyReminder.habitOutlook(today: today, context: context)
        check(empty.pending.isEmpty && empty.days.isEmpty, "功课时辰：还没有功课时一条也不排")
        let otherDay = today.adding(days: 3).weekdayIndex
        _ = habit("冥想", order: 0, weekdays: [otherDay])
        let water = habit("喝水", order: 1, target: 8)
        let sleep = habit("早睡", order: 2)
        _ = habit("读书", order: 3)
        DataStore.save(context)
        let partial = HabitLog(dateKey: today.key, quantity: 3)
        partial.habit = water
        context.insert(partial)
        let done = HabitLog(dateKey: today.key)
        done.habit = sleep
        context.insert(done)
        DataStore.save(context)
        let outlook = DailyReminder.habitOutlook(today: today, context: context)
        check(outlook.pending == ["喝水", "读书"] && outlook.days.count == ReminderPlan.horizonDays - 1,
              "功课时辰：今天未圆满的是「\(outlook.pending.joined(separator: "」「"))」（喝水 3/8 不算圆满、早睡已打、冥想今天不用做）")
        check(ReminderPlan.habitsBody(pending: outlook.pending) == "还有「喝水」「读书」未圆满。", "功课时辰：通知正文写出实名")

        // 8. 点了通知：“今日免”只记回应（清零），“落一笔”的回复经 AppHost 的主 context 入卷
        // 上次关机前记下了睡下的时刻：这次启动时收尾
        var poweredOff = backoff
        poweredOff.awaySince = ReminderPlan.Moment(day: today.adding(days: -1), minute: 23 * 60)
        DailyReminder.state = poweredOff
        DailyReminder.shared.start(context: context, effects: effects)
        check(DailyReminder.state.awaySince == nil && DailyReminder.state.ignored == backoff.ignored,
              "提醒：启动时收尾上次关机（或合盖后没醒来）前记下的时刻")
        let todayID = ReminderPlan.identifier(.write, day: today)
        DailyReminder.shared.respond(identifier: todayID, action: DailyReminder.skipAction, text: nil)
        check(DailyReminder.state.answered == [today.key] && DailyReminder.state.ignored == 0 && context.all(JournalEntry.self).count == 3,
              "落笔时辰：点“今日免”只记一次回应（没理会清零），不入卷")
        DailyReminder.shared.respond(identifier: todayID, action: DailyReminder.replyAction, text: "通知里写的一句")
        check(context.all(JournalEntry.self).contains { $0.body == "通知里写的一句" && $0.kindValue == .diary && $0.dateKey == today.key },
              "落笔时辰：通知里“落一笔”回车即入卷")
        DailyReminder.shared.respond(identifier: "apt.weekly-review", action: DailyReminder.replyAction, text: "不该入卷")
        check(!context.all(JournalEntry.self).contains { $0.body == "不该入卷" }, "落笔时辰：别的通知不当成落笔回复")
    }
}
