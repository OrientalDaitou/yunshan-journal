import Foundation

// 快捷键的唯一底本。每个快捷键只在这里定一次：哪几个键、写法、做什么、在哪里生效、怎么挂上去。
// 菜单命令、按钮的 .keyboardShortcut、页面按键（不带 ⌘ 的方向键、空格、回车）、全局热键都从这里取组合键，
// “快捷键一览”小卷（帮助菜单 ⌘/，洞府设置里也有入口）照 KeyGuide 分组列出——改键只改这里，一览不会和实际脱节。
// CoreCheck 核对：同一处同时生效的组合键不重复、不占系统常用键、写法与键位一致、每一项都在界面代码里挂上了；
// 运行时自检（SelfTest+keys）再把各页离屏挂一遍，看每一项是不是真的挂上了。
// 这里不引 SwiftUI / AppKit（CoreCheck 要用 swiftc 单独编译），换成 KeyboardShortcut、NSEvent 的部分在 Views/KeyCommands.swift。

/// 修饰键
struct KeyMods: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let control = KeyMods(rawValue: 1 << 0)
    static let option = KeyMods(rawValue: 1 << 1)
    static let shift = KeyMods(rawValue: 1 << 2)
    static let command = KeyMods(rawValue: 1 << 3)

    /// macOS 菜单里的写法与次序：⌃⌥⇧⌘
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// 一个组合键：按键 + 修饰键
struct KeyCombo: Hashable, Sendable {
    enum Key: Hashable, Sendable {
        /// 字母、数字、标点（字母一律写小写）
        case character(Character)
        case `return`, escape, space, up, down, left, right

        /// 一览与悬停提示里的写法
        var symbol: String {
            switch self {
            case .character(let c): String(c).uppercased()
            case .return: "↩"
            case .escape: "Esc"
            case .space: "空格"
            case .up: "↑"
            case .down: "↓"
            case .left: "←"
            case .right: "→"
            }
        }
    }

    var key: Key
    var mods: KeyMods

    init(_ key: Key, _ mods: KeyMods = []) {
        self.key = key
        self.mods = mods
    }

    /// ⌘ 加一个字符（extra 是另外再按的修饰键）
    static func command(_ character: Character, _ extra: KeyMods = []) -> KeyCombo {
        KeyCombo(.character(character), extra.union(.command))
    }

    var display: String { mods.symbols + key.symbol }

    /// 不带 ⌘ ⌃ ⌥ 的键（方向键、空格、回车、Esc）：在输入框里本来就有用处，页面按键只在光标不在输入框时才接
    var isBare: Bool { mods.intersection([.command, .control, .option]).isEmpty }
}

/// 快捷键在哪里生效（同一处同时生效的组合键不能重复，见 KeyMap.conflicts）
enum KeyScope: Hashable, Sendable {
    /// 菜单栏命令：哪个窗口在前都有效（弹窗开着时也是）
    case menu
    /// 全局热键：在别的应用里也有效
    case system
    /// 主窗口的任何一页
    case window
    /// 主窗口的某一页（AppSection 的 rawValue）
    case page(String)
    /// 盖在主窗口上的渡劫画面
    case breakthrough
    /// 弹窗（编辑表单、修订、导出、导入……）
    case dialog
    /// 全局搜索窗
    case search
    /// 月历（选日期的小窗）
    case calendar
    /// 随手记浮窗
    case quickCapture

    var label: String {
        switch self {
        case .menu: "菜单栏"
        case .system: "全局热键"
        case .window: "主窗口"
        case .page(let page): "主窗口 · \(KeyMap.pageTitles[page] ?? page)"
        case .breakthrough: "渡劫画面"
        case .dialog: "弹窗"
        case .search: "搜索窗"
        case .calendar: "月历"
        case .quickCapture: "随手记"
        }
    }
}

