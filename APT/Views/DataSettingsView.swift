import SwiftUI
import SwiftData

/// 洞府设置：单列四组，按使用频率排序；每组一行可折叠的标题，折叠时显示一句状态摘要。
/// ①景致与提醒 ②数据与备份 ③修为与境界 ④旧卷。长段说明收进 ⓘ 悬停提示；
/// 成功的一句话反馈走窗口顶部的纸色小胶囊（effects.hint），出错的说明就地显示。
struct DataSettingsView: View {
    struct ImportRequest: Identifiable {
        var id = UUID()
        var url: URL
    }

    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @Query private var settingsList: [AppSettings]
    @Query(sort: \ImportReceipt.importedAt, order: .reverse) private var receipts: [ImportReceipt]
    @Query private var legacy: [LegacyRecord]
    @State private var importRequest: ImportRequest?
    @State private var browsingKind: String?
    /// 导出、备份、恢复出错的说明（就地显示在“数据与备份”里）
    @State private var storageError: String?
    /// 登录项的状态：页面出现、回到前台时读一次（去系统设置里允许之后回来就是新的），不在每次刷新时问系统
    @State private var loginStatus: LoginItem.Status = .off
    @State private var busy = false
    @State private var restoreCandidate: BackupService.Info?
    @State private var pendingRestore: URL?
    /// 下面这些都在 .task / onAppear 里算好存起来，不在每次刷新时重算（旧版账本 JSON 约 240KB）
    @State private var backups: [BackupService.Info] = []
    /// “从备份恢复”平时只列最近 20 份，点“较早的 N 份”再展开其余的（每周、迁移前、恢复前等较早的也都选得到）
    @State private var showAllBackups = false
    @State private var archiveCounts: [ArchiveCount] = []
    @State private var legacyLedgerCount: Int?
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(ReviewReminder.enabledKey) private var weeklyReminder = false
    @AppStorage(DailyReminder.writeKey) private var writeReminder = false
    @AppStorage(DailyReminder.writeMinuteKey) private var writeMinute = ReminderPlan.defaultWriteMinute
    @AppStorage(DailyReminder.habitsKey) private var habitsReminder = false
    @AppStorage(DailyReminder.habitsMinuteKey) private var habitsMinute = ReminderPlan.defaultHabitsMinute
    @AppStorage(DailyReminder.eventsKey) private var eventsReminder = false
    @AppStorage(DailyReminder.eventsLeadKey) private var eventsLead = ReminderPlan.defaultEventLead
    @AppStorage(DailyReminder.lookbackKey) private var lookbackReminder = false
    @AppStorage(OffsiteBackup.enabledKey) private var offsiteOn = false
    /// 每周另存选的文件夹、上次没存上的原因：收起时的摘要和标题旁的“存在哪里”跟着变
    @AppStorage(OffsiteBackup.pathKey) private var offsitePath = ""
    @AppStorage(OffsiteBackup.lastErrorKey) private var offsiteError = ""
    /// 天色随时辰（晨昼暮夜）；关掉后始终是白昼的景致
    @AppStorage("sky.followsClock") private var skyFollowsClock = true
    @Environment(\.spiritMotion) private var motion
    @Environment(\.openWindow) private var openWindow

    /// “从备份恢复”先列出的份数
    private static let recentBackupCount = 20

    private var legacyDefaultExists: Bool { FileManager.default.fileExists(atPath: LegacyReader.defaultDatabaseURL.path) }

    var body: some View {
        // 横幅只留一句短句（场景默认题词）
        PageScaffold(page: .data) {
            if let settings = settingsList.first {
                appearanceGroup(settings).ysEntrance(order: 0)
            }
            storageGroup.ysEntrance(order: 1)
            if let settings = settingsList.first {
                SettingsGroup(title: "修为与境界", summary: cultivationSummary(settings), storageKey: "settings.group.cultivation") {
                    CultivationSettingsForm(settings: settings)
                }
                .ysEntrance(order: 2)
            }
            legacyGroup.ysEntrance(order: 3)
        }
        .task(id: legacy.count) { summarizeArchive() }
        .onAppear {
            reloadBackups()
            loginStatus = LoginItem.status
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = LoginItem.status
        }
        .sheet(item: $importRequest) { LegacyImportSheet(url: $0.url, isFirstRun: false) {} }
        .confirmationDialog("从这份备份恢复？", isPresented: Binding(isPresent: $restoreCandidate),
                            presenting: restoreCandidate) { info in
            Button("恢复并重新打开应用", role: .destructive) { requestRestore(info) }
            Button("取消", role: .cancel) {}
        } message: { info in
            Text("将换成 \(DateText.display(info.date)) 的\(info.kind.label)备份。应用会退出并自动重新打开：打开数据库之前，先把现在的数据整体移到 Backups/恢复前-<时间>/（不会删除，之后还能再恢复回来），再换上这份备份。这份备份之后写的内容不在恢复后的数据里。"
                 + (AppHost.otherInstanceRunning ? "\n\n注意：另一个“云山修习录”进程正在运行（例如 Xcode 调试版），请先把它退出。" : ""))
        }
        .sheet(item: Binding(get: { browsingKind.map { KindBox(kind: $0) } }, set: { browsingKind = $0?.kind })) { box in
            LegacyArchiveBrowser(kind: box.kind, records: legacy.filter { $0.kind == box.kind })
        }
    }

    private struct ArchiveCount: Identifiable {
        var kind: String
        var count: Int
        var id: String { kind }
    }

    private struct KindBox: Identifiable {
        var kind: String
        var id: String { kind }
    }

    // MARK: ① 景致与提醒

