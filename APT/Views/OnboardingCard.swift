import SwiftUI
import SwiftData
import AppKit

// 今日洞府左栏的“筑基三关”（#8，新手卡）：三件十秒就能做完的小事——立一项功课、落第一笔、随手一记或请 AI 代笔。
// 判定、写法与“落印只放一次”的规矩在 Core/Onboarding（CoreCheck 逐条核对）；这里只取数与画。
// 出不出现由首页决定（Onboarding.shows：没收起、有记录的日子不到 30 天、三关没全过或全过的就是今天），
// 首页据此把修为卡收成一行。本卡出现时：
// - 每一行左边一个印位：没过是虚线圆，过了是一方朱砂小印（印文“一”“二”“三”）。某一关在卡片可见时变成已过：
//   印从 1.3 倍落到 1、墨色晕开（关动效、离屏截图时直接落定）；每关只落一次（onboarding.sealed）。
//   卡片第一次出现时，已经过了的几关静默记下，不连放；
// - “可见”指主窗口是键盘窗口：在别的应用里按 ⌥⌘J、请 AI 投传书时主窗口在后面，随手记浮窗开着、上面挂着弹窗时也不算。
//   这时过的关先按没过画、不记落印也不提示（只记功成那天），等主窗口重新成为键盘窗口再落印、掠金光、提示——仪式不在后台放掉；
// - 三关全过：整卡掠过一道金光（同样只一次；金光记在 @State 里放完，不随偏好里记下“done”立刻撤掉），
//   标题换成宋体金字“筑基功成”，当天留着，次日不再出现（onboarding.doneDay）；
// - 一关的六枚功法谱胶囊点一下就立好（HabitTemplateInstaller.install，今日功课卡立刻出现），立错了去每日功课页删；
// - 三关：全局热键 ⌥⌘J 没注册上时（随手记写下的 quick.hotKeyError 不空），说明改成“点菜单栏的笔形小图标随手记一句”、按钮写“试一下随手记”；
// - 卡底“另可：”两件可选的事（落笔时辰提醒、登录时自动打开），已开的不显示；调试实例照 #2 / #3 只记开关并提示。
// 取数：功课名借修为模型（不读打卡关系）；修行录篇数、传书封数是两次 fetchCount（约 1 毫秒），数据库每次保存后重数。

/// 筑基三关卡
struct OnboardingCard: View {
    var today: LocalDay
    /// “更多功法 →”：打开新建功课弹窗（弹窗挂在首页上，顶部就是功法谱）
    var onCreateHabit: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(CultivationModel.self) private var cultivation
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    /// 主窗口是不是键盘窗口：不是时（在后台、挂着弹窗、随手记浮窗开着）刚过的关先不落印，见 visible
    @Environment(\.controlActiveState) private var activeState
    @AppStorage(Onboarding.quickUsedKey) private var quickUsed = false
    @AppStorage(Onboarding.sealedKey) private var sealed: String?
    @AppStorage(Onboarding.doneDayKey) private var doneDay = ""
    @AppStorage(Onboarding.dismissedKey) private var dismissed = false
    @AppStorage(DailyReminder.writeKey) private var writeReminder = false
    /// 全局热键 ⌥⌘J 没注册上时随手记写下的那句（不空就是没注册上）：三关改说点菜单栏的笔形小图标
    @AppStorage(QuickCaptureKeys.hotKeyError) private var hotKeyError = ""
    /// 登录项开没开（系统的状态不会自己通知，出现时、点过“开启”后各读一次）
    @State private var loginOn = true
    /// 数据库保存过几次：变了就重数篇数与传书（body 里现数，不另存一份）
    @State private var revision = 0
    /// 正在掠过“筑基功成”的金光：record() 里遇到功成时置真，扫完（约 2.2 秒）自己置回。
    /// 不能由偏好里的 sealed 决定在不在：record() 同一刻就把“done”写进去，金光层会在插进去的同一毫秒被撤掉
    @State private var sweeping = false

    /// 卡片此刻看得见：主窗口是键盘窗口（不在别的应用后面、没挂弹窗、随手记浮窗也收起了）；离屏截图一律算看得见
    private var visible: Bool { RenderMode.offscreen || activeState == .key }

