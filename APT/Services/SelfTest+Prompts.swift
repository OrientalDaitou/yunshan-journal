import Foundation
import SwiftData
import SwiftUI
import AppKit

// r1-ritual（#4）的运行时自检：首页落笔卡的问心签、晨课一愿、晚课三省，以及“类型不再沿用”。
// 纯函数（时段、题库、轮换、合成格式、三格开不开）在 CoreCheck；这里核对写进偏好和修行录的那一半，
// 并把落笔卡在晨、昼、暮夜各挂一次，看框真的在不在、预填的是什么。
// 偏好用自检临时数据目录那一份（AppPreferences.defaults：自检一定设了 APT_STORE_DIR，是单独的偏好域），用过的键最后都清掉。

extension SelfTest {
    @MainActor
    static func promptsChecks(_ check: (Bool, String) -> Void) throws {
        let defaults = AppPreferences.suiteName != nil ? AppPreferences.defaults : UserDefaults(suiteName: "io.github.orientaldaitou.yunshan.selftest-prompts")!
        defer { clearRiteKeys(defaults) }
        clearRiteKeys(defaults)
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        let effects = EffectsCenter()
        effects.motionEnabled = false
        let today = LocalDay.today()

        // 1. 问心签：“答此签”写进正文入卷后记为今天答过；今天仍是这一签（卡上“今日已答”），一轮之后（154 天）半年内不再轮到它
        let slip = DailyRiteStore.slip(on: today, defaults: defaults)
        let diary = JournalEntry(kind: .diary, title: "", body: DailyPrompts.insertingAnswer(slip, into: "上午三个小时都在写论文"), dateKey: today.key)
        JournalActions.save(diary, context: context, effects: effects)
        let noted = DailyRiteStore.noteAnswer(body: diary.body, day: today, defaults: defaults)
        let lap = today.adding(days: DailyPrompts.rotation.count)
        let lapSlip = DailyRiteStore.slip(on: lap, defaults: defaults)
        check(noted == slip && DailyRiteStore.isAnswered(slip, on: today, defaults: defaults)
              && DailyRiteStore.slip(on: today, defaults: defaults) == slip
              && DailyPrompts.pick(on: lap) == slip && lapSlip != slip && lapSlip.category == slip.category
              && lapSlip != DailyPrompts.pick(on: lap.adding(days: 1)),
              "问心签：答签入卷后记为今天答过，今天仍是「\(slip.text)」，\(DailyPrompts.rotation.count) 天后轮到它时换成同一类的另一道（不是第二天那道）")
        check(DailyRiteStore.noteAnswer(body: "今天下午去了图书馆", day: today, defaults: defaults) == nil
              && DailyRiteStore.answered(defaults).count == 1, "问心签：不是在答签的正文不记")
        DailyRiteStore.skip(on: today, defaults: defaults)
        let swapped = DailyRiteStore.slip(on: today, defaults: defaults)
        check(swapped != slip && defaults.integer(forKey: DailyRite.skipKey(today)) == 1 && !DailyRiteStore.isAnswered(swapped, on: today, defaults: defaults),
              "换一签：今天的次数记在 prompts.skip.<日期>，换成「\(swapped.text)」")

        // 2. 晨课一愿：去掉空白、并成一行；立愿时顺手清掉过期的按日记录；撤去时连“已成与否”一起清
        defaults.set("旧愿", forKey: DailyRite.vowKey(today.adding(days: -90)))
        defaults.set(2, forKey: DailyRite.skipKey(today.adding(days: -1)))
        defaults.set("前天没立成的半句", forKey: DailyRite.vowDraftKey(today.adding(days: -2)))
        defaults.set("昨天的半句", forKey: DailyRite.vowDraftKey(today.adding(days: -1)))
        DailyRiteStore.setVow("  写完第三章\n3 页 ", on: today, defaults: defaults)
        check(defaults.string(forKey: DailyRite.vowKey(today)) == "写完第三章 3 页"
              && defaults.object(forKey: DailyRite.vowKey(today.adding(days: -90))) == nil
              && defaults.object(forKey: DailyRite.skipKey(today.adding(days: -1))) == nil
              && defaults.object(forKey: DailyRite.vowDraftKey(today.adding(days: -2))) == nil
              && defaults.string(forKey: DailyRite.vowDraftKey(today.adding(days: -1))) == "昨天的半句"
              && defaults.integer(forKey: DailyRite.skipKey(today)) == 1,
              "立今日一愿：写进 dashboard.vow.<日期>（并成一行），90 天前的愿、昨天的换签次数、前天的立愿草稿顺手清掉，今天的不动")
        defaults.set("1", forKey: DailyRite.vowDoneKey(today))
        DailyRiteStore.setVow("写完第三章 3 页", on: today, defaults: defaults)
        let keptDone = defaults.string(forKey: DailyRite.vowDoneKey(today)) == "1"
        DailyRiteStore.setVow("改成先读两篇文献", on: today, defaults: defaults)
        let changedDone = defaults.object(forKey: DailyRite.vowDoneKey(today)) == nil
        defaults.set("1", forKey: DailyRite.vowDoneKey(today))
        DailyRiteStore.setVow(" ", on: today, defaults: defaults)
        check(keptDone && changedDone
              && defaults.object(forKey: DailyRite.vowKey(today)) == nil && defaults.object(forKey: DailyRite.vowDoneKey(today)) == nil,
              "改愿：同一件事不动“已成”，换成另一件事“已成 / 未成”作废；撤去时愿与“已成与否”一起清掉")

        // 3. 晚课 21:30 合成：日省（复盘·日省）入今天，修为 +15；记下明日第一件事，三格草稿清空；修行录里有这篇就是“晚课已毕”
        check(!DailyRiteStore.eveningSaved(on: today, context: context), "晚课合成之前：今晚还不算已毕")
        DailyRiteStore.setVow("写完第三章 3 页", on: today, defaults: defaults)
        defaults.set("1", forKey: DailyRite.vowDoneKey(today))
        for field in ["done", "stuck", "next"] { defaults.set("草稿", forKey: DailyRite.eveningDraftKey(field)) }
        check(!DailyRiteStore.eveningDraftBlank(defaults), "三格写了字：不算空（跨过 05:00 也不收起）")
        let evening = DailyRiteActions.saveEvening(done: "第三章写到第 3 页", stuck: " ", next: "先改第二节", day: today, today: today,
                                                    now: today.date(minutes: 21 * 60 + 30), context: context, effects: effects, defaults: defaults)
        let entry = evening?.entry
        check(entry?.kindValue == .review && entry?.period == ReviewPeriod.day.rawValue && entry?.title == DailyRite.eveningTitle
              && entry?.body == "【今日一愿】写完第三章 3 页（已成）\n【所得】第三章写到第 3 页\n【下一步】先改第二节"
              && entry?.dateKey == today.key && entry?.minute == 21 * 60 + 30 && evening?.gain == JournalKind.review.xp,
              "晚课合成日省：复盘·日省「晚课 · 三省」入今天 21:30，正文带【今日一愿】【所得】【下一步】，修为 +\(evening?.gain ?? 0)")
        check(defaults.string(forKey: DailyRite.nextFirstKey(today)) == "先改第二节"
              && DailyRiteStore.eveningSaved(on: today, context: context) && DailyRiteStore.eveningDraftBlank(defaults)
              && ["done", "stuck", "next"].allSatisfy { defaults.string(forKey: DailyRite.eveningDraftKey($0)) == "" },
              "晚课合成后：记下“明日第一件事”（次日晨课的昨夜所定）、修行录里有了这篇就是今晚已毕，三格草稿清空")

        // 3b. 同一晚再写一篇、“明日第一件事”空着：不删掉第一篇定下的
        let again = DailyRiteActions.saveEvening(done: "又补了一张图", stuck: "", next: " ", day: today, today: today,
                                                  now: today.date(minutes: 22 * 60), context: context, effects: effects, defaults: defaults)
        check(again != nil && defaults.string(forKey: DailyRite.nextFirstKey(today)) == "先改第二节",
              "同一晚第二篇日省“明日第一件事”留空：第一篇定下的“先改第二节”照留")

        // 4. 凌晨 00:30、04:30 合成：都记在前一天、不记钟点；没写明日第一件事就不动已有的
        let yesterday = today.adding(days: -1)
        defaults.set("旧的", forKey: DailyRite.nextFirstKey(yesterday))
        let late = DailyRiteActions.saveEvening(done: "熬夜把图画完", stuck: "", next: "", day: DailyRite.ritualDay(minute: 30, today: today),
                                                today: today, now: today.date(minutes: 30), context: context, effects: effects, defaults: defaults)
        let dawn = DailyRiteActions.saveEvening(done: "天快亮了", stuck: "", next: "先睡一觉", day: DailyRite.ritualDay(minute: 4 * 60 + 30, today: today),
                                                today: today, now: today.date(minutes: 4 * 60 + 30), context: context, effects: effects, defaults: defaults)
        check(late?.entry.dateKey == yesterday.key && late?.entry.minute == nil && late?.entry.body == "【所得】熬夜把图画完"
              && dawn?.entry.dateKey == yesterday.key && dawn?.entry.minute == nil
              && defaults.string(forKey: DailyRite.nextFirstKey(yesterday)) == "先睡一觉"
              && DailyRiteStore.eveningSaved(on: yesterday, context: context),
              "凌晨 00:30、04:30 的晚课都记在前一天（不记钟点；与暮夜同在 05:00 分界）：04:30 写的明日第一件事，05:00 晨课就读得到")

        // 4b. 在修行录删掉那几篇晚课：今晚不再算已毕
        // 直接删（不走 JournalActions.delete：那会开 8 秒“撤销删除”的窗口，挡住别的自检里的换日）
        for saved in [entry, again?.entry].compactMap({ $0 }) { context.delete(saved) }
        DataStore.save(context)
        check(!DailyRiteStore.eveningSaved(on: today, context: context), "在修行录删掉今晚的“晚课 · 三省”：签回到“晚课 · 三省”（不再写已毕）")

        // 5. 三格全空：不入卷
        let before = context.all(JournalEntry.self).count
        let empty = DailyRiteActions.saveEvening(done: " ", stuck: "\n", next: "", day: today, today: today,
                                                 context: context, effects: effects, defaults: defaults)
        check(empty == nil && context.all(JournalEntry.self).count == before, "晚课三格全空：不合成、不入卷")

        // 6. 首页落笔卡在晨、昼、暮夜各挂一次：框在不在、预填的是什么、三格开不开
        try composerHostChecks(check, container: container, effects: effects, defaults: defaults, today: today)
    }

