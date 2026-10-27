import SwiftUI
import SwiftData

/// 今日洞府右栏最上面的“所向”（#8）：进行中的目标最多两行（必须 > 应该 > 可以，再按期限近，见 GoalStripRules），
/// 每行“完成学位论文初稿　▬▬▬▭▭　65% · 还剩 58 天”；过期写“期限已过 3 天”（警示色），没期限写“未定期限”。
/// 整行点开修士名帖；多于两个时标题行右侧“另有 N 个 →”。没有进行中的目标时整张不出（这一格没有子视图，右栏不留卡距）。
/// 只取进行中的目标（谓词交给数据库，目标一般只有几个）；只依赖日期：父视图刷新时不重取。
struct GoalStrip: View, Equatable {
    var today: LocalDay
    var onOpen: () -> Void
    @Query(filter: #Predicate<Goal> { $0.status == "active" }) private var goals: [Goal]

    /// 父视图刷新时只看日期（打开名帖的回调每次都是新的闭包，不算变化）
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.today == rhs.today }

    var body: some View {
        let items = goals.filter { $0.modelContext != nil }.map {
            GoalStripRules.Item(title: $0.title, priority: $0.priority, progress: $0.progress, targetDate: $0.targetDate, createdAt: $0.createdAt)
        }
        if !items.isEmpty {
            let pick = GoalStripRules.pick(items)
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "所向", detail: "",
                          hint: "进行中的目标：必须的在前，再按期限近；点一行打开修士名帖") {
                    if let more = GoalStripRules.moreText(pick.more) {
                        Button(more, action: onOpen).buttonStyle(.cardLink).help("在修士名帖里看全部目标")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(pick.shown.enumerated()), id: \.offset) { _, item in
                        GoalStripRow(item: item, today: today, onOpen: onOpen)
                    }
                }
                .padding(.horizontal, -8)
            }
            // 与首页其他卡同样的 24 内边距：标题的金色竖条与下面“今日功课”的竖条左右对齐
            .xianCard()
            .ysEntrance(order: 1)
        }
    }
}

/// 所向的一行：名字、进度条、百分比与期限。放得下就一行，窄了把进度条与期限挪到第二行（名字不被挤成“…”）
private struct GoalStripRow: View {
    var item: GoalStripRules.Item
    var today: LocalDay
    var onOpen: () -> Void

    var body: some View {
        let deadline = GoalStripRules.deadline(item.targetDate, today: today)
        Button(action: onOpen) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    title
                    Spacer(minLength: 8)
                    ProgressBar(value: Double(item.progress) / 100, height: 5).frame(width: 72)
                    figures(deadline)
                }
                VStack(alignment: .leading, spacing: 5) {
                    title
                    HStack(spacing: 10) {
                        ProgressBar(value: Double(item.progress) / 100, height: 5)
                        figures(deadline)
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .yunshanTile(cornerRadius: Radius.inner)
        }
        .buttonStyle(.plain)
        .help("\(item.title)：进度 \(GoalStripRules.percent(item.progress))，\(deadline.text)。点开修士名帖")
        .accessibilityLabel("\(item.title)，进度 \(GoalStripRules.percent(item.progress))，\(deadline.text)")
    }

    private var title: some View {
        Text(item.title).font(.ysCallout).foregroundStyle(Theme.ink).lineLimit(1)
    }

    private func figures(_ deadline: (text: String, overdue: Bool)) -> some View {
        HStack(spacing: 4) {
            Text(GoalStripRules.percent(item.progress)).foregroundStyle(Theme.ink)
            Text("·").foregroundStyle(Theme.inkSoft.opacity(0.6))
            Text(deadline.text).foregroundStyle(deadline.overdue ? Theme.warning : Theme.inkSoft)
        }
        .font(.ysCaption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}
