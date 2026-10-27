import AppKit
import Foundation
import SwiftData

// r3-courierui（传书界面接线）的运行时自检：部分收录的传书笺副标题“· 1 条未收”、退回的行留在最后（收下的多时也不被折进
// “另有 N 条”）、多封合并时那封冒号前注“1 条未收”、退回的行与这处小注用警示色、撤销确认框不列退回的行；
// 摘要行里紧挨日期、数量的空格是不换行空格；回执不再催 AI“写绝对日期”，给 AI 的 README 与技能同一说法。
// 修复：多封合并时“1 条未收”写在冒号前（按笺上的字号与宽度排版，总在第一行）、整封没收录的“未收录 · …”整行警示色；
// 消费行的“$18.00［类别］”整块不折开、折行时不以“［”起头；撤销框清单的附注不算条数；README 示例日期写 today / tomorrow。
// 摘要行的写法、折叠与解析在 Tools/CoreCheck（// MARK: r3-courierui）里测。

extension SelfTest {
    static func courierUIChecks(_ check: (Bool, String) -> Void) throws {
        let c = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: c)
        DataStore.profile(in: c)
        let sport = Habit(title: "运动")
        let zen = Habit(title: "冥想")
        zen.targetValue = 10
        zen.unit = "分钟"
        for (i, h) in [sport, zen].enumerated() {
            h.sortOrder = i
            c.insert(h)
        }
        DataStore.save(c)
        let today = LocalDay.today(in: CourierService.timeZone)
        func payload(_ items: String) throws -> CourierPayload {
            try CourierParser.parse(Data(#"{"from":"自检","items":[\#(items)]}"#.utf8))
        }
        func deliver(_ items: String, _ name: String) throws -> (delivery: CourierDelivery, payload: CourierPayload,
                                                                 skipped: [(index: Int, skip: CourierRoster.Skip)]) {
            let p = try payload(items)
            let r = try CourierService.applyCore(p, fileName: name, context: c, partial: true)
            return (r.delivery, p, r.skipped)
        }

        // 1. 部分收录（午饭 + 跑步 + 弹琴）：跑步按同类说法记到“运动”，弹琴对不上任何功课按条退回；
        //    传书笺副标题“· 1 条未收”，退回的行在最后、警示色
        let a = try deliver(#"{"type":"expense","amount":18,"description":"界面自检午饭"},{"type":"checkin","habit":"跑步"},"#
                            + #"{"type":"checkin","habit":"弹琴"}"#, "courierui-a.json")
        let fx = EffectsCenter()
        fx.courierArrived(a.delivery)
        let card = fx.courier
        check(a.delivery.itemCount == 2 && a.skipped.count == 1
              && card?.detail == "来自 自检 · 收录 2 条 · 1 条未收"
              && card?.lines.last == "未收 · 打卡「弹琴」：没有这项功课" && card?.lines.count == 3
              && card.map { CourierCardText.tone($0.lines.last ?? "").warning } == true
              && card.map { !CourierCardText.tone($0.lines[0]).warning } == true
              && card?.deliveryID == a.delivery.deliveryID,
              "部分收录的传书笺：副标题“收录 2 条 · 1 条未收”，退回的行排最后、警示色，其余照常（\(card?.detail ?? "nil")；\(card?.lines ?? [])）")

        // 2. 收下的条目多（6 条日记 + 1 条退回）：只折收下的，退回的行仍露出来，“另有 N 条”只数收下的
        let many = (1...6).map { #"{"type":"diary","body":"界面自检第\#($0)篇"}"# }.joined(separator: ",")
        let b = try deliver(many + #",{"type":"checkin","habit":"古筝"}"#, "courierui-b.json")
        fx.courierArrived(b.delivery)
        let folded = fx.courier?.lines ?? []
        check(b.delivery.itemCount == 6 && folded.count == 6 && folded[4] == "…… 另有 2 条"
              && folded.last == "未收 · 打卡「古筝」：没有这项功课" && fx.courier?.detail == "来自 自检 · 收录 6 条 · 1 条未收",
              "收下的多时只折收下的：4 条 + “另有 2 条” + 退回的那行（\(folded)）")

        // 3. 一轮收到两封（其中一封部分收录）：每封一行，那封冒号前注“1 条未收”单独警示色，副标题合计
        let d = try deliver(#"{"type":"note","body":"界面自检灵感"}"#, "courierui-d.json")
        fx.courierBatch(deliveries: [a.delivery, d.delivery], failures: [])
        let batch = fx.courier
        let first = batch?.lines.first ?? ""
        let tone = CourierCardText.tone(first)
        check(batch?.title == "飞剑传书 · 2 封" && batch?.detail.hasPrefix("收录 3 条 · 1 条未收") == true
              && first.hasPrefix("自检 · 2 条 · 1 条未收：消费 · ")
              && tone.lead == "自检 · 2 条 · " && tone.mark == "1 条未收" && !tone.warning && tone.lead + (tone.mark ?? "") + tone.body == first
              && batch.map { !$0.lines[1].contains("未收") && CourierCardText.tone($0.lines[1]).mark == nil } == true,
              "多封合并：部分收录的那封冒号前注“1 条未收”（只这几个字警示色），副标题合计（\(batch?.detail ?? "nil")；\(batch?.lines ?? [])）")
        // 3b. 同一轮里另有一封整封没收录（进了 AI/failed/）：那行“未收录 · 文件：原因”整行警示色，笺头仍是青色纸飞机
        fx.courierBatch(deliveries: [a.delivery], failures: [(file: "claude-courierui-x.json", message: "第 2 条：找不到习惯「游泳」")])
        let mixedBatch = fx.courier
        let rejectedLine = mixedBatch?.lines.first { $0.hasPrefix("未收录 · ") } ?? ""
        check(mixedBatch?.failed == false && rejectedLine == "未收录 · claude-courierui-x.json：第 2 条：找不到习惯「游泳」"
              && CourierCardText.tone(rejectedLine).warning && CourierCardText.tone(rejectedLine).mark == nil
              && mixedBatch.map { CourierCardText.tone($0.lines[0]).mark == "1 条未收" } == true,
              "多封合并里整封没收录的那行整行警示色，部分收录那封只“1 条未收”警示色（\(mixedBatch?.lines ?? [])）")
        // 3c. 首条摘要很长时，“1 条未收”仍排在笺上的第一行（按笺上的字号与正文宽度 312pt 排版；笺上每行最多两行、从行尾截断）
        let longFirst = "日程 · 10月23日 15:00–16:00 · 和导师讨论论文第三章实验部分的修改意见与下一步计划和时间安排表"
        let longLine = CourierLineDecor.batchLine(from: "ChatGPT", itemCount: 2,
                                                  summary: [longFirst, "打卡 · 10月22日 · 运动", CourierLineDecor.skippedLine("打卡「弹琴」：没有这项功课")]
                                                      .joined(separator: "\n"))
        let longTone = CourierCardText.tone(longLine)
        let laidOut = CourierCardText.gluingFigures(longTone.lead) + CourierCardText.unbreakable(longTone.mark ?? "")
            + CourierCardText.display(longTone.body).text
        let markStart = (CourierCardText.gluingFigures(longTone.lead) as NSString).length
        let markRows = Self.courierUIRows(laidOut, width: 312, range: NSRange(location: markStart, length: (CourierCardText.unbreakable("1 条未收") as NSString).length))
        check(longTone.mark == "1 条未收" && markRows == [0],
              "首条摘要很长时“1 条未收”仍在第一行，不会被两行的上限截掉（排在第 \(markRows) 行）")

        // 4. 撤销确认框（CourierPanel.undoMessage 列的摘要）不列退回的行；撤销只撤收下的
        let undoList = CourierLineDecor.undoLines(a.delivery.summary.split(separator: "\n").map(String.init))
        check(undoList.count == 2 && !undoList.contains(where: CourierLineDecor.isSkipped)
              && CourierLineDecor.undoListing(a.delivery.summary.split(separator: "\n").map(String.init)) == undoList.map { "· " + $0 }
              && !CourierLineDecor.isWarningLine("…… 另有 3 条"),
              "撤销确认框只列收下的 2 条（\(undoList)）")
        // 撤销框清单：相对日期的附注不加“· ”、不算条数、放最后（7 条 + 附注：7 条全列，不写“另有”）
        let remark = "（相对日期按写入那天 10月21日 计算）"
        let seven = (1...7).map { "日记 · 10月21日 · 第\($0)篇" }
        let listing = CourierLineDecor.undoListing(seven + [remark])
        check(listing == seven.map { "· " + $0 } + [remark],
              "撤销框清单：附注放最后、不算进“另有 N 条”（\(listing)）")

        // 5. 摘要行：新立功课的括注、目标进度里紧挨日期与数量的空格是不换行空格；去掉后与原来的写法相同，进度照样解析得回来
        let h = try deliver(#"{"type":"habit","title":"界面自检读书","frequency":"weekly","times_per_week":3,"target":20,"unit":"页"},"#
                            + #"{"type":"goal","title":"界面自检目标","progress":10}"#, "courierui-h.json")
        let hLines = h.delivery.summary.split(separator: "\n").map(String.init)
        let habitLine = hLines.first { $0.hasPrefix("功课 · ") } ?? ""
        let goalLine = hLines.first { $0.hasPrefix("目标 · ") } ?? ""
        check(habitLine == "功课 · 新立「界面自检读书」（每周\u{A0}3\u{A0}次，每次\u{A0}20页，自\u{A0}\(today.shortLabel)\u{A0}起）"
              && goalLine == "目标 · 新立「界面自检目标」（进度\u{A0}10%）"
              && habitLine.replacingOccurrences(of: "\u{A0}", with: " ") == "功课 · 新立「界面自检读书」（每周 3 次，每次 20页，自 \(today.shortLabel) 起）",
              "摘要行：括注与进度里紧挨日期、数量的空格是不换行空格（\(hLines)）")
        let goal = c.all(Goal.self).first { $0.title == "界面自检目标" }
        let u = try deliver(#"{"type":"goal","action":"update","title":"界面自检目标","progress":35}"#, "courierui-u.json")
        let move = CourierLineDecor.progressMove(u.delivery.summary)
        check(goal?.progress == 35 && u.delivery.summary == "目标 · 界面自检目标：进度\u{A0}10% →\u{A0}35%"
              && move == CourierLineDecor.ProgressMove(title: "界面自检目标", from: 10, to: 35, completed: false)
              && CourierLineDecor.progressMove("目标 · 界面自检目标：进度 10% → 35%") == move,
              "目标进度行：箭头后是不换行空格；新旧两种写法都解析得出进度（\(u.delivery.summary)）")
        // 传书笺显示时日期、数量照样粘成一个词（不换行空格也认）
        let shown = CourierCardText.display(habitLine).text
        check(shown.replacingOccurrences(of: "\u{2060}", with: "") == habitLine && shown.contains("2\u{2060}0\u{2060}页")
              && CourierCardText.gluingFigures("每周\u{A0}3\u{A0}次").contains("3\u{2060}\u{A0}\u{2060}次")
              && CourierCardText.gluingFigures("午饭 $18.00［餐饮与外卖］") == "午饭 " + CourierCardText.unbreakable("$18.00［餐饮与外卖］"),
              "传书笺显示：数与单位之间是不换行空格时也粘成一个词，消费行的“$18.00［类别］”整个不折开；去掉 U+2060 后与原行相同")
        // 消费行放不下时在“$”前折行：按笺上的字号在 150–400pt 各种宽度排版，没有哪一行以“［”起头，金额与类别总在同一行
        let expense = CourierCardText.display("自检 · 2 条 · 1 条未收：消费 · 10月22日 · 午饭 拉面 $18.00［餐饮与外卖］").text
        let blockStart = (expense as NSString).range(of: "$").location
        var badWidth: Int?
        for width in stride(from: 150, through: 400, by: 2) {
            let starts = Self.courierUIRowStarts(expense, width: CGFloat(width))
            let blockRows = Self.courierUIRows(expense, width: CGFloat(width),
                                               range: NSRange(location: blockStart, length: (expense as NSString).length - blockStart))
            let opensWithBracket = starts.contains { start in
                (expense as NSString).substring(from: start).replacingOccurrences(of: "\u{2060}", with: "").hasPrefix("［")
            }
            if opensWithBracket || blockRows.count != 1 { badWidth = width; break }
        }
        check(badWidth == nil, "消费行：金额与类别整块不折开、折行时下一行从“$”起（宽 \(badWidth.map(String.init) ?? "-")pt 时不对）")

        // 6. 回执不再催“写绝对日期”；给 AI 的 README 与技能同一说法（today / yesterday / tomorrow 直接写，不用先跑 date）
        let r = try deliver(#"{"type":"diary","date":"today","body":"界面自检相对日期"}"#, "courierui-r.json")
        let receipt = CourierService.receiptText(r.delivery, payload: r.payload, written: Date(), base: today, latest: today)
        let readme = CourierService.readme(context: c)
        check(r.payload.relativeDates == 1 && receipt.contains("相对写法") && !receipt.contains("绝对日期")
              && !readme.contains("请写绝对日期") && readme.contains("不用先跑 `date`")
              && readme.contains("直接写 `today` / `yesterday` / `tomorrow`"),
              "回执与给 AI 的 README：日期直接写 today / yesterday / tomorrow，不再要求写绝对日期")
        // README 的「文件格式」示例与规则一致：今天、明天写 today / tomorrow，只有 review 那条示范“别的日子”写 YYYY-MM-DD
        let example = readme.components(separatedBy: "## 文件格式").dropFirst().first?.components(separatedBy: "```").dropFirst().first ?? ""
        let fixedDates = example.components(separatedBy: "\n").filter { $0.range(of: #""(date|start_date)": "\d{4}-"#, options: .regularExpression) != nil }
        check(example.contains(#""type": "diary",   "date": "today""#) && example.contains(#""type": "event",   "date": "tomorrow""#)
              && example.contains(#""start_date": "today""#) && fixedDates.count == 1 && fixedDates.first?.contains(#""type": "review""#) == true,
              "README 示例：日期写 today / tomorrow，只有 review 一条写 YYYY-MM-DD（\(fixedDates.count) 条写死日期）")
    }

    /// 按传书笺正文的字号（TypeSize.caption 的系统字体）在给定宽度里排版，返回 range 里的字落在第几行（从 0 起，去重升序）
    static func courierUIRows(_ text: String, width: CGFloat, range: NSRange) -> [Int] {
        let rows = courierUIRowRanges(text, width: width)
        return rows.indices.filter { NSIntersectionRange(rows[$0], range).length > 0 }
    }

    /// 同上，返回每一行第一个字的位置（字符下标）
    static func courierUIRowStarts(_ text: String, width: CGFloat) -> [Int] {
        courierUIRowRanges(text, width: width).map(\.location)
    }

    /// 排版后每一行的字符范围（NSTextStorage 只在这里活着：NSLayoutManager 不持有它）
    private static func courierUIRowRanges(_ text: String, width: CGFloat) -> [NSRange] {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: TypeSize.caption)])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var rows: [NSRange] = []
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var row = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &row)
            rows.append(layout.characterRange(forGlyphRange: row, actualGlyphRange: nil))
            glyph = max(NSMaxRange(row), glyph + 1)
        }
        return withExtendedLifetime(storage) { rows }
    }
}