    private func appearanceGroup(_ settings: AppSettings) -> some View {
        let mode = AppearanceMode(rawValue: appearanceRaw) ?? .system
        // 提醒只写开着的：“晨光 · 浅色 · 动效已开 · 落笔 21:30 · 周复盘已开”
        let reminders = ReminderPlan.summary(write: writeReminder ? writeMinute : nil, habits: habitsReminder ? habitsMinute : nil,
                                             events: eventsReminder ? eventsLead : nil, lookback: lookbackReminder,
                                             weekly: weeklyReminder, loginItem: loginStatus.isOn)
        let summary = ([mode.label, "动效\(settings.motionEnabled ? "已开" : "已关")"] + reminders).joined(separator: " · ")
        return SettingsGroup(title: "景致与提醒", summary: summary, storageKey: "settings.group.appearance") {
            VStack(alignment: .leading, spacing: 2) {
                FormRow(label: "外观") {
                    HStack(spacing: 10) {
                        SegmentedTabs(options: AppearanceMode.allCases.map { ($0.rawValue, $0.label) }, selection: $appearanceRaw)
                            .fixedSize()
                        InfoTip("晨光为浅色，月色为深色；顶栏右侧的日月图标也可随时切换。")
                    }
                }
                FormRow(label: "天色") {
                    HStack(spacing: 10) {
                        Toggle("随时辰变换晨昼暮夜", isOn: $skyFollowsClock)
                        InfoTip("清晨薄雾、黄昏霞光、入夜星河；关闭后始终是白昼的景致。")
                    }
                }
                FormRow(label: "动效") {
                    HStack(spacing: 10) {
                        Toggle("灵光、雾气、突破动画", isOn: Binding(get: { settings.motionEnabled }, set: {
                            settings.motionEnabled = $0
                            DataStore.save(context)
                        }))
                        InfoTip("系统开启“减少动态效果”时，动效会自动停下。")
                    }
                }
                ReminderRows(loginStatus: $loginStatus)
                FormRow(label: "随手记") {
                    Text("在任何地方按 \(KeyCommand.quickCapture.display)，或点菜单栏的笔形小图标")
                        .font(.ysCallout).foregroundStyle(Theme.text)
                        .help("不用打开主窗口，就能写一句或记一笔账")
                }
                FormRow(label: "时区") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.timezoneID).font(.ysCallout).foregroundStyle(Theme.text)
                        if settings.timezoneID != TimeZone.current.identifier {
                            Hint("本机当前时区为 \(TimeZone.current.identifier)。日程按本机时间显示。", tone: .warning)
                        }
                    }
                }
                FormRow(label: "快捷键") {
                    HStack(spacing: 10) {
                        Button { openWindow(id: KeyGuide.windowID) } label: { Label("快捷键一览…", systemImage: "keyboard") }
                            .buttonStyle(.yunshanCompact)
                            .help("各页的新建、切换、打卡都有快捷键，一张小卷全列出来")
                        Text(KeyCommand.keyGuide.display).font(.ysCaption.monospacedDigit()).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
    }

    // MARK: ② 数据与备份

    /// 只看每日、每周、手动：“恢复前”“升级前”“迁移前”是特殊时刻留的保险，不代表最近一次备份了现在的数据
    private var lastBackupText: String {
        backups.first(where: { $0.kind.isRoutine }).map { "最近备份 \(DateText.display($0.date))" } ?? "尚未备份"
    }

    /// 打开了每周另存且选过文件夹：数据不再“只在这台 Mac 上”
    private var offsiteActive: Bool { offsiteOn && !offsitePath.isEmpty }

    /// 收起时的摘要：每周另存这次没存上时换一句，并用警示色（展开后那一行写原因）
    private var storageSummary: String {
        let base = "\(lastBackupText) · 共 \(backups.count) 份"
        guard offsiteOn else { return base }
        return base + (offsiteError.isEmpty ? " · 每周另存已开" : " · 每周另存这次没存上")
    }

    private var storageGroup: some View {
        SettingsGroup(title: "数据与备份",
                      detail: offsiteActive ? "本机 · 每周另存" : "仅存本机",
                      hint: offsiteActive ? "数据在这台 Mac 上，另外每周整份存一份到「\(OffsiteBackup.displayName(offsitePath))」" : "数据只保存在这台 Mac 上",
                      summary: storageSummary, summaryWarning: offsiteOn && !offsiteError.isEmpty,
                      storageKey: "settings.group.storage", tier: .jade) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.inkSoft).accessibilityHidden(true)
                    Text(lastBackupText).font(.ysBody).monospacedDigit().foregroundStyle(Theme.ink)
                    Text("· 共 \(backups.count) 份").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                    InfoTip("每天自动备份一份（数据库、账簿与可读的 JSON），保留最近 \(BackupService.dailyKeep) 天与 \(BackupService.weeklyKeep) 周；装上新版本第一次打开时，还会在打开数据库之前先留一份“升级前”备份（保留 \(BackupService.upgradeKeep) 份）；新版本改了数据结构、要迁移数据库时另留一份“迁移前”备份，不自动删除。备份都在数据文件夹里，建议偶尔“另存一份”到 iCloud 云盘或外接硬盘。")
                }
                HStack(spacing: 10) {
                    Button { backupNow() } label: {
                        if busy { ProgressView().controlSize(.small) } else { Label("立即备份", systemImage: "externaldrive.badge.plus") }
                    }
                    .buttonStyle(.yunshanPrimary)
                    .disabled(busy)
                    Menu {
                        Button("打开备份文件夹") {
                            try? FileManager.default.createDirectory(at: BackupService.root, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(BackupService.root)
                        }
                        Button("另存一份到…") { saveCopyElsewhere() }
                            .disabled(busy)
                            .help("把此刻的数据整份备份到别的文件夹，例如 iCloud 云盘或外接硬盘")
                        Button("完整导出 JSON…") { exportJSON() }
                            .disabled(busy)
                        Divider()
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([DataStore.directory]) }
                            .help(DataStore.storeURL.path)
                    } label: {
                        HStack(spacing: 6) {
                            Text("更多")
                            Image(systemName: "chevron.down").font(.system(size: TypeSize.micro, weight: .semibold))
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    // 数据路径不明文显示：放在这里的悬停提示（菜单里的“在 Finder 中显示”可直接打开）
                    .help("打开备份文件夹、另存一份、完整导出 JSON、在 Finder 中显示。数据文件：\(DataStore.storeURL.path)")
                }
                OffsiteBackupRow()
                if let pendingRestore {
                    VStack(alignment: .leading, spacing: 8) {
                        Hint("已安排在下次打开时从「\(pendingRestore.lastPathComponent)」恢复", tone: .warning, symbol: "arrow.uturn.backward.circle")
                        HStack(spacing: 8) {
                            Button("立即重新打开") { AppHost.relaunch() }
                                .buttonStyle(.yunshanCompact)
                            Button("取消恢复") {
                                BackupService.cancelRestoreRequest()
                                self.pendingRestore = nil
                                storageError = nil
                                effects.hint("已取消恢复，数据保持原样")
                            }
                            .buttonStyle(.yunshanCompact)
                        }
                    }
                }
                if !backups.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 0) {
                            Hint("选一份备份，应用会重新打开并换上它；现在的数据会先整体移到“恢复前”文件夹，不会丢。")
                                .padding(.bottom, 6)
                            let shown = showAllBackups ? backups : Array(backups.prefix(Self.recentBackupCount))
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, info in
                                // 点一行先弹出确认，确认后才恢复
                                EditableRow(dividerAbove: index > 0, editLabel: "恢复这份备份…", action: { restoreCandidate = info }) {
                                    HStack(spacing: 12) {
                                        Text(DateText.display(info.date)).font(.ysCallout).monospacedDigit().foregroundStyle(Theme.ink)
                                        Text(info.kind.label).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                                        Spacer(minLength: 8)
                                        Text("恢复…").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                                    }
                                }
                            }
                            if backups.count > Self.recentBackupCount {
                                olderBackupsToggle(count: backups.count - Self.recentBackupCount)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("从备份恢复").font(.ysCallout).foregroundStyle(Theme.ink)
                    }
                }
                if let storageError { Hint(storageError, tone: .error) }
            }
        }
    }

    /// 列表末尾一行“较早的 N 份 ›”：点开列出其余的备份，再点收起（与账簿“已保留 N 项”同一种写法）
    private func olderBackupsToggle(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1)
            Button {
                withAnimation(motion ? Motion.standard : nil) { showAllBackups.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(showAllBackups ? "收起较早的 \(count) 份" : "较早的 \(count) 份").monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: TypeSize.micro, weight: .bold))
                        .rotationEffect(.degrees(showAllBackups ? -90 : 0))
                }
                .font(.system(size: TypeSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkSoft)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showAllBackups ? "只列最近 \(Self.recentBackupCount) 份" : "列出全部 \(backups.count) 份备份")
            .accessibilityValue(showAllBackups ? "已展开" : "已收起")
        }
    }

    private func reloadBackups() {
        backups = BackupService.list()
        pendingRestore = BackupService.pendingRestore
    }

    // MARK: ③ 修为与境界

    private func cultivationSummary(_ settings: AppSettings) -> String {
        let count = settings.realms.count
        let numerals = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        let realms = (1...numerals.count).contains(count) ? "\(numerals[count - 1])境" : "\(count) 境"
        return settings.cultivationEnabled ? "已启用 · 每日上限 \(settings.dailyCap) · \(realms)" : "未启用 · \(realms)"
    }

    // MARK: ④ 旧卷（导入旧版、导入记录、旧版存档、旧账簿）

    private var legacySummary: String {
        if let receipt = receipts.first {
            return "已于 \(LocalDay(date: receipt.importedAt).label(relativeTo: .today()))导入 · 存档 \(legacy.count) 条"
        }
        return legacy.isEmpty ? "尚未导入旧版数据" : "存档 \(legacy.count) 条"
    }

    /// 已经导入过时默认折叠（首次启动另有自动弹出的导入窗口，不依赖这里）
    private var legacyGroup: some View {
        SettingsGroup(title: "旧卷", summary: legacySummary, storageKey: "settings.group.legacy", defaultExpanded: receipts.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                SubHeading(title: "从旧版 APT 导入",
                           info: "旧版数据库只会被复制后读取，原文件不做任何改动。可以重复导入：已导入的记录会自动跳过，不会覆盖你在新版中的修改。")
                if legacyDefaultExists {
                    Hint("已找到旧版数据库", tone: .success)
                } else {
                    Hint("默认位置没有旧版数据库", symbol: "questionmark.circle")
                }
                AdaptiveButtonRow {
                    Button("导入旧版数据库…") { importRequest = ImportRequest(url: LegacyReader.defaultDatabaseURL) }
                        .disabled(!legacyDefaultExists)
                        .help(LegacyReader.defaultDatabaseURL.path)
                    Button("选择其他文件…") {
                        if let url = FilePanels.open(allowedExtensions: ["sqlite3", "sqlite", "db", "json"],
                                                     directory: LegacyReader.defaultDatabaseURL.deletingLastPathComponent()) {
                            importRequest = ImportRequest(url: url)
                        }
                    }
                    .help("支持旧版的 SQLite 数据库、备份（.sqlite3）以及 JSON 导出文件")
                }
                if !receipts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("导入记录").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                        ForEach(receipts) { receipt in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(receipt.summary).font(.ysCaption).foregroundStyle(Theme.inkSoft).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    // 路径、SHA 是机器信息，保留等宽
                                    Text("来源：\(receipt.sourcePath)\nSHA-256：\(receipt.sha256)").font(.ysCaption.monospaced()).foregroundStyle(Theme.inkSoft)
                                        .textSelection(.enabled)
                                }
                                .padding(.top, 4)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(DateText.display(receipt.importedAt)).font(.ysCallout).monospacedDigit()
                                    Text(receipt.sourceKind).font(.ysCallout).foregroundStyle(Theme.inkSoft)
                                }
                            }
                        }
                    }
                }
                Divider().opacity(0.6)
                SubHeading(title: "旧版存档", detail: "\(legacy.count) 条原始记录",
                           info: "旧版每张表、每个设置项都原样保存在这里，包括新版还没有对应界面的内容（如复盘、AI 分析历史）。以后的版本可以直接从这里重建。")
                if archiveCounts.isEmpty {
                    EmptyHint(symbol: "tray", text: "尚未导入")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(archiveCounts.enumerated()), id: \.element.id) { index, item in
                            EditableRow(dividerAbove: index > 0, editLabel: "查看", action: { browsingKind = item.kind }) {
                                HStack {
                                    Text(LegacyArchiveBrowser.label(for: item.kind)).font(.ysCallout).foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text("\(item.count) 条").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                                }
                            }
                            // 英文表名（如 ai_analysis_history）只在悬停时显示
                            .help(item.kind)
                        }
                    }
                }
                if let count = legacyLedgerCount {
                    HStack(alignment: .firstTextBaseline) {
                        Hint("旧版灵石账簿（\(count) 笔交易）已并入「灵石账簿」页，原始存档仍保留在这里", symbol: "yensign.circle")
                        Spacer(minLength: 8)
                        Button("打开账簿") { AppRouter.shared.page = .finance }.buttonStyle(.cardLink)
                    }
                }
            }
        }
    }

    /// 各类存档条数与旧版账本笔数：只在存档条数变化时算一次
    private func summarizeArchive() {
        archiveCounts = Dictionary(grouping: legacy, by: \.kind).map { ArchiveCount(kind: $0.key, count: $0.value.count) }.sorted { $0.kind < $1.kind }
        if let record = legacy.last(where: { $0.kind == "settings" && $0.legacyID == "finance_ledger_v1" }),
           let data = record.json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let transactions = object["transactions"] as? [Any] {
            legacyLedgerCount = transactions.count
        } else {
            legacyLedgerCount = nil
        }
    }

    // MARK: 动作

    /// 先让按钮显示“处理中”再做同步的重活（备份、导出要在主线程读数据库）
    private func runBusy(_ work: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            work()
            busy = false
        }
    }

    private func backupNow() {
        storageError = nil
        runBusy {
            do {
                let url = try BackupService.backup(context: context, kind: .manual)
                effects.hint("已备份：\(url.lastPathComponent)", icon: "checkmark.circle")
            } catch {
                storageError = error.localizedDescription
            }
            reloadBackups()
        }
    }

    private func exportJSON() {
        storageError = nil
        DataStore.save(context)
        do {
            let data = try DataExporter.fullExport(context: context)
            if let url = FilePanels.save(data: data, suggestedName: "APT-完整备份-\(LocalDay.today().key).json", allowedExtensions: ["json"]) {
                effects.hint("已导出：\(url.lastPathComponent)", icon: "checkmark.circle")
            }
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// 把此刻的数据整份备份到数据文件夹以外。不拿“最近一份备份”去复制：它可能是一天前的每日备份，
    /// 刚从备份恢复过时更可能是“恢复前”（已经换下来的旧数据）
    private func saveCopyElsewhere() {
        storageError = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "存到这里"
        panel.message = "选一个数据文件夹以外的位置（例如 iCloud 云盘或外接硬盘），此刻的数据会整份备份过去"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if destination.standardizedFileURL.path.hasPrefix(DataStore.directory.standardizedFileURL.path) {
            storageError = "请选数据文件夹以外的位置：放在里面的话，数据文件夹出问题时会一起丢失"
            return
        }
        runBusy {
            do {
                let copy = try BackupService.exportCurrent(context: context, to: destination)
                effects.hint("已另存到：\(destination.lastPathComponent)/\(copy.lastPathComponent)", icon: "checkmark.circle")
            } catch {
                storageError = "另存失败：\(error.localizedDescription)"
            }
        }
    }

    private func requestRestore(_ info: BackupService.Info) {
        storageError = nil
        do {
            DataStore.save(context)
            try BackupService.requestRestore(from: info.url)
            pendingRestore = info.url
            effects.hint(AppHost.relaunch() ? "正在重新打开应用并恢复…" : "已安排恢复：请重新打开应用完成恢复")
        } catch {
            storageError = error.localizedDescription
        }
    }
}

/// “每周自动另存一份到 [文件夹]”：默认关。打开时先选文件夹，选好立刻存第一份（看得到存成了没有）；
/// 之后每周第一次备份检查时由 OffsiteBackup 再存。存不成时不弹窗，只在这一行写“上次另存失败：原因”。
private struct OffsiteBackupRow: View {
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @AppStorage(OffsiteBackup.enabledKey) private var enabled = false
    @AppStorage(OffsiteBackup.pathKey) private var path = ""
    @AppStorage(OffsiteBackup.lastSuccessKey) private var lastSuccess: Double = 0
    @AppStorage(OffsiteBackup.lastErrorKey) private var lastError = ""
    @State private var working = false
    /// 选文件夹时的就地说明（例如选到了数据文件夹里面）
    @State private var choiceNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("每周自动另存一份到", isOn: Binding(get: { enabled }, set: { on in
                    if on {
                        // 弹出选文件夹的窗口放到这次点击处理完之后
                        Task { @MainActor in choose() }
                    } else {
                        enabled = false
                        choiceNote = nil
                    }
                }))
                .disabled(working)
                Button { choose() } label: {
                    Label(path.isEmpty ? "选择文件夹…" : OffsiteBackup.displayName(path), systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.yunshanCompact)
                .disabled(working)
                .help(path.isEmpty ? "选一个数据文件夹以外的位置，例如 iCloud 云盘或外接硬盘" : "\(path)\n点一下换一个文件夹")
                if working { ProgressView().controlSize(.small) }
                InfoTip("每周第一次备份检查时（打开应用后片刻、之后每 30 分钟、Mac 唤醒后），在选的文件夹里的“\(OffsiteBackup.containerName)”下整份存一份（和“另存一份到…”相同），只保留最近 \(OffsiteBackup.keep) 份，只删它自己存的那些。文件夹不在（例如外接硬盘没接上）时不打扰，下次检查再试。")
            }
            .frame(minHeight: 32)
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        if let choiceNote {
            Hint(choiceNote, tone: .warning)
        } else if enabled, !lastError.isEmpty {
            // 别处这份没存上：就地用警示色写一句，不弹窗打扰
            Hint("上次另存失败：\(lastError)", tone: .warning)
        } else if enabled, lastSuccess > 0 {
            Hint("上次另存 \(DateText.display(Date(timeIntervalSince1970: lastSuccess))) · 在“\(OffsiteBackup.containerName)”里，留最近 \(OffsiteBackup.keep) 份",
                 symbol: "checkmark.circle")
        } else if enabled {
            Hint("本周这份会在下次备份检查时存好", symbol: "clock")
        }
    }

    /// 选一个文件夹：选好就打开每周另存、马上存第一份；取消就保持原样
    private func choose() {
        guard !working else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        panel.prompt = "每周存到这里"
        panel.message = "选一个数据文件夹以外的位置（例如 iCloud 云盘或外接硬盘），每周会在里面的“\(OffsiteBackup.containerName)”里存一份，只留最近 \(OffsiteBackup.keep) 份"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if OffsiteBackup.isInsideDataFolder(destination) {
            choiceNote = "请选数据文件夹以外的位置：放在里面的话，数据文件夹出问题时会一起丢失"
            return
        }
        choiceNote = nil
        path = destination.path
        enabled = true
        working = true
        Task { @MainActor in
            // 先让小转圈显示出来，再做同步的重活（与“立即备份”相同）
            try? await Task.sleep(for: .milliseconds(60))
            let outcome = OffsiteBackup.perform(context: context, destination: destination)
            OffsiteBackup.record(outcome)
            if case .saved(let made) = outcome {
                effects.hint("已另存到：\(OffsiteBackup.displayName(destination.path))/\(OffsiteBackup.containerName)/\(made.lastPathComponent)",
                             icon: "checkmark.circle")
            }
            working = false
        }
    }
}