    var body: some View {
        let _ = revision
        let facts = OnboardingLoader.facts(context: context, habitTitles: habitTitles, quickUsed: quickUsed)
        let passed = Onboarding.passed(facts)
        // 画出来的几关：看不见时刚过、还没落印的先按没过画，看得见了再落（见 Onboarding.shown）
        let shown = Onboarding.shown(passed: passed, sealed: sealed, visible: visible)
        let done = shown.count == Onboarding.Gate.allCases.count
        let animated = motion && !RenderMode.offscreen
        VStack(alignment: .leading, spacing: 14) {
            header(passed: shown, done: done)
            Text(done ? Onboarding.doneLine : Onboarding.intro)
                .font(.ysCallout)
                .foregroundStyle(done ? Theme.gold : Theme.inkSoft)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Onboarding.Gate.allCases, id: \.self) { gate in
                    gateRow(gate, facts: facts, passed: shown,
                            fresh: animated && Onboarding.isFresh(gate, passed: shown, sealed: sealed))
                }
            }
            optionalRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            // 三关全过、这一次看到：整卡掠过一道金光（只一次；扫完自己撤）
            if sweeping {
                OnboardingGoldSweep { sweeping = false }.padding(-24)
            }
        }
        .xianCard(ornament: "yunshan-ornament-seal-v1")
        .onAppear {
            loginOn = LoginItem.status.isOn
            record(passed)
        }
        .onChange(of: passed) { _, new in record(new) }
        // 主窗口重新成为键盘窗口（从别的应用切回来、随手记浮窗收起、弹窗关了）：在后台过的关这时才落印、掠金光、提示
        .onChange(of: visible) { _, now in if now { record(passed) } }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { _ in revision &+= 1 }
    }

    /// 未归档的功课名（按排序；刚删掉、模型还没重算的跳过）
    private var habitTitles: [String] {
        cultivation.rows.filter { $0.habit.modelContext != nil }.map(\.habit.title)
    }

    /// 卡片看到这一刻的三关：落印、金光、功成那天记进偏好（规矩见 Onboarding.step）。
    /// 看不见时只记功成那天；落过的印、金光与“筑基功成”的提示等看得见了再说
    private func record(_ passed: Set<Onboarding.Gate>) {
        let step = Onboarding.step(passed: passed, sealed: sealed, doneDay: doneDay, today: today, visible: visible)
        if let new = step.sealed, sealed != new { sealed = new }
        if let day = step.doneDay { doneDay = day }
        guard step.celebrate else { return }
        effects.hint("筑基功成 · 三关已过，山门自开", icon: "checkmark.seal")
        // 金光只在动效开着时放（关动效时金字标题就是静态版）
        if motion && !RenderMode.offscreen { sweeping = true }
    }

    // MARK: 标题行

    @ViewBuilder
    private func header(passed: Set<Onboarding.Gate>, done: Bool) -> some View {
        if done {
            // 功成：宋体金字，旁边仍写“已过 3 / 3”
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Capsule()
                    .fill(LinearGradient(colors: [Theme.gold, Theme.gold.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1.5, height: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(Onboarding.doneTitle).font(Theme.songti(TypeSize.heading + 2, .bold)).tracking(4).foregroundStyle(Theme.gold)
                Text(Onboarding.progressText(passed)).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                Spacer(minLength: 8)
                dismissButton
            }
            .accessibilityElement(children: .contain)
        } else {
            CardTitle(title: "筑基三关", detail: Onboarding.progressText(passed),
                      hint: "三件十秒就能做完的小事；过完三关，次日这张卡自行收起") {
                dismissButton
            }
        }
    }

    /// “收起”是永久的：用关闭的叉，不用别处“折叠、还能展开”的 chevron.up；点了提示一句之后去哪儿做
    private var dismissButton: some View {
        Button {
            withAnimation(motion ? Motion.standard : nil) { dismissed = true }
            effects.hint(Onboarding.dismissedHint, icon: "checkmark.circle")
        } label: {
            Label("收起", systemImage: "xmark")
        }
        .buttonStyle(.inlineAction())
        .help(Onboarding.dismissHelp)
    }

    // MARK: 三关

    private func gateRow(_ gate: Onboarding.Gate, facts: Onboarding.Facts, passed: Set<Onboarding.Gate>, fresh: Bool) -> some View {
        let isPassed = passed.contains(gate)
        return HStack(alignment: .top, spacing: 12) {
            OnboardingSealSlot(gate: gate, passed: isPassed, fresh: fresh)
            VStack(alignment: .leading, spacing: 6) {
                Text(gate.title)
                    .font(.system(size: TypeSize.callout, weight: .semibold))
                    .foregroundStyle(isPassed ? Theme.inkSoft : Theme.ink)
                if isPassed {
                    Label(Onboarding.doneText(gate, facts), systemImage: "checkmark")
                        .font(.ysCaption)
                        .foregroundStyle(Theme.positive)
                } else {
                    Text(Onboarding.todo(gate, hotKeyFailed: !hotKeyError.isEmpty))
                        .font(.ysCaption)
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    extras(gate, facts: facts)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(gate.title)：\(isPassed ? "已过" : "未过")")
    }

    @ViewBuilder
    private func extras(_ gate: Onboarding.Gate, facts: Onboarding.Facts) -> some View {
        switch gate {
        case .habit:
            FlowLayout(spacing: 6) {
                ForEach(HabitTemplates.starter) { template in
                    OnboardingTemplateChip(template: template) { install(template) }
                }
                Button("更多功法", action: onCreateHabit)
                    .buttonStyle(.cardLink)
                    .help("打开新建功课：十二式功法谱，或自己写一项")
                    .padding(.leading, 4)
                    .padding(.top, 4)
            }
        case .write:
            EmptyView()
        case .quick:
            HStack(spacing: 6) {
                Button {
                    QuickCapturePanel.shared.show()
                } label: {
                    Label(Onboarding.quickTryLabel(hotKeyFailed: !hotKeyError.isEmpty), systemImage: "square.and.pencil")
                }
                .buttonStyle(.inlineAction(Theme.gold))
                .help(Onboarding.quickTryHelp(hotKeyFailed: !hotKeyError.isEmpty))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Onboarding.askExample, forType: .string)
                    effects.hint(Onboarding.copiedHint, icon: "doc.on.doc")
                } label: {
                    Label("复制例句", systemImage: "doc.on.doc")
                }
                .buttonStyle(.inlineAction())
                .help(Onboarding.copyHelp)
            }
            .padding(.leading, -6)
        }
    }

    /// 点功法谱胶囊：立好这一式（同名的已有就不重复立），今日功课卡立刻出现
    private func install(_ template: HabitTemplate) {
        let next = (cultivation.habits.map(\.sortOrder).max() ?? -1) + 1
        let habit = HabitTemplateInstaller.install(template, context: context, sortOrder: next)
        effects.hint("已立「\(habit.title)」：在今日功课里打卡；立错了可在每日功课页删除", icon: "checkmark.circle")
    }

    // MARK: 另可

    /// 两件可选的事：落笔时辰提醒、登录时自动打开。已开的不显示，两件都开了整行不出
    @ViewBuilder
    private var optionalRow: some View {
        if !writeReminder || !loginOn {
            VStack(alignment: .leading, spacing: 8) {
                // 分隔线右侧给右下角的玉印装饰让位：画到离右缘 72pt 处为止，末段渐隐，不从印钮上横穿过去
                LinearGradient(stops: [.init(color: Theme.line, location: 0), .init(color: Theme.line, location: 0.7),
                                       .init(color: Theme.line.opacity(0), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                    .padding(.trailing, 72)
                FlowLayout(spacing: 4) {
                    Text("另可：").font(.ysCaption).foregroundStyle(Theme.inkSoft).padding(.top, 3)
                    if !writeReminder {
                        optionalItem("每晚 \(ClockTime.text(DailyReminder.writeMinute)) 提醒落一笔",
                                     help: "到点还没写才发一条通知，可在通知里直接写一句入卷；时刻在洞府设置 → 景致与提醒里改",
                                     action: enableWrite)
                    }
                    if !writeReminder && !loginOn {
                        // “开启”按钮自带 6pt 内边距：点的右边补上同样的 6pt，两边留白一样
                        Text("·").font(.ysCaption).foregroundStyle(Theme.inkSoft.opacity(0.6)).padding(.top, 3).padding(.trailing, 6)
                    }
                    if !loginOn {
                        optionalItem("登录时自动打开", help: "登录 Mac 时自动打开云山修习录，⌥⌘J、菜单栏与提醒才都在", action: enableLogin)
                    }
                }
            }
        }
    }

    private func optionalItem(_ text: String, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Text(text).font(.ysCaption).foregroundStyle(Theme.text)
            Button("开启", action: action).buttonStyle(.inlineAction(Theme.gold)).help(help)
        }
    }

    private func enableWrite() {
        Task { @MainActor in
            let ok = await DailyReminder.shared.setWrite(enabled: true)
            if !DailyReminder.touchesSystem {
                effects.hint(DailyReminder.debugNote)
            } else if ok {
                effects.hint("已开启：每晚 \(ClockTime.text(DailyReminder.writeMinute)) 提醒落一笔", icon: "checkmark.circle")
            } else {
                effects.hint(DailyReminder.deniedNote, icon: "exclamationmark.circle")
            }
        }
    }

    private func enableLogin() {
        let status = LoginItem.setEnabled(true)
        loginOn = status.isOn
        if LoginItem.isDebugInstance {
            effects.hint(LoginItem.debugNote)
            return
        }
        switch status {
        case .on: effects.hint("已开启：登录时自动打开", icon: "checkmark.circle")
        case .needsApproval: effects.hint(LoginItem.approvalNote, icon: "exclamationmark.circle")
        case .off: effects.hint("登录项没有登记上，可在洞府设置 → 景致与提醒里再试", icon: "exclamationmark.circle")
        case .failed(let reason): effects.hint("登录项没有登记上：\(reason)", icon: "exclamationmark.circle")
        }
    }
}

// MARK: - 取数

/// 筑基三关的取数（界面与自检共用）
@MainActor
enum OnboardingLoader {
    /// 三关要的几样：功课名由调用方给（首页借修为模型），修行录篇数与传书封数各一次 fetchCount
    static func facts(context: ModelContext, habitTitles: [String], quickUsed: Bool) -> Onboarding.Facts {
        Onboarding.Facts(habitTitles: habitTitles,
                         entries: (try? context.fetchCount(FetchDescriptor<JournalEntry>())) ?? 0,
                         quickUsed: quickUsed,
                         letters: (try? context.fetchCount(FetchDescriptor<CourierDelivery>())) ?? 0)
    }

    /// 有记录的日子（落笔或打卡），数到 enough 就停：先看打卡的日子（修为模型已缓存），不够再按日期从新到旧一页页取修行录的日期。
    /// 老用户第一页就够 30 天；新用户篇数少，一页取完。返回值到了 enough 之后不再精确
    static func recordDays(context: ModelContext, habitDays: [LocalDay], enough: Int = Onboarding.veteranDays, page: Int = 400) -> Int {
        var habits = Set<LocalDay>()
        for day in habitDays {
            habits.insert(day)
            if habits.count >= enough { return habits.count }
        }
        var keys: [String] = []
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.dateKey, order: .reverse)])
            descriptor.propertiesToFetch = [\.dateKey]
            descriptor.fetchLimit = page
            descriptor.fetchOffset = offset
            let rows = (try? context.fetch(descriptor)) ?? []
            keys.append(contentsOf: rows.map(\.dateKey))
            let count = Onboarding.recordDays(journal: keys, habits: Array(habits))
            if count >= enough || rows.count < page { return count }
            offset += page
        }
    }

    /// 打卡过的日子（含已归档的功课）：借修为模型的统计
    static func habitDays(_ cultivation: CultivationModel) -> [LocalDay] {
        cultivation.habitStats.values.flatMap { $0.logs.keys }
    }

    /// 上一次数的结果：哪个库、哪一天、当时的篇数与打卡条数 → 有记录的日子
    private static var cached: (stamp: String, days: Int)?

    /// 首页每次刷新都要知道出不出筑基卡：按“库、今天、篇数、打卡条数”记住上次数的结果，这几样没变就不再取数
    /// （篇数是一次 fetchCount；首页切回来时整页重建，有缓存就不会先不出、下一帧再冒出来）
    static func recordDays(context: ModelContext, cultivation: CultivationModel, today: LocalDay) -> Int {
        let store = StoreIdentity.key(for: context)
        // 数出过老用户的库：永不再出，之后连篇数也不必数
        if veterans.contains(store) { return Onboarding.veteranDays }
        let entries = (try? context.fetchCount(FetchDescriptor<JournalEntry>())) ?? 0
        let logs = cultivation.habitStats.values.reduce(0) { $0 + $1.logs.count }
        let stamp = "\(store)|\(today.key)|\(entries)|\(logs)"
        if let cached, cached.stamp == stamp { return cached.days }
        let days = recordDays(context: context, habitDays: habitDays(cultivation))
        cached = (stamp, days)
        if days >= Onboarding.veteranDays { veterans.insert(store) }
        return days
    }

    /// 已经数出“有记录的日子 ≥ 30”的库（这个进程里）
    private static var veterans = Set<StoreIdentity.Key>()
}