/// 快捷键怎么挂上去的
enum KeyHookup: Sendable {
    /// 菜单栏命令（APTApp 的 commands）
    case menu
    /// 按钮上的 .keyboardShortcut（界面里写 .keyCommand(…)）
    case button
    /// 页面按键（界面里写 .pageKeys([…])）：光标不在输入框里时才接
    case pageKey
    /// 全局热键（Carbon，随手记浮窗）
    case hotKey
    /// 系统本来的行为（弹窗回车确认、Esc 关闭、月历方向键……）：这里只登记写法，挂的地方用 .keyCommand / .keyNote 标出
    case convention
}

/// 应用里的全部快捷键（一览里的每一行都从这里来）
enum KeyCommand: String, CaseIterable, Sendable {
    // 全局
    case pages, search, keyGuide, settings, quickCapture
    // 落笔（今日洞府、修行录）
    case composeFocus, composeSubmit
    // 修行录
    case entryPrev, entryNext, entryExpand, entryOpen
    // 修士名帖
    case newGoal
    // 时辰卷
    case newEvent, weekPrev, weekNext, weekToday
    // 起居有常
    case newRoutine
    // 每日功课
    case newHabit, habitPrev, habitNext, habitCheckIn
    // 灵石账簿
    case newExpense, monthPrev, monthNext
    // 岁月长卷
    case yearPrev, yearNext, periodPrev, periodNext
    // 问道灵枢
    case copyForAI
    // 弹窗与浮窗
    case dialogConfirm, dialogCancel, searchMove, searchOpen, calendarMove, calendarPick
    case quickCaptureSubmit, quickCaptureClose, breakthroughClose

    struct Spec: Sendable {
        var combos: [KeyCombo]
        var title: String
        var scopes: [KeyScope]
        var hookup: KeyHookup
        /// 一览里标题后的小字
        var note: String? = nil
    }