/// 设置页的一组：玉简 / 纸笺卡，标题行整行可点、折叠或展开；折叠时右侧显示一句状态摘要。
/// 展开状态记在偏好设置里（storageKey），没记过时用 defaultExpanded。
struct SettingsGroup<Content: View>: View {
    var title: String
    /// 标题旁只放状态（如“仅存本机”）
    var detail: String
    /// 悬停标题时的说明
    var hint: String
    /// 折叠时显示的一句状态摘要
    var summary: String
    /// 摘要用警示色（朱砂）：有件事需要人看一眼，例如每周另存这次没存上
    var summaryWarning: Bool
    var tier: CardTier
    private let defaultExpanded: Bool
    private let content: () -> Content
    /// "" 没记过（用 defaultExpanded）；"1" 展开；"0" 折叠
    @AppStorage private var stored: String
    @Environment(\.spiritMotion) private var motion

    init(title: String, detail: String = "", hint: String = "", summary: String, summaryWarning: Bool = false, storageKey: String,
         defaultExpanded: Bool = true, tier: CardTier = .paper, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.hint = hint
        self.summary = summary
        self.summaryWarning = summaryWarning
        self.tier = tier
        self.defaultExpanded = defaultExpanded
        self.content = content
        _stored = AppStorage(wrappedValue: "", storageKey)
    }

