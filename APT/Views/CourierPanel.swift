import SwiftUI
import SwiftData
import AppKit

// MARK: - 飞剑传书面板

struct CourierPanel: View {
    var deliveries: [CourierDelivery]
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects: EffectsCenter?
    @Environment(\.spiritMotion) private var motion
    @State private var visible = CourierPanel.pageSize
    /// “⋯”→“可以这样跟 AI 说…”弹出的例句小窗（有传书之后才从菜单里打开；一封都没有时例句直接铺在卡里）
    @State private var askAIOpen = false
    @State private var pendingUndo: CourierDelivery?
    @State private var preview = CourierUndoPreview()
    @State private var report: (text: String, failed: Bool)?

    /// 默认只列最近 3 封
    private static let pageSize = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "飞剑传书", detail: deliveries.isEmpty ? "" : "\(deliveries.count) 封", hint: "AI 代笔：经飞剑传书送进来的记录，每一封都能整批撤销") {
                // 不常用的收进“⋯”：跟 AI 说的例句（有传书之后）、打开收件箱、给别的 AI 的格式说明
                Menu {
                    if !deliveries.isEmpty {
                        Button { askAIOpen = true } label: { Label("可以这样跟 AI 说…", systemImage: "text.bubble") }
                        Divider()
                    }
                    Button { NSWorkspace.shared.open(CourierService.root) } label: { Label("打开收件箱", systemImage: "folder") }
                    Button(action: copyReadme) { Label("复制格式说明（给别的 AI）", systemImage: "doc.on.doc") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Theme.inkSoft)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("跟 AI 说的例句、收件箱与格式说明")
                .accessibilityLabel("传书设置")
                .popover(isPresented: $askAIOpen, arrowEdge: .bottom) {
                    AskAIHint(inPopover: true)
                        .padding(16)
                        .frame(width: 340)
                        .environment(\.spiritMotion, motion)
                }
            }
            if let report {
                Hint(report.text, tone: report.failed ? .error : .success)
            }
            if deliveries.isEmpty {
                // 一封都没有时才讲怎么用：在哪儿说、六句可复制的例句（有传书后收进“⋯”）
                AskAIHint()
            }
            ForEach(deliveries.prefix(visible)) { d in row(d) }
            if deliveries.count > Self.pageSize {
                HStack(spacing: 16) {
                    if deliveries.count > visible {
                        Button("更早的 \(min(20, deliveries.count - visible)) 封") { visible += 20 }
                            .buttonStyle(.cardLink)
                    }
                    if visible > Self.pageSize {
                        Button { visible = Self.pageSize } label: { Label("收起", systemImage: "chevron.up") }
                            .buttonStyle(.inlineAction())
                    }
                }
            }
        }
        .xianCard()
        .confirmationDialog("撤销这次传书？", isPresented: Binding(isPresent: $pendingUndo),
                            presenting: pendingUndo) { d in
            // 按钮上的条数与正文同一个说法：记录、档案字段、目标分开数
            let buttons = CourierUndoWording.buttons(preview.wording)
            Button(buttons.keep, role: .destructive) { performUndo(d) }
            if let all = buttons.all {
                Button(all, role: .destructive) { performUndo(d, keepEdited: false) }
            }
            Button("不撤销", role: .cancel) {}
        } message: { d in
            Text(undoMessage(d))
        }
    }

    /// 整份投递格式说明（与收件箱里的 AI/README.md 同一份）：给不在这个文件夹里、没有技能可用的 AI
    private func copyReadme() {
        FilePanels.copyToClipboard(CourierService.readme(context: context))
        effects?.hint("已复制格式说明，发给别的 AI 即可", icon: "checkmark.circle")
    }

    private func row(_ d: CourierDelivery) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: d.undone ? "arrow.uturn.backward.circle" : "paperplane.circle.fill")
                .foregroundStyle(d.undone ? Theme.inkSoft : Theme.info)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(d.from) · \(d.itemCount) 条").font(.ysCallout.weight(.medium)).monospacedDigit()
                    .foregroundStyle(d.undone ? Theme.inkSoft : Theme.ink)
                    .strikethrough(d.undone)
                Text(DateText.display(d.receivedAt) + (d.undone ? " · 已撤销" : ""))
                    .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
            }
            .help(d.summary)
            Spacer()
            // 撤销仍是一键可点（点后有确认）。就地执行的操作：撤销图标 + 朱砂小字，不带“→”（与传书笺上的“↶ 撤销此书”一致）
            if !d.undone {
                Button {
                    preview = CourierService.undoPreviewDetail(d, context: context)
                    pendingUndo = d
                } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.inlineAction(Theme.warning))
                .help("撤销这封传书写入的记录")
            }
        }
    }

    /// 确认框正文：来源一行，撤销会做什么（记录是删除；档案字段与目标是恢复成传书之前的内容，分开说）、
    /// 保留哪些改过的与“全部撤销”会怎样、逐条的保留原因（CourierUndoWording，与传书笺同一套说法），再列传书摘要。
    /// 按条退回的打卡（“未收 · …”）当时就没写入、不在撤销范围，不列；附注行（“（相对日期按…）”）不算条数、放最后
    /// （CourierLineDecor.undoListing）
    private func undoMessage(_ d: CourierDelivery) -> String {
        var lines = ["来自 \(d.from) · \(DateText.display(d.receivedAt))，共 \(d.itemCount) 条。"]
        lines += CourierUndoWording.panelLines(preview.wording)
        let summary = CourierLineDecor.undoListing(d.summary.split(separator: "\n").map(String.init))
        if !summary.isEmpty {
            lines.append("")
            lines += summary
        }
        return lines.joined(separator: "\n")
    }

    private func performUndo(_ d: CourierDelivery, keepEdited: Bool = true) {
        let result = CourierService.undo(d, context: context, keepEdited: keepEdited)
        if let failure = result.failure {
            report = ("撤销失败：\(failure)", true)
        } else {
            // 档案字段、目标是恢复原内容，不算“删除”；与传书笺上的结果同一套说法
            report = (CourierUndoWording.resultSentence(result.wording), false)
        }
        let shown = report?.text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if report?.text == shown { report = nil }
        }
    }
}
