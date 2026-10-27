import SwiftUI
import SwiftData

/// 修行录左栏「卷中洞见」：近 90 日记录里的统计规律（最长连续落笔、心境与功课、星期与花钱、最稳与常歇的功课……），最多 3 条，
/// 先报喜再提醒（顺序见 Insight.Kind：有报喜的，第一条就是报喜的）。
/// 每条都有最小样本，不够就不出；措辞只说“…的日子里，…平均…”，不作因果判断；依据（“依据 64 天的心境与打卡”）在悬停提示里。
/// 标题右侧“岁月长卷 →”去看所选时段的全部洞见。
///
/// 取数与计算都走 AIDigest（与问道灵枢、snapshot.md 共用一份按“数据戳 + 今天”的静态缓存，只取元数据不取正文），
/// 不依赖修行录页的 @Query，结果也不只存在卡片自己的 @State 里：切回修行录时卡片是新建的，第一帧就直接拿缓存显示。
/// 进页、过午夜、数据库保存（防抖 1 秒）时核对一次数据戳，没变就是查表。
/// 整个应用一条修行录、打卡、账目都没有时整张卡不显示（新用户的左栏不多一张只有提示的卡）。
struct ChronicleInsightCard: View, Equatable {
    /// “岁月长卷 →”跳去的页面；nil 时不显示这个链接。
    /// 默认按名字找侧栏里的「岁月长卷」页：那一页合入（AppSection 有了 annals）之后链接自动出现，在那之前这里照样能编译。
    var annalsPage: AppSection?

    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 有没有任何记录：三个只取 1 条的小查询（保存后 SwiftData 会重取，很便宜）。
    /// 卡片藏起来时没有生命周期可挂，靠它们在第一篇日记 / 第一次打卡写下后把卡片带出来
    @Query(ChronicleInsightCard.firstEntry) private var anyEntry: [JournalEntry]
    @Query(ChronicleInsightCard.firstLog) private var anyLog: [HabitLog]
    @Query(ChronicleInsightCard.firstLedger) private var anyLedger: [FinanceStore]
    /// 最近一份长期摘要；nil = 第一次计算还没完成（只显示标题行）
    @State private var digest: LongTermDigest?
    /// 数据库保存的次数：变了就（防抖 1 秒后）核对一次数据戳
    @State private var saves = 0
    /// 上次给用户看过的几条（“类型 + 正文”）：新出现或文字变了的那条淡入并一闪金星，看过的不再闪
    @AppStorage("chronicle.insights.seen") private var seen = ""

    init(annalsPage: AppSection? = AppSection(rawValue: "annals")) {
        self.annalsPage = annalsPage
        _digest = State(initialValue: AIDigest.latest())
    }

    static func == (a: Self, b: Self) -> Bool { a.annalsPage == b.annalsPage }

    private static var firstEntry: FetchDescriptor<JournalEntry> { probe() }
    private static var firstLog: FetchDescriptor<HabitLog> { probe() }
    private static var firstLedger: FetchDescriptor<FinanceStore> { probe() }
    private static func probe<T: PersistentModel>() -> FetchDescriptor<T> {
        var descriptor = FetchDescriptor<T>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    private var animate: Bool { motion && !reduceMotion && !RenderMode.offscreen }

    /// 修行录、打卡、账目任有一样就显示（账簿只在前两样都没有时才读，有解码缓存）
    private var hasRecords: Bool {
        if !anyEntry.isEmpty || !anyLog.isEmpty { return true }
        guard !anyLedger.isEmpty, let ledger = try? FinanceService.load(context) else { return false }
        return !ledger.transactions.isEmpty
    }

    var body: some View {
        if hasRecords { card }
    }

    private var card: some View {
        let today = LocalDay.today()
        let shown = digest?.cardInsights ?? []
        let fresh = LongTermDigest.freshKinds(seen: seen, shown: shown)
        let token = LongTermDigest.seenToken(shown)
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "卷中洞见", detail: "近 \(LongTermDigest.windowDays) 日",
                      hint: "只做统计，不代表因果；样本不够的不列。悬停一条可看依据") {
                HStack(spacing: 8) {
                    if let annalsPage {
                        Button("岁月长卷") { router.page = annalsPage }
                            .buttonStyle(.cardLink)
                            .help("在岁月长卷里看一年 / 一季的全部洞见")
                    }
                    // 星图小物：洞见即“观星”，与岁月长卷“其七 · 洞见”同一张
                    SceneryImage(name: "yunshan-ornament-star-map-v1")
                        .frame(width: 30, height: 30)
                        .opacity(0.72)
                        .padding(.vertical, -6)
                }
            }
            if let digest {
                if shown.isEmpty {
                    Hint("记录再多一些，这里会浮现规律：心境与功课、星期与花钱……", symbol: "sparkles")
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(shown.enumerated()), id: \.element.line) { index, insight in
                            InsightRow(insight: insight, play: animate && fresh.contains(insight.kind), order: index)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("卷中洞见，\(digest.cardInsights.count) 条")
                }
            }
        }
        .xianCard()
        .onAppear {
            // 离屏截图：同步算完（.task 赶不上截图）
            if RenderMode.offscreen { digest = AIDigest.digest(context: context, today: today) }
        }
        // 进页、过午夜、保存之后核对数据戳（没变就是查表）；保存后防抖 1 秒，连续保存只算最后一次
        .task(id: "\(today.key)|\(saves)") {
            if saves > 0 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            } else {
                // 先让切页转场动起来再算（通常快照早已算好、这里只是查表；冷启动后第一次在 5 年数据上约半秒）
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            let next = AIDigest.digest(context: context, today: today)
            guard next != digest else { return }
            withAnimation(animate ? Motion.standard : nil) { digest = next }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
            if (note.object as? ModelContext) === context { saves += 1 }
        }
        // 这几条看过了：等淡入与金星播完再记下（中途切走就当没看过，下次进来照样闪）
        .task(id: token) {
            guard digest != nil, !shown.isEmpty, token != seen else { return }
            do { try await Task.sleep(for: .seconds(animate ? 1.6 : 0.2)) } catch { return }
            seen = token
        }
    }
}