    private var expanded: Bool { stored.isEmpty ? defaultExpanded : stored == "1" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(motion ? Motion.standard : nil) { stored = expanded ? "0" : "1" }
            } label: {
                CardTitle(title: title, detail: detail, hint: hint) {
                    HStack(spacing: 10) {
                        if !expanded {
                            Text(summary).font(.ysCaption).monospacedDigit()
                                .foregroundStyle(summaryWarning ? Theme.warning : Theme.inkSoft)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: TypeSize.caption, weight: .semibold))
                            .foregroundStyle(Theme.inkSoft)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail.isEmpty ? title : "\(title)，\(detail)")
            .accessibilityValue(expanded ? "已展开" : "已折叠：\(summary)")
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            if expanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .xianCard(tier: tier)
        // 设置项都是短行：卡片限宽，展开箭头和摘要不会远在宽屏的最右边
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
    }

    static var maxWidth: CGFloat { 760 }
}

/// 组里的小标题（旧卷里的“从旧版 APT 导入”“旧版存档”）：右侧可带条数和 ⓘ 说明
private struct SubHeading: View {
    var title: String
    var detail: String = ""
    var info: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 无衬线半粗：小标题里有“APT”这样的西文，宋体会把字母拆散
            Text(title).font(.ysBody.weight(.semibold)).foregroundStyle(Theme.ink)
            if !detail.isEmpty { Text(detail).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft) }
            if !info.isEmpty { InfoTip(info) }
        }
    }
}

