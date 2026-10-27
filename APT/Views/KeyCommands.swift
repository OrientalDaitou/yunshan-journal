import SwiftUI
import AppKit
import Carbon.HIToolbox

// 把 Core/KeyMap 里登记的快捷键挂到界面上：
// - 按钮：`.keyCommand(.newEvent)`（组合键从 KeyCommand 取，不在界面里另写一份）；
// - 页面按键：`.pageKeys([.entryNext: { … }])`，方向键、空格、回车这类不带 ⌘ 的键，光标不在输入框里时才接；
// - 系统本来的行为（月历方向键、随手记 Esc 收起……）：`.keyNote(.calendarMove)` 只登记，不另挂。
// 挂的时候顺手记一笔（KeyBindingLog）：运行时自检把各页离屏挂一遍，核对一览里列出的每一项都真的挂上了。

extension KeyCombo {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let c): KeyEquivalent(c)
        case .return: .return
        case .escape: .escape
        case .space: .space
        case .up: .upArrow
        case .down: .downArrow
        case .left: .leftArrow
        case .right: .rightArrow
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var modifiers: SwiftUI.EventModifiers = []
        if mods.contains(.command) { modifiers.insert(.command) }
        if mods.contains(.shift) { modifiers.insert(.shift) }
        if mods.contains(.option) { modifiers.insert(.option) }
        if mods.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }

    /// 从按键事件认出组合键：方向键、回车、空格、Esc 按键码认（不受输入法、键盘布局影响），其余按不带修饰键的字符认
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: KeyMods = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        let key: Key
        switch Int(event.keyCode) {
        case kVK_UpArrow: key = .up
        case kVK_DownArrow: key = .down
        case kVK_LeftArrow: key = .left
        case kVK_RightArrow: key = .right
        case kVK_Return, kVK_ANSI_KeypadEnter: key = .return
        case kVK_Space: key = .space
        case kVK_Escape: key = .escape
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1, let c = characters.first else { return nil }
            key = .character(c)
        }
        self.init(key, mods)
    }
}

extension KeyCommand {
    /// 按钮上挂的快捷键。弹窗的确认 / 取消用 SwiftUI 的 defaultAction / cancelAction（同样是回车 / Esc，另有默认按钮的样子，⌘. 也能取消）
    var shortcut: KeyboardShortcut {
        switch self {
        case .dialogConfirm: .defaultAction
        case .dialogCancel, .breakthroughClose: .cancelAction
        default: combo.keyboardShortcut
        }
    }

    /// 悬停提示：“新增日程（⌘N）”
    func help(_ text: String) -> String { "\(text)（\(display)）" }
}

/// 界面里挂上过的快捷键：运行时自检核对一览里的每一项都挂上了（正式使用时只是一个小集合，不影响什么）
enum KeyBindingLog {
    nonisolated(unsafe) private(set) static var seen: Set<KeyCommand> = []
    static func note(_ command: KeyCommand) { seen.insert(command) }
    static func reset() { seen = [] }
}

extension View {
    /// 挂上一览里登记的快捷键（组合键从 KeyCommand 取）
    func keyCommand(_ command: KeyCommand) -> some View {
        KeyBindingLog.note(command)
        return keyboardShortcut(command.shortcut)
    }

    /// 侧栏第 position 项（从 1 数）的切页键：⌘1…⌘9、⌘0；再往后的项不挂
    func keyCommand(_ command: KeyCommand, position: Int) -> some View {
        KeyBindingLog.note(command)
        return keyboardShortcut(KeyCommand.pageCombo(forPosition: position).map(\.keyboardShortcut))
    }

    /// 系统本来就有的按键行为（月历方向键、搜索框回车、随手记 Esc 收起……）：只登记，不另挂
    func keyNote(_ command: KeyCommand) -> some View {
        KeyBindingLog.note(command)
        return self
    }

