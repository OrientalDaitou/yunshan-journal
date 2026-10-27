import Foundation
import SwiftData

// #21 能耗（内存与后台）的运行时自检：传书巡查的门铃（InboxWatcher）与快照指纹里的作息一段。
// 门铃只在临时目录里测，不碰数据目录的收件箱、不跑巡查；自检模式下巡查本就不启动（这里也核对一遍）。
// 节奏的规矩（前台 3 秒、后台 60 秒兜底 / 没门铃 10 秒、等文件写稳、数据停稳再确认）在 Tools/CoreCheck（// MARK: e2-energy-bg）里测；
// “停稳”按钟点算（改动后满约 3 秒，门铃中途叫醒不提前重建，SnapshotCalm）在这里第 5 节测。
// 心境按钮去掉 .drawingGroup() 后两侧有没有细竖线，看离屏图：APT_RENDER_ONLY=sheets 的 sheet-light/dark-journal.png。

extension SelfTest {
    static func energy2Checks(_ check: (Bool, String) -> Void) throws {
        func ms(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }
        /// 转主线程的 run loop，直到 done 成立或超时，返回用了多少秒（门铃的事件在主队列上送达）
        func spin(until done: () -> Bool, seconds: Double = 2) -> Double {
            let start = Date()
            while !done() && Date().timeIntervalSince(start) < seconds { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return Date().timeIntervalSince(start)
        }

        // 0. 自检（以及离屏、命令行）模式下不巡查、不盯收件箱
        check(!CourierService.patrolling && !AppHost.shared.isRunning && InboxWatcher.openSources == 0,
              "能耗：自检模式下传书巡查不启动、收件箱没有门铃（开着的目录监视 \(InboxWatcher.openSources) 个）")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("apt-energy2-\(UUID().uuidString)", isDirectory: true)
        let inbox = base.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // 1. 目录门铃：投进一封当场就响，不等一轮
        let bell = InboxWatcher(observing: false)
        defer { bell.stop() }
        check(bell.watch(inbox) && bell.watching && InboxWatcher.openSources == 1, "门铃：盯上临时收件箱")
        let written = Date()
        try Data("{\"from\":\"自检\",\"items\":[]}".utf8).write(to: inbox.appendingPathComponent("a.json"))
        let heard = spin(until: { bell.rings > 0 })
        check(bell.rings > 0 && heard < 1, "门铃：投进一封后 \(ms(heard)) 内就响（不再等 3 秒一轮）")
        // 收录时延：响了之后等文件写稳（满 1 秒）再收，后台也一样；合计约 1–1.5 秒，在“约 3 秒内收录”之内
        let age = CourierService.settlingAge(in: inbox)
        let pace = CourierPace.next(foreground: false, watching: true, unsettled: false, settlingAge: age)
        let delay = Date().addingTimeInterval(pace.seconds).timeIntervalSince(written)
        check(age != nil && delay >= CourierPace.settle && delay < 2,
              "收录时延：后台投进一封约 \(String(format: "%.1f", delay)) 秒后收录（等写稳 1 秒，约 3 秒内）")
        check(CourierService.settlingAge(in: inbox, now: Date().addingTimeInterval(2)) == nil,
              "门铃：写稳满 1 秒的传书不再算“等写稳”（照常按 pendingFiles 收录）")

        // 2. 收件箱删掉重建：watch 认出换了目录节点，重新盯上（仍只开一个），照样响
        try FileManager.default.removeItem(at: inbox)
        _ = spin(until: { false }, seconds: 0.1)
        check(!bell.watch(inbox) && !bell.watching && InboxWatcher.openSources == 0, "门铃：收件箱不在时不盯（巡查会先建好再来）")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        check(bell.watch(inbox) && InboxWatcher.openSources == 1, "门铃：收件箱重建后重新盯上（仍只开一个监视）")
        let before = bell.rings
        try Data("{}".utf8).write(to: inbox.appendingPathComponent("b.json"))
        let again = spin(until: { bell.rings > before })
        check(bell.rings > before, "门铃：重建后的收件箱投进一封照样响（\(ms(again))）")

        // 3. 睡着时被叫醒：60 秒兜底的那一觉，门铃一响就醒；刚看过一轮又响，补足 0.5 秒间隔再看（一连串保存只多看一次）
        let sleeper = InboxWatcher(observing: false)
        defer { sleeper.stop() }
        var woke = false
        Task { @MainActor in
            await sleeper.wait(CourierPace.watched)
            woke = true
        }
        _ = spin(until: { false }, seconds: 0.2)
        sleeper.ring()
        let slept = spin(until: { woke }, seconds: 3)
        check(woke && slept < 0.5, "门铃：60 秒兜底的一觉，门铃一响 \(ms(slept)) 内醒来")
        var wokeAgain = false
        sleeper.ring()
        let start = Date()
        Task { @MainActor in
            await sleeper.wait(CourierPace.watched)
            wokeAgain = true
        }
        _ = spin(until: { wokeAgain }, seconds: 3)
        let gap = Date().timeIntervalSince(start)
        check(wokeAgain && gap >= CourierPace.minimumGap - 0.15 && gap < 1.5,
              "门铃：刚看完一轮又响，隔 \(ms(gap)) 再看（至少约 \(ms(CourierPace.minimumGap))，不连着空转）")

        // 4. 保存叫醒巡查；作息块不整表取进指纹，原地修改靠保存通知记下的时刻认出
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        let saves = InboxWatcher()
        defer { saves.stop() }
        let block = RoutineBlock(title: "能耗自检早课", kind: "study", weekday: 0, startMinute: 7 * 60, endMinute: 8 * 60)
        context.insert(block)
        let stampBefore = InboxWatcher.routineSavedAt
        DataStore.save(context)
        _ = spin(until: { saves.rings > 0 }, seconds: 1)
        check(saves.rings > 0 && InboxWatcher.routineSavedAt > stampBefore, "门铃：数据库一保存就叫醒巡查，并记下作息块随保存改动的时刻")
        let first = CourierService.fingerprint(context)
        block.title = "能耗自检晨读"
        DataStore.save(context)
        _ = spin(until: { false }, seconds: 0.05)
        let edited = CourierService.fingerprint(context)
        check(edited != first, "快照指纹：作息块原地改名（不动 createdAt）保存后指纹会变")
        let stampAfterEdit = InboxWatcher.routineSavedAt
        let ringsBefore = saves.rings
        context.insert(JournalEntry(kind: .diary, body: "能耗自检"))
        DataStore.save(context)
        _ = spin(until: { saves.rings > ringsBefore }, seconds: 1)
        check(saves.rings > ringsBefore && InboxWatcher.routineSavedAt == stampAfterEdit,
              "门铃：保存修行录也叫醒巡查，但不动作息块的改动时刻")
        context.delete(block)
        DataStore.save(context)
        _ = spin(until: { false }, seconds: 0.05)
        check(CourierService.fingerprint(context) != edited, "快照指纹：作息块增删后指纹会变（按条数与最近新建）")

        // 5. 停稳按钟点算（SnapshotCalm，巡查每轮就这样调它）：改了一块作息，0.6 秒后又被一声不改指纹的铃叫醒
        //    （点缓冲步进器会保存，但缓冲不进指纹；切走再切回也响铃），这一轮不重建；下一觉只睡到改动后满 3 秒，那时确认没再变才重建
        let calmBlock = RoutineBlock(title: "能耗自检午课", kind: "study", weekday: 1, startMinute: 13 * 60, endMinute: 14 * 60)
        context.insert(calmBlock)
        DataStore.save(context)
        _ = spin(until: { false }, seconds: 0.05)
        let steady = CourierService.fingerprint(context)
        let t0 = Date()
        var calm = SnapshotCalm(steady)
        check(calm.settled(steady, now: t0), "快照停稳：起步后指纹没变就算停稳（起步那一轮照常补上快照，与以前一样）")
        calmBlock.endMinute = 14 * 60 + 30
        DataStore.save(context)
        _ = spin(until: { false }, seconds: 0.05)
        let changed = CourierService.fingerprint(context)
        check(changed != steady && !calm.settled(changed, now: t0), "快照停稳：作息块改了的这一轮不重建")
        let settings = DataStore.settings(in: context)
        let ringsBeforeStep = saves.rings
        settings.bufferBeforeMinutes += 5
        DataStore.save(context)
        _ = spin(until: { saves.rings > ringsBeforeStep }, seconds: 1)
        let stepped = CourierService.fingerprint(context)
        check(saves.rings > ringsBeforeStep && stepped == changed, "门铃：点缓冲步进器会保存、叫醒巡查，但不改快照指纹")
        check(!calm.settled(stepped, now: t0.addingTimeInterval(0.6)),
              "快照停稳：改动后 0.6 秒又被不改指纹的铃叫醒，这一轮不重建（以前看相邻两轮一样就当场重建）")
        let rest = calm.pace(CourierPace.next(foreground: false, watching: true, unsettled: true), now: t0.addingTimeInterval(0.6))
        check(abs(rest.seconds - 2.4) < 0.001 && rest.tolerance <= 1,
              "快照停稳：那之后只睡到改动后满 3 秒（还剩 \(String(format: "%.1f", rest.seconds)) 秒），不多等一整轮")
        check(calm.pace(CourierPace.foreground, now: t0) == CourierPace.foreground && calm.pace(CourierPace.foreground, now: t0.addingTimeInterval(-5)) == CourierPace.foreground,
              "快照停稳：刚改完时照常 3 秒一轮；钟面倒拨时按常规节奏")
        check(!calm.settled(stepped, now: t0.addingTimeInterval(2.5)) && calm.settled(stepped, now: t0.addingTimeInterval(2.95)),
              "快照停稳：改动后 2.5 秒还不算停稳，掐着 3 秒醒来（差几毫秒）就算停稳、这一轮重建")
        // 改作息、点步进器交替进行：每改一次从头计时，最后一次改动后满 3 秒才重建一次（以前每一对操作都重建一次）
        var busy = SnapshotCalm("甲", changedAt: t0)
        let rounds: [(at: Double, seen: String)] = [(0.6, "甲"), (1.0, "乙"), (1.6, "乙"), (2.0, "丙"), (2.6, "丙"), (3.4, "丙"), (5.0, "丙")]
        let rebuilt = rounds.filter { busy.settled($0.seen, now: t0.addingTimeInterval($0.at)) }.map(\.at)
        check(rebuilt == [5.0], "快照停稳：改动与不改指纹的铃交替时只在最后一次改动后满 3 秒重建一次（重建于第 \(rebuilt) 秒）")
        var back = SnapshotCalm("甲", changedAt: t0)
        check(back.settled("甲", now: t0.addingTimeInterval(-10)), "快照停稳：钟面倒拨（改动时刻在未来）算停稳，不会一直不重建")
        context.delete(calmBlock)
        DataStore.save(context)
    }
}