// MARK: - 小件

/// 一关的功法谱胶囊：图标 + “喝水 · 8 杯”，悬停淡金描边；点一下就立好
private struct OnboardingTemplateChip: View {
    var template: HabitTemplate
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: template.symbol).font(.system(size: TypeSize.micro + 1)).foregroundStyle(Theme.jade)
                Text(template.chipText).lineLimit(1)
            }
            .font(.ysCaption)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hover ? Theme.jade.opacity(0.1) : Theme.mist.opacity(0.8), in: Capsule())
            .overlay(Capsule().strokeBorder(hover ? Theme.gold.opacity(0.6) : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("立下「\(template.title)」：\(template.detailText)。立错了可在每日功课页删除")
        .accessibilityLabel("立下\(template.chipText)")
    }
}

/// 一关的印位：没过是虚线圆（衬一个淡淡的序号）；过了是一方朱砂小印。
/// fresh（卡片可见时刚过、还没落过）时印从 1.3 倍落到 1、背后一团墨色晕开；否则直接落定
private struct OnboardingSealSlot: View {
    /// 朱砂印泥：与落笔入卷的朱印同一种沉稳的朱红（深浅色同色）
    static let ink = Color(red: 0.70, green: 0.20, blue: 0.16)
    var gate: Onboarding.Gate
    var passed: Bool
    var fresh: Bool

