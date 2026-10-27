import SwiftUI
import SwiftData

// 今日洞府左栏“旧笔新读”：把往年今日写下的话摆到每天必看的首页上
// （回看审计：首页四张卡全是“今天”，往日回看藏在修行录左栏第三张）。
// 取哪几天、眉题、摘句与落款的规矩在 Core/DashboardRules（CoreCheck 逐条核对）；这里只取数与画。

/// 旧笔新读卡（纸笺卡）：标题行“旧笔新读  一年前的今天 · 周三”，右侧一枚沙漏小物（与修行录“往日回看”同一枚）；
/// 正文是一段左侧金线的引文（宋体，标题一行 + 正文摘句，最多 3 行），下面落款“心境 晴 · 2025年10月22日”，
/// 行尾就地操作“换一篇 ↻”“读全文 →”（点引文同样打开只读的阅读弹窗）。
/// - 先看一年前、半年前、一月前、一周前的今天（各自前后放宽一天，与往日回看同几天）；
///   都没有 → 7 天以前的珍藏（按日期固定从某一篇起）；再没有 → 7 天以前的任一篇（同样按日期固定）；
///   都没有（写过，但都在近 7 天里）→ 一行“写满七日，这里会浮现你写过的话。”；一篇修行录都没有 → 整张卡不出。
/// - “换一篇”顺延：各时点的篇目之后接着珍藏，最多 12 篇，绕一圈回到第一篇。
/// - 取数只在 `.task(id: 今天)` 里做一次（DashboardLookBackLoader）：都按 dateKey / 珍藏的谓词直接取，几毫秒；
///   不整表取，也不为它去建修行录摘要（5 年数据第一次建约 0.4 秒）。有没有修行录靠一个只取 1 条的小查询，第一篇写下后卡片自己出来。
/// - 在阅读弹窗里删掉一篇：与修行录一样先拍快照，首页底部给约 8 秒“撤销删除”（DashboardLookBackUndo），修为扣回有提示；
///   删除、撤销后都按当天重新取一次（删掉的换成下一篇；候选删光了照样往下找珍藏、旧笔，不会误写“写满七日”）。
///   别处删掉了正显示的篇目（卡片还开着）时同样重取。
struct DashboardLookBack: View, Equatable {
    var today: LocalDay
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    @Query(DashboardLookBack.probe) private var anyEntry: [JournalEntry]
    @State private var picks: [DashboardLookBackLoader.Pick] = []
    /// 这一天取过数没有（没取到之前不说“写满七日”，免得一闪）
    @State private var loadedDay: String?
    /// “换一篇”翻到第几篇
    @State private var index = 0
    /// “换一篇”的小箭头转了几圈（动效开着时每点一下转一圈）
    @State private var spins = 0.0
    @State private var reading: JournalEntry?

