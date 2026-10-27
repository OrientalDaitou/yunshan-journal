import AppKit
import SwiftData

/// 应用级常驻服务：飞剑传书巡查（含快照刷新）、自动备份、每日提醒的重排、失去前台 / 退出前保存。
///
/// 不挂在主窗口上：关掉主窗口、只留菜单栏随手记时照常运行（以前挂在 RootView 的 .task 上，关窗就停）。
/// 在 APTApp.init 拿到数据库后启动一次；命令行模式（--self-test / --check-store / --render-pages / --add / --seed-demo）
/// 与离屏渲染时绝不启动，避免碰到正式的收件箱、快照与备份。
@MainActor
final class AppHost {
    static let shared = AppHost()

    /// 全应用唯一的特效中心：主窗口（传书笺、渡劫、落印）与后台巡查共用，窗口重新打开也是同一个
    let effects = EffectsCenter()
    private(set) var isRunning = false
    private var tasks: [Task<Void, Never>] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private init() {}

    /// 正常以图形界面启动（不是命令行工具模式、也不是离屏截图）
    static var isInteractiveLaunch: Bool {
        let args = CommandLine.arguments
        let tools = ["--self-test", "--check-store", "--render-pages", "--add", "--seed-demo"]
        return !RenderMode.offscreen && !tools.contains { args.contains($0) }
    }

    /// 启动后台服务；重复调用（例如窗口重新打开）不会再启动第二份。
    func start(container: ModelContainer) {
        guard !isRunning, Self.isInteractiveLaunch else { return }
        isRunning = true
        let context = container.mainContext
        let effects = self.effects

        // 通知代理要在启动完成前设置：应用没开时点“该写周复盘了”启动，这次点击也能直达复盘落笔。
        // 落笔时辰 / 功课时辰同理：先记下主 context，应用是被“落一笔”的回复拉起来的，这一句也能当场入卷
        // 点开周复盘提醒翻开七日小卷：现在只有修行录接收这个标志，所以切到修行录由它打开（今日洞府也接上后改回只设标志）
        DailyReminder.openWeekly = { DailyReminder.openWeeklyInChronicle() }
        ReviewReminder.shared.install()
        DailyReminder.shared.start(context: context, effects: effects)
        BackupService.cleanupLeftovers()

        // 传书巡查第一轮就可能记账：先建好设置与名帖、把旧版存档里的账本并入（与 RootView.bootstrap 相同，都可重复执行）。
        // 否则主窗口没出现时，传书里的一笔记账会先新建一本只有这一笔的账，旧版账簿就再也并不进来了
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        FinanceService.migrateArchivedLedgerIfNeeded(context)

        // 飞剑传书：每 3 秒看一次收件箱，数据有变化就刷新快照（主窗口关着时传书笺不显示，但照常收录）
        tasks.append(Task { @MainActor in
            await CourierService.run(context: context, effects: effects)
        })
        // 自动备份：启动后稍等片刻做当天的备份，之后每 30 分钟检查一次。
        // Task.sleep(for:) 用连续时钟，Mac 睡眠期间也计时；唤醒后另外立即检查一次。
        tasks.append(Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                BackupService.runIfDue(context: context)
                do { try await Task.sleep(for: .seconds(30 * 60)) } catch { return }
            }
        })
        // 全局热键 ⌥⌘J：等应用跑起来再注册（不依赖主窗口出现）
        Task { @MainActor in QuickCapturePanel.shared.registerHotKey() }

        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                BackupService.runIfDue(context: context)
            }
        }
        // 每日提醒（落笔时辰、功课时辰）重排：数据保存后（防抖 2 秒：写了一篇就撤掉今天那条、打卡圆满就不再催）、
        // 跨过午夜、改时区或系统时间、睡眠唤醒后。调试实例与离屏不碰系统通知（DailyReminder 里自己拦）
        observe(.default, ModelContext.didSave) { DailyReminder.shared.scheduleSoon() }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            observe(.default, name) { DailyReminder.shared.scheduleSoon(after: 1) }
        }
        // 睡下 / 关机前记下这一刻、醒来时收尾：这段里到点的落笔提醒没送到眼前，不算“没理会”（不然合盖几天回来就成了三日一问）
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) {
            DailyReminder.shared.noteAway()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willPowerOffNotification) {
            DailyReminder.shared.notePowerOff()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) {
            DailyReminder.shared.noteBack()
            DailyReminder.shared.scheduleSoon(after: 5)
        }
        // 落笔提醒刚改成三日一问：主窗口下次出现时飘一句（只说一次）
        observe(.default, NSWindow.didBecomeMainNotification) {
            guard let window = NSApp.mainWindow, !(window is NSPanel), window.frame.width > 800,
                  let notice = DailyReminder.shared.takeBackoffNotice() else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                effects.hint(notice, icon: "bell")
            }
        }
        // 失去前台、即将退出时把未保存的修改落盘（不只靠 SwiftData 约 40 秒一次的自动保存）
        for name in [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification] {
            observe(.default, name) {
                if context.hasChanges { DataStore.save(context) }
            }
        }
    }

    /// 同步回调（在发出通知的主线程上立刻执行，退出前的保存来得及完成）
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { action() }
            } else {
                Task { @MainActor in action() }
            }
        }
        observers.append((center, token))
    }

    // MARK: 重启与多开检查

    /// 同一个应用（同一 bundle id）的其他进程是否正在运行，例如 Xcode 调试版和已安装版同时开着
    static var otherInstanceRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// 退出后自动重新打开（用于从备份恢复）。调试时设置了 APT_STORE_DIR 的话只退出，不自动重开
    /// （重新打开不会带上这个环境变量，会误开正式数据）。返回是否会自动重开。
    @discardableResult
    static func relaunch() -> Bool {
        let debugStore = DataStore.customDirectory != nil
        var willReopen = false
        if !debugStore {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // 等本进程完全退出、数据库关闭后再打开；路径作为 $0 传入，不必担心空格与中文
            process.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                                 Bundle.main.bundleURL.path]
            do {
                try process.run()
                willReopen = true
            } catch {
                NSLog("APT 无法安排重新打开：\(error)")
            }
        }
        Task { @MainActor in NSApp.terminate(nil) }
        return willReopen
    }
}