    var body: some View {
        ZStack {
            if passed {
                OnboardingSeal(text: gate.seal, fresh: fresh)
            } else {
                Circle()
                    .strokeBorder(Theme.inkSoft.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Text(gate.seal).font(Theme.songti(TypeSize.caption, .semibold)).foregroundStyle(Theme.inkSoft.opacity(0.5))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

private struct OnboardingSeal: View {
    var text: String
    /// 出现那一刻是不是刚过（记在 @State 里：偏好记下这一关后父视图会传 false，正放着的落印不受影响）
    @State private var fresh: Bool
    @State private var landed: Bool
    @State private var bloom: Bool

    init(text: String, fresh: Bool) {
        self.text = text
        _fresh = State(initialValue: fresh)
        _landed = State(initialValue: !fresh)
        _bloom = State(initialValue: !fresh)
    }

    var body: some View {
        ZStack {
            // 墨色晕开：落下那一刻一团朱砂淡淡化开
            Circle()
                .fill(OnboardingSealSlot.ink.opacity(0.35))
                .blur(radius: 5)
                .scaleEffect(bloom ? 1.9 : 0.6)
                .opacity(bloom ? 0 : (fresh ? 0.8 : 0))
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(OnboardingSealSlot.ink.opacity(0.92))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                    .padding(2.5)
                Text(text).font(Theme.songti(15, .bold)).foregroundStyle(Color.white.opacity(0.95))
            }
            .frame(width: 26, height: 26)
            .rotationEffect(.degrees(-5))
            .scaleEffect(landed ? 1 : 1.3)
            .opacity(landed ? 1 : 0)
            .shadow(color: OnboardingSealSlot.ink.opacity(0.25), radius: 3, y: 1)
        }
        .onAppear {
            guard fresh else { return }
            withAnimation(Motion.ceremony.delay(0.15)) { landed = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.25)) { bloom = true }
        }
    }
}

/// 三关全过时整卡掠过的一道金光：斜着一条淡金光带从左扫到右，等 0.35 秒起扫、约 1.6 秒，扫完（约 2.2 秒）叫 onFinish 撤掉。
/// 在不在由卡片的 @State（sweeping）决定，只在动效开着时出现
private struct OnboardingGoldSweep: View {
    /// 扫完：卡片把 sweeping 置回假，金光层撤掉
    var onFinish: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // 深浅色都看得见：两侧淡金、中间一线白光（不用叠加混合：浅色纸面上叠加的白光看不出来）
            LinearGradient(colors: [.clear, Theme.gold.opacity(0.4), Color.white.opacity(0.6), Theme.gold.opacity(0.4), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 160, height: geo.size.height * 1.6)
                .rotationEffect(.degrees(18))
                .offset(x: -200 + (geo.size.width + 400) * progress, y: -geo.size.height * 0.3)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).delay(0.35)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { onFinish() }
        }
    }
}
