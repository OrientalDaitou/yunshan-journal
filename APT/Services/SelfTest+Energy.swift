import SwiftUI
import AppKit

// #20 能耗（界面侧）的运行时自检：不弹窗口、不碰系统通知与登录项。
// 3 分钟、30 秒、遮挡与开关的组合这些判断在 Tools/CoreCheck（// MARK: e2-energy-ui）里测；这里测接上 AppKit 的那一段：
// ActivityWatch 挂上窗口后装了本地事件监视、打开了鼠标移动事件；满 3 分钟记为闲着、一次操作（真走 NSApp.sendEvent 的事件）
// 立刻恢复；页面按键的 keyDown 被别的本地监视吞掉时，抬键照样叫得醒；摘掉后复位。
// 挂一扇不上屏的主窗口（RootView）：闲满 3 分钟只停页面底与横幅的光点，effects.motionEnabled（打卡圈、功课圆满、悬停浮起
// 跟着的那个开关）不变；抬一下键立刻接着走。金光呼吸的 Core Animation 版：一直关着动效时不挂动画、停在 1 倍；打开后挂上呼吸
// （与原公式同一条曲线、30 帧、从 1 倍那一点接着长）；关掉 / 没人看时原地停（动画还在、只是暂停），再开接着走；深浅色换色。
// 这些只证明逻辑与接线。真窗口里的实测没做成：调试实例一直不是前台应用（系统一个通知弹框占着前台），所以“前台静置 3 分钟停、
// 一动即续、主窗口被完全挡住时停”，以及省下的显卡与 WindowServer 占用，都还待真窗口验证。

extension SelfTest {
    static func energyChecks(_ check: (Bool, String) -> Void) throws {
        // 1. ActivityWatch：挂上一扇不上屏的窗口
        let watch = ActivityWatch()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = false
        watch.attach(window)
        check(watch.monitoring && window.acceptsMouseMovedEvents && watch.watched,
              "能耗：主窗口挂上后装了本地事件监视、打开鼠标移动事件，开始时算“有人在看”")
        // 还没上屏的窗口不算被挡住（否则一启动动效就停）
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        check(!watch.occluded, "能耗：窗口还没摆上屏时不算被挡住")

        // 2. 满 3 分钟才记为闲着；之后不再定时
        let start = ProcessInfo.processInfo.systemUptime
        watch.noteActivity(at: start)
        let early = watch.checkIdle(now: start + 179)
        check(early == 1 && !watch.idle, "能耗：2 分 59 秒时还不算闲着，1 秒后再看一次（\(String(describing: early))）")
        let late = watch.checkIdle(now: start + MotionGate.idleAfter)
        check(late == nil && watch.idle && !watch.watched, "能耗：满 3 分钟记为闲着，动效视为关，不再定时")

        // 3. 一次真的操作（经 NSApp.sendEvent 分发的修饰键事件，不落到任何窗口）立刻恢复
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: 0) {
            NSApp.sendEvent(event)
        }
        check(!watch.idle && watch.watched, "能耗：闲着时来一次操作（本地事件监视收到）立刻恢复")

