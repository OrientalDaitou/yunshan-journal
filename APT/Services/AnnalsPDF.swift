import SwiftUI
import AppKit
import PDFKit

/// 岁月长卷导出：Markdown（AnnalsRenderer + 附录全文）与 A4 PDF（长卷各块用 ImageRenderer 矢量排进 PDF，附录复用修行录导出）。
@MainActor
enum AnnalsPDF {
    static let pageSize = CGSize(width: 595, height: 842)
    /// 上下左右页边
    static let margin: CGFloat = 48
    /// 页眉、页脚各占的高度（含与正文之间的空隙）
    static let header: CGFloat = 30
    static let footer: CGFloat = 26
    /// 块与块之间的间距
    static let gap: CGFloat = 22
    /// 每页正文可用的高度
    static var available: CGFloat { pageSize.height - margin * 2 - header - footer }
    static let appendixTitle = "附 · 珍藏与长篇全文"

    /// Markdown：长卷 + 两个空行 + 珍藏与长篇全文（没有篇目时不附）
    static func markdown(_ report: AnnalsReport, appendix: [JournalExport.Item]) -> String {
        var text = AnnalsRenderer.markdown(report)
        if !appendix.isEmpty { text += "\n\n" + JournalExport.markdown(appendix, title: appendixTitle) }
        return text
    }

    /// 同步写出 PDF（SelfTest.run 是同步的 @MainActor 函数，不能 await；5–10 页加 ≤ 11 篇附录用不着分卷让出主线程）。
    /// 整个排版包在浅色外观里：Theme 的颜色是随外观变的 NSColor，不包的话深色模式下导出会是深底
    static func write(_ report: AnnalsReport, appendix: [JournalExport.Item], to url: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("APT-annals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scrollURL = appendix.isEmpty ? url : folder.appendingPathComponent("scroll.pdf")
        var failure: Error?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            do { try writeScroll(report, to: scrollURL) } catch { failure = error }
        }
        if let failure { throw failure }
        guard !appendix.isEmpty else { return }
        // 附录：现成的同步版修行录排版（≤ 11 篇，不需要分卷），再用 PDFKit 逐页拼到长卷后面
        let appendixURL = folder.appendingPathComponent("appendix.pdf")
        try JournalExport.writePDF(html: JournalExport.html(appendix, title: appendixTitle), to: appendixURL)
        guard let merged = PDFDocument(url: scrollURL), let tail = PDFDocument(url: appendixURL) else { throw CocoaError(.fileReadCorruptFile) }
        for index in 0..<tail.pageCount {
            if let page = tail.page(at: index) { merged.insert(page, at: merged.pageCount) }
        }
        guard merged.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 长卷部分：量出各块高度 → 贪心装页（AnnalsLayout.pack）→ 每页宣纸底、页眉、各块、页脚，逐块矢量画进同一个 PDF 上下文
    private static func writeScroll(_ report: AnnalsReport, to url: URL) throws {
        let width = AnnalsSections.printWidth
        let renderers = AnnalsSections.printBlocks(report).map { block -> ImageRenderer<AnyView> in
            let renderer = ImageRenderer(content: block)
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            return renderer
        }
        let heights: [CGFloat] = renderers.map { renderer in
            var height: CGFloat = 0
            renderer.render { size, _ in height = size.height }
            return height
        }
        let pages = AnnalsLayout.pack(heights: heights.map(Double.init), available: Double(available), gap: Double(gap))
        var box = CGRect(origin: .zero, size: pageSize)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: report.period.title + " · 岁月长卷",
                                                                kCGPDFContextCreator as String: "云山修习录"] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let title = report.period.title + " · 岁月长卷"
        for (pageIndex, blocks) in pages.enumerated() {
            pdf.beginPDFPage(nil)
            drawPaper(pdf)
            draw(PageMark(text: title, alignment: .leading), in: pdf, top: margin - 6, height: 16)
            var y = margin + header
            for index in blocks {
                let height = heights[index]
                let scale = CGFloat(AnnalsLayout.fitScale(height: Double(height), available: Double(available)))
                pdf.saveGState()
                // CoreGraphics 的 y 从页底算起：块的上沿在离页顶 y 处
                pdf.translateBy(x: margin + (width - width * scale) / 2, y: pageSize.height - y - height * scale)
                pdf.scaleBy(x: scale, y: scale)
                renderers[index].render { _, render in render(pdf) }
                pdf.restoreGState()
                y += height * scale + gap
            }
            draw(PageMark(text: "— \(pageIndex + 1) —", alignment: .center), in: pdf, top: pageSize.height - margin + 4, height: 16)
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    /// 宣纸底 #FBFBF6，四周一道淡金细框（像卷心的边栏）
    private static func drawPaper(_ pdf: CGContext) {
        pdf.setFillColor(NSColor(hex: 0xFBFBF6).cgColor)
        pdf.fill(CGRect(origin: .zero, size: pageSize))
        pdf.setStrokeColor(NSColor(hex: 0x9B7951, alpha: 0.35).cgColor)
        pdf.setLineWidth(0.6)
        pdf.stroke(CGRect(origin: .zero, size: pageSize).insetBy(dx: 26, dy: 26))
        pdf.setStrokeColor(NSColor(hex: 0x9B7951, alpha: 0.18).cgColor)
        pdf.setLineWidth(0.4)
        pdf.stroke(CGRect(origin: .zero, size: pageSize).insetBy(dx: 29, dy: 29))
    }

    /// 页眉 / 页脚的一行小字
    private static func draw<V: View>(_ view: V, in pdf: CGContext, top: CGFloat, height: CGFloat) {
        let width = pageSize.width - margin * 2
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        pdf.saveGState()
        pdf.translateBy(x: margin, y: pageSize.height - top - height)
        renderer.render { _, render in render(pdf) }
        pdf.restoreGState()
    }
}

/// 页眉“二〇二六年 · 岁月长卷”、页脚“— 3 —”
private struct PageMark: View {
    var text: String
    var alignment: Alignment

    var body: some View {
        Text(text)
            .font(Theme.songti(9.5, .medium))
            .tracking(2)
            .foregroundStyle(Color(nsColor: NSColor(hex: 0x9B7951)))
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}
