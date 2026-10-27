import SwiftUI
import SwiftData

@main
struct APTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer?
    private let loadError: String?

    private let lockedOut: Bool

    init() {
        SelfTest.runIfRequested()
        // 同一份数据已经被另一个云山修习录进程打开（例如调试版和已安装版同时开着）：不打开数据库、不做恢复与备份，
        // 只说明情况，免得两个进程互相覆盖对方的修改。旧版已安装应用不持有单实例锁，所以拿到锁之后再看一眼
        // 有没有同一应用的其他进程真的开着这个数据库（新版第一次打开时会原地迁移，不能和开着它的旧版撞在一起）
        guard InstanceLock.acquire(), !InstanceLock.storeOpenByAnotherInstance() else {
            InstanceLock.release()
            container = nil
            loadError = nil
            lockedOut = true
            return
        }
        lockedOut = false
        // 上次在设置里选了“从备份恢复”：打开数据库之前先换上备份（现有数据整体移到 Backups/恢复前-…，不删除）
        let restore = BackupService.applyPendingRestoreIfNeeded()
        BackupService.lastRestoreOutcome = restore
        // 恢复没完成、原数据还有一部分留在“恢复前”文件夹里没能放回：这次不打开数据库。
        // 否则数据库不在原位时 SwiftData 会新建一个空库，传书、备份和你的记录都会写进这个空库里
        if let aside = restore?.dataLeftAside {
            container = nil
            loadError = "原数据还留在：\(aside.path)\n为免新建空数据库、在不完整的数据里继续记录，这次没有打开数据库。"
            return
        }
        do {
            let made = try DataStore.makeContainer()
            container = made
            loadError = nil
            AppDelegate.databaseOpen = true
            QuickCapturePanel.shared.container = made
            // 传书巡查、自动备份等后台服务挂在应用上，关掉主窗口也照常运行
            AppHost.shared.start(container: made)
        } catch {
            container = nil
            loadError = DataStore.describe(error)
        }
    }

    var body: some Scene {
        WindowGroup("云山修习录", id: "main") {
            Group {
                if let container {
                    RootView(effects: AppHost.shared.effects)
                        .modelContainer(container)
                        .frame(minWidth: 1120, minHeight: 760)
                } else if lockedOut {
                    InstanceLockedView()
                } else {
                    StoreErrorView(message: loadError ?? "未知错误")
                }
            }
            // 偏好设置（草稿、展开状态、历史最高境界……）：调试数据目录用独立的一份，见 AppPreferences
            .defaultAppStorage(AppPreferences.defaults)
        }
        // 隐藏系统标题栏：页面一直延伸到窗口顶端，不再有那条灰色标题条
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // 应用菜单“洞府设置… ⌘,”、帮助菜单“快捷键一览… ⌘/”（快捷键都登记在 Core/KeyMap）
            KeyMenuCommands(databaseOpen: container != nil)
        }

        // 快捷键一览：一张小卷（帮助菜单 ⌘/、洞府设置里那一行打开；只开一个，再按 ⌘/ 是把它带到前面）
        Window("快捷键一览", id: KeyGuide.windowID) {
            KeyGuideWindow(container: container)
                .defaultAppStorage(AppPreferences.defaults)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // 窗口菜单里不再另列一项（帮助菜单里已有）
        .commandsRemoved()

        // 菜单栏小窗：点小图标，上半段一眼看今天（功课一键打卡、下一项日程、今日已落），下半段即写随手记；
        // 记完、按 Esc 收起（见 Views/MenuBarPanel）。⌥⌘J 全局唤出的是只有随手记的浮窗。
        // 没打开数据库（被单实例锁拦下、数据库打不开）时不放图标：点开也是空的，还会和正在用的那个并排出现两个笔形图标
        MenuBarExtra(isInserted: .constant(container != nil)) {
            if let container {
                MenuBarPanel()
                    .modelContainer(container)
                    .defaultAppStorage(AppPreferences.defaults)
            }
        } label: {
            Image(systemName: "pencil.and.scribble")
                .accessibilityLabel("云山修习录 · 今日与随手记")
        }
        .menuBarExtraStyle(.window)
    }
}

/// 应用代理：只管“关掉最后一个窗口后要不要退出”。
/// 打开了数据库时不退出（和以前一样留在菜单栏，随手记、传书巡查、自动备份照常）；
/// 没打开数据库（被单实例锁拦下、数据库打不开）时，关掉说明窗口就退出，不在后台留一个什么都做不了、还占着“另一个进程”名头的进程。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// APTApp.init 打开数据库成功后设为 true
    nonisolated(unsafe) static var databaseOpen = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.databaseOpen
    }
}