    /// 父视图刷新时只看日期：取过的篇目留着，不重取
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.today == rhs.today }

    /// 有没有任何一篇修行录：只取 1 条
    private static var probe: FetchDescriptor<JournalEntry> {
        var descriptor = FetchDescriptor<JournalEntry>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// 还在库里的篇目（在阅读弹窗里删掉的跳过；已删除的对象不能再读）
    private var valid: [DashboardLookBackLoader.Pick] {
        picks.filter { $0.entry.modelContext != nil && !$0.entry.isDeleted }
    }

    var body: some View {
        // 在这里删过、撤销过几次：变了就按当天重取（读它的只有这张卡和底部的撤销条，首页其余卡片不跟着重算）
        let revision = DashboardLookBackUndo.shared.revision
        // 入场挂在 if 里面：一篇都没有时这里什么都不出，左栏不为它留卡距（栏位由首页在外面挂 overviewSlot）
        if !anyEntry.isEmpty {
            card
                .xianCard()
                .ysEntrance(order: 2)
                .task(id: "\(today.key)#\(revision)") { load() }
                // 别处删掉了取到的篇目（这张卡还开着）：重取，空出来的位置换成下一篇
                .onChange(of: valid.count) { _, count in
                    if count < picks.count { load() }
                }
                // 删除走首页自己的撤销（快照 + 底部约 8 秒“撤销删除”），确认框里“约 8 秒内可以找回”说的就是它
                .sheet(item: $reading) { entry in
                    JournalEditSheet(entry: entry, startReadOnly: true) { deleted in
                        DashboardLookBackUndo.shared.delete(deleted, context: context, effects: effects)
                    }
                }
        }
    }

    private var card: some View {
        let valid = self.valid
        let pick = valid.isEmpty ? nil : valid[index % valid.count]
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "旧笔新读", detail: pick?.eyebrow ?? "",
                      hint: "往年今日写下的话：一年、半年、一月、一周前的今天；都没有时取一篇珍藏") {
                SceneryImage(name: "yunshan-ornament-hourglass-v1")
                    .frame(width: 30, height: 30)
                    .opacity(0.7)
                    .padding(.vertical, -6)
                    .accessibilityHidden(true)
            }
            if let pick {
                quote(pick.entry)
                    .id(pick.entry.persistentModelID)
                    .transition(motion ? .opacity.combined(with: .offset(y: 4)) : .identity)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 落款按这一篇现在的样子写（在阅读弹窗里修订过心境、日期也跟着变）
                    Text(DashboardRules.signature(kindLabel: pick.entry.kindValue == .diary ? nil : pick.entry.kindValue.label,
                                                  mood: pick.entry.mood, day: LocalDay(key: pick.entry.dateKey) ?? pick.day))
                        .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).lineLimit(1)
                    Spacer(minLength: 8)
                    if valid.count > 1 {
                        Button(action: next) {
                            HStack(spacing: 3) {
                                Text("换一篇")
                                Image(systemName: "arrow.clockwise").rotationEffect(.degrees(spins))
                            }
                        }
                        .buttonStyle(.inlineAction())
                        .help("换一篇往日写下的（共 \(valid.count) 篇，绕一圈回到这篇）")
                    }
                    Button("读全文") { reading = pick.entry }
                        .buttonStyle(.cardLink)
                        .help("打开这一篇阅读；要改点“修订”")
                }
            } else if loadedDay == today.key {
                EmptyHint(symbol: "hourglass", text: DashboardRules.waitingLine)
            }
        }
    }

    /// 引文：左侧一道金线，宋体；有标题时标题一行、正文摘句两行，没有标题时摘句三行。整块可点，悬停泛淡玉底
    private func quote(_ entry: JournalEntry) -> some View {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = DashboardRules.excerpt(entry.body)
        return Button { reading = entry } label: {
            VStack(alignment: .leading, spacing: 4) {
                if !title.isEmpty {
                    Text(title).font(Theme.songti(TypeSize.body, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                if !excerpt.isEmpty || title.isEmpty {
                    Text(excerpt.isEmpty ? entry.displayTitle : excerpt)
                        .font(Theme.songti(TypeSize.body))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(3)
                        .lineLimit(title.isEmpty ? 3 : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.gold.opacity(0.75)).frame(width: 2).padding(.vertical, 2)
            }
            .yunshanTile(cornerRadius: Radius.inner)
        }
        .buttonStyle(.plain)
        .help("阅读这一篇")
        .accessibilityLabel("旧笔：" + (title.isEmpty ? excerpt : title + "。" + excerpt))
    }

    private func next() {
        withAnimation(motion ? Motion.standard : nil) {
            index += 1
            if motion { spins += 360 }
        }
    }

    /// 按当天取一次。同一天里重取（删除、撤销之后）留在原来翻到的位置：删掉的那篇换成排在它后面的一篇，撤销后它回到原处
    private func load() {
        picks = DashboardLookBackLoader.load(context, today: today)
        if loadedDay != today.key { index = 0 }
        loadedDay = today.key
    }
}

/// 旧笔新读里删掉的那一篇：首页底部约 8 秒的“撤销删除”（与修行录、岁月长卷同样的做法：先拍快照再删，撤销时原样插回，修为随之扣回 / 恢复）。
/// 放在页面之外：删完切走又切回来、或换日整页重建，提示条和快照都还在（换日本身在撤销期间也会先等，见 JournalActions.undoWindowOpen）。
/// 只有底部的提示条和旧笔新读卡读它，首页其余卡片不跟着重算。
@MainActor
@Observable
final class DashboardLookBackUndo {
    static let shared = DashboardLookBackUndo()
    /// 提示条停多久
    static let seconds: TimeInterval = 8

    /// 正在给的“撤销删除”；到点收起
    private(set) var offer: DeletedEntryOffer?
    /// 删除、撤销各加一：旧笔新读按它重取
    private(set) var revision = 0

    /// 删除一篇：拍快照、删掉（修为扣回，effects 给出提示），底部给约 8 秒“撤销删除”。返回这次的提示条
    @discardableResult
    func delete(_ entry: JournalEntry, context: ModelContext, effects: EffectsCenter?) -> DeletedEntryOffer {
        let offer = DeletedEntryOffer(snapshot: JournalActions.delete(entry, context: context, effects: effects))
        self.offer = offer
        revision += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.seconds))
            if self?.offer?.id == offer.id { self?.offer = nil }
        }
        return offer
    }

    /// 撤销删除：用快照原样插回（修为恢复）。提示条已经换成别的、或已收起时不动，返回 false
    @discardableResult
    func restore(_ offer: DeletedEntryOffer, context: ModelContext, effects: EffectsCenter?) -> Bool {
        guard self.offer?.id == offer.id else { return false }
        self.offer = nil
        JournalActions.restore(offer.snapshot, context: context, effects: effects)
        revision += 1
        return true
    }
}

