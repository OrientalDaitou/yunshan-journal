import SwiftUI
import SwiftData

// MARK: - 印谱（修士名帖最上面一张纸笺卡）与里程碑检测
//
// 八枚印的条件、第一次运行静默补记、一天最多庆一枚都在 Core/Milestones.swift（CoreCheck 核对）；
// 这里取数（只用缓存的元数据）、写偏好、画印谱。检测由 RootView 在保存后约 1 秒、跨午夜时调用 MilestoneWatcher.check。

/// 印谱在偏好设置里的几项（不动数据模型）
enum MilestoneKeys {
    /// 已得的印与得印日（MilestoneLedger.encoded）；没有这一项 = 第一次运行
    static let ledger = "milestones.celebrated"
    /// 最近一次庆祝的那天：一天最多庆一枚
    static let lastDay = "milestones.celebratedDay"
    /// 刚得、名帖印谱下次出现时要盖印亮起的几枚（亮过即清）
    static let fresh = "milestones.fresh"
    /// 已达成、今天已庆过一枚而留到明天的几枚（印谱里画成“印已成”）
    static let pending = "milestones.pending"
}

@MainActor
enum MilestoneWatcher {
    /// 看一眼有没有新得的印：返回这次要庆的那一枚（第一次运行、没有新的、今天已庆过一枚时为 nil）。
    /// 印谱已集齐时什么都不取；没集齐时也只取还没得的那几枚要用的数：修行录走 JournalDigest 的缓存（只有日期与类型），
    /// 功课借修为模型已取好的习惯（不重新取习惯，免得打卡关系变冷），传书与目标各一次很小的查询。
    @discardableResult
    static func check(context: ModelContext, defaults: UserDefaults = AppPreferences.defaults, today: LocalDay = .today()) -> Milestone? {
        let ledger = MilestoneLedger(encoded: defaults.string(forKey: MilestoneKeys.ledger))
        if let ledger, ledger.isComplete {
            if defaults.string(forKey: MilestoneKeys.pending)?.isEmpty == false { defaults.set("", forKey: MilestoneKeys.pending) }
            return nil
        }
        let needed = Set(Milestone.allCases).subtracting(ledger?.earned.keys.map { $0 } ?? [])
        let reached = Milestones.reached(input(context: context, needed: needed, today: today), today: today)
        let step = Milestones.step(ledger: ledger, lastCelebrated: defaults.string(forKey: MilestoneKeys.lastDay), reached: reached, today: today)
        if step.changed { defaults.set(step.ledger.encoded, forKey: MilestoneKeys.ledger) }
        let pending = MilestoneLedger.listText(step.pending)
        if (defaults.string(forKey: MilestoneKeys.pending) ?? "") != pending { defaults.set(pending, forKey: MilestoneKeys.pending) }
        guard let milestone = step.celebrate else { return nil }
        defaults.set(today.key, forKey: MilestoneKeys.lastDay)
        let fresh = MilestoneLedger.list(defaults.string(forKey: MilestoneKeys.fresh) ?? "") + [milestone]
        defaults.set(MilestoneLedger.listText(fresh), forKey: MilestoneKeys.fresh)
        return milestone
    }

