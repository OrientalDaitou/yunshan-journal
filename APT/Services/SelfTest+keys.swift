import Foundation
import SwiftUI
import SwiftData
import AppKit
import Carbon.HIToolbox

// 快捷键一览的运行时自检：
// - 底本（Core/KeyMap）：同一处同时生效的组合键不重复、不占系统常用键、每个快捷键在一览里正好列一次、各页与 AppSection 对得上；
// - 换算：组合键换成 SwiftUI 的 KeyboardShortcut、从按键事件认回组合键、换成 Carbon 全局热键，都对得上；
// - 页面按键的守门：光标在输入框里、窗口不在前面时不接；
// - 真的挂上了：把十个页面、编辑弹窗、搜索窗、月历、随手记、渡劫画面离屏挂一遍，再取一遍菜单命令，
//   看界面里挂快捷键的地方（.keyCommand / .pageKeys / .keyNote，KeyBindingLog 记着）是不是把一览里列的每一项都挂上了。
// 用内存库和一个单独的临时偏好域（用完删掉），不碰正式数据。

extension SelfTest {
    static func keysChecks(_ check: (Bool, String) -> Void) throws {
        func detail(_ problems: [String]) -> String { problems.isEmpty ? "" : "：" + problems.prefix(4).joined(separator: "；") }

        // 1. 底本本身
        let conflicts = KeyMap.conflicts()
        check(conflicts.isEmpty, "快捷键：同一处同时生效的组合键没有重复（主窗口十页、弹窗、搜索窗、月历、随手记各查一遍）" + detail(conflicts))
        let reserved = KeyMap.reservedHits()
        check(reserved.isEmpty, "快捷键：不占系统常用键（⌘Q、⌘W、⌘Z、⌘C、⌘← 这类）" + detail(reserved))
        let guide = KeyMap.guideProblems()
        check(guide.isEmpty && KeyGuide.listed.count == KeyCommand.allCases.count,
              "快捷键一览：\(KeyCommand.allCases.count) 个快捷键各列一次，分 \(KeyGuide.sections.count) 组" + detail(guide))
        let sections = AppSection.allCases
        check(KeyMap.pageIDs == sections.map(\.rawValue) && sections.allSatisfy { KeyMap.pageTitles[$0.rawValue] == $0.title },
              "快捷键：底本里的侧栏各页与 AppSection 的次序、页名一致")
        let scopedPages = KeyCommand.allCases.flatMap(\.scopes).compactMap { scope -> String? in
            if case .page(let page) = scope { return page }
            return nil
        }
        let ornaments = KeyGuide.sections.map { section in
            section.page.flatMap { AppSection(rawValue: $0)?.ornament } ?? section.ornament ?? ""
        }
        check(scopedPages.allSatisfy { AppSection(rawValue: $0) != nil } && ornaments.allSatisfy { Scenery.image($0) != nil },
              "快捷键：各命令所在的页都存在，一览每组的小物插画都在包里")
        let pageCombos = sections.indices.map { KeyCommand.pageCombo(forPosition: $0 + 1) }
        check(pageCombos.allSatisfy { $0 != nil } && pageCombos.compactMap { $0 } == KeyCommand.pages.combos
              && Set(pageCombos.compactMap { $0 }).count == sections.count && KeyCommand.pages.display == "⌘1 … ⌘0",
              "快捷键：侧栏 \(sections.count) 页各有自己的 ⌘ 数字（⌘1…⌘9、⌘0），一览写作“⌘1 … ⌘0”")
        check(KeyCommand.composeSubmit.display == "⌘↩" && KeyCommand.copyForAI.display == "⇧⌘C" && KeyCommand.quickCapture.display == "⌥⌘J"
              && KeyCommand.weekPrev.display == "⌘[" && KeyCommand.entryExpand.display == "空格" && KeyCommand.searchMove.display == "↑ ↓",
              "快捷键：写法按 macOS 菜单的次序（⌥⌘J、⇧⌘C、⌘↩），空格、方向键写成中文与箭头")

        // 2. 换算：SwiftUI 的快捷键、按键事件、Carbon 热键
        let all = KeyCommand.allCases.flatMap { command in command.combos.map { (command, $0) } }
        let shortcutsMatch = all.allSatisfy { _, combo in
            let shortcut = combo.keyboardShortcut
            return shortcut.key == combo.keyEquivalent && shortcut.modifiers == combo.eventModifiers
        }
        let dialogKeys = KeyboardShortcut.defaultAction.key == KeyCommand.dialogConfirm.combo.keyEquivalent
            && KeyboardShortcut.defaultAction.modifiers.isEmpty && KeyCommand.dialogConfirm.combo.mods.isEmpty
            && KeyboardShortcut.cancelAction.key == KeyCommand.dialogCancel.combo.keyEquivalent
            && KeyboardShortcut.cancelAction.modifiers.isEmpty && KeyCommand.breakthroughClose.combo == KeyCommand.dialogCancel.combo
        check(shortcutsMatch && dialogKeys,
              "快捷键：\(all.count) 个组合键换成 SwiftUI 快捷键键位、修饰键不变；弹窗的回车 / Esc 与系统默认按钮、取消按钮是同一个键")
        let roundTrip = all.filter { _, combo in KeyCombo(event: keyEvent(combo)) != combo }
        check(roundTrip.isEmpty, "快捷键：按下每个组合键（模拟按键事件）都认得回来"
              + (roundTrip.isEmpty ? "" : "：认不出 " + roundTrip.map { $0.1.display }.joined(separator: "、")))
        let hot = QuickCapturePanel.carbonHotKey(for: QuickCapturePanel.hotKeyCombo)
        check(hot?.code == UInt32(kVK_ANSI_J) && hot?.modifiers == UInt32(cmdKey | optionKey)
              && QuickCapturePanel.carbonHotKey(for: KeyCombo(.return, .command)) == nil,
              "快捷键：随手记全局热键 ⌥⌘J 换成 Carbon 热键（字母键 J、⌘ 加 ⌥）；不是字母键的不注册")

        // 3. 页面按键的守门：光标在输入框里、窗口不在前面时不接
        let field = NSTextField(), editor = NSTextView()
        check(PageKeys.isTyping(editor) && PageKeys.isTyping(field) && !PageKeys.isTyping(nil) && !PageKeys.isTyping(NSView()),
              "页面按键：光标在文本框、正文框里时不接（方向键、空格、回车留给打字）")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        check(!PageKeys.accepts(keyEvent(KeyCombo(.down)), in: window), "页面按键：窗口不是键盘窗口时不接")
        window.close()

        // 4. 一览里列的每一项都真的挂上了
        KeyBindingLog.reset()
        try hostKeyedViews()
        _ = KeyMenuCommands(databaseOpen: true).body
        _ = QuickCapturePanel.hotKeyCombo
        let seen = KeyBindingLog.seen
        let missing = KeyGuide.listed.filter { !seen.contains($0) }
        check(missing.isEmpty, "快捷键一览：列出的 \(KeyGuide.listed.count) 项都在界面上挂着（十个页面、弹窗、搜索窗、月历、随手记、渡劫画面、菜单离屏挂一遍）"
              + (missing.isEmpty ? "" : "；没挂上：" + missing.map(\.title).joined(separator: "、")))
        let hooked = KeyGuide.listed.allSatisfy { command in
            switch command.hookup {
            case .pageKey: command.combo.isBare
            case .menu: command.scopes == [.menu]
            case .hotKey: command.scopes == [.system]
            case .button, .convention: true
            }
        }
        check(hooked, "快捷键：页面按键都是不带 ⌘ 的键（带 ⌘ 的挂在按钮上），菜单命令只在菜单里、全局热键只在系统里")
    }