/// 收进 ⓘ 的说明：悬停显示，读屏读出
private struct InfoTip: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: TypeSize.caption))
            .foregroundStyle(Theme.inkSoft)
            .help(text)
            .accessibilityLabel("说明")
            .accessibilityValue(text)
    }
}

/// 一排按钮：放得下就横排，窗口窄时自动改成竖排，不会把卡片撑出页边距
struct AdaptiveButtonRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

// MARK: - 提醒

/// “景致与提醒”里的“提醒”一节：落笔时辰、功课时辰、日程、那年今日、周复盘、开机。
/// 开关先乐观地切换，再等系统授权；快速开关时只认最后一次，旧请求晚回来不会把开关改回去。
/// 调试数据目录（APT_STORE_DIR）：系统通知、登录项都和已安装的正式应用共用（同一个 bundle id），
/// 这里一动就会改到正式应用排好的提醒和你的登录项，所以只记下开关（记在调试实例自己的偏好里），不动系统。
private struct ReminderRows: View {
    @Binding var loginStatus: LoginItem.Status
    @Environment(EffectsCenter.self) private var effects
    @AppStorage(DailyReminder.writeKey) private var write = false
    @AppStorage(DailyReminder.writeMinuteKey) private var writeMinute = ReminderPlan.defaultWriteMinute
    @AppStorage(DailyReminder.habitsKey) private var habits = false
    @AppStorage(DailyReminder.habitsMinuteKey) private var habitsMinute = ReminderPlan.defaultHabitsMinute
    @AppStorage(ReviewReminder.enabledKey) private var weekly = false
    @AppStorage(ReviewReminder.weekdayKey) private var weeklyWeekday = ReminderPlan.defaultWeeklyWeekday
    @AppStorage(ReviewReminder.minuteKey) private var weeklyMinute = ReminderPlan.defaultWeeklyMinute
    @AppStorage(DailyReminder.eventsKey) private var events = false
    @AppStorage(DailyReminder.eventsLeadKey) private var eventsLead = ReminderPlan.defaultEventLead
    @AppStorage(DailyReminder.lookbackKey) private var lookback = false
    /// 排程与退避的记录：变了（例如刚改成三日一问、点了恢复每日）这一节跟着刷新
    @AppStorage(DailyReminder.stateKey) private var stateText = ""
    /// 正在向系统申请通知权限的那几行
    @State private var pending: Set<Row> = []
    /// 各行就地显示的出错说明
    @State private var errors: [Row: String] = [:]
    /// 各行最新一次开关请求的序号：旧请求晚回来时丢弃结果
    @State private var requests: [Row: Int] = [:]
    /// 周复盘改星期 / 时刻后稍等再重排（时刻格子连点几下只排一次）
    @State private var weeklyTask: Task<Void, Never>?

    enum Row: Hashable { case write, habits, events, lookback, weekly, login }