    var spec: Spec {
        let journal: [KeyScope] = [.page("overview"), .page("chronicle")]
        switch self {
        case .pages:
            return Spec(combos: Self.pageCombos, title: "切换侧栏各页", scopes: [.window], hookup: .button, note: "侧栏自上而下")
        case .search:
            return Spec(combos: [.command("f")], title: "搜索全部记录", scopes: [.window], hookup: .button)
        case .keyGuide:
            return Spec(combos: [.command("/")], title: "快捷键一览", scopes: [.menu], hookup: .menu, note: "帮助菜单")
        case .settings:
            return Spec(combos: [.command(",")], title: "洞府设置", scopes: [.menu], hookup: .menu)
        case .quickCapture:
            return Spec(combos: [.command("j", .option)], title: "随手记", scopes: [.system], hookup: .hotKey, note: "在别的应用里也能唤出")
        case .composeFocus:
            return Spec(combos: [.command("n")], title: "跳到落笔框", scopes: journal, hookup: .button, note: "今日洞府与修行录")
        case .composeSubmit:
            return Spec(combos: [KeyCombo(.return, .command)], title: "落笔入卷", scopes: journal, hookup: .button)
        case .entryPrev:
            return Spec(combos: [KeyCombo(.up)], title: "上一篇", scopes: [.page("chronicle")], hookup: .pageKey)
        case .entryNext:
            return Spec(combos: [KeyCombo(.down)], title: "下一篇", scopes: [.page("chronicle")], hookup: .pageKey)
        case .entryExpand:
            return Spec(combos: [KeyCombo(.space)], title: "展开或收起这一篇", scopes: [.page("chronicle")], hookup: .pageKey)
        case .entryOpen:
            return Spec(combos: [KeyCombo(.return)], title: "修订这一篇", scopes: [.page("chronicle")], hookup: .pageKey)
        case .newGoal:
            return Spec(combos: [.command("n")], title: "新立目标", scopes: [.page("profile")], hookup: .button)
        case .newEvent:
            return Spec(combos: [.command("n")], title: "新增日程", scopes: [.page("schedule")], hookup: .button)
        case .weekPrev:
            return Spec(combos: [.command("[")], title: "上一周", scopes: [.page("schedule")], hookup: .button)
        case .weekNext:
            return Spec(combos: [.command("]")], title: "下一周", scopes: [.page("schedule")], hookup: .button)
        case .weekToday:
            return Spec(combos: [.command("t")], title: "回到本周", scopes: [.page("schedule")], hookup: .button)
        case .newRoutine:
            return Spec(combos: [.command("n")], title: "新增作息", scopes: [.page("routine")], hookup: .button)
        case .newHabit:
            return Spec(combos: [.command("n")], title: "新立功课", scopes: [.page("habits")], hookup: .button)
        case .habitPrev:
            return Spec(combos: [KeyCombo(.up)], title: "上一项", scopes: [.page("habits")], hookup: .pageKey)
        case .habitNext:
            return Spec(combos: [KeyCombo(.down)], title: "下一项", scopes: [.page("habits")], hookup: .pageKey)
        case .habitCheckIn:
            return Spec(combos: [KeyCombo(.space)], title: "给选中的功课打卡", scopes: [.page("habits")], hookup: .pageKey,
                        note: "再按一次取消；数量型直接按目标记满，已记了未达标的数量时弹出数量输入")
        case .newExpense:
            return Spec(combos: [.command("n")], title: "手记一笔", scopes: [.page("finance")], hookup: .button)
        case .monthPrev:
            return Spec(combos: [.command("[")], title: "上个月", scopes: [.page("finance")], hookup: .button)
        case .monthNext:
            return Spec(combos: [.command("]")], title: "下个月", scopes: [.page("finance")], hookup: .button)
        case .yearPrev:
            return Spec(combos: [.command("[")], title: "上一年", scopes: [.page("annals")], hookup: .button)
        case .yearNext:
            return Spec(combos: [.command("]")], title: "下一年", scopes: [.page("annals")], hookup: .button)
        case .periodPrev:
            return Spec(combos: [KeyCombo(.left)], title: "上一段", scopes: [.page("annals")], hookup: .pageKey)
        case .periodNext:
            return Spec(combos: [KeyCombo(.right)], title: "下一段", scopes: [.page("annals")], hookup: .pageKey, note: "全年与各季之间")
        case .copyForAI:
            return Spec(combos: [.command("c", .shift)], title: "复制给 AI", scopes: [.page("ai")], hookup: .button)
        case .dialogConfirm:
            return Spec(combos: [KeyCombo(.return)], title: "确认", scopes: [.dialog], hookup: .convention, note: "编辑、修订、导出等弹窗")
        case .dialogCancel:
            return Spec(combos: [KeyCombo(.escape)], title: "取消", scopes: [.dialog], hookup: .convention)
        case .searchMove:
            return Spec(combos: [KeyCombo(.up), KeyCombo(.down)], title: "搜索里选结果", scopes: [.search], hookup: .convention)
        case .searchOpen:
            return Spec(combos: [KeyCombo(.return)], title: "打开", scopes: [.search], hookup: .convention)
        case .calendarMove:
            return Spec(combos: [KeyCombo(.left), KeyCombo(.right), KeyCombo(.up), KeyCombo(.down)], title: "月历里换日子",
                        scopes: [.calendar], hookup: .convention)
        case .calendarPick:
            return Spec(combos: [KeyCombo(.return)], title: "选定", scopes: [.calendar], hookup: .convention)
        case .quickCaptureSubmit:
            // 四个按钮名的字间夹 U+2060（看不见）：一览里折行时整个词一起走，不折成“记入时辰 / 卷”
            return Spec(combos: [KeyCombo(.return, .command)], title: "随手记记下", scopes: [.quickCapture], hookup: .button,
                        note: "按认出的类型写“" + ["落笔入卷", "入账", "打卡", "记入时辰卷"]
                            .map { $0.map(String.init).joined(separator: "\u{2060}") }.joined(separator: " / ") + "”")
        case .quickCaptureClose:
            return Spec(combos: [KeyCombo(.escape)], title: "收起", scopes: [.quickCapture], hookup: .convention, note: "收起时写了一半的留在草稿里")
        case .breakthroughClose:
            return Spec(combos: [KeyCombo(.escape)], title: "关闭渡劫画面", scopes: [.breakthrough], hookup: .button)
        }
    }

