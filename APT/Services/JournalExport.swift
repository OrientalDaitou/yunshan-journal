import Foundation
import AppKit
import PDFKit

/// 修行录导出：Markdown（给 AI / 存档）或排好版的 PDF（打印 / 收藏）。
@MainActor
enum JournalExport {
    struct Item {
        var day: LocalDay
        var minute: Int?
        var kind: JournalKind
        var title: String
        var body: String
        var mood: Int?
        var period: String
        var tags: [String]
        var source: String?
    }

    static func items(_ entries: [JournalEntry]) -> [Item] {
        entries.sorted { ($0.dateKey, $0.minute ?? -1, $0.createdAt) < ($1.dateKey, $1.minute ?? -1, $1.createdAt) }
            .map { Item(day: $0.day, minute: $0.minute, kind: $0.kindValue, title: $0.title, body: $0.body, mood: $0.mood,
                        period: $0.period, tags: $0.tags, source: $0.isFromCourier ? $0.sourceNote : nil) }
    }

    private static func meta(_ i: Item) -> String {
        var parts = [i.kind.label]
        if let m = i.minute { parts.insert(ClockTime.text(m), at: 0) }
        if !i.period.isEmpty { parts.append(ReviewPeriod.label(for: i.period)) }
        if let mood = i.mood { parts.append("心境「\(Mood.label(mood))」") }
        if !i.tags.isEmpty { parts.append(i.tags.map { "#\($0)" }.joined(separator: " ")) }
        if let source = i.source { parts.append("由 \(source) 代记") }
        return parts.joined(separator: " · ")
    }

    static func markdown(_ items: [Item], title: String) -> String {
        var out = ["# \(title)", "", "共 \(items.count) 篇 · 导出于 \(LocalDay.today().longLabel)", ""]
        var lastDay: LocalDay?
        for i in items {
            if i.day != lastDay {
                out += ["", "## \(i.day.longLabel)", ""]
                lastDay = i.day
            }
            out.append("### " + (i.title.isEmpty ? i.kind.label : i.title))
            out.append("*\(meta(i))*")
            out.append("")
            if !i.body.isEmpty { out += [i.body, ""] }
        }
        return out.joined(separator: "\n")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 宣纸色、宋体、按日分卷的 HTML（用来排 PDF）
    /// - Parameters:
    ///   - header: 是否排卷首标题（分卷排版时只有第一卷排）
    ///   - total: 卷首写的总篇数（分卷时传整份的篇数）
    static func html(_ items: [Item], title: String, header: Bool = true, total: Int? = nil) -> String {
        var body = ""
        var lastDay: LocalDay?
        for i in items {
            if i.day != lastDay {
                // 系统 HTML 排版不认 margin，用空段落隔开每一天
                body += "<p class='gap'>&nbsp;</p><h2>◆ \(escape(i.day.longLabel))</h2>"
                lastDay = i.day
            }
            body += "<div class='entry'><h3>\(escape(i.title.isEmpty ? i.kind.label : i.title))</h3>"
            body += "<p class='meta'>\(escape(meta(i)))</p>"
            if !i.body.isEmpty { body += "<p>\(escape(i.body).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            body += "</div>"
        }
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: 'Songti SC', serif; color: #263e35; font-size: 12pt; line-height: 1.7; }
        h1 { font-size: 24pt; letter-spacing: 6px; margin-bottom: 2px; color: #24493d; }
        .sub { color: #9b7951; font-size: 10pt; letter-spacing: 2px; }
        h2 { font-size: 15pt; color: #9b7951; border-bottom: 1px solid #dce1d4; padding-bottom: 3px; margin-top: 22px; }
        h3 { font-size: 13pt; margin: 12px 0 0 0; color: #24493d; }
        .meta { color: #627367; font-size: 9.5pt; margin: 2px 0 4px 0; font-family: 'PingFang SC', sans-serif; }
        p { margin: 4px 0; }
        p.gap { font-size: 9pt; line-height: 1.2; }
        </style></head><body>
        \(header ? "<h1>\(escape(title))</h1><div class='sub'>云山修习录 · 共 \(total ?? items.count) 篇 · \(escape(LocalDay.today().longLabel)) 导出</div>" : "")
        \(body)
        </body></html>
        """
    }

    /// 用系统排版把 HTML 分页输出为 A4 PDF。
    static func writePDF(html: String, to url: URL) throws {
        guard let data = html.data(using: .utf8),
              let attributed = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 60; info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(attributed)
        view.backgroundColor = NSColor(hex: 0xFBFBF6)
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 篇目多时分卷排版：整卷放进一个超高的文本视图，分页会在约 30 万点高度后急剧变慢（几百篇就要卡死几十秒、占数 GB 内存）。
    /// 所以按天（尽量在月初）切成每卷几十篇的小块，各排成一份临时 PDF，再用 PDFKit 按顺序拼成一份。
    /// 卷与卷之间让出主线程，界面可以刷新进度、响应“取消”。篇目少时与 `writePDF(html:to:)` 完全相同。
    static func writePDF(items: [Item], title: String, to url: URL,
                         progress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
                         isCancelled: () -> Bool = { false }) async throws {
        let parts = volumes(items)
        guard parts.count > 1 else {
            progress(0, 1)
            try writePDF(html: html(items, title: title), to: url)
            progress(1, 1)
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("APT-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let merged = PDFDocument()
        var sources: [PDFDocument] = []   // 拼完之前保留各卷，页面才不会失效
        for (index, part) in parts.enumerated() {
            progress(index, parts.count)
            try await Task.sleep(nanoseconds: 20_000_000)   // 让出主线程刷新进度
            if isCancelled() { throw CancellationError() }
            let file = folder.appendingPathComponent("part-\(index).pdf")
            try writePDF(html: html(part, title: title, header: index == 0, total: items.count), to: file)
            guard let document = PDFDocument(url: file) else { throw CocoaError(.fileReadCorruptFile) }
            for page in 0..<document.pageCount {
                if let pdfPage = document.page(at: page) { merged.insert(pdfPage, at: merged.pageCount) }
            }
            sources.append(document)
        }
        progress(parts.count, parts.count)
        if isCancelled() { throw CancellationError() }
        guard merged.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 切卷：同一天不拆开；每卷不超过约 80 篇 / 6 万字；已过半时遇到新的月份就另起一卷。
    static func volumes(_ items: [Item], maxItems: Int = 80, maxChars: Int = 60_000) -> [[Item]] {
        var days: [[Item]] = []
        for item in items {
            if let last = days.last?.last, last.day == item.day { days[days.count - 1].append(item) } else { days.append([item]) }
        }
        var result: [[Item]] = []
        var current: [Item] = []
        var chars = 0
        for day in days {
            let size = day.reduce(0) { $0 + $1.title.utf16.count + $1.body.utf16.count + 60 }
            if let last = current.last {
                let newMonth = last.day.month != day[0].day.month || last.day.year != day[0].day.year
                let full = current.count + day.count > maxItems || chars + size > maxChars
                let halfway = current.count * 2 >= maxItems || chars * 2 >= maxChars
                if full || (newMonth && halfway) {
                    result.append(current)
                    current = []
                    chars = 0
                }
            }
            current += day
            chars += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
