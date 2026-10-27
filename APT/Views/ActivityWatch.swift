import SwiftUI
import AppKit
import Combine

/// 主窗口此刻有没有人在看（#20 能耗）：近 3 分钟有没有操作、主窗口是不是被完全挡住。
/// 只管常驻循环层（页面底的云、光点、远山、星、晨雾，横幅光点，长卷金光呼吸）：没人看时停在当前画面，碰一下鼠标、敲一下键立刻接着飘。
/// RootView 另算 ambient = 动效开关 && 有人在看，只交给这几层（页面底按 ambient 注入 spiritMotion，横幅光点与金光呼吸看 someoneWatching）；
/// spiritMotion、effects.motionEnabled 仍是原义（动效开关 + 减少动态效果 + 窗口在前台），所以悬停浮起、切页、打卡圈、功课圆满、
/// 落印这些“人一动才有”的效果闲着时照旧，指针下的卡片不会因为闲满 3 分钟落下又弹起。
/// - 操作：本应用自己的鼠标、键盘、滚轮、修饰键事件（本地事件监视：只收本应用的事件，不要辅助功能权限）；
///   按键连抬键一起收：页面按键（↑↓、空格、←→）的 keyDown 可能被先排上的页面键监视吞掉，抬键没有哪个监视会吞，一定收得到。
///   回到前台、主窗口重新露出来也算一次。每次操作只记一个时间，不刷新界面；只有“闲着 ↔ 有人”翻转时才刷新一次
/// - 闲着：最长 30 秒看一次（离 3 分钟不到 30 秒时正好在 3 分钟那一刻看），已经闲着时不再定时
/// - 遮挡：只看这扇主窗口的 occlusionState（被别的应用窗口完全盖住、最小化、在别的桌面、锁屏）
/// 离屏截图不装任何监听，两样恒为假，动效照旧只由动效开关决定。
@MainActor
final class ActivityWatch: ObservableObject {
    /// 前台放着满 3 分钟没人碰
    @Published private(set) var idle = false
    /// 主窗口被完全挡住
    @Published private(set) var occluded = false

    /// 有人在看：没闲着、主窗口也露在外面
    var watched: Bool { !idle && !occluded }

    /// 最后一次操作（开机以来的秒数，与 NSEvent.timestamp 同一个钟）
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    /// 本地事件监视装上了没有（自检看）
    var monitoring: Bool { monitor != nil }
    private var monitor: EventMonitorToken?
    private var occlusion: AnyCancellable?
    private var activation: AnyCancellable?
    private var checkTask: Task<Void, Never>?
    private weak var window: NSWindow?

    /// 视图放进窗口 / 换窗口 / 拆掉时调用（ActivityProbe）。nil 表示主窗口没了：摘掉全部监听
    func attach(_ window: NSWindow?) {
        guard !RenderMode.offscreen else { return }
        guard let window else { return stop() }
        if window !== self.window {
            self.window = window
            // 鼠标在窗口里移动也要送到应用（本地监视才收得到）；SwiftUI 的悬停跟踪区不一定覆盖整扇窗
            window.acceptsMouseMovedEvents = true
            occlusion = NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
                .sink { [weak self] _ in self?.occlusionChanged() }
            // 窗口还没摆上屏时不看（会被当成“挡住”）：上屏那一刻系统会发通知
            if window.isVisible { occlusionChanged() }
        }
        start()
    }

    /// 摘掉监听、复位：主窗口关掉后不再定时，下次打开从“有人在看”开始
    func stop() {
        monitor = nil
        occlusion = nil
        activation = nil
        checkTask?.cancel()
        checkTask = nil
        window = nil
        set(idle: false)
        set(occluded: false)
    }

    /// 算作“有人在动”的事件。抬键、松开鼠标也算：应用里会吞键的本地监视（页面按键、搜索 ↑↓、快捷键一览）都只吞 keyDown，
    /// 同一种事件的几个本地监视谁先被调用随安装而变，排在后面就收不到被吞的那一下；抬键 / 松开没人吞，一定送得到
    static let activityEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                                        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                                        .otherMouseDragged, .keyDown, .keyUp, .scrollWheel, .flagsChanged, .magnify]

    private func start() {
        if monitor == nil {
            let token = NSEvent.addLocalMonitorForEvents(matching: Self.activityEvents) { [weak self] event in
                self?.noteActivity()
                return event
            }
            monitor = token.map(EventMonitorToken.init)
        }
        if activation == nil {
            // 从别的应用切回来（⌘Tab、点程序坞）本身就是在看
            activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in self?.noteActivity() }
        }
        noteActivity()
    }

    /// 有一次操作：记下时间；正闲着就立刻恢复，没在定时就排下一次检查
    func noteActivity(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastActivity = now
        set(idle: false)
        if checkTask == nil { scheduleCheck() }
    }

    private func scheduleCheck() {
        checkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.checkIdle() else { return }
                try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(2))
            }
        }
    }

    /// 看一眼闲没闲：满 3 分钟就记为闲着、不再定时（返回 nil），否则返回下一次检查的间隔（定时检查与自检调用）
    @discardableResult
    func checkIdle(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        let delay = MotionGate.nextCheck(now: now, lastActivity: lastActivity)
        if delay == nil {
            checkTask = nil
            set(idle: true)
        }
        return delay
    }

    private func occlusionChanged() {
        guard let window else { return }
        let hidden = MotionGate.isOccluded(onScreen: window.isVisible || window.isMiniaturized,
                                           visibleFlag: window.occlusionState.contains(.visible))
        // 重新露出来（挪开了挡着的窗口、解锁屏幕）算一次操作：不用再动一下鼠标才接着飘
        if occluded && !hidden { noteActivity() }
        set(occluded: hidden)
    }

    // 值没变就不赋：@Published 每赋一次都会让 RootView 重算一遍
    private func set(idle value: Bool) { if idle != value { idle = value } }
    private func set(occluded value: Bool) { if occluded != value { occluded = value } }
}

/// 本地事件监视的票根：释放时自动摘掉（ActivityWatch 被释放、或 stop() 置空时）
private final class EventMonitorToken {
    private let token: Any
    init(_ token: Any) { self.token = token }
    deinit { NSEvent.removeMonitor(token) }
}

/// 挂在主窗口根视图背后的空视图：把所在的窗口报给 ActivityWatch（放进窗口时装监听，拆掉时摘）。
/// 不接收点击、不画任何东西
struct ActivityProbe: NSViewRepresentable {
    let watch: ActivityWatch

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.watch = watch
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        guard view.watch !== watch else { return }
        view.watch = watch
        view.watch?.attach(view.window)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.watch?.stop()
    }

    final class ProbeView: NSView {
        weak var watch: ActivityWatch?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch?.attach(window)
        }
    }
}

private struct SomeoneWatchingKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 主窗口此刻有没有人在看（ActivityWatch.watched，RootView 注入；别处——离屏截图、随手记浮窗、菜单栏——恒为 true）。
    /// 只给常驻循环层用：横幅光点（Scenery）、长卷金光呼吸（BreathingGlow）。悬停、转场、仪式不要看它
    var someoneWatching: Bool {
        get { self[SomeoneWatchingKey.self] }
        set { self[SomeoneWatchingKey.self] = newValue }
    }
}