    // MARK: 挂落笔卡

    /// 挂着的落笔卡：可改偏好后再排一次版，看里面的输入框（SwiftUI 的 TextField 在 macOS 上是 NSTextField，按提示语认）
    @MainActor
    private final class HostedComposer {
        let window: NSWindow
        var kind: JournalKind

        init<V: View>(_ make: (Binding<JournalKind>) -> V, kind: JournalKind) {
            self.kind = kind
            let box = Box()
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            box.owner = self
            let binding = Binding(get: { box.owner?.kind ?? .diary }, set: { box.owner?.kind = $0 })
            let view = NSHostingView(rootView: make(binding).frame(width: 520))
            view.frame = CGRect(x: 0, y: 0, width: 560, height: 640)
            window.contentView = view
            settle()
        }

        private final class Box { weak var owner: HostedComposer? }

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        /// 提示语 → 框里此刻的字
        func fields() -> [String: String] {
            var found: [String: String] = [:]
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, field.isEditable, let placeholder = field.placeholderString {
                    found[placeholder] = field.stringValue
                }
                view.subviews.forEach(walk)
            }
            if let root = window.contentView { walk(root) }
            return found
        }

        /// 按一下 ⌘↩（落笔入卷），返回有没有按钮接
        func pressSubmit() -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "\r",
                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return false }
            let handled = window.contentView?.performKeyEquivalent(with: event) ?? false
            settle()
            return handled
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    private static func composerHostChecks(_ check: (Bool, String) -> Void, container: ModelContainer, effects: EffectsCenter,
                                           defaults: UserDefaults, today: LocalDay) throws {
        let savedMinute = SkyTime.fixedMinute
        defer { SkyTime.fixedMinute = savedMinute }
        let textKey = JournalDraft.key("dashboard", "text")
        let savedText = defaults.object(forKey: textKey)
        defer { defaults.set(savedText, forKey: textKey) }
        let context = container.mainContext
        let vowField = "今天最想做成的一件事是？"
        let eveningField = "今天做成了什么？哪怕一小步。"

        func host(minute: Int, kind: JournalKind, draft: String) -> HostedComposer {
            SkyTime.fixedMinute = Double(minute)
            defaults.set(draft, forKey: textKey)
            return HostedComposer({ binding in
                JournalComposer(kind: binding, compact: true)
                    .environment(effects)
                    .environment(\.spiritMotion, false)
                    .modelContainer(container)
                    .defaultAppStorage(defaults)
            }, kind: kind)
        }

        // 6a. ⌘↩ 在晨、昼、暮夜都挂在主按钮上；草稿空时类型回到日记，写了一半的保留
        for field in ["done", "stuck", "next"] { defaults.set("", forKey: DailyRite.eveningDraftKey(field)) }
        // 今天还没立愿（前面立过的撤去），全新自检库里也还没有今天、昨天的晚课
        defaults.removeObject(forKey: DailyRite.vowKey(today))
        for old in context.all(JournalEntry.self) where old.title == DailyRite.eveningTitle { context.delete(old) }
        DataStore.save(context)
        KeyBindingLog.reset()
        let morning = host(minute: 7 * 60 + 30, kind: .note, draft: "")
        let morningHooked = KeyBindingLog.seen.contains(.composeSubmit)
        let morningFields = morning.fields()
        morning.close()
        KeyBindingLog.reset()
        let noon = host(minute: 14 * 60, kind: .note, draft: "写了一半的灵感")
        let noonHooked = KeyBindingLog.seen.contains(.composeSubmit)
        let noonFields = noon.fields()
        noon.close()
        defaults.set("1", forKey: DailyRite.eveningOpenKey)
        KeyBindingLog.reset()
        let night = host(minute: 21 * 60 + 30, kind: .review, draft: "")
        let nightHooked = KeyBindingLog.seen.contains(.composeSubmit)
        let nightFields = night.fields()
        night.close()
        check(morningHooked && noonHooked && nightHooked,
              "首页落笔卡在晨 07:30、昼 14:00、暮夜 21:30（晚课三格开着）都挂得上，⌘↩ 都在主按钮上")
        check(morning.kind == .diary && night.kind == .diary && noon.kind == .note,
              "首页落笔类型不再沿用：草稿空时打开回到日记（灵感、复盘都回），写了一半的灵感保留")
        check(morningFields[vowField] != nil && noonFields[vowField] == nil && nightFields[eveningField] != nil && morningFields[eveningField] == nil,
              "首页落笔卡：07:30 有立愿框，14:00 没写过就不显示（不催），21:30 开关开着、正文空着时换成晚课三格："
              + "\(morningFields.keys.sorted()) / \(noonFields.keys.sorted()) / \(nightFields.keys.sorted())")

        // 6b. 立愿草稿按日期记：昨天写了一半的不预填到今天早上；“昨夜所定”只在昨夜那篇晚课还在时出现
        let yesterday = today.adding(days: -1)
        defaults.set("写完第三章 3 页", forKey: DailyRite.vowDraftKey(yesterday))
        defaults.removeObject(forKey: DailyRite.vowKey(today))
        let fresh = host(minute: 7 * 60 + 30, kind: .diary, draft: "")
        let freshVow = fresh.fields()[vowField]
        fresh.close()
        check(freshVow == "", "立愿草稿按日期记：昨天框里写了一半的，今天早上不预填（框是空的：\(freshVow ?? "没有框")）")

        // 6c. 过了 11:00 正写着的立愿草稿还在：框留着、字也在
        defaults.set("先读两篇文献", forKey: DailyRite.vowDraftKey(today))
        let afternoon = host(minute: 14 * 60, kind: .diary, draft: "")
        let afternoonVow = afternoon.fields()[vowField]
        afternoon.close()
        defaults.removeObject(forKey: DailyRite.vowDraftKey(today))
        check(afternoonVow == "先读两篇文献", "立愿框写了一半时过了 11:00 也留着（字还在：\(afternoonVow ?? "没有框")），不会整块消失")

        // 6d. 正文写了字进暮夜：不自动换三格；把正文清空的那一下也不突然换（只在进页、换时段时判定一次）
        let written = host(minute: 21 * 60 + 30, kind: .diary, draft: "白天写了一半的日记")
        let writtenOpen = written.fields()[eveningField] != nil
        defaults.set("", forKey: textKey)
        // 顺手改一下立愿草稿：框跟着出现，说明这张卡确实按新的偏好重排过了
        defaults.set("顺手一试", forKey: DailyRite.vowDraftKey(today))
        written.settle()
        let clearedFields = written.fields()
        let clearedOpen = clearedFields[eveningField] != nil
        written.close()
        defaults.removeObject(forKey: DailyRite.vowDraftKey(today))
        check(!writtenOpen && !clearedOpen && clearedFields[vowField] == "顺手一试",
              "暮夜正文框里写着字：不自动换成晚课三格；清空正文的那一下也不突然换（写着 \(writtenOpen)、清空后 \(clearedOpen)，卡已重排：\(clearedFields[vowField] ?? "没有")）")

        // 6e. 今晚已合成过：签写“晚课已毕”，再进页不自动打开三格
        let done = JournalEntry(kind: .review, title: DailyRite.eveningTitle, body: "【所得】画完了", dateKey: today.key)
        done.period = ReviewPeriod.day.rawValue
        context.insert(done)
        DataStore.save(context)
        let after = host(minute: 21 * 60 + 40, kind: .diary, draft: "")
        let afterOpen = after.fields()[eveningField] != nil
        after.close()
        context.delete(done)
        DataStore.save(context)
        check(!afterOpen, "今晚已有“晚课 · 三省”：再进首页不自动打开三格（签写“晚课已毕”，点签才再写一篇）")
        defaults.removeObject(forKey: DailyRite.eveningOpenKey)

        // 6f. 修行录（完整落笔框）入卷时正文以「签文」开头也算答过：首页“答此签”后“翻开修行录”，草稿带过去写完入卷的
        let page = "selftest-prompts"
        let slip = DailyPrompts.pick(on: today.adding(days: 3))
        defer { for field in ["title", "text", "tags", "mood", "period", "day", "kind"] { defaults.removeObject(forKey: JournalDraft.key(page, field)) } }
        defaults.set(DailyPrompts.insertingAnswer(slip, into: "在修行录里写完的"), forKey: JournalDraft.key(page, "text"))
        let chronicle = HostedComposer({ binding in
            JournalComposer(kind: binding, draftPage: page)
                .environment(effects)
                .environment(\.spiritMotion, false)
                .modelContainer(container)
                .defaultAppStorage(defaults)
        }, kind: .diary)
        let pressed = chronicle.pressSubmit()
        chronicle.close()
        let inChronicle = context.all(JournalEntry.self).first { DailyPrompts.answered(in: $0.body) == slip }
        check(pressed && inChronicle != nil && DailyRiteStore.answered(defaults)[slip.id] == today,
              "修行录落笔框入卷（⌘↩）时正文以「\(slip.text)」开头：也记为今天答过，首页不再显示“答此签”（按下 \(pressed)、入卷 \(inChronicle != nil)）")
        if let inChronicle {
            context.delete(inChronicle)
            DataStore.save(context)
        }
    }

    /// 清掉这一项用到的偏好（自检的临时偏好域里）
    @MainActor
    private static func clearRiteKeys(_ defaults: UserDefaults) {
        let prefixes = [DailyRite.vowPrefix, DailyRite.vowDonePrefix, DailyRite.nextFirstPrefix, DailyRite.skipPrefix,
                        DailyRite.answeredKey, DailyRite.eveningOpenKey, DailyRite.vowDraftPrefix, "draft.dashboard.evening."]
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
    }
}