/// 同一份数据只允许一个应用进程打开（例如 Xcode 调试版和已安装版都没设 APT_STORE_DIR 时）：
/// 两个进程同时开着同一个库时 SwiftData 不报冲突，后保存的会用它读到的旧内容整本覆盖另一个的修改（灵石账簿尤甚）。
/// 用数据目录里的 .instance.lock 做 flock 独占锁；进程退出（包括崩溃）时系统自动释放，不会留下“死锁”。
enum InstanceLock {
    private nonisolated(unsafe) static var descriptor: Int32 = -1

    static var lockURL: URL { DataStore.directory.appendingPathComponent(".instance.lock") }

    /// 拿到锁返回 true；另一个进程正占着这份数据时返回 false。
    /// 锁文件建不出来（权限等）、或所在磁盘不支持加锁（部分网络卷）时不拦，照常打开（另有 storeOpenByAnotherInstance 兜底）。
    static func acquire() -> Bool {
        if descriptor >= 0 { return true }
        try? FileManager.default.createDirectory(at: DataStore.directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            return true
        }
        let code = errno
        close(fd)
        // 只有“锁已被别的进程占着”（EWOULDBLOCK，即 EAGAIN）才算有人在用；其它错误说明这里加不了锁，不能因此永远打不开
        if code == EWOULDBLOCK { return false }
        NSLog("APT 单实例锁不可用（errno \(code)），照常打开")
        return true
    }

    /// 放开锁（这个进程决定不打开数据库时），免得它停在说明页上还挡着别的进程
    static func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// 同一应用（同一 bundle id）的其他进程里，有没有哪个正打开着这份数据库文件。
    /// 旧版已安装应用不持有 .instance.lock，光靠 flock 拦不住它：这里直接看对方进程打开着哪些文件（同一用户的进程不需要额外权限）。
    /// 只认真正打开着这个 APT.store 的进程：用别的 APT_STORE_DIR 的调试实例、停在“正在使用”说明页的进程都不算。
    /// 从备份恢复后自动重开时旧进程可能刚刚退出：发现有人开着时每 0.2 秒再看一次，最多约 2 秒。
    static func storeOpenByAnotherInstance(waitingUpTo seconds: Double = 2) -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        var file = stat()
        // 还没有数据库：谁也不可能开着它
        guard stat(DataStore.storeURL.path, &file) == 0 else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        func someoneHasIt() -> Bool {
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains { $0.processIdentifier != me && !$0.isTerminated && process($0.processIdentifier, hasOpen: file) }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while someoneHasIt() {
            guard Date() < deadline else { return true }
            usleep(200_000)
        }
        return false
    }

    /// 进程 pid 是否打开着 file 这个文件（按磁盘设备号与 inode 比较，不受路径写法、符号链接影响）
    static func process(_ pid: pid_t, hasOpen file: stat) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // 多留一些位置：两次调用之间对方可能又打开了文件
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
            let vnode = info.pvip.vip_vi.vi_stat
            if vnode.vst_ino == file.st_ino && vnode.vst_dev == UInt32(bitPattern: file.st_dev) { return true }
        }
        return false
    }
}
