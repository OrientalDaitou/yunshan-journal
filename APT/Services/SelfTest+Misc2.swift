import Foundation
import SwiftData
import SwiftUI
import AppKit

// e-misc（#25 杂项）的运行时自检：
// 1. 传书笺撤销说明：真收录一封带日记的传书，说明句末是“删除后无法找回。”，切开后只有这一句用朱砂；只恢复档案时没有这句；
// 2. 传书笺排版：宽 384，“备注 +「…」”整段换到下一行；日期、数量与单位按笺宽实排不在中间折开（只改显示，行文不变）；
// 3. 账簿账头：没有退款、教育支出时不写“扣款”；“部分”改叫“未导全”；
// 4. 渡劫画面标题背后的暗晕半径 280，离屏画得出来；暗晕在光柱下面，光柱中段的亮度不被压暗；
// 5. 快捷键一览里随手记 ⌘↩ 那一行叫“随手记记下 / 收起”，组合键不变，小字折行时按钮名整词一起走。
// 纯函数（说法、切分、空状态文案、⌘↩ 的说明）在 CoreCheck 末尾的 e-misc 一节。

extension SelfTest {
    @MainActor
    static func misc2Checks(_ check: (Bool, String) -> Void) throws {
        // 1. 撤销说明：真收录一封传书（一篇日记 + 一个档案字段）再看预览
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        DataStore.profile(in: context)["main_tasks"] = "旧任务"
        DataStore.save(context)
        func deliver(_ items: [[String: Any]], _ name: String) throws -> CourierDelivery {
            let data = try JSONSerialization.data(withJSONObject: ["from": "自检", "items": items])
            return try CourierService.apply(try CourierParser.parse(data), fileName: name, context: context)
        }
        let today = LocalDay.today()
        let mixed = try deliver([["type": "diary", "date": today.key, "body": "e-misc 自检·撤销说明"],
                                 ["type": "profile", "fields": ["main_tasks": "新任务"]]], "e-misc-mixed.json")
        let plan = RootView.courierUndoPlan(CourierService.undoPreviewDetail(mixed, context: context))
        let parts = CourierUndoWording.splitWarning("再点一次即撤销：" + plan)
        check(plan == "将删除 1 条记录，恢复 1 个档案字段。删除后无法找回。"
              && parts.warning == "删除后无法找回。" && parts.body == "再点一次即撤销：将删除 1 条记录，恢复 1 个档案字段。",
              "传书笺撤销说明：有删除时句末加“删除后无法找回。”，只有这一句切出来用朱砂（\(plan)）")
        let panel = CourierUndoWording.panelLines(CourierService.undoPreviewDetail(mixed, context: context).wording)
        check(panel.first?.hasSuffix(CourierUndoWording.deletionWarning) == true,
              "左栏确认框第一行也以“删除后无法找回。”收尾，与传书笺同一句（\(panel.first ?? "")）")
        _ = CourierService.undo(mixed, context: context, refresh: false)
        let profileOnly = try deliver([["type": "profile", "fields": ["main_tasks": "又一版任务"]]], "e-misc-profile.json")
        let quiet = RootView.courierUndoPlan(CourierService.undoPreviewDetail(profileOnly, context: context))
        check(quiet == "将恢复 1 个档案字段" && CourierUndoWording.splitWarning(quiet).warning == nil,
              "只恢复档案字段时不写“删除后无法找回”，整段正文色（\(quiet)）")

        // 2. 传书笺排版
        let goalLine = "目标 · 完成学位论文初稿：进度 60% → 65%；备注 +「第三章初稿完成」"
        check(CourierCardText.width == 384
              && CourierCardText.wrappingNote(goalLine) == "目标 · 完成学位论文初稿：进度 60% → 65%\n备注 +「第三章初稿完成」"
              && CourierCardText.wrappingNote("功课 · 新立「冥想」（每天，每次 10分钟，自 10月21日 起）") == "功课 · 新立「冥想」（每天，每次 10分钟，自 10月21日 起）"
              && CourierLineDecor.progressMove(goalLine) != nil,
              "传书笺：宽 384；“备注 +「…」”整段另起一行，没有备注的行不动，进度行照样认得出")
        let glued = CourierCardText.unbreakable(CourierUndoWording.deletionWarning)
        check(glued.replacingOccurrences(of: "\u{2060}", with: "") == CourierUndoWording.deletionWarning
              && glued.unicodeScalars.filter { $0 == "\u{2060}" }.count == CourierUndoWording.deletionWarning.count - 1,
              "传书笺：朱砂的“删除后无法找回。”字间夹字连接符，整句不折开，去掉后与原句相同")
        // 只改了备注的目标行（“：备注 +「”）也把备注整段换到下一行，冒号留在上一行
        let noteOnly = "目标 · 更新「完成学位论文初稿与答辩准备」：备注 +「第三章初稿完成」"
        check(CourierCardText.wrappingNote(noteOnly) == "目标 · 更新「完成学位论文初稿与答辩准备」：\n备注 +「第三章初稿完成」"
              && CourierCardText.display(noteOnly).noteWrapped && !CourierCardText.display("功课 · 新立「早睡」（每天，自 10月23日 起）").noteWrapped,
              "传书笺：只改备注的目标行，“备注 +「…」”同样另起一行")

        // 日期、数量与单位不折开：功法谱十二式经传书新立时的行（另加“拉伸”改成每周 3 次），按笺上正文宽度实排一遍，
        // 折行处都不落在“10月23日”“8000步”“90分钟”“3 次”这类片段中间；显示文本去掉 U+2060 后与原行相同
        let base = LocalDay(year: 2026, month: 10, day: 22), start = LocalDay(year: 2026, month: 10, day: 23)
        func habitLine(_ t: HabitTemplate, weekly: Int? = nil) -> String {
            let h = CourierHabit(title: t.title, frequency: weekly == nil ? t.frequency : .weekly, timesPerWeek: weekly ?? t.targetPerWeek,
                                 weekdays: weekly == nil ? t.weekdays : [], target: t.targetValue, unit: t.unit, startDay: start,
                                 category: t.group, symbol: t.symbol, notes: t.notes)
            return CourierLineDecor.habitCreateLine(h, today: base)
        }
        var lines = HabitTemplates.all.map { habitLine($0) }
        if let stretch = HabitTemplates.named("拉伸") { lines.append(habitLine(stretch, weekly: 3)) }
        lines.append(CourierLineDecor.habitCreateLine(CourierHabit(title: "跑步", frequency: .daily, timesPerWeek: 1, weekdays: [], target: 5,
                                                                   unit: "公里", startDay: LocalDay(year: 2027, month: 1, day: 5), category: "身体",
                                                                   symbol: "figure.run", notes: ""), today: base))
        let textWidth = CourierCardText.width - 32 - 40   // 笺的左右内边距 16 × 2，正文前面让出图标的 40
        var unchanged: [String] = [], split: [String] = [], unglued = 0
        for line in lines {
            let shown = CourierCardText.display(line).text
            if shown.replacingOccurrences(of: "\u{2060}", with: "") != line { unchanged.append(line) }
            if !misc2BreaksInsideFigures(shown, width: textWidth).isEmpty { split.append(line) }
            if !misc2BreaksInsideFigures(line, width: textWidth).isEmpty { unglued += 1 }
        }
        check(unchanged.isEmpty && split.isEmpty && lines.count == 14
              && lines.contains("功课 · 新立「步数」（每天，每次\u{A0}8000步，自\u{A0}10月23日\u{A0}起）")
              && CourierCardText.gluingFigures("自 10月23日 起").contains("1\u{2060}0\u{2060}月\u{2060}2\u{2060}3\u{2060}日"),
              "传书笺：日期、数量与单位不在中间折行，去掉 U+2060 后与原行相同（不粘时 \(unglued) 行会折在中间；仍折开的：\(split)；行文变了的：\(unchanged)）")

        // 3. 账簿账头与月份小标
        check(!FinanceHeadlineRule.showsDebit(refundCents: 0, educationCents: 0)
              && FinanceHeadlineRule.showsDebit(refundCents: 86, educationCents: 0)
              && FinanceHeadlineRule.showsDebit(refundCents: 0, educationCents: 120_000)
              && FinanceHeadlineRule.partialLabel == "未导全" && FinanceHeadlineRule.partialSymbol == "exclamationmark.circle"
              && NSImage(systemSymbolName: FinanceHeadlineRule.partialSymbol, accessibilityDescription: nil) != nil,
              "账簿：没有退款、教育支出时不写“扣款”（与净消费同一个数）；月份小标写“未导全”并带小图标")

        // 4. 渡劫标题背后的暗晕：半径 280；定格离屏画得出来
        let renderer = ImageRenderer(content: TribulationScene.still(realm: "元婴", emblem: RealmBadge.emblem(for: 3), elapsed: 3.2)
            .frame(width: 900, height: 700))
        check(TribulationScene.haloRadius == 280 && renderer.nsImage.map { $0.size.width >= 900 } == true,
              "渡劫：标题背后的暗晕半径 280，3.2 秒定格画得出来")
        // 暗晕夹在劫云与光柱之间：光柱中段（境界名到“道心坚定”一带）不被压暗。叠在灰底上按 1180×780 定格，
        // 量画面正中一条竖带的平均亮度（暗晕若盖在光柱上，约 0.71 × (1 − 0.5) ≈ 0.36–0.45；在下面时约 0.7）
        let pillar = ImageRenderer(content: ZStack {
            Color(white: 0.3)
            TribulationScene.still(realm: "元婴", emblem: RealmBadge.emblem(for: 3), elapsed: 3.2)
        }.frame(width: 1180, height: 780))
        pillar.scale = 1
        let lit = pillar.cgImage.flatMap { misc2MeanLuminance($0, x: 587...593, y: 420...560) }
        check((lit ?? 0) > 0.6, "渡劫：暗晕在光柱下面，光柱中段不被压暗（亮度 \(lit.map { String(format: "%.2f", $0) } ?? "nil")）")

        // 5. 快捷键一览：随手记 ⌘↩（按钮名字间夹了 U+2060，比较前去掉）
        let row = KeyGuide.sections.flatMap(\.rows).first { $0.commands.contains(.quickCaptureSubmit) }
        check(row?.title == "随手记记下 / 收起" && KeyCommand.quickCaptureSubmit.display == "⌘↩"
              && (row?.note ?? "").replacingOccurrences(of: "\u{2060}", with: "").hasPrefix("按认出的类型写“落笔入卷 / 入账 / 打卡 / 记入时辰卷”"),
              "快捷键一览：随手记那一行叫“随手记记下 / 收起”，⌘↩ 不变（\(row?.title ?? "nil")）")
        // 按一览里这行小字的大致宽度实排：折行不落在“记入时辰卷”等按钮名中间
        let keyNote = row?.note ?? ""
        let keyWidths: [CGFloat] = [480, 420, 380, 340]
        let keyBreaks = keyWidths.flatMap { misc2LineBreaks(keyNote, width: $0) }
        let plainNote = keyNote.replacingOccurrences(of: "\u{2060}", with: "") as NSString
        let labelRanges = ["落笔入卷", "入账", "打卡", "记入时辰卷"].map { plainNote.range(of: $0) }
        // 折行处换算回不含 U+2060 的位置（每个 U+2060 占一个 UTF-16 单位）
        let keyNS = keyNote as NSString
        let brokenLabels = keyBreaks.compactMap { at -> Int? in
            let plainAt = at - keyNS.substring(to: at).unicodeScalars.filter { $0 == "\u{2060}" }.count
            return labelRanges.contains { $0.location < plainAt && plainAt < $0.location + $0.length } ? plainAt : nil
        }
        check(!keyNote.isEmpty && brokenLabels.isEmpty, "快捷键一览：随手记那行小字折行时按钮名整词一起走（折在：\(brokenLabels)）")
    }