    /// 只取 needed 里那几枚要用的数
    static func input(context: ModelContext, needed: Set<Milestone>, today: LocalDay) -> MilestoneInput {
        var input = MilestoneInput()
        let journal: Set<Milestone> = [.firstEntry, .sevenDays, .thirtyDays, .hundredDays, .firstReview]
        if !needed.isDisjoint(with: journal) {
            let rows = JournalDigest.shared.sync(context).rows
            input.entryDays = rows.map(\.dateKey)
            input.reviewDays = rows.lazy.filter { $0.kind == JournalKind.review.rawValue }.map(\.dateKey)
        }
        if needed.contains(.firstHabit), ((try? context.fetchCount(FetchDescriptor<Habit>())) ?? 0) > 0 {
            // 立下的那天：创建日与开始日取早的（旧版导入的功课创建日是导入那天，开始日更早）；修为模型还没看到新习惯时记今天
            let days = CultivationModel.shared(for: context).habits.map { habit in
                min(LocalDay(date: habit.createdAt), LocalDay(key: habit.startDate) ?? LocalDay(date: habit.createdAt))
            }
            input.firstHabit = days.min() ?? today
        }
        if needed.contains(.firstCourier) {
            var first = FetchDescriptor<CourierDelivery>(sortBy: [SortDescriptor(\.receivedAt)])
            first.fetchLimit = 1
            input.firstCourier = (try? context.fetch(first))?.first.map { LocalDay(date: $0.receivedAt) }
        }
        if needed.contains(.goalDone) {
            // 以状态为准（GoalListRules.isDone）：进度 100% 但仍是进行中的不算
            let done = (try? context.fetch(FetchDescriptor<Goal>(predicate: #Predicate { $0.status == "completed" }))) ?? []
            input.firstGoalDone = done.map { LocalDay(date: $0.updatedAt) }.min()
        }
        return input
    }
}

/// 挂在主窗口根视图背后、看不见的检测器：这个库每保存一次（或跨过午夜）计一下，停约 1 秒再看一眼印谱
/// （传书、导入连存几次只看一回）；新得一枚就飘“得印 · …”。刚出现时同样等 1 秒再看（第一次运行把已达成的静默记下），
/// 不拖慢窗口出现；离屏截图等不到这 1 秒，出现时当场看，名帖印谱截得到已达成的印。
/// 应用不在前台时（例如切到终端跟 AI 说话，传书在后台收录）先不看：记一笔“等回来”，切回前台约 1 秒后再看、再飘，
/// 期间不记“今天已庆过”、不占当天的名额，飘字也不会在没人看的窗口上自行散掉。
/// 计数放在这里而不在 RootView：每次保存只让这个小视图重算，根视图和正文页不跟着动
struct MilestoneProbe: View {
    var dayKey: String
    /// 印谱写在哪个偏好域（自检换成用完即删的独立域）
    var defaults: UserDefaults = AppPreferences.defaults
    /// 应用在不在前台（自检换成自己拨的开关）
    var isActive: @MainActor () -> Bool = MilestoneProbe.appIsActive
    /// “回到前台”的通知（自检换成自己的名字，不惊动别处）
    var activation: Notification.Name = NSApplication.didBecomeActiveNotification
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @State private var tick = 0
    /// 在后台时攒下的一次检测：回到前台再看
    @State private var waitingForActive = false

    @MainActor
    static func appIsActive() -> Bool { NSApp?.isActive ?? true }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: RunLoop.main)) { note in
                // 只认自己这个 context 的保存（应用里所有写入都走主 context）。不读 saver.container：
                // 自检里有的库用完就释放，别处的宿主视图还活着时，读已销毁库的 container 会直接崩溃
                guard (note.object as? ModelContext) === context else { return }
                tick &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: activation)) { _ in
                guard waitingForActive else { return }
                waitingForActive = false
                tick &+= 1
            }
            .onChange(of: dayKey) { _, _ in tick &+= 1 }
            .onAppear { if RenderMode.offscreen { look() } }
            .task(id: tick) {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard RenderMode.offscreen || isActive() else {
                    waitingForActive = true
                    return
                }
                look()
            }
    }

    private func look() {
        guard let milestone = MilestoneWatcher.check(context: context, defaults: defaults) else { return }
        effects.sealEarned(milestone)
    }
}

/// 朱砂印泥：与落笔入卷的朱印同一种朱红（深浅色同色）
private let sealInk = Color(red: 0.70, green: 0.20, blue: 0.16)

/// 印谱：标题“印谱 · 已得 3 / 8 枚”，八枚 44pt 方印一行。已得是朱砂底白色宋体两字（悬停写哪天得），
/// 未得是淡墨虚线框（悬停写怎样得），已达成、等明天盖印的是淡金虚线框。刚得的那枚这次出现时盖印亮起一次。
struct SealBook: View {
    @AppStorage(MilestoneKeys.ledger) private var ledgerText = ""
    @AppStorage(MilestoneKeys.fresh) private var freshText = ""
    @AppStorage(MilestoneKeys.pending) private var pendingText = ""
    @Environment(\.spiritMotion) private var motion
    /// 这次出现时盖印亮起的几枚（出现时从偏好里取走）
    @State private var lighting: Set<Milestone> = []

    /// 每枚印微微歪一点（像手钤的），悬停时摆正
    private static let tilts: [Double] = [-2.5, 1.5, -1, 2.5, -2, 1, -1.5, 2]

    var body: some View {
        let ledger = MilestoneLedger(encoded: ledgerText) ?? MilestoneLedger()
        let pending = Set(MilestoneLedger.list(pendingText))
        let today = LocalDay.today()
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "印谱", detail: ledger.countText, hint: "八件小事，各得一方印；每枚只庆一次，得了就一直在")
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(Milestone.allCases.enumerated()), id: \.element) { index, milestone in
                    let status: SealCell.Status = ledger.earned[milestone].map { .earned($0) } ?? (pending.contains(milestone) ? .pending : .locked)
                    SealCell(milestone: milestone, status: status, today: today, tilt: Self.tilts[index % Self.tilts.count],
                             lighting: lighting.contains(milestone), motion: motion)
                        .frame(maxWidth: .infinity)
                }
            }
            if ledger.earned.isEmpty && pending.isEmpty {
                Text("落下第一篇，就得第一方印。").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
        }
        .xianCard()
        .onAppear(perform: takeFresh)
        // 印谱正在眼前时得了新印（例如在名帖里刚把目标改成已完成，约 1 秒后得“功成”）：当场亮起，不等下次进页
        .onChange(of: freshText) { _, _ in takeFresh() }
    }

    /// 从偏好里取走刚得的几枚，交给各自的印位盖印亮起；亮过即清（离屏截图用的是临时偏好域，照样清掉）
    private func takeFresh() {
        let fresh = MilestoneLedger.list(freshText)
        guard !fresh.isEmpty else { return }
        lighting.formUnion(fresh)
        freshText = ""
        // 亮完（约 2.5 秒）收回金光与涟漪的图层；离屏截图停在亮起那一刻，不收
        guard !RenderMode.offscreen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lighting.subtract(fresh) }
    }
}

