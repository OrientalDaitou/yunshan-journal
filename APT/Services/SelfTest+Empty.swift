import SwiftUI
import SwiftData
import AppKit

// 空状态统一（P4 任务 11）：文案与写法在 Core/EmptyCopy.swift，逐条核对写法在 Tools/CoreCheck 里；
// 这里测要用到应用资源、界面和数据库的部分：小物对得上侧栏、读得出来，各页留白等高，离屏渲染的“全空”真的一条记录都没有。

extension SelfTest {
    static func emptyStateChecks(_ check: (Bool, String) -> Void) throws {
        // 1. 小物：就是侧栏里这一页的那枚（首页“今日功课”与每日功课页共用一张），都能从应用包里读出
        let pages: [(AppSection, EmptyCopy)] = [(.chronicle, .chronicle), (.schedule, .schedule), (.routine, .routine),
                                               (.habits, .habits), (.finance, .finance), (.annals, .annals)]
        check(pages.count == EmptyCopy.all.count && pages.allSatisfy { $0.0.ornament == $0.1.ornament },
              "空状态：各页大号留白的小物就是侧栏里这一页的那枚（\(pages.count) 页）")
        let missing = EmptyCopy.all.filter { Scenery.image($0.copy.ornament) == nil }.map { $0.name }
        check(missing.isEmpty, "空状态：大号留白的小物都能从应用包里读出" + (missing.isEmpty ? "" : "（读不出：\(missing.joined(separator: "、"))）"))

        // 2. 尺寸统一：同宽下“一行说明 + 一排按钮”的几页留白等高；修行录不带按钮，不留按钮那一排的空位
        func height<V: View>(_ view: V) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: 900).environment(\.spiritMotion, false))
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let withButton = EmptyCopy.all.filter { $0.name != "chronicle" }.map { item in
            (item.name, height(OrnamentEmpty(item.copy) {
                Button {} label: { Label("按钮", systemImage: "plus") }.buttonStyle(.yunshanPrimary)
            }))
        }
        let first = withButton.first?.1 ?? 0
        let floor = EmptyStateMetrics.ornament + EmptyStateMetrics.vertical * 2
        check(withButton.allSatisfy { abs($0.1 - first) < 0.5 } && first > floor,
              "空状态：各页大号留白同宽下等高（\(withButton.map { "\($0.0) \(Int($0.1.rounded()))" }.joined(separator: "、")) pt）")
        let bare = height(OrnamentEmpty(.chronicle))
        check(bare > floor && first - bare >= 30,
              "空状态：不带按钮的留白不留按钮那一排的空位（\(Int(bare.rounded())) pt，带按钮的 \(Int(first.rounded())) pt）")
        // 一行小字带不带行尾操作，高度只差按钮本身，不另起一行
        let hint = height(EmptyHint(.nothingAhead))
        let hintWithAction = height(EmptyHint(.nothingAhead) {
            Button {} label: { Label("新增日程", systemImage: "plus") }.buttonStyle(.inlineAction(Theme.gold))
        })
        check(hint > 0 && hintWithAction < hint * 1.8, "空状态：一行小字带上行尾操作仍是一行（\(Int(hint.rounded())) → \(Int(hintWithAction.rounded())) pt）")

        // 3. 离屏渲染的“全空”（APT_RENDER_EMPTY=1，仅调试版）：即使给了存在的旧版数据库、同时设了演示数据，内存库里也一条记录都没有
        #if DEBUG
        check(PageRenderer.emptyRequested(["APT_RENDER_EMPTY": "1"]) && !PageRenderer.emptyRequested([:])
              && !PageRenderer.emptyRequested(["APT_RENDER_NOSEED": "1"]), "空状态：APT_RENDER_EMPTY=1 才是“全空”，NOSEED 不算")
        let container = try DataStore.makeContainer(inMemory: true)
        let c = container.mainContext
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        PageRenderer.prepareData(c, env: ["APT_RENDER_EMPTY": "1", "APT_RENDER_DEMO": "1"], legacyPath: LegacyReader.defaultDatabaseURL.path)
        let records = c.all(JournalEntry.self).count + c.all(Habit.self).count + c.all(HabitLog.self).count
            + c.all(ScheduleEvent.self).count + c.all(RoutineBlock.self).count + c.all(Goal.self).count
            + c.all(LegacyRecord.self).count + c.all(CourierDelivery.self).count + c.all(AdviceRecord.self).count
        let transactions = (try? FinanceService.load(c))?.transactions.count ?? 0
        check(records == 0 && transactions == 0 && c.all(Profile.self).count == 1 && c.all(AppSettings.self).count == 1,
              "空状态：离屏“全空”不读旧版数据库、不加示例与演示数据（记录 \(records) 条、交易 \(transactions) 笔；只有空白的档案与设置各一份）")
        #else
        check(!PageRenderer.emptyRequested(["APT_RENDER_EMPTY": "1"]), "空状态：发布版不认 APT_RENDER_EMPTY")
        #endif
    }
}