    var combos: [KeyCombo] { spec.combos }
    /// 第一个组合键（只有一个键的命令就是它）
    var combo: KeyCombo { spec.combos[0] }
    var title: String { spec.title }
    var scopes: [KeyScope] { spec.scopes }
    var hookup: KeyHookup { spec.hookup }
    var note: String? { spec.note }

    /// 一览与悬停提示里的写法：⌘1…⌘0 这一组写成“⌘1 … ⌘0”，其余逐个列出
    var display: String {
        if self == .pages, let first = combos.first, let last = combos.last { return "\(first.display) … \(last.display)" }
        return combos.map(\.display).joined(separator: " ")
    }

    /// 侧栏第 position 项（从 1 数）的切页键：1–9 → ⌘1…⌘9，第 10 项 → ⌘0，再往后没有（见 NavShortcut）
    static func pageCombo(forPosition position: Int) -> KeyCombo? {
        NavShortcut.digit(forPosition: position).map { .command($0) }
    }

    /// ⌘1…⌘9、⌘0：数字行有几个就排几个
    private static var pageCombos: [KeyCombo] {
        (1...KeyMap.pageIDs.count).compactMap(pageCombo(forPosition:))
    }
}

// MARK: - 一览

/// “快捷键一览”小卷的分组与行：一行是一个命令，或成对的一组（上一篇 / 下一篇）
enum KeyGuide {
    struct Row: Identifiable, Sendable {
        var commands: [KeyCommand]
        var id: String { commands.map(\.rawValue).joined(separator: "+") }
        /// 每个命令一枚键帽（几个键的合成一枚：“⌘1 … ⌘0”“↑ ↓”）
        var caps: [String] { commands.map(\.display) }
        var title: String { commands.map(\.title).joined(separator: " / ") }
        /// 不带 ⌘ 的页面按键：光标在输入框里时不起作用
        var bare: Bool { commands.contains { $0.hookup == .pageKey } }
        /// 各命令的小字都留下（合成一行的两个键各有说明时用“；”连起来，不丢后一句）
        var note: String? {
            let notes = commands.compactMap(\.note)
            return notes.isEmpty ? nil : notes.joined(separator: "；")
        }
    }

    struct Section: Identifiable, Sendable {
        var title: String
        /// 本组对应的侧栏页（AppSection 的 rawValue）：小物插画用那一页的；nil 时用 ornament
        var page: String?
        var ornament: String?
        var rows: [Row]
        var id: String { title }
    }

    /// 帮助菜单打开的那个窗口（Window 场景的 id）
    static let windowID = "keys"