    /// 模拟按下一个组合键（方向键、回车、空格、Esc 给真的按键码；字符键给字符）
    private static func keyEvent(_ combo: KeyCombo) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if combo.mods.contains(.command) { flags.insert(.command) }
        if combo.mods.contains(.shift) { flags.insert(.shift) }
        if combo.mods.contains(.option) { flags.insert(.option) }
        if combo.mods.contains(.control) { flags.insert(.control) }
        let code: Int, characters: String
        switch combo.key {
        case .character(let c): code = kVK_ANSI_A; characters = String(c)
        case .return: code = kVK_Return; characters = "\r"
        case .escape: code = kVK_Escape; characters = "\u{1B}"
        case .space: code = kVK_Space; characters = " "
        case .up: code = kVK_UpArrow; characters = "\u{F700}"
        case .down: code = kVK_DownArrow; characters = "\u{F701}"
        case .left: code = kVK_LeftArrow; characters = "\u{F702}"
        case .right: code = kVK_RightArrow; characters = "\u{F703}"
        }
        // 字符键用 A 的按键码：KeyCombo(event:) 对它只看字符
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                keyCode: UInt16(code))!
    }

    /// 把挂快捷键的界面都离屏挂一遍（窗口不显示、不截图）：十个页面（内存库里放一项功课、一篇日记、一笔手记账，
    /// 功课页的上下切换、账簿的月份箭头、长卷的工具条才会出现），再加编辑弹窗、搜索窗、月历、随手记、渡劫画面
    @MainActor
    private static func hostKeyedViews() throws {
        let container = try DataStore.makeContainer(inMemory: true)
        let context = container.mainContext
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        let today = LocalDay.today()
        let habit = Habit(title: "快捷键自检晨读")
        habit.startDate = today.adding(days: -3).key
        context.insert(habit)
        context.insert(JournalEntry(kind: .diary, body: "快捷键自检", dateKey: today.key))
        DataStore.save(context)
        _ = try FinanceService.mutate(context) {
            $0.transactions.append(ManualExpense.transaction(day: today, cents: 1850, category: "餐饮与外卖",
                                                             description: "快捷键自检", note: "", reason: "手动记账"))
        }

        // 偏好用自检的临时数据目录那一份（AppPreferences.defaults：自检一定设了 APT_STORE_DIR，是单独的偏好域，
        // 正式应用的偏好碰不到；万一是正式那份，就改用单独的自检偏好域）；先记下“旧版导入已问过”，挂主窗口时不弹导入预览
        let defaults = AppPreferences.suiteName != nil ? AppPreferences.defaults : UserDefaults(suiteName: "io.github.orientaldaitou.yunshan.selftest-keys")!
        defaults.set(true, forKey: "legacyPromptDismissed")
        defer { defaults.removeObject(forKey: "legacyPromptDismissed") }

        func host<V: View>(_ view: V, size: CGSize) {
            let root = view.modelContainer(container).defaultAppStorage(defaults)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            window.contentView = nil
            window.close()
        }

        for section in AppSection.allCases {
            host(RootView(initialSelection: section), size: CGSize(width: 1440, height: 920))
        }
        let effects = EffectsCenter()
        func sheet<V: View>(_ view: V) -> some View {
            view.yunshanSheet().environment(effects).environment(\.spiritMotion, false)
        }
        var day = today
        host(sheet(HabitEditor(habit: nil, nextSortOrder: 0)), size: CGSize(width: 900, height: 900))
        host(sheet(GlobalSearchView()), size: CGSize(width: 700, height: 600))
        host(sheet(MonthCalendar(selection: Binding(get: { day }, set: { day = $0 })) {}), size: CGSize(width: 400, height: 460))
        host(sheet(QuickCaptureView(onDone: {})), size: CGSize(width: 500, height: 420))
        // 渡劫画面：动效关着时是一张静态卡（挂 Esc 的那颗隐形按钮两种画面都有）
        effects.motionEnabled = false
        effects.breakthrough = "筑基"
        host(TribulationOverlay().environment(effects), size: CGSize(width: 900, height: 700))
        effects.breakthrough = nil
    }
}
