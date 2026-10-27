import Foundation
import SwiftData
import AppKit

// 关键时刻的仪式（落笔入卷、功课圆满、朱印、渡劫时收起）的运行时自检：真 SwiftData、内存库，
// 只用 EffectsCenter 的内存状态和一个记录用的假播放器，不写偏好、不碰正式数据目录。
// 时间轴与规则本身在 Tools/CoreCheck 里测。

/// 记录用的假播放器：EffectsCenter.ritualPlayer 是弱引用，自检里要用局部常量拿住它
@MainActor
private final class RecordingRitualPlayer: RitualPlayer {
    var played: [EffectsCenter.Ritual] = []
    var seals = 0
    var cancelled = 0
    func play(_ ritual: EffectsCenter.Ritual) { played.append(ritual) }
    func playSeal(_ seal: EffectsCenter.Seal) { seals += 1 }
    func cancelAll() { cancelled += 1 }

    var consummations: Int { played.filter { if case .consummation = $0 { true } else { false } }.count }
}

extension SelfTest {
    static func ritualChecks(_ check: (Bool, String) -> Void) throws {
        let today = LocalDay.today()
        let config = CultivationConfig()
        func context() throws -> ModelContext {
            let c = ModelContext(try DataStore.makeContainer(inMemory: true))
            DataStore.settings(in: c)
            DataStore.profile(in: c)
            DataStore.save(c)
            return c
        }
        func habit(_ title: String, in c: ModelContext, kind: HabitFrequency = .daily) -> Habit {
            let h = Habit(title: title)
            h.frequencyKind = kind
            if kind == .weekly { h.targetPerWeek = 3 }
            h.startDate = today.adding(days: -10).key
            c.insert(h)
            DataStore.save(c)
            return h
        }
        func toggle(_ h: Habit, _ day: LocalDay, _ c: ModelContext, _ effects: EffectsCenter) {
            HabitActions.toggle(h, on: day, context: c, effects: effects, allHabits: c.all(Habit.self), config: config)
        }
        func isConsummation(_ ritual: EffectsCenter.Ritual?) -> Bool {
            if case .consummation = ritual { return true }
            return false
        }

        // 1–3. 两项“每天”的功课：打第一项不播；打完第二项（今天由未圆满变圆满）播一次；取消再打上不再播；补齐昨天不播
        let c = try context()
        let read = habit("仪式自检晨读", in: c), walk = habit("仪式自检散步", in: c)
        let effects = EffectsCenter()
        effects.motionEnabled = true
        let player = RecordingRitualPlayer()
        effects.ritualPlayer = player
        toggle(read, today, c, effects)
        check(player.played.isEmpty, "功课圆满：今天只打了一项，不播")
        toggle(walk, today, c, effects)
        check(isConsummation(player.played.last) && player.consummations == 1 && effects.lastRitual == player.played.last,
              "功课圆满：打完今天最后一项，播一次“四方灵光汇丹田、金符展开”")
        toggle(walk, today, c, effects)
        let offXP = CultivationService.fullState(context: c).perDay[today] ?? 0
        toggle(walk, today, c, effects)
        let onXP = CultivationService.fullState(context: c).perDay[today] ?? 0
        check(player.consummations == 1 && onXP - offXP == 30,
              "功课圆满：取消再打上不再播（每天一次），修为照常回到圆满（今日 \(offXP) → \(onXP)，含圆满 +20）")
        toggle(read, today.adding(days: -1), c, effects)
        toggle(walk, today.adding(days: -1), c, effects)
        check(player.consummations == 1, "功课圆满：在过去某天补齐不播")

        // 4. 只有“每周 N 次”的习惯：永远不算圆满
        let weeklyContext = try context()
        let weekly = habit("仪式自检运动", in: weeklyContext, kind: .weekly)
        let weeklyEffects = EffectsCenter()
        let weeklyPlayer = RecordingRitualPlayer()
        weeklyEffects.ritualPlayer = weeklyPlayer
        toggle(weekly, today, weeklyContext, weeklyEffects)
        check(weeklyPlayer.played.isEmpty && weeklyEffects.lastRitual == nil, "功课圆满：只有“每周 N 次”的习惯时不播")

        // 5. 关动效：不调播放器，只飘一行金字“功课圆满”
        let quietContext = try context()
        let quietHabit = habit("仪式自检冥想", in: quietContext)
        let quiet = EffectsCenter()
        quiet.motionEnabled = false
        let quietPlayer = RecordingRitualPlayer()
        quiet.ritualPlayer = quietPlayer
        toggle(quietHabit, today, quietContext, quiet)
        check(quietPlayer.played.isEmpty && quiet.toasts.contains { $0.text == "功课圆满" },
              "功课圆满：关闭动效时不放仪式，只飘一行“功课圆满”")

        // 6. 落笔入卷（动效开、登记了落笔框与“修行录”）：朱印交给图层画，另放纸卷合拢、飞入修行录
        let body = "  今天把第三章收尾了。\n \n\n明天开始写第四章。  "
        effects.ritualAnchors[.composer] = (UUID(), CGRect(x: 340, y: 420, width: 760, height: 60))
        effects.ritualAnchors[.chronicleNav] = (UUID(), CGRect(x: 18, y: 300, width: 264, height: 55))
        JournalActions.save(JournalEntry(kind: .diary, body: body), context: c, effects: effects)
        if case .inscription(let inscription) = player.played.last {
            check(inscription.preview == "今天把第三章收尾了。\n明天开始写第四章。" && inscription.kind == .diary
                  && inscription.slip != nil && inscription.target != nil && effects.lastRitual == player.played.last,
                  "落笔入卷：交给图层的纸笺是整理过的正文，带着落笔框与“修行录”的位置")
        } else {
            check(false, "落笔入卷：动效开时应放落笔仪式")
        }
        check(player.seals == 1 && effects.seal?.drawnByRitualHost == true, "落笔入卷：朱印改由仪式图层画，SwiftUI 版不再画")

        // 7. 关动效：不放仪式、不交给图层，SwiftUI 朱印照旧（关动效时直接落定）
        let sealsBefore = player.seals, playedBefore = player.played.count
        effects.motionEnabled = false
        JournalActions.save(JournalEntry(kind: .note, body: "关动效的灵感"), context: c, effects: effects)
        check(player.seals == sealsBefore && player.played.count == playedBefore && effects.seal != nil && effects.seal?.drawnByRitualHost == false,
              "落笔入卷：关闭动效时不放仪式，朱印照旧由 SwiftUI 画")

        // 8. 主窗口关着（没有图层）、动效开：落笔照常盖 SwiftUI 朱印不出错；凑成圆满退回飘字
        let headless = EffectsCenter()
        headless.motionEnabled = true
        JournalActions.save(JournalEntry(kind: .review, title: "自检复盘", body: "没有主窗口时入卷"), context: c, effects: headless)
        check(headless.seal?.text == "复盘" && headless.seal?.drawnByRitualHost == false && headless.lastRitual == nil,
              "落笔入卷：主窗口关着时不放仪式、不出错，朱印照旧")
        let headlessContext = try context()
        let lone = habit("仪式自检读书", in: headlessContext)
        toggle(lone, today, headlessContext, headless)
        check(headless.toasts.contains { $0.text == "功课圆满" } && headless.lastRitual == nil, "功课圆满：没有仪式图层时退回飘字")

        // 9. 渡劫一来，正在放的仪式淡掉
        effects.motionEnabled = true
        effects.celebrate(realm: "筑基")
        check(player.cancelled == 1, "渡劫开始时，正在放的落笔 / 圆满仪式收起")
        effects.breakthrough = nil

        // 10. 补卡不播：用 toggle 补过去三天
        let pastContext = try context()
        let past = habit("仪式自检补卡", in: pastContext)
        let pastEffects = EffectsCenter()
        let pastPlayer = RecordingRitualPlayer()
        pastEffects.ritualPlayer = pastPlayer
        for offset in 1...3 { toggle(past, today.adding(days: -offset), pastContext, pastEffects) }
        check(pastPlayer.played.isEmpty && pastEffects.lastRitual == nil, "功课圆满：补过去三天的卡不播")

        // 11. 真的图层宿主：放、定格都能建出图层，渡劫时收起不出错（只看图层树，不看画面）
        let host = RitualHostView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        host.layoutSubtreeIfNeeded()
        let hostEffects = EffectsCenter()
        hostEffects.motionEnabled = true
        hostEffects.ritualPlayer = host
        hostEffects.ritualAnchors[.composer] = (UUID(), CGRect(x: 340, y: 420, width: 760, height: 60))
        hostEffects.ritualAnchors[.chronicleNav] = (UUID(), CGRect(x: 18, y: 300, width: 264, height: 55))
        hostEffects.ritualAnchors[.dantian] = (UUID(), CGRect(x: 30, y: 150, width: 64, height: 64))
        // 放一场要在主线程上建层、取样关键帧：记下用时（点下去到提交的那几毫秒）
        var started = Date()
        hostEffects.stamp("入卷", at: CGRect(x: 980, y: 492, width: 120, height: 38), inscription: "图层自检", kind: .note)
        let inscriptionMs = Date().timeIntervalSince(started) * 1000
        started = Date()
        hostEffects.perfectDayChanged(day: today, wasPerfect: false, isPerfect: true)
        let consummationMs = Date().timeIntervalSince(started) * 1000
        func layerCount(_ layer: CALayer?) -> Int { (layer?.sublayers ?? []).reduce(1) { $0 + layerCount($1) } }
        let built = layerCount(host.layer)
        // 第二场（小图、字体都已备好）：平常每次落笔、打满功课时的用时
        hostEffects.perfectCelebratedDay = nil
        started = Date()
        hostEffects.stamp("复盘", at: CGRect(x: 980, y: 492, width: 120, height: 38), inscription: "图层自检第二场", kind: .review)
        let inscriptionWarmMs = Date().timeIntervalSince(started) * 1000
        started = Date()
        hostEffects.perfectDayChanged(day: today, wasPerfect: false, isPerfect: true)
        let consummationWarmMs = Date().timeIntervalSince(started) * 1000
        host.pose(.consummation(EffectsCenter.Consummation(dantian: CGRect(x: 30, y: 150, width: 64, height: 64), source: CGPoint(x: 900, y: 500))), at: 0.8)
        hostEffects.celebrate(realm: "金丹")
        check(built > 300 && isConsummation(hostEffects.lastRitual) && hostEffects.seal?.drawnByRitualHost == true,
              "仪式图层：落笔、朱印、圆满都建出了图层（共 \(built) 层），定格与收起不出错；建层提交用时 落笔 \(String(format: "%.1f", inscriptionMs)) ms、圆满 \(String(format: "%.1f", consummationMs)) ms（第二场 \(String(format: "%.1f", inscriptionWarmMs)) / \(String(format: "%.1f", consummationWarmMs)) ms）")
        hostEffects.breakthrough = nil
    }
}