    /// 页面按键：方向键、空格、回车这类不带 ⌘ 的键（见 PageKeys.accepts）。处理了返回 true（按键就此吞掉），
    /// 没处理（比如已在第一篇还按 ↑）返回 false，按键照常往下传
    func pageKeys(_ handlers: [KeyCommand: () -> Bool]) -> some View {
        handlers.keys.forEach(KeyBindingLog.note)
        return background(PageKeyHost(handlers: handlers).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// 页面按键的挂点：顺手取主窗口的 EffectsCenter（渡劫画面开没开），交给监听在按键那一刻去看
private struct PageKeyHost: View {
    var handlers: [KeyCommand: () -> Bool]
    @Environment(EffectsCenter.self) private var effects: EffectsCenter?

    var body: some View {
        PageKeyMonitor(handlers: handlers, effects: effects)
    }
}

/// 页面按键什么时候接
enum PageKeys {
    /// 主窗口是键盘窗口、上面没有弹窗或模态窗口、没盖着渡劫画面、光标不在输入框里（也没有输入法正在选字）时才接；
    /// 空格、回车不接按住不放的连发，打开了“键盘导航”（全键盘控制）时留给获得焦点的按钮
    @MainActor
    static func accepts(_ event: NSEvent, in window: NSWindow, effects: EffectsCenter? = nil) -> Bool {
        guard !covered(by: effects) else { return false }
        guard window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil, !isTyping(window.firstResponder) else { return false }
        if [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)),
           event.isARepeat || NSApp.isFullKeyboardAccessEnabled {
            return false
        }
        return true
    }

    /// 渡劫画面正盖着主窗口：页面按键一律不接（不然按空格想“继续”，会把底下刚打的卡取消掉、回车会在画面底下开修订弹窗）。
    /// 画面只认 Esc 与点击关闭；它自己 5.5 秒后散去，之后页面按键照常
    @MainActor
    static func covered(by effects: EffectsCenter?) -> Bool {
        effects?.breakthrough != nil
    }

    /// 正在输入框里打字（文本框、正文框的编辑器都是 NSText），或焦点在会自己用方向键、空格的控件上（NSControl：
    /// 日期选择、列表、下拉菜单，以及打开键盘导航时获得焦点的按钮）
    static func isTyping(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSControl
    }

    /// 点了列表里的一项（修行录的一篇、一项功课）：光标若还在落笔框、搜索框里，就让它离开，
    /// 之后的方向键、空格、回车交给页面（写到一半的内容都在草稿或绑定里，不会丢）
    @MainActor
    static func endTyping() {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil, window.firstResponder is NSText else { return }
        window.makeFirstResponder(nil)
    }
}

/// 页面按键的监听：挂在页面背后的一个空视图上，页面在时装、页面拆掉时摘；只认自己所在的那个窗口的按键。
/// 处理函数每次页面刷新都换成最新的（拿到的是页面当时的状态）
private struct PageKeyMonitor: NSViewRepresentable {
    var handlers: [KeyCommand: () -> Bool]
    /// 主窗口的 EffectsCenter（按键那一刻看渡劫画面开没开）；不在主窗口里时为 nil
    var effects: EffectsCenter?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.handlers = handlers
        context.coordinator.effects = effects
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handlers = handlers
        context.coordinator.effects = effects
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        weak var view: NSView?
        var handlers: [KeyCommand: () -> Bool] = [:]
        weak var effects: EffectsCenter?
        private var monitor: Any?

        @MainActor
        func install() {
            // 离屏截图不装事件监听
            guard monitor == nil, !RenderMode.offscreen else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // 页面没走正常的拆除（例如整个窗口被释放）时也摘掉监听
        deinit { remove() }

        @MainActor
        private func handle(_ event: NSEvent) -> Bool {
            guard let window = view?.window, event.window === window, PageKeys.accepts(event, in: window, effects: effects),
                  let combo = KeyCombo(event: event) else { return false }
            // 同一页里一个组合键只对应一个命令（KeyMap.conflicts 保证）
            guard let action = handlers.first(where: { $0.key.combos.contains(combo) })?.value else { return false }
            return action()
        }
    }
}

// MARK: - 菜单栏

/// 菜单栏里的快捷键：应用菜单“洞府设置… ⌘,”、帮助菜单“快捷键一览… ⌘/”（换掉系统默认那个打不开的“帮助”）
struct KeyMenuCommands: Commands {
    /// 数据库打开了（被单实例锁拦下、数据库打不开时没有洞府设置可去）
    var databaseOpen: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("洞府设置…") { Self.openSettings() }
                .keyCommand(.settings)
                .disabled(!databaseOpen)
        }
        CommandGroup(replacing: .help) {
            Button("快捷键一览…") { openWindow(id: KeyGuide.windowID) }
                .keyCommand(.keyGuide)
        }
    }

    /// 切到洞府设置：主窗口关着就重新打开，最小化了就还原。主窗口上正开着弹窗（编辑表单、修订、确认框、打卡数量框）时不切页，
    /// 只把窗口带到前面——切页会把弹窗连同里面没保存的内容一起关掉
    @MainActor
    static func openSettings() {
        if RootView.isPresentingModal {
            NSSound.beep()
        } else {
            AppRouter.shared.page = .data
        }
        AppRouter.showMainWindow()
    }
}
