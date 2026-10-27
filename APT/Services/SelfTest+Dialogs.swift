import AppKit
import SwiftData
import SwiftUI

// MARK: - e-dialogs：弹窗与控件一致（#24）
// 编辑弹窗底部渐隐的浓淡、一周作息图的几条小规矩（每小时 26pt、20 分钟以上写字、图例“56 小时”）、
// 新增作息的三个常用选法、功课页“+1”与首页同一条步长规则，以及几张弹窗在 1180×780 的窗口里放得下。
// 三处步长规则彼此对得上，在 Tools/CoreCheck 的 e-dialogs 一节核对。

extension SelfTest {
    static func dialogsChecks(_ check: (Bool, String) -> Void) throws {
        // 1. 编辑弹窗底部渐隐：放得下（或滚到底）不显示；藏着 24pt 以上全浓；中间按比例，取到 0.1 一档
        check(EditorSheetFade.opacity(hiddenBelow: 0) == 0 && EditorSheetFade.opacity(hiddenBelow: 1) == 0
              && EditorSheetFade.opacity(hiddenBelow: -40) == 0 && EditorSheetFade.opacity(hiddenBelow: .nan) == 0
              && EditorSheetFade.opacity(hiddenBelow: 12) == 0.5 && EditorSheetFade.opacity(hiddenBelow: 24) == 1
              && EditorSheetFade.opacity(hiddenBelow: 300) == 1 && EditorSheetFade.height == 24,
              "编辑弹窗底部渐隐：放得下不显示，藏着一半（12pt）半浓，24pt 以上全浓")

        // 2. 一周作息图：30 分钟的早餐也写名字（9pt），一小时以上用角标字号，不到 20 分钟画细线不写字
        let hour = RoutineChartRules.hourHeight
        func size(_ minutes: Int) -> CGFloat? { RoutineChartRules.labelSize(minutes: minutes, height: CGFloat(minutes) / 60 * hour) }
        check(hour == 26 && size(15) == nil && size(19) == nil && size(20) == 9 && size(30) == 9
              && size(60) == TypeSize.micro && size(8 * 60) == TypeSize.micro,
              "作息图每小时 26pt：20–30 分钟的段写 9pt 名字，一小时以上用角标字号，不到 20 分钟是细线")
        check(RoutineChartRules.fillOpacity(dark: false, hover: false) == 0.18 && RoutineChartRules.fillOpacity(dark: true, hover: false) == 0.28
              && RoutineChartRules.fillOpacity(dark: false, hover: true) > 0.18,
              "作息色块底色：类别色 18%（深色 28%），悬停再浓一档")
        check(RoutineChartRules.hoursText(56 * 60) == "56 小时" && RoutineChartRules.hoursText(1050) == "17.5 小时"
              && RoutineChartRules.hoursText(0) == "0 小时" && RoutineChartRules.hoursText(45) == "0.8 小时",
              "图例时长写“56 小时”“17.5 小时”，不再用英文 h：\(RoutineChartRules.hoursText(56 * 60))")

        // 2b. 日程前后缓冲那一行：有作息总在；没有作息、缓冲也是 0 才收起；设过缓冲（日程弹窗照样按它提醒）就得照常可改
        check(RoutineChartRules.showsBuffer(hasRoutine: true, before: 0, after: 0)
              && !RoutineChartRules.showsBuffer(hasRoutine: false, before: 0, after: 0)
              && RoutineChartRules.showsBuffer(hasRoutine: false, before: 15, after: 0)
              && RoutineChartRules.showsBuffer(hasRoutine: false, before: 0, after: 5),
              "起居有常：没有作息但设过日程前后缓冲时，缓冲行照常出现在引导卡底部（两边都是 0 才收起）")

        // 2c. 行尾的玉印勾选只画方框：不留与文字的 9pt 间距，右缘和分隔线对齐；带文字的勾选照旧
        func toggleSize(_ view: some View) -> CGSize {
            let host = NSHostingView(rootView: view.environment(\.spiritMotion, false))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let box = toggleSize(Toggle("", isOn: .constant(true)).toggleStyle(.yunshanBox))
        let hiddenLabel = toggleSize(Toggle("", isOn: .constant(true)).toggleStyle(.yunshan).labelsHidden())
        let labeled = toggleSize(Toggle("记住这个商户", isOn: .constant(false)).toggleStyle(.yunshan))
        check(box.width == YunshanToggleStyle.boxSize && box.height == YunshanToggleStyle.boxSize
              && labeled.width > YunshanToggleStyle.boxSize + 9,
              "分类记忆行尾勾选只占 18×18 的方框（藏文字的旧写法占 \(Int(hiddenLabel.width))pt 宽），带文字的勾选照旧：方框 \(Int(box.width))×\(Int(box.height))、带字 \(Int(labeled.width))")

        // 3. 新增作息“哪几天”的三个常用选法
        check(RoutineDayPreset.all.map(\.label) == ["工作日", "周末", "每天"]
              && RoutineDayPreset.all.map(\.days) == [[0, 1, 2, 3, 4], [5, 6], Array(0...6)],
              "新增作息：工作日 / 周末 / 每天三枚筛选签，各选对那几天")

        // 4. 功课页“+1”直接用首页的步长规则：8 杯 +1、30 分钟 +5、8000 步 +1000、没有目标按 1
        let steps: [(Double?, Double)] = [(nil, 1), (0, 1), (8, 1), (20, 1), (21, 5), (30, 5), (120, 5), (121, 15), (8000, 1000)]
        let wrong = steps.filter { HabitDetail.step($0.0) != $0.1 || HabitDetail.step($0.0) != DashboardRules.quantityStep(target: $0.0 ?? 0) }
        check(wrong.isEmpty && DashboardRules.stepLabel(HabitDetail.step(8000)) == "+1000" && DashboardRules.stepLabel(HabitDetail.step(8)) == "+1",
              "功课页 +1 与首页同一条规则（DashboardRules）：8 杯 +1、30 分钟 +5、8000 步 +1000" + (wrong.isEmpty ? "" : "（不对：\(wrong.map(\.0))）"))

        // 5. 弹窗放得下：1180×780 的窗口（去掉 28pt 标题栏）里，几张编辑弹窗都不超出
        check(HabitEditor.sheetHeight(new: true) == 700 && HabitEditor.sheetHeight(new: false) == 680,
              "习惯弹窗加高：新建 700、编辑 680（备注一节不再被按钮栏切在一半）")
        let container = try DataStore.makeContainer(inMemory: true)
        let c = container.mainContext
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        let habit = Habit(title: "喝水")
        habit.symbol = "drop"
        habit.targetValue = 8
        habit.unit = "杯"
        c.insert(habit)
        DataStore.save(c)
        let limit = CGSize(width: 1180, height: 780 - 28)
        let sheets: [(String, AnyView)] = [
            ("新建习惯", AnyView(HabitEditor(habit: nil, nextSortOrder: 0))),
            ("编辑习惯", AnyView(HabitEditor(habit: habit, nextSortOrder: 0))),
            ("新增作息", AnyView(RoutineEditor(group: nil))),
            ("导入记录", AnyView(FinanceSourcesSheet())),
            ("分类记忆", AnyView(FinanceRulesSheet())),
        ]
        var oversized: [String] = []
        for (name, view) in sheets {
            let host = NSHostingView(rootView: view
                .environment(EffectsCenter())
                .environment(\.spiritMotion, false)
                .modelContainer(container)
                .defaultAppStorage(AppPreferences.defaults))
            host.frame = CGRect(origin: .zero, size: CGSize(width: 900, height: 900))
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            if fitting.width > limit.width || fitting.height > limit.height || fitting.height < 100 {
                oversized.append("\(name) \(Int(fitting.width))×\(Int(fitting.height))")
            }
        }
        check(oversized.isEmpty, "新建 / 编辑习惯、新增作息、导入记录、分类记忆在 1180×780 的窗口里放得下" + (oversized.isEmpty ? "" : "（超出：\(oversized)）"))
    }
}