/// 另一个云山修习录进程正在使用同一份数据：这个进程不打开数据库，只说明情况并提供退出。
/// 每 2 秒看一眼另一个还在不在：它退出后可以直接重新打开（这个进程的数据库是启动时决定的，要重开才用得上）。
struct InstanceLockedView: View {
    @State private var otherRunning = true

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 42)).foregroundStyle(Theme.gold)
            Text(otherRunning ? "另一个云山修习录正在使用这份数据" : "另一个云山修习录已经退出").font(.ysTitle)
            Text(otherRunning
                 ? "同一份数据同时被两个应用打开时，后保存的一方会覆盖另一方的修改，所以这个窗口没有打开数据库。\n请切换到已经开着的云山修习录（菜单栏的笔形图标也算），或先把它彻底退出，再打开这一个。"
                 : (DataStore.customDirectory == nil
                    ? "这个窗口是在它退出之前打开的，还没有打开数据库。点“重新打开”就能用这份数据。"
                    : "这个窗口是在它退出之前打开的，还没有打开数据库。请退出这个，再重新打开（调试数据目录不会自动重开）。"))
                .font(.ysCallout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("数据位置：\(DataStore.directory.path)").font(.ysCaption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if otherRunning {
                    Button("切换到已开着的那个") {
                        if let id = Bundle.main.bundleIdentifier {
                            let me = ProcessInfo.processInfo.processIdentifier
                            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                                .first { $0.processIdentifier != me }?.activate()
                        }
                    }
                    Button("退出这个") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
                } else if DataStore.customDirectory == nil {
                    Button("退出这个") { NSApp.terminate(nil) }
                    Button("重新打开") { AppHost.relaunch() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("退出这个") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 320)
        .task {
            // 只看有没有同一应用的别的进程（不去碰锁，免得正好挡住别的进程启动）；用别的数据目录的调试实例也算，宁可多等
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                otherRunning = AppHost.otherInstanceRunning
            }
        }
    }
}

/// 数据库打不开时不新建空库、不覆盖原文件：说明位置与原因，并可以从最近的备份恢复。
/// 恢复做到一半、原数据还有一部分留在“恢复前”文件夹里时，那个文件夹不列进备份（里面可能只有一部分原数据，
/// 当备份换上去会缺账簿或 -wal），改成单独的“放回原数据”，相当于取消这次恢复。
struct StoreErrorView: View {
    var message: String
    @State private var backups: [BackupService.Info] = []
    @State private var candidate: BackupService.Info?
    @State private var confirmPutBack = false
    @State private var note: String?

    /// 没能放回原处的原数据所在的“恢复前”文件夹
    private var leftAside: URL? { BackupService.lastRestoreOutcome?.dataLeftAside }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 42)).foregroundStyle(Theme.warning)
                Text("数据文件无法打开").font(.ysTitle)
                if let outcome = BackupService.lastRestoreOutcome {
                    Text(outcome.message).font(.ysCallout).foregroundStyle(outcome.succeeded ? Theme.jade : Theme.cinnabar)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                Text(message).font(.ysCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("数据位置：\(DataStore.storeURL.path)").font(.ysCaption).textSelection(.enabled)
                if let aside = leftAside {
                    // 恢复做到一半没能完成：原文件被移开过，不能说“没有改动原文件”
                    Text("为避免丢失数据，应用没有新建空数据库。下次打开应用时会再试一次完成这次恢复（原数据只移动、不删除）；也可以放回原数据、取消这次恢复，或从下面的备份恢复。")
                        .font(.ysCallout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([DataStore.directory]) }
                        Button("显示留在“恢复前”里的原数据") { NSWorkspace.shared.activateFileViewerSelecting([aside]) }
                    }
                    Button("放回原数据，取消这次恢复…") { confirmPutBack = true }
                        .confirmationDialog("把原数据放回原处？", isPresented: $confirmPutBack) {
                            Button("放回并重新打开") { restore(from: aside) }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("不再换上备份：应用会退出并重新打开，把留在 Backups/\(aside.lastPathComponent)/ 里的原数据移回数据文件夹（只移动、不删除）。")
                        }
                } else {
                    Text("为避免丢失数据，应用没有新建空数据库，也没有改动原文件。可以从下面的备份恢复：当前的数据文件会先整体移到 Backups/恢复前-<时间>/，不会删除。")
                        .font(.ysCallout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([DataStore.directory]) }
                }

                if !backups.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("最近的备份").font(.ysHeading)
                    VStack(spacing: 6) {
                        ForEach(backups.prefix(8)) { info in
                            HStack {
                                Text(DateText.display(info.date)).font(.ysCallout.monospacedDigit())
                                Text(info.kind.label).font(.ysCaption).foregroundStyle(.secondary)
                                Spacer()
                                Button("从此备份恢复…") { candidate = info }
                            }
                        }
                    }
                    .frame(maxWidth: 420)
                } else {
                    Text("没有找到可用的备份（\(BackupService.root.path)）。").font(.ysCaption).foregroundStyle(.secondary)
                }
                if let note { Text(note).font(.ysCallout).foregroundStyle(Theme.cinnabar).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            backups = BackupService.list().filter { info in !(leftAside.map { BackupService.sameFolder($0, info.url) } ?? false) }
        }
        .confirmationDialog("从这份备份恢复？", isPresented: Binding(isPresent: $candidate), presenting: candidate) { info in
            Button("恢复并重新打开", role: .destructive) { restore(from: info.url) }
            Button("取消", role: .cancel) {}
        } message: { info in
            Text("将使用 \(DateText.display(info.date)) 的\(info.kind.label)备份。应用会退出并重新打开：先把现在打不开的数据文件移到 Backups/恢复前-<时间>/，再换上这份备份。")
        }
    }

    /// 选“放回原数据”时传的是留着原数据的“恢复前”文件夹：BackupService 认得出来，下次启动只把原数据放回原处
    private func restore(from url: URL) {
        do {
            try BackupService.requestRestore(from: url)
            AppHost.relaunch()
        } catch {
            note = error.localizedDescription
        }
    }
}