    static let sections: [Section] = [
        Section(title: "全局", ornament: "yunshan-ornament-compass-v1",
                rows: [Row(commands: [.pages]), Row(commands: [.search]), Row(commands: [.keyGuide]),
                       Row(commands: [.settings]), Row(commands: [.quickCapture])]),
        Section(title: "落笔", ornament: "yunshan-ornament-brush-v1",
                rows: [Row(commands: [.composeFocus]), Row(commands: [.composeSubmit])]),
        Section(title: "修行录", page: "chronicle",
                rows: [Row(commands: [.entryPrev, .entryNext]), Row(commands: [.entryExpand]), Row(commands: [.entryOpen])]),
        Section(title: "修士名帖", page: "profile", rows: [Row(commands: [.newGoal])]),
        Section(title: "时辰卷", page: "schedule",
                rows: [Row(commands: [.newEvent]), Row(commands: [.weekPrev, .weekNext]), Row(commands: [.weekToday])]),
        Section(title: "起居有常", page: "routine", rows: [Row(commands: [.newRoutine])]),
        Section(title: "每日功课", page: "habits",
                rows: [Row(commands: [.newHabit]), Row(commands: [.habitPrev, .habitNext]), Row(commands: [.habitCheckIn])]),
        Section(title: "灵石账簿", page: "finance", rows: [Row(commands: [.newExpense]), Row(commands: [.monthPrev, .monthNext])]),
        Section(title: "岁月长卷", page: "annals", rows: [Row(commands: [.yearPrev, .yearNext]), Row(commands: [.periodPrev, .periodNext])]),
        Section(title: "问道灵枢", page: "ai", rows: [Row(commands: [.copyForAI])]),
        Section(title: "弹窗与浮窗", ornament: "yunshan-ornament-letters-v1",
                rows: [Row(commands: [.dialogConfirm, .dialogCancel]), Row(commands: [.searchMove, .searchOpen]),
                       Row(commands: [.calendarMove, .calendarPick]), Row(commands: [.quickCaptureSubmit, .quickCaptureClose]),
                       Row(commands: [.breakthroughClose])]),
    ]

    /// 一览里列出的全部命令（按出现次序）
    static var listed: [KeyCommand] { sections.flatMap { $0.rows.flatMap(\.commands) } }

    /// 与组合键 combo 相同的各行（一览里按下某个键时，这几行一起亮）
    static func rows(matching combo: KeyCombo) -> Set<String> {
        Set(sections.flatMap(\.rows).filter { row in row.commands.contains { $0.combos.contains(combo) } }.map(\.id))
    }
}

// MARK: - 核对

enum KeyMap {
    /// 侧栏各页（AppSection 的 rawValue，自上而下）；运行时自检核对它和 AppSection.allCases 一致
    static let pageIDs = ["overview", "chronicle", "profile", "schedule", "routine", "habits", "finance", "annals", "ai", "data"]
    static let pageTitles = ["overview": "今日洞府", "chronicle": "修行录", "profile": "修士名帖", "schedule": "时辰卷", "routine": "起居有常",
                             "habits": "每日功课", "finance": "灵石账簿", "annals": "岁月长卷", "ai": "问道灵枢", "data": "洞府设置"]

    /// 同时生效的命令（一处一组）：主窗口每一页（菜单、全局热键、主窗口通用键、本页键、渡劫画面），
    /// 以及弹窗、搜索窗、月历、随手记（菜单、全局热键在这些窗口里也有效）
    static func liveTogether() -> [(context: String, commands: [KeyCommand])] {
        let everywhere: Set<KeyScope> = [.menu, .system]
        func live(_ scopes: Set<KeyScope>) -> [KeyCommand] {
            KeyCommand.allCases.filter { command in command.scopes.contains { scopes.contains($0) } }
        }
        var groups: [(context: String, commands: [KeyCommand])] = pageIDs.map { page in
            (KeyScope.page(page).label, live(everywhere.union([.window, .breakthrough, .page(page)])))
        }
        for scope in [KeyScope.dialog, .search, .calendar, .quickCapture] {
            groups.append((scope.label, live(everywhere.union([scope]))))
        }
        return groups
    }

    /// 撞车的组合键（空 = 没有）：同一处同时生效的两个命令用了同一个组合键，或一个命令里同一个键写了两遍
    static func conflicts() -> [String] {
        var problems: [String] = []
        for command in KeyCommand.allCases where Set(command.combos).count != command.combos.count {
            problems.append("「\(command.title)」里同一个组合键写了两遍")
        }
        for (context, commands) in liveTogether() {
            var owner: [KeyCombo: KeyCommand] = [:]
            for command in commands {
                for combo in command.combos {
                    if let other = owner[combo], other != command {
                        problems.append("\(context)：\(combo.display) 同时给了「\(other.title)」和「\(command.title)」")
                    } else {
                        owner[combo] = command
                    }
                }
            }
        }
        return problems
    }