private struct SealCell: View {
    enum Status: Equatable {
        /// 已得（得印日 YYYY-MM-DD）
        case earned(String)
        /// 已达成，明天盖印
        case pending
        case locked
    }

    var milestone: Milestone
    var status: Status
    var today: LocalDay
    var tilt: Double
    /// 刚得：这次出现时盖印亮起一次
    var lighting: Bool
    var motion: Bool
    @State private var hover = false
    /// 盖印：从 1.9 倍、斜 14° 弹簧落定
    @State private var landed = true
    /// 落定时一圈朱砂涟漪、一团金光
    @State private var ripple = false
    @State private var glow = 0.0

    private static let side: CGFloat = 44

    private var help: String {
        switch status {
        case .earned(let day): "\(milestone.name) · \(Milestone.earnedHelp(day, today: today))"
        case .pending: "\(milestone.name) · 印已成，明日盖印"
        case .locked: milestone.requirement
        }
    }

    private var earned: Bool { if case .earned = status { true } else { false } }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if lighting {
                    SoftGlow(color: Theme.gold.opacity(0.75))
                        .frame(width: Self.side * 2.4, height: Self.side * 2.4)
                        .opacity(glow)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(sealInk.opacity(0.55), lineWidth: 1.4)
                        .frame(width: Self.side, height: Self.side)
                        .scaleEffect(ripple ? 1.9 : 0.8)
                        .opacity(ripple ? 0 : (landed ? 0.8 : 0))
                }
                face
                    .frame(width: Self.side, height: Self.side)
                    .scaleEffect(landed ? (hover && motion ? 1.08 : 1) : 1.9)
                    .rotationEffect(.degrees(landed ? (hover ? 0 : tilt) : tilt - 14))
                    .opacity(landed ? 1 : 0)
            }
            .frame(width: Self.side + 8, height: Self.side + 8)
            Text(milestone.name)
                .font(.ysCaption)
                .foregroundStyle(earned ? Theme.ink : Theme.inkSoft.opacity(status == .pending ? 0.95 : 0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .contentShape(Rectangle())
        .help(help)
        .onHover { inside in
            withAnimation(motion ? .spring(response: 0.28, dampingFraction: 0.7) : nil) { hover = inside }
        }
        .onAppear(perform: stamp)
        .onChange(of: lighting) { _, now in if now { stamp() } }
        // 印谱与“刚得”两项偏好分两次送到：先知道要亮、后知道已得时，等变成已得再盖
        .onChange(of: status) { _, _ in if lighting { stamp() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(milestone.name)，" + (earned ? "已得，\(help)" : status == .pending ? "印已成，明日盖印" : "未得，\(milestone.requirement)"))
    }

    @ViewBuilder
    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        switch status {
        case .earned:
            shape
                .fill(LinearGradient(colors: [sealInk.opacity(0.97), sealInk.opacity(0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(Color.white.opacity(0.72), lineWidth: 1.1).padding(3.5))
                .overlay(Text(milestone.seal).font(Theme.songti(15, .bold)).foregroundStyle(Color.white.opacity(0.95)))
                .shadow(color: sealInk.opacity(hover ? 0.5 : 0.2), radius: hover ? 8 : 2, y: 1)
        case .pending:
            shape
                .fill(Theme.gold.opacity(0.08))
                .overlay(shape.strokeBorder(Theme.gold.opacity(hover ? 0.95 : 0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5])))
                .overlay(Text(milestone.seal).font(Theme.songti(15, .bold)).foregroundStyle(Theme.gold.opacity(0.8)))
                .shadow(color: Theme.gold.opacity(hover ? 0.4 : 0.15), radius: hover ? 8 : 4)
        case .locked:
            shape
                .fill(Theme.mist.opacity(hover ? 0.6 : 0.35))
                .overlay(shape.strokeBorder(hover ? Theme.gold.opacity(0.6) : Theme.inkSoft.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .overlay(Text(milestone.seal).font(Theme.songti(15, .bold)).foregroundStyle(Theme.inkSoft.opacity(hover ? 0.5 : 0.3)))
        }
    }

    /// 刚得的那枚：盖印亮起一次。关动效时直接是已得的样子；离屏截图停在落定、金光未散的那一刻
    private func stamp() {
        guard lighting, earned else { return }
        if RenderMode.offscreen {
            glow = 0.85
            return
        }
        guard motion else { return }
        landed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(Motion.ceremony) { landed = true }
            withAnimation(.easeOut(duration: 0.25).delay(0.12)) { glow = 1 }
            withAnimation(.easeOut(duration: 0.9).delay(0.12)) { ripple = true }
            withAnimation(.easeInOut(duration: 1.4).delay(0.9)) { glow = 0 }
        }
    }
}