    private var backingOff: Bool { write && DailyReminder.decodeState(stateText).backingOff }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel
            FormRow(label: "落笔时辰", top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("每天", isOn: Binding(get: { write }, set: { setDaily(.write, $0) }))
                            .accessibilityLabel("每天提醒落一笔")
                        MinuteField(label: "", minutes: Binding(get: { writeMinute }, set: {
                            writeMinute = ReminderPlan.clampMinute($0)
                            DailyReminder.shared.scheduleSoon(after: 0.8)
                        }))
                        .accessibilityLabel("落笔时辰的时刻")
                        Text("提醒落一笔").foregroundStyle(Theme.text)
                        InfoTip("今天已经写过就不提醒；在通知里可以直接写一句入卷，点开通知是随手记。连续三次没理会，会自动改成三日一问（到点时 Mac 合盖、关机或没开通知的那几天不算）。")
                    }
                    if backingOff {
                        HStack(spacing: 2) {
                            Hint(ReminderPlan.backoffNote + " ·", symbol: "moon.zzz")
                            Button { restoreDaily() } label: { Text("恢复每日") }
                                .buttonStyle(.inlineAction(Theme.gold))
                                .help("回到每天提醒")
                        }
                    }
                    status(.write)
                }
            }
            FormRow(label: "功课时辰", top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("每天", isOn: Binding(get: { habits }, set: { setDaily(.habits, $0) }))
                            .accessibilityLabel("每天提醒未圆满的功课")
                        MinuteField(label: "", minutes: Binding(get: { habitsMinute }, set: {
                            habitsMinute = ReminderPlan.clampMinute($0)
                            DailyReminder.shared.scheduleSoon(after: 0.8)
                        }))
                        .accessibilityLabel("功课时辰的时刻")
                        Text("提醒未圆满的功课").foregroundStyle(Theme.text)
                        InfoTip("功课都圆满了就不提醒；还没有功课时不提醒。通知里写出还没圆满的前三项，点“去打卡”回到今日洞府。")
                    }
                    status(.habits)
                }
            }
            FormRow(label: "日程", top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("开始前", isOn: Binding(get: { events }, set: { setDaily(.events, $0) }))
                            .accessibilityLabel("日程开始前提醒")
                        ChipPicker(selection: Binding(get: { ReminderPlan.clampLead(eventsLead) }, set: {
                            eventsLead = ReminderPlan.clampLead($0)
                            DailyReminder.shared.scheduleSoon(after: 0.8)
                        }), options: ReminderPlan.eventLeadOptions.map { (value: $0, label: "\($0) 分钟") })
                        .accessibilityLabel("日程提醒提前几分钟")
                        Text("提醒").foregroundStyle(Theme.text)
                        InfoTip("只提今天与明天有钟点的日程（全天的不提），一次最多 12 条。通知里写时刻、名称与地点，点开回到时辰卷那一周。")
                    }
                    status(.events)
                }
            }
            FormRow(label: "那年今日", top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("每天 9:00 提起往年的今天", isOn: Binding(get: { lookback }, set: { setDaily(.lookback, $0) }))
                        InfoTip("一年、半年、一月、一周前的今天写过才提；通知里摘那天写下的前 30 字（复盘的小标题不算），点开回到今日洞府。")
                    }
                    // 与带时刻签的几行同高
                    .frame(minHeight: 32)
                    status(.lookback)
                }
            }
            FormRow(label: "周复盘", top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("每周", isOn: Binding(get: { weekly }, set: { setDaily(.weekly, $0) }))
                            .accessibilityLabel("每周提醒写周复盘")
                        ChipPicker(selection: Binding(get: { ReminderPlan.clampWeekday(weeklyWeekday) }, set: {
                            weeklyWeekday = $0
                            weeklyTimeChanged()
                        }), options: ReminderPlan.weekdayOrder.map { (value: $0, label: ReminderPlan.weekdayName($0)) })
                        .accessibilityLabel("周复盘提醒的星期")
                        MinuteField(label: "", minutes: Binding(get: { weeklyMinute }, set: {
                            weeklyMinute = ReminderPlan.clampMinute($0)
                            weeklyTimeChanged()
                        }))
                        .accessibilityLabel("周复盘提醒的时刻")
                        Text("提醒写周复盘").foregroundStyle(Theme.text)
                        InfoTip("通知里写这一周落笔几篇、功课完成几成；点开翻到修行录，打开七日小卷。")
                    }
                    status(.weekly)
                }
            }
            FormRow(label: "开机", top: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle("登录 Mac 时自动打开云山修习录", isOn: Binding(get: { loginStatus.isOn }, set: setLogin))
                        InfoTip("打开后会在菜单栏待命，关掉窗口也不退出；随手记 ⌥⌘J、飞剑传书、提醒才一直都在。")
                    }
                    // 与上面带时刻签的三行同高：四行节奏一致，下面多出说明时标签也对齐第一行
                    .frame(minHeight: 32)
                    if loginStatus == .needsApproval {
                        // 不是出错，只是还差你点一下允许：不用朱砂
                        Hint(LoginItem.approvalNote, symbol: "hand.raised")
                        Button { LoginItem.openSettings() } label: { Label("打开登录项设置", systemImage: "gearshape") }
                            .buttonStyle(.yunshanCompact)
                    }
                    if let error = errors[.login] { Hint(error, tone: .error) }
                }
            }
            // 一节到此为止：下面的随手记、时区、快捷键不是提醒
            Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1).padding(.vertical, 6)
        }
    }

    /// 小标题“提醒”，后面一道细线，把下面四行和外观、动效分开
    private var sectionLabel: some View {
        HStack(spacing: 10) {
            Text("提醒").font(.system(size: TypeSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSoft)
            Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    /// 申请权限中、或出错时的一行
    @ViewBuilder
    private func status(_ row: Row) -> some View {
        if pending.contains(row) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Hint("正在向系统申请通知权限…")
            }
        } else if let error = errors[row] {
            Hint(error, tone: .error)
        }
    }

    private func nextRequest(_ row: Row) -> Int {
        let request = (requests[row] ?? 0) + 1
        requests[row] = request
        return request
    }

    // MARK: 动作

    /// 这一行的开关（@AppStorage，与 DailyReminder 读写同一份偏好）
    private func setFlag(_ row: Row, _ on: Bool) {
        switch row {
        case .write: write = on
        case .habits: habits = on
        case .events: events = on
        case .lookback: lookback = on
        case .weekly: weekly = on
        case .login: break
        }
    }

    /// 打开成功后飘的一句
    private func enabledHint(_ row: Row) -> String {
        switch row {
        case .write: "已开启：每天 \(ClockTime.text(writeMinute)) 提醒落一笔"
        case .habits: "已开启：每天 \(ClockTime.text(habitsMinute)) 提醒未圆满的功课"
        case .events: "已开启：日程开始前 \(ReminderPlan.clampLead(eventsLead)) 分钟提醒"
        case .lookback: "已开启：每天 9:00 提起往年的今天"
        case .weekly, .login: "已开启：\(ReminderPlan.weeklyLabel(weekday: weeklyWeekday, minute: weeklyMinute)) 提醒"
        }
    }

    /// 落笔时辰 / 功课时辰 / 日程 / 那年今日 / 周复盘的开关（星期与时刻、提前量按这一行选的）
    private func setDaily(_ row: Row, _ on: Bool) {
        let request = nextRequest(row)
        setFlag(row, on)
        errors[row] = nil
        if row == .weekly { weeklyTask?.cancel() }
        let set: (Bool) async -> Bool = { on in
            switch row {
            case .write: return await DailyReminder.shared.setWrite(enabled: on)
            case .events: return await DailyReminder.shared.setEvents(enabled: on)
            case .lookback: return await DailyReminder.shared.setLookback(enabled: on)
            case .weekly: return await DailyReminder.shared.setWeekly(enabled: on)
            case .habits: return await DailyReminder.shared.setHabits(enabled: on)
            case .login: return true   // 登录项走 setLogin，不经这里
            }
        }
        guard DailyReminder.touchesSystem else {
            pending.remove(row)
            Task { _ = await set(on) }
            effects.hint(DailyReminder.debugNote, icon: "info.circle")
            return
        }
        if on { pending.insert(row) } else { pending.remove(row) }
        Task {
            let ok = await set(on)
            // 已经被后来的操作取代：DailyReminder 重排时读的是最新的开关，不必再管
            guard request == requests[row] else { return }
            pending.remove(row)
            if on && !ok {
                setFlag(row, false)
                errors[row] = DailyReminder.deniedNote
            } else if on {
                effects.hint(enabledHint(row), icon: "checkmark.circle")
            }
        }
    }

    /// 改了周复盘的星期或时刻：开着时稍等片刻按新的时刻重排（关着时只记下，打开时用）。
    /// 周复盘也由 DailyReminder 排（接下来 12 次各一条、正文写本周实数），重排时顺手撤掉以前每周重复的那一条
    private func weeklyTimeChanged() {
        weeklyTask?.cancel()
        guard weekly, DailyReminder.touchesSystem else { return }
        weeklyTask = Task {
            do { try await Task.sleep(for: .seconds(0.8)) } catch { return }
            guard weekly else { return }
            await DailyReminder.shared.reschedule()
            effects.hint("周复盘改为\(ReminderPlan.weeklyLabel(weekday: weeklyWeekday, minute: weeklyMinute)) 提醒", icon: "checkmark.circle")
        }
    }

    private func restoreDaily() {
        DailyReminder.shared.restoreDaily()
        effects.hint("落笔提醒已恢复每日", icon: "checkmark.circle")
    }

    /// 登录项开关：调试实例只记开关
    private func setLogin(_ on: Bool) {
        errors[.login] = nil
        let result = LoginItem.setEnabled(on)
        if LoginItem.isDebugInstance {
            loginStatus = result
            effects.hint(LoginItem.debugNote, icon: "info.circle")
            return
        }
        switch result {
        case .failed(let message):
            loginStatus = LoginItem.status
            errors[.login] = "没能登记登录项：\(message)"
        case .on:
            loginStatus = .on
            effects.hint("已开启：登录 Mac 时自动打开", icon: "checkmark.circle")
        case .needsApproval, .off:
            loginStatus = result
        }
    }
}

