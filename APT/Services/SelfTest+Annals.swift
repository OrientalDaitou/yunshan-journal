import Foundation
import SwiftData
import AppKit
import PDFKit

// 岁月长卷（页面 B 部分）的运行时自检：真数据算出的报告与按日期数的篇数一致、页面缓存命中与失效、
// PDF（同步写、含附录、深色外观下仍是浅底）、Markdown 导出、侧栏第 10 页与 ⌘ 数字、页首画与各节小物都在包里。
// 统计本身在 Tools/CoreCheck 里测（AnnalsEngine / AnnalsLayout）。

extension SelfTest {
    static func annalsChecks(_ check: (Bool, String) -> Void) throws {
        try annalsNavigationChecks(check)
        let c = try annalsContext()
        let today = LocalDay.today()
        seedAnnals(c, today: today)

        // 1. 报告：今年的篇数与按日期数的一致（晚于今天的补记不计）
        guard let period = AnnalsPeriod.make(.year(today.year), today: today) else { return check(false, "岁月长卷：今年的时段为空") }
        let input = RecordCollector.input(context: c, from: period.first, to: period.last, today: today, text: true)
        let report = AnnalsEngine.report(period, input: input)
        let fromKey = period.first.key, toKey = today.key
        let counted = try c.fetchCount(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dateKey >= fromKey && $0.dateKey <= toKey }))
        check(report.writing?.entries == counted && !report.isEmpty && report.cultivation != nil && report.finance != nil,
              "岁月长卷：今年 \(counted) 篇，与按日期数的一致；功课、修为、灵石各节都有")
        let parts = AnnalsLayout.parts(report).map(\.part)
        check(parts.first == .writing && parts.last == .insights && AnnalsLayout.parts(report).map(\.number).first == "其一",
              "岁月长卷：节号从“其一”起按实际显示的节排（" + AnnalsLayout.parts(report).map { $0.number + $0.part.title }.joined(separator: "、") + "）")

        // 2. 页面缓存：数据没变时第二次直接查表；插入一篇并保存后数据戳变了才重算
        let key = period.storageKey + "|" + today.key
        let stamp = RecordCollector.stamp(context: c)
        let before = AnnalsCache.computed
        _ = AnnalsCache.report(key: key, stamp: stamp) { report }
        _ = AnnalsCache.report(key: key, stamp: RecordCollector.stamp(context: c)) { report }
        let hit = AnnalsCache.computed == before + 1
        c.insert(JournalEntry(kind: .note, body: "长卷缓存自检", dateKey: today.key))
        DataStore.save(c)
        let newStamp = RecordCollector.stamp(context: c)
        var recomputed = false
        _ = AnnalsCache.report(key: key, stamp: newStamp) {
            recomputed = true
            return AnnalsEngine.report(period, input: RecordCollector.input(context: c, from: period.first, to: period.last, today: today, text: true))
        }
        check(hit && newStamp != stamp && recomputed, "岁月长卷：数据没变时命中缓存，插入一篇并保存后数据戳改变、重算一次")

        // 3. 导出：附录篇目（珍藏 + 最长的日记）按 uid 现取；Markdown 含附录标题、不含 Optional(
        let fresh = AnnalsEngine.report(period, input: RecordCollector.input(context: c, from: period.first, to: period.last, today: today, text: true))
        let uids = fresh.highlights.pinned.map(\.uid) + fresh.highlights.longest.map(\.uid)
        let appendix = JournalExport.items(try c.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { uids.contains($0.uid) })))
        let markdown = AnnalsPDF.markdown(fresh, appendix: appendix)
        check(!appendix.isEmpty && appendix.count == uids.count && markdown.hasPrefix("# \(period.title) · 岁月长卷")
              && markdown.contains("# \(AnnalsPDF.appendixTitle)") && !markdown.contains("Optional(") && !markdown.contains("nil"),
              "岁月长卷：Markdown 导出 \(markdown.count) 字，附 \(appendix.count) 篇珍藏与长篇全文")

        // 4. PDF：同步写出，长卷之后接附录；深色外观下再写一次不崩、首页仍是浅底（两次取色一致）
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("APT-annals-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let light = folder.appendingPathComponent("light.pdf"), dark = folder.appendingPathComponent("dark.pdf")
        let blocks = AnnalsSections.printBlocks(fresh).count
        let started = Date()
        try AnnalsPDF.write(fresh, appendix: appendix, to: light)
        let pdfMs = Int(Date().timeIntervalSince(started) * 1000)
        let scrollOnly = folder.appendingPathComponent("scroll.pdf")
        try AnnalsPDF.write(fresh, appendix: [], to: scrollOnly)
        // 调试：APT_ANNALS_PDF_OUT=<文件夹> 时把这份 PDF 另存一份出来看排版
        if let out = ProcessInfo.processInfo.environment["APT_ANNALS_PDF_OUT"] {
            try? FileManager.default.copyItem(at: light, to: URL(fileURLWithPath: out).appendingPathComponent("annals-\(UUID().uuidString.prefix(6)).pdf"))
        }
        let pages = PDFDocument(url: light)?.pageCount ?? 0
        let scrollPages = PDFDocument(url: scrollOnly)?.pageCount ?? 0
        check(scrollPages >= 2 && pages > scrollPages, "岁月长卷：PDF 长卷 \(blocks) 块排成 \(scrollPages) 页，加附录共 \(pages) 页（用时 \(pdfMs) ms）")
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: .darkAqua)
        defer { app.appearance = previous }
        try AnnalsPDF.write(fresh, appendix: appendix, to: dark)
        app.appearance = previous
        let lightLuma = pageLuminance(light), darkLuma = pageLuminance(dark)
        check(lightLuma.map { $0 > 0.85 } == true && darkLuma.map { $0 > 0.85 } == true && abs((lightLuma ?? 0) - (darkLuma ?? 1)) < 0.005,
              "岁月长卷：深色外观下导出的 PDF 首页仍是浅底（平均亮度 " + [lightLuma, darkLuma].map { $0.map { String(format: "%.3f", $0) } ?? "?" }.joined(separator: " / ") + "）")

        // 5. 空时段（记录起点之前的一年）：长卷照常排卷首与卷尾，一页
        let past = today.year - 6
        if let empty = AnnalsPeriod.make(.year(past), today: today) {
            let r = AnnalsEngine.report(empty, input: RecordCollector.input(context: c, from: empty.first, to: empty.last, today: today, text: true))
            let url = folder.appendingPathComponent("empty.pdf")
            try AnnalsPDF.write(r, appendix: [], to: url)
            check(r.isEmpty && AnnalsLayout.parts(r).isEmpty && PDFDocument(url: url)?.pageCount == 1
                  && AnnalsSections.printBlocks(r).count == 3,
                  "岁月长卷：没有记录的 \(past) 年只排卷首、“这段时间没有记录。”与卷尾，PDF 一页")
        }

        #if DEBUG
        // 调试：另用两年演示数据排一份 PDF（看洞见、灵石等各节在纸上的样子）
        if let out = ProcessInfo.processInfo.environment["APT_ANNALS_PDF_OUT"] {
            let demo = try annalsContext()
            _ = DemoSeeder.seed(into: demo, years: 2)
            let r = AnnalsEngine.report(period, input: RecordCollector.input(context: demo, from: period.first, to: period.last, today: today, text: true))
            let ids = r.highlights.pinned.map(\.uid) + r.highlights.longest.map(\.uid)
            let items = JournalExport.items(try demo.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { ids.contains($0.uid) })))
            try AnnalsPDF.write(r, appendix: items, to: URL(fileURLWithPath: out).appendingPathComponent("annals-demo.pdf"))
        }
        #endif

        // 6. 时段的存取：失效的键（未来、写坏了）回到默认；季度在新年份还没开始时切回全年
        check(AnnalsView.period(for: "\(today.year + 1)", today: today).storageKey == AnnalsPeriod.make(AnnalsPeriod.defaultScope(today: today), today: today)?.storageKey
              && AnnalsView.period(for: "乱写", today: today).storageKey == AnnalsView.period(for: "", today: today).storageKey
              && AnnalsView.period(for: "\(today.year - 1)-Q2", today: today).storageKey == "\(today.year - 1)-Q2",
              "岁月长卷：所选时段失效（未来 / 写坏）时用默认时段，往年的季度照常打开")
    }

    /// 侧栏第 10 页与 ⌘ 数字：case 顺序 = 侧栏显示顺序；岁月长卷 ⌘8、问道灵枢 ⌘9、洞府设置 ⌘0；页首画与各节小物都在包里
    private static func annalsNavigationChecks(_ check: (Bool, String) -> Void) throws {
        let sidebar = AppSection.common + AppSection.more
        let digits = AppSection.allCases.enumerated().map { NavShortcut.digit(forPosition: $0.offset + 1) }
        check(sidebar == AppSection.allCases && AppSection.allCases.count == 10 && AppSection.more.first == .annals
              && digits.compactMap { $0 }.map(String.init).joined() == "1234567890",
              "侧栏十项：显示顺序与 ⌘ 数字一致（岁月长卷 ⌘8、问道灵枢 ⌘9、洞府设置 ⌘0）")
        let scene = Scenery.scene(for: .annals)
        let assets = [scene.light, scene.foliage, AppSection.annals.ornament, "yunshan-ornament-texture-cloud-v1", "yunshan-ornament-scroll-v1"]
            + AnnalsLayout.Part.allCases.map(\.ornament)
        let missing = assets.filter { Bundle.main.url(forResource: $0, withExtension: "webp") == nil }
        check(missing.isEmpty && scene.night == nil && scene.needsMoonlight(dark: true),
              "岁月长卷：页首画（藏卷书案，深色调成月色）、前景、各节小物都在包里" + (missing.isEmpty ? "" : "（缺：\(missing.joined(separator: "、"))）"))
    }

    /// 两年零星修行录（带心境、标签、珍藏、几篇长日记）、两项功课与打卡、几笔手记
    private static func seedAnnals(_ c: ModelContext, today: LocalDay) {
        let long = String(repeating: "山间的雾一层层退下去，书案上的灯还亮着。", count: 8)
        for offset in stride(from: 700, through: 0, by: -2) {
            let kind: JournalKind = offset % 10 == 0 ? .review : offset % 3 == 0 ? .note : .diary
            let entry = JournalEntry(kind: kind, title: offset % 4 == 0 ? "长卷自检 \(offset)" : "",
                                     body: offset % 14 == 0 ? long + "\(offset)" : "长卷自检第 \(offset) 天", dateKey: today.adding(days: -offset).key)
            entry.mood = kind == .diary ? 1 + offset % 5 : nil
            entry.tags = offset % 6 == 0 ? ["自检", "长卷"] : []
            entry.pinned = offset % 40 == 0
            c.insert(entry)
        }
        c.insert(JournalEntry(kind: .diary, body: "后天的补记", dateKey: today.adding(days: 2).key))
        let daily = Habit(title: "长卷自检晨读")
        daily.startDate = today.adding(days: -500).key
        let weekly = Habit(title: "长卷自检跑步")
        weekly.frequencyKind = .weekly
        weekly.targetPerWeek = 2
        weekly.startDate = today.adding(days: -300).key
        c.insert(daily)
        c.insert(weekly)
        for (habit, days) in [(daily, (1...500).filter { $0 % 4 != 0 }), (weekly, (1...300).filter { $0 % 3 == 0 })] {
            for offset in days {
                let log = HabitLog(dateKey: today.adding(days: -offset).key)
                c.insert(log)
                log.habit = habit
            }
        }
        var ledger = FinanceLedger()
        for (index, offset) in [0, 3, 20, 45, 90, 200, 400].enumerated() {
            ledger.transactions.append(ManualExpense.transaction(id: "manual-annals-\(index)", day: today.adding(days: -offset), cents: 1500 + index * 250,
                                                                 category: index % 2 == 0 ? "餐饮与外卖" : "交通出行", description: "长卷自检", note: "", reason: "自检"))
        }
        try? FinanceService.save(ledger, context: c)
        DataStore.save(c)
    }

    /// PDF 首页的平均亮度（0…1）：先铺黑底再画页面，缺了宣纸底或块成了深底都会明显变暗
    private static func pageLuminance(_ url: URL) -> Double? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let w = 119, h = 168
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / AnnalsPDF.pageSize.width, y: CGFloat(h) / AnnalsPDF.pageSize.height)
        page.draw(with: .mediaBox, to: ctx)
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var total = 0.0
        for i in 0..<(w * h) {
            total += (Double(bytes[i * 4]) + Double(bytes[i * 4 + 1]) + Double(bytes[i * 4 + 2])) / 765
        }
        return total / Double(w * h)
    }

    /// 干净的内存库（与 SelfTest.freshContext 相同，那个是 private 的）
    private static func annalsContext() throws -> ModelContext {
        let context = ModelContext(try DataStore.makeContainer(inMemory: true))
        DataStore.settings(in: context)
        DataStore.profile(in: context)
        DataStore.save(context)
        return context
    }
}
