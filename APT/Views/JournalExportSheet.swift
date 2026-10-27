import SwiftUI
import AppKit

/// 导出修行录：选范围与格式。
struct JournalExportSheet: View {
    var filtered: [JournalEntry]
    var all: [JournalEntry]
    var filterDescription: String
    @Environment(\.dismiss) private var dismiss
    @State private var range = "filtered"
    @State private var format = "md"
    /// 导出后的说明：取消（说明）或失败（错误）
    @State private var message: (text: String, failed: Bool)?
    /// 正在排 PDF：第几卷 / 共几卷
    @State private var progress: (done: Int, total: Int)?
    @State private var cancelRequested = false

    private var today: LocalDay { .today() }
    /// 超过这么多篇导出 PDF 时先提醒要分卷排版、需要一些时间
    private static let largePDF = 300

    private var ranges: [(key: String, label: String, entries: [JournalEntry])] {
        let thisMonth = String(today.key.prefix(7))
        let lastMonthDay = today.firstOfMonth.adding(days: -1)
        let lastMonth = String(lastMonthDay.key.prefix(7))
        let since30 = today.adding(days: -29).key
        return [
            ("filtered", filterDescription.isEmpty ? "当前列表" : "当前筛选：\(filterDescription)", filtered),
            ("month", "本月（\(today.month)月）", all.filter { $0.dateKey.hasPrefix(thisMonth) }),
            ("last", "上月（\(lastMonthDay.month)月）", all.filter { $0.dateKey.hasPrefix(lastMonth) }),
            ("30", "近 30 天", all.filter { $0.dateKey >= since30 }),
            ("all", "全部", all),
        ]
    }

    var body: some View {
        let options = ranges
        let chosen = options.first { $0.key == range } ?? options[0]
        let exporting = progress != nil
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(eyebrow: "修行录", title: "导出成卷")
            FormSection {
                FormRow(label: "范围") {
                    ChipPicker(selection: $range, options: options.map { ($0.key, "\($0.label) · \($0.entries.count) 篇") })
                }
                FormRow(label: "格式") {
                    SegmentedTabs(options: [("md", "Markdown（给 AI / 存档）"), ("pdf", "PDF（打印 / 收藏）")], selection: $format)
                }
            }
            .disabled(exporting)
            Hint(format == "md" ? "Markdown 可以直接整段发给 AI 做复盘，也方便放进笔记软件。" : "按日分卷、宋体排版的 A4 文档，适合打印或长期收藏。")
            if format == "pdf", chosen.entries.count > Self.largePDF, !exporting {
                Hint("篇目较多（\(chosen.entries.count) 篇），PDF 会分卷排版再合成一份，可能需要一些时间；导出时可随时取消。", symbol: "hourglass")
            }
            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                        .tint(Theme.jade)
                    Text(cancelRequested ? "正在取消…" : "正在排版第 \(min(progress.done + 1, progress.total)) / \(progress.total) 卷……")
                        .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                }
            }
            if let message { Hint(message.text, tone: message.failed ? .error : .note) }
            HStack {
                Spacer()
                Button("取消") {
                    if exporting { cancelRequested = true } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(cancelRequested)
                Button("导出") { export(chosen) }
                    .buttonStyle(.yunshanPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.entries.isEmpty || exporting)
            }
        }
        .padding(24)
        .frame(width: 520)
        .yunshanSheet()
        .interactiveDismissDisabled(exporting)
    }

    private func export(_ chosen: (key: String, label: String, entries: [JournalEntry])) {
        let items = JournalExport.items(chosen.entries)
        let title = "修行录 · " + chosen.label.replacingOccurrences(of: "当前筛选：", with: "")
        let name = "修行录-\(chosen.key == "all" ? "全部" : today.key)"
        message = nil
        if format == "md" {
            if FilePanels.save(data: Data(JournalExport.markdown(items, title: title).utf8), suggestedName: name + ".md", allowedExtensions: ["md"]) != nil {
                dismiss()
            }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name + ".pdf"
            panel.allowedContentTypes = [.pdf]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            cancelRequested = false
            progress = (0, 1)
            Task { @MainActor in
                do {
                    // 分卷排版，卷与卷之间让出主线程刷新进度，篇目再多也不会整段卡死
                    try await JournalExport.writePDF(items: items, title: title, to: url,
                                                     progress: { done, total in progress = (done, total) },
                                                     isCancelled: { cancelRequested })
                    progress = nil
                    dismiss()
                } catch is CancellationError {
                    progress = nil
                    cancelRequested = false
                    message = ("已取消导出。", false)
                } catch {
                    progress = nil
                    cancelRequested = false
                    message = ("导出 PDF 失败：\(error.localizedDescription)", true)
                }
            }
        }
    }
}