        // 3b. 页面按键（↑↓、空格、←→）的 keyDown 会被页面键监视吞掉（return nil），而几个本地监视谁先被调用随安装而变：
        //     抬键、松开鼠标也算操作，没有哪个监视吞它们，一定叫得醒
        check(ActivityWatch.activityEvents.contains(.keyUp) && ActivityWatch.activityEvents.contains(.leftMouseUp)
              && ActivityWatch.activityEvents.contains(.rightMouseUp) && ActivityWatch.activityEvents.contains(.keyDown),
              "能耗：活动监视收按键也收抬键、松开鼠标")
        func key(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                             isARepeat: false, keyCode: 49)
        }
        _ = watch.checkIdle(now: ProcessInfo.processInfo.systemUptime + MotionGate.idleAfter + 1)
        if let up = key(.keyUp) { NSApp.sendEvent(up) }
        check(!watch.idle, "能耗：闲着时只抬一下键（空格）也立刻恢复")
        // 吞 keyDown 的监视在活动监视前后各装一个：不论谁先被调用，按下的那一下都被吞掉，抬键照样送到
        // 照页面键监视（PageKeyMonitor）的样子：认出功课页的“打卡”键（空格）就吞掉
        let swallow: (NSEvent) -> NSEvent? = { event in
            KeyCombo(event: event).map(KeyCommand.habitCheckIn.combos.contains) == true ? nil : event
        }
        let swallowBefore = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: swallow)
        let paged = ActivityWatch()
        paged.attach(window)
        let swallowAfter = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: swallow)
        _ = paged.checkIdle(now: ProcessInfo.processInfo.systemUptime + MotionGate.idleAfter + 1)
        let wasIdle = paged.idle
        if let down = key(.keyDown) { NSApp.sendEvent(down) }
        if let up = key(.keyUp) { NSApp.sendEvent(up) }
        check(wasIdle && !paged.idle, "能耗：页面键监视吞掉了空格的 keyDown，抬键照样把闲着叫醒")
        _ = paged.checkIdle(now: ProcessInfo.processInfo.systemUptime + MotionGate.idleAfter + 1)
        if let release = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            NSApp.sendEvent(release)
        }
        check(!paged.idle, "能耗：松开鼠标也算一次操作")
        [swallowBefore, swallowAfter].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        paged.attach(nil)
        let resumed = watch.checkIdle()
        check(resumed.map { $0 > 20 && $0 <= MotionGate.checkEvery } == true,
              "能耗：恢复后从头计时，下一次最多 30 秒后再看（\(String(describing: resumed))）")

        // 4. 主窗口拆掉：摘掉监听、复位成“有人在看”（下次打开从头算）
        _ = watch.checkIdle(now: ProcessInfo.processInfo.systemUptime + MotionGate.idleAfter + 1)
        watch.attach(nil)
        check(!watch.monitoring && !watch.idle && !watch.occluded, "能耗：主窗口拆掉后摘掉监听并复位")
        window.close()

        // 5. 金光呼吸：Core Animation 版
        let host = BreathingGlowHostView(frame: NSRect(x: 0, y: 0, width: 130, height: 130))
        host.layout()
        host.configure(dark: false, animate: false)
        check(host.glow.animation(forKey: "breath") == nil
              && abs(host.glow.bounds.width - 104) < 0.5 && host.glow.position == CGPoint(x: 65, y: 65),
              "金光呼吸：一直关着动效时不挂动画、停在 1 倍；光团 104 点居中（视图大一圈，放大不被裁）")
        let lightColors = host.glow.colors as? [CGColor] ?? []
        let alphas = lightColors.map(\.alpha)
        check(alphas.count == 3 && abs(alphas[0] - 0.5) < 0.01 && abs(alphas[1] - 0.275) < 0.01 && alphas[2] == 0
              && host.glow.type == .radial && host.glow.locations == [0, 0.35, 1],
              "金光呼吸：与 SoftGlow 同一团光（透明度 0.5 / 0.275 / 0，位置 0 / 0.35 / 1，径向）")
        host.configure(dark: false, animate: true)
        let breath = host.glow.animation(forKey: "breath") as? CAKeyframeAnimation
        let values = (breath?.values as? [Double]) ?? []
        let curveOK = values.count == 25 && values.enumerated().allSatisfy { index, v in
            abs(v - MotionGate.Breath.scale(at: MotionGate.Breath.period * Double(index) / 24)) < 1e-9
        }
        check(breath != nil && curveOK && breath?.duration == MotionGate.Breath.period && breath?.repeatCount == .infinity
              && breath?.preferredFrameRateRange.maximum == 30 && host.layer?.speed == 1,
              "金光呼吸：打开动效挂上呼吸——原公式同一条曲线（0.9 ↔ 1.15、2.4 秒）、30 帧、在渲染进程里走")
        check(abs(MotionGate.Breath.scale(at: breath?.timeOffset ?? 0) - 1) < 1e-9, "金光呼吸：从 1 倍那一点接着长，不先跳回 0.9")
        host.configure(dark: false, animate: false)
        check(host.glow.animation(forKey: "breath") != nil && host.layer?.speed == 0, "金光呼吸：关掉 / 没人看时原地暂停（动画还在，不复位不跳）")
        host.configure(dark: false, animate: true)
        check(host.layer?.speed == 1 && host.glow.animation(forKey: "breath") != nil, "金光呼吸：再打开接着走")
        host.configure(dark: true, animate: true)
        let darkColors = host.glow.colors as? [CGColor] ?? []
        let lightFirst = lightColors.first.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        let darkFirst = darkColors.first.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        check(darkFirst != nil && lightFirst != nil && (darkFirst?.redComponent ?? 0) > (lightFirst?.redComponent ?? 1),
              "金光呼吸：深色换成月下的亮金（Theme.gold 深色值），浅色是赭金")

        // 6. 金光呼吸只多看一样“有人在看”：长卷特效开着、没人看时不挂呼吸（停在 1 倍）；有人看时照常呼吸
        func glowHost(watched: Bool) -> BreathingGlowHostView? {
            let view = BreathingGlow(size: 104).environment(\.annalsAnimate, true).environment(\.someoneWatching, watched)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(x: 0, y: 0, width: 130, height: 130)
            hosting.layoutSubtreeIfNeeded()
            return subviews(of: BreathingGlowHostView.self, in: hosting).first
        }
        let unwatched = glowHost(watched: false), watchedGlow = glowHost(watched: true)
        check(unwatched?.glow.animation(forKey: "breath") == nil && unwatched?.layer?.speed == 0
              && watchedGlow?.glow.animation(forKey: "breath") != nil && watchedGlow?.layer?.speed == 1,
              "金光呼吸：长卷特效开着、主窗口没人看时停着；有人看时呼吸")

        try mainWindowIdleChecks(check)
    }

    /// 挂一扇不上屏的主窗口（首页，动效开、窗口按在前台算）：闲满 3 分钟、一抬键时，各层与动效开关的样子
    private static func mainWindowIdleChecks(_ check: (Bool, String) -> Void) throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(true, "能耗：这台机器开着“减少动态效果”，主窗口动效本来就关，跳过闲置接线的检查")
            return
        }
        let container = try DataStore.makeContainer(inMemory: true)
        DataStore.settings(in: container.mainContext)
        DataStore.profile(in: container.mainContext)
        DataStore.save(container.mainContext)
        let defaults = AppPreferences.suiteName != nil ? AppPreferences.defaults : UserDefaults(suiteName: "io.github.orientaldaitou.yunshan.selftest-energy")!
        defaults.set(true, forKey: "legacyPromptDismissed")
        defer { defaults.removeObject(forKey: "legacyPromptDismissed") }

        let effects = EffectsCenter()
        let root = RootView(initialSelection: .overview, effects: effects)
            .environment(\.controlActiveState, .key)
            .modelContainer(container)
            .defaultAppStorage(defaults)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: 1440, height: 920)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            hosting.layoutSubtreeIfNeeded()
        }
        defer {
            window.contentView = nil
            window.close()
        }
        settle()
        let watch = subviews(of: ActivityProbe.ProbeView.self, in: hosting).first?.watch
        func speeds() -> [Float] { subviews(of: EmitterHostView.self, in: hosting).map { $0.layer?.speed ?? -1 } }
        let before = speeds()
        check(watch?.watched == true && effects.motionEnabled && before.count >= 2 && before.allSatisfy { $0 == 1 },
              "能耗：主窗口有人在看时，页面底与横幅的光点（\(before.count) 层）都在走，动效开关开")

        _ = watch?.checkIdle(now: ProcessInfo.processInfo.systemUptime + MotionGate.idleAfter + 1)
        settle()
        let idle = speeds()
        check(watch?.idle == true && idle.count == before.count && idle.allSatisfy { $0 == 0 },
              "能耗：闲满 3 分钟，页面底与横幅的光点原地停（\(idle)）")
        check(effects.motionEnabled,
              "能耗：闲着不改动效开关：打卡圈照放、功课圆满照放仪式，指针下的卡片与侧栏项不会落下又弹起")

        if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                     isARepeat: false, keyCode: 49) {
            NSApp.sendEvent(up)
        }
        settle()
        let resumed = speeds()
        check(watch?.idle == false && effects.motionEnabled && resumed.count == before.count && resumed.allSatisfy { $0 == 1 },
              "能耗：抬一下键，光点立刻接着走（\(resumed)）")
    }

    /// 视图树里某一类 AppKit 视图（NSViewRepresentable 放进去的那些）
    private static func subviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let hit = view as? T { found.append(hit) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
}