// MARK: - 修为与境界

/// “修为与境界”组的内容：开关、每日上限、境界名称与门槛、修为规则（规则全文只在这里）
struct CultivationSettingsForm: View {
    @Bindable var settings: AppSettings
    @Environment(\.modelContext) private var context
    @State private var draftRealms: [String] = []
    /// 门槛按文字编辑、每敲一个字就解析：带格式的数字框要按回车或失去焦点才提交，直接点“应用”会用上旧值
    @State private var draftThresholdTexts: [String] = []
    @State private var editing = false
    @State private var applied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                FormRow(label: "修为") {
                    Toggle("启用修为与境界", isOn: Binding(get: { settings.cultivationEnabled }, set: {
                        settings.cultivationEnabled = $0
                        DataStore.save(context)
                    }))
                }
                FormRow(label: "每日上限") {
                    Stepper("\(settings.dailyCap) 修为", value: Binding(get: { settings.dailyCap }, set: {
                        settings.dailyCap = $0
                        DataStore.save(context)
                    }), in: 30...1000, step: 10)
                    .monospacedDigit()
                    .accessibilityLabel("每日修为上限")
                }
            }
            DisclosureGroup(isExpanded: $editing) {
                VStack(spacing: 6) {
                    ForEach(draftRealms.indices, id: \.self) { index in
                        HStack {
                            Text("\(index + 1)").font(.ysCaption.monospacedDigit()).foregroundStyle(Theme.inkSoft).frame(width: 18)
                            TextField("境界", text: $draftRealms[index]).frame(width: 90)
                            if index == 0 {
                                Text("0").frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Theme.inkSoft)
                            } else if index < draftThresholdTexts.count {
                                TextField("门槛", text: $draftThresholdTexts[index])
                            }
                        }
                    }
                    HStack {
                        Button("恢复默认九境") {
                            draftRealms = CultivationConfig.defaultRealms
                            draftThresholdTexts = CultivationConfig.defaultThresholds.map(String.init)
                        }
                        Spacer()
                        if applied { Hint("已应用", tone: .success) }
                        Button("应用") {
                            guard let thresholds = draftThresholds else { return }
                            var config = settings.cultivation
                            config.realms = draftRealms.map { $0.trimmingCharacters(in: .whitespaces) }
                            config.thresholds = thresholds
                            settings.cultivation = config
                            DataStore.save(context)
                            applied = true
                        }
                        .disabled(!draftValid)
                    }
                    if !draftValid {
                        Hint("门槛要填整数并从小到大递增，名称不能为空", tone: .error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("境界名称与门槛").font(.ysCallout).foregroundStyle(Theme.ink)
            }
            .onAppear {
                draftRealms = settings.realms
                draftThresholdTexts = settings.thresholds.map(String.init)
            }
            .onChange(of: draftRealms) { applied = false }
            .onChange(of: draftThresholdTexts) { applied = false }
            DisclosureGroup {
                Text(CultivationEngine.rulesDescription).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } label: {
                Text("修为规则").font(.ysCallout).foregroundStyle(Theme.ink)
            }
        }
    }

    /// 解析后的门槛；有一格不是整数就是 nil
    private var draftThresholds: [Int]? {
        let values = draftThresholdTexts.map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }
    }

    private var draftValid: Bool {
        guard let thresholds = draftThresholds, draftRealms.count == thresholds.count, !draftRealms.isEmpty, thresholds.first == 0 else { return false }
        return draftRealms.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            && zip(thresholds, thresholds.dropFirst()).allSatisfy { $0 < $1 }
    }
}