    /// macOS 与文本编辑约定俗成的组合键：应用里的快捷键不去占（⌘F 本来就是“查找”、⌘, 本来就是“设置”，意思相同，不算占用）
    static let reserved: [(combo: KeyCombo, meaning: String)] = [
        (.command("q"), "退出"), (.command("w"), "关闭窗口"), (.command("h"), "隐藏应用"), (.command("h", .option), "隐藏其他应用"),
        (.command("m"), "最小化"), (.command("z"), "撤销"), (.command("z", .shift), "重做"), (.command("x"), "剪切"),
        (.command("c"), "拷贝"), (.command("v"), "粘贴"), (.command("v", [.option, .shift]), "粘贴并匹配样式"), (.command("a"), "全选"),
        (.command("`"), "切换同一应用的窗口"), (.command("f", .control), "全屏"), (.command("/", .shift), "帮助菜单里搜索"),
        (.command("e"), "用所选内容查找"), (.command("g"), "查找下一个"), (.command("g", .shift), "查找上一个"), (.command("j"), "跳到所选内容"),
        (.command(";"), "检查拼写"), (.command(";", .shift), "拼写和语法"), (.command("."), "取消"), (.command("p"), "打印"),
        (.command("s"), "存储"), (.command("o"), "打开"), (.command("q", .control), "锁定屏幕"),
        (.command("3", .shift), "截屏"), (.command("4", .shift), "截取所选部分"), (.command("5", .shift), "截屏工具"),
        (KeyCombo(.space, .command), "聚焦搜索"), (KeyCombo(.space, .control), "切换输入法"), (KeyCombo(.space, [.control, .command]), "表情与符号"),
        (KeyCombo(.escape, [.option, .command]), "强制退出"),
        (KeyCombo(.left, .command), "光标到行首"), (KeyCombo(.right, .command), "光标到行尾"),
        (KeyCombo(.up, .command), "光标到开头"), (KeyCombo(.down, .command), "光标到末尾"),
        (KeyCombo(.left, .option), "光标左移一个词"), (KeyCombo(.right, .option), "光标右移一个词"),
        (KeyCombo(.up, .option), "光标到段首"), (KeyCombo(.down, .option), "光标到段尾"),
    ]

    /// 占了系统常用键的命令（空 = 没有）
    static func reservedHits() -> [String] {
        KeyCommand.allCases.flatMap { command in
            command.combos.compactMap { combo in
                reserved.first { $0.combo == combo }.map { "「\(command.title)」用了 \(combo.display)（系统的“\($0.meaning)”）" }
            }
        }
    }

    /// 一览没列全或列重了的命令（空 = 每个命令正好列一次）
    static func guideProblems() -> [String] {
        let listed = KeyGuide.listed
        var problems: [String] = []
        for command in KeyCommand.allCases {
            let count = listed.filter { $0 == command }.count
            if count != 1 { problems.append("「\(command.title)」在一览里出现了 \(count) 次") }
        }
        for section in KeyGuide.sections where section.page == nil && section.ornament == nil {
            problems.append("「\(section.title)」没有小物插画")
        }
        for section in KeyGuide.sections where section.page.map({ !pageIDs.contains($0) }) ?? false {
            problems.append("「\(section.title)」对应的页不存在")
        }
        return problems
    }

    /// 界面代码里挂这个命令的写法（CoreCheck 在源码里找它们，找不到就是一览里列了却没挂上）。
    /// 按钮也可以交给一个带 `command:` 参数的小函数去挂（账簿、长卷的左右箭头）；真挂没挂上由运行时自检离屏核对
    static func hookupPatterns(_ command: KeyCommand) -> [String] {
        let name = command.rawValue
        switch command.hookup {
        case .menu, .button: return ["keyCommand(.\(name)", "command: .\(name)"]
        case .pageKey: return [".\(name):"]
        case .hotKey: return ["KeyCommand.\(name)"]
        case .convention: return ["keyCommand(.\(name)", "keyNote(.\(name)"]
        }
    }
}