    /// 按 12pt 系统字（.ysCaption）在给定宽度里实排，返回每个折行处（下一行开头的 UTF-16 位置）
    @MainActor
    private static func misc2LineBreaks(_ text: String, width: CGFloat) -> [Int] {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: TypeSize.caption)])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 10_000), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        return lines.dropFirst().map { CTLineGetStringRange($0).location }
    }

    /// 实排后落在日期、数量与单位片段（CourierCardText.figurePattern，先去掉 U+2060 再认）中间的折行处
    @MainActor
    private static func misc2BreaksInsideFigures(_ text: String, width: CGFloat) -> [Int] {
        let ns = text as NSString
        // 认片段要在去掉 U+2060 的文本上认，再把位置映射回原文本
        var units: [unichar] = [], map: [Int] = []   // map[i] = 去掉后第 i 个 UTF-16 单位在原文本里的位置
        for i in 0..<ns.length where ns.character(at: i) != 0x2060 {
            units.append(ns.character(at: i)); map.append(i)
        }
        let plainNS = NSString(characters: units, length: units.count)
        let figures = CourierCardText.figurePattern.matches(in: plainNS as String, range: NSRange(location: 0, length: plainNS.length)).map { m -> ClosedRange<Int> in
            map[m.range.location]...map[m.range.location + m.range.length - 1]
        }
        return misc2LineBreaks(text, width: width).filter { at in figures.contains { $0.lowerBound < at && at <= $0.upperBound } }
    }

    /// 一块区域的平均亮度（0–1，按 sRGB 的 Rec.709 权重）
    private static func misc2MeanLuminance(_ image: CGImage, x: ClosedRange<Int>, y: ClosedRange<Int>) -> Double? {
        let w = image.width, h = image.height
        guard x.upperBound < w, y.upperBound < h,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var sum = 0.0, n = 0.0
        for row in y {
            for col in x {
                // 位图第 0 行在最上面（CGContext 的数据按从上到下排）
                let o = (row * w + col) * 4
                sum += (0.2126 * Double(px[o]) + 0.7152 * Double(px[o + 1]) + 0.0722 * Double(px[o + 2])) / 255
                n += 1
            }
        }
        return n > 0 ? sum / n : nil
    }
}