// MARK: - 导入预览与确认

struct LegacyImportSheet: View {
    var url: URL
    var isFirstRun: Bool
    var onFinish: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: LegacySnapshot?
    @State private var preview: LegacyImporter.Report?
    @State private var result: LegacyImporter.Report?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SceneryImage(name: "yunshan-ornament-scroll-v1").frame(width: 46, height: 46)
                VStack(alignment: .leading) {
                    Text(isFirstRun ? "发现旧版 APT 的数据" : "导入旧版数据").font(.ysTitle).foregroundStyle(Theme.ink)
                    Text(url.path).font(.ysCaption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(Theme.warning)
            } else if let result {
                Label("导入完成", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.positive).font(.ysBody.weight(.semibold))
                report(result)
            } else if let snapshot, let preview {
                Text("\(snapshot.source.rawValue)，schema \(snapshot.schemaVersion)，共 \(snapshot.recordCount) 条记录、\(snapshot.settings.count) 个设置项。")
                    .font(.ysCallout)
                let nonEmpty = snapshot.collections.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
                Text(nonEmpty.map { "\(LegacyArchiveBrowser.label(for: $0.key)) \($0.value.count)" }.joined(separator: "　"))
                    .font(.ysCaption).foregroundStyle(.secondary)
                Text("将会：").font(.ysBody.weight(.semibold))
                report(preview)
                Text("原数据库不会被修改。所有原始记录都会完整存档；旧版灵石账簿会并入「灵石账簿」页，复盘、AI 分析历史等暂无对应界面的内容保留在存档里。")
                    .font(.ysCaption).foregroundStyle(.secondary)
            } else {
                ProgressView("正在读取…")
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if result != nil || error != nil {
                    Button("完成") { onFinish(); dismiss() }.buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button(isFirstRun ? "以后再说" : "取消") { onFinish(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button("确认导入") { apply() }
                        .buttonStyle(.yunshanPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(snapshot == nil || !(preview?.hasChanges ?? false))
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .yunshanSheet()
        .task { load() }
    }

    private func report(_ report: LegacyImporter.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(report.lines, id: \.self) { line in
                Label(line, systemImage: line.hasPrefix("注意") ? "exclamationmark.triangle" : "circle.fill")
                    .labelStyle(BulletLabelStyle())
                    .font(.ysCallout)
            }
            if !report.hasChanges { Text("没有需要导入的新内容。").font(.ysCallout).foregroundStyle(.secondary) }
        }
    }

    private func load() {
        do {
            let snapshot = try LegacyReader.read(url: url)
            self.snapshot = snapshot
            preview = LegacyImporter.run(snapshot, context: context, dryRun: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply() {
        guard let snapshot else { return }
        result = LegacyImporter.run(snapshot, context: context, dryRun: false)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5.5)).foregroundStyle(Theme.inkSoft)
            configuration.title
        }
    }
}

// MARK: - 存档浏览

struct LegacyArchiveBrowser: View {
    var kind: String
    var records: [LegacyRecord]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PersistentIdentifier?

    static func label(for kind: String) -> String {
        [
            "profile": "个人资料", "goals": "目标", "milestones": "里程碑", "projects": "项目", "tasks": "任务",
            "calendar": "日程", "habits": "习惯", "habit_logs": "打卡", "daily_plans": "每日计划", "daily_logs": "每日记录",
            "sessions": "专注记录", "notes": "笔记", "reviews": "复盘", "ai_analysis_history": "AI 分析历史",
            "timeline": "时间线", "inbox": "收集箱", "file_references": "文件引用", "settings": "设置项",
            "audit_log": "审计日志", "schema_migrations": "迁移记录", "xp_events": "修为记录", "workouts": "运动",
            "meals": "饮食", "research_projects": "研究项目", "experiments": "实验", "decisions": "决策",
            "students": "学生", "lessons": "课程", "teaching_materials": "教学资料", "daily_reviews": "每日复盘",
            "weekly_reviews": "每周复盘", "recycle_bin": "回收站",
        ][kind] ?? kind
    }

    private var selected: LegacyRecord? { records.first { $0.persistentModelID == selection } ?? records.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("旧版存档 · \(Self.label(for: kind))").font(.ysTitle).foregroundStyle(Theme.ink)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            HSplitView {
                List(records, selection: $selection) { record in
                    VStack(alignment: .leading) {
                        Text(record.legacyID).font(.ysCaption.monospaced()).lineLimit(1)
                        Text(record.legacyUpdatedAt.isEmpty ? "—" : record.legacyUpdatedAt).font(.ysCaption).foregroundStyle(.secondary)
                    }
                    .tag(record.persistentModelID)
                }
                .frame(minWidth: 220)
                ScrollView {
                    Text(pretty(selected?.json ?? ""))
                        .font(.ysCaption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(minWidth: 420)
            }
        }
        .frame(width: 820, height: 560)
        .yunshanSheet()
    }

    private func pretty(_ json: String) -> String {
        // 超大记录（例如财务账簿）只截取前 200 KB 显示，存档本身完整。
        guard json.utf8.count < 400_000, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else {
            return String(json.prefix(200_000))
        }
        let text = String(decoding: out, as: UTF8.self)
        return text.count > 200_000 ? String(text.prefix(200_000)) + "\n…（仅显示前一部分，存档完整）" : text
    }
}