/// 卷中洞见的一条：左侧带淡色光晕的小图标（心境 / 连续金、功课玉、花钱青），右侧正文；整行是一块内嵌格，不可点。
/// 新出现或文字变了的那条（play）依次淡入（错开 80 毫秒），图标处一颗金色小星一闪（0.6 秒，只一次）。
private struct InsightRow: View {
    var insight: Insight
    var play: Bool
    var order: Int
    @State private var shown: Bool
    /// 金星一闪的触发器：变一次播一次
    @State private var flashes = 0

    init(insight: Insight, play: Bool, order: Int) {
        self.insight = insight
        self.play = play
        self.order = order
        _shown = State(initialValue: !play)
    }

    private var tint: Color {
        switch insight.tone {
        case .mood: Theme.precious
        case .habit: Theme.positive
        case .spend: Theme.info
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            Text(insight.text)
                .font(.ysCallout)
                .lineSpacing(2)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Theme.mist.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .help(insight.basis)
        .accessibilityElement(children: .combine)
        .accessibilityHint(insight.basis)
        .opacity(shown ? 1 : 0)
        .offset(x: shown ? 0 : -8)
        .onAppear {
            guard play else { return }
            // 卡片自己进页上浮约 0.5 秒：之后再一条条点亮
            let delay = 0.42 + Double(order) * 0.08
            withAnimation(.easeOut(duration: 0.38).delay(delay)) { shown = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay + 0.12))
                flashes += 1
            }
        }
    }

    /// 图标：底下一团同色淡光晕；play 时金星在右上角一闪，光晕随之亮一下
    private var icon: some View {
        ZStack {
            Circle().fill(tint.opacity(0.12)).frame(width: 24, height: 24)
            Image(systemName: insight.symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .keyframeAnimator(initialValue: StarFlash(), trigger: flashes) { view, value in
            view
                .background {
                    SoftGlow(color: Theme.gold.opacity(0.55 * value.glow))
                        .frame(width: 46, height: 46)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.gold)
                        .shadow(color: Theme.gold.opacity(0.8), radius: 3)
                        .scaleEffect(value.scale)
                        .rotationEffect(.degrees(value.spin))
                        .opacity(value.star)
                        .offset(x: 6, y: -6)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.3, duration: 0.24)
                CubicKeyframe(0.5, duration: 0.36)
            }
            KeyframeTrack(\.star) {
                LinearKeyframe(1, duration: 0.12)
                LinearKeyframe(1, duration: 0.18)
                CubicKeyframe(0, duration: 0.3)
            }
            KeyframeTrack(\.spin) {
                CubicKeyframe(45, duration: 0.6)
            }
            KeyframeTrack(\.glow) {
                CubicKeyframe(1, duration: 0.2)
                CubicKeyframe(0, duration: 0.4)
            }
        }
        .frame(width: 24, height: 24)
        .padding(.top, -2)
        .accessibilityHidden(true)
    }
}

/// 金星一闪的几项动画值（静止时都看不见）
private struct StarFlash {
    var scale: CGFloat = 0.3
    var star: Double = 0
    var spin: Double = -20
    var glow: Double = 0
}