/// 首页底部“已删除「…」 · 撤销删除”：与修行录、岁月长卷同一种胶囊（那两条各自私有，照样式另写）。
/// 动效开着时从底部滑入、收起时滑出；关着时只淡入淡出。
struct DashboardLookBackUndoBar: View {
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animate: Bool { motion && !reduceMotion && !RenderMode.offscreen }

    var body: some View {
        let undo = DashboardLookBackUndo.shared
        ZStack {
            if let offer = undo.offer {
                HStack(spacing: 12) {
                    Image(systemName: "trash").foregroundStyle(Theme.inkSoft)
                    Text("已删除「\(offer.snapshot.label)」").foregroundStyle(Theme.ink).lineLimit(1)
                    Button("撤销删除") { undo.restore(offer, context: context, effects: effects) }
                        .buttonStyle(.yunshanCompact)
                        .help("把这一篇原样找回，修为随之恢复")
                }
                .font(.ysCallout)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                // 按路径画的胶囊：系统 Capsule 的底加描边在两端会多出两截细竖线（见 PathCapsule）
                .background(Theme.card, in: PathCapsule())
                .overlay(PathCapsule().strokeBorder(Theme.gold.opacity(0.45)))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.bottom, 26)
                .transition(animate ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
            }
        }
        .animation(animate ? .easeOut(duration: 0.25) : nil, value: undo.offer?.id)
    }
}

/// 旧笔新读取哪几篇（界面与自检共用）。都按谓词直接取，不整表取：
/// 四个时点那 12 天一次取出；珍藏只取 7 天以前、标了珍藏的；兜底的旧笔先数一数、再按日期固定的位置各取 1 条。
@MainActor
enum DashboardLookBackLoader {
    struct Pick {
        var entry: JournalEntry
        /// 这一篇的日期
        var day: LocalDay
        /// 眉题：“一年前的今天 · 周三”“珍藏 · 3 个月前”“10 日前 · 周一”
        var eyebrow: String
    }

    /// “换一篇”最多轮到这么多篇
    static let limit = 12
    /// 兜底的旧笔（没有往年今日、也没有珍藏时）最多取这么多篇
    static let olderLimit = 5

    static func load(_ context: ModelContext, today: LocalDay) -> [Pick] {
        var picks: [Pick] = []
        var seen = Set<PersistentIdentifier>()
        func add(_ entry: JournalEntry, eyebrow: (LocalDay) -> String) {
            guard picks.count < limit, seen.insert(entry.persistentModelID).inserted else { return }
            let day = LocalDay(key: entry.dateKey) ?? entry.day
            picks.append(Pick(entry: entry, day: day, eyebrow: eyebrow(day)))
        }

        // 1. 一年前、半年前、一月前、一周前（先远后近），同一天的按时间先后
        let keys = DashboardRules.lookBackKeys(today: today)
        let near = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { keys.contains($0.dateKey) }))) ?? []
        let byDay = Dictionary(grouping: near, by: \.dateKey)
        for span in DashboardRules.lookBackFound(today: today, written: Set(byDay.keys)) {
            for entry in JournalOrder.oldestFirst(byDay[span.day.key] ?? []) {
                add(entry) { _ in DashboardRules.spanEyebrow(span.label, day: span.day, exact: span.exact) }
            }
        }

        // 2. 7 天以前的珍藏：按日期排好，从按今天固定的那一篇起绕一圈
        let cutoff = DashboardRules.olderCutoff(today: today).key
        let pinned = (try? context.fetch(FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.pinned == true && $0.dateKey <= cutoff },
            sortBy: [SortDescriptor(\.dateKey), SortDescriptor(\.createdAt)]))) ?? []
        for position in DashboardRules.rotation(count: pinned.count, start: DashboardRules.dailyIndex(today, count: pinned.count), limit: limit) {
            add(pinned[position]) { DashboardRules.pinnedEyebrow(day: $0, today: today) }
        }
        guard picks.isEmpty else { return picks }

        // 3. 兜底：7 天以前的任一篇（同样按今天固定的位置起，各取 1 条）
        let older = #Predicate<JournalEntry> { $0.dateKey <= cutoff }
        let count = (try? context.fetchCount(FetchDescriptor(predicate: older))) ?? 0
        for position in DashboardRules.rotation(count: count, start: DashboardRules.dailyIndex(today, count: count), limit: olderLimit) {
            var descriptor = FetchDescriptor(predicate: older, sortBy: [SortDescriptor(\.dateKey), SortDescriptor(\.createdAt)])
            descriptor.fetchOffset = position
            descriptor.fetchLimit = 1
            if let entry = (try? context.fetch(descriptor))?.first {
                add(entry) { DashboardRules.olderEyebrow(day: $0, today: today) }
            }
        }
        return picks
    }
}
