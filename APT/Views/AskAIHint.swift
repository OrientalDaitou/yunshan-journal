import SwiftUI

// MARK: - 可以这样跟 AI 说

/// 修行录“飞剑传书”卡里的教学：在哪儿说、怎么说，六句例句各带“复制”。
/// 一封传书都没有时直接铺在卡里（替换原来那句说明）；有了传书后收进卡片标题右侧“⋯”→“可以这样跟 AI 说…”的小弹窗。
/// 例句与上一级目录 `.claude/skills/apt-record/SKILL.md` 里的说法对得上：记账、打卡、日程、目标进度、陪我复盘今天、看看这周。
struct AskAIHint: View {
    static let title = "可以这样跟 AI 说"
    /// 要在 Finder / Claude Code 里找的文件夹名（与磁盘上一字不差）
    static let folder = "yunshan-journal"
    static let lead = "在 Claude Code 里打开「\(folder)」文件夹，直接说："
    /// 卡里显示的文件夹名：空格换成不换行空格，窄栏里整个名字留在同一行，不会从中间折开
    static var folderUnbroken: String { folder.replacingOccurrences(of: " ", with: "\u{00A0}") }
    static let phrases = [
        "帮我记一下：午饭现金 18",
        "我今天冥想了 10 分钟",
        "明天下午 3 点组会，记进日程",
        "论文进度到 70% 了",
        "陪我复盘今天",
        "看看我这周状态怎么样",
    ]
    static let footnote = "几秒内飞剑送达；每一封都能在这里整批撤销。"

    /// 小弹窗里自带标题；铺在卡里时卡片标题已是“飞剑传书”，这里只写一行小标题
    var inPopover = false
    @Environment(EffectsCenter.self) private var effects: EffectsCenter?
    @Environment(\.spiritMotion) private var motion
    /// 刚复制的那一句（约 1.6 秒后复原）
    @State private var copied: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane")
                    .font(.system(size: inPopover ? TypeSize.callout : TypeSize.caption, weight: .medium))
                    .foregroundStyle(Theme.info)
                    .accessibilityHidden(true)
                Text(Self.title)
                    .font(inPopover ? .ysHeading : .ysCallout.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            // 文件夹名加重、不折行（读屏仍读整句 lead）
            (Text("在 Claude Code 里打开「") + Text(Self.folderUnbroken).fontWeight(.semibold).foregroundStyle(Theme.ink)
                + Text("」文件夹，直接说："))
                .font(.ysCaption)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Self.lead)
            VStack(spacing: 2) {
                ForEach(Array(Self.phrases.enumerated()), id: \.offset) { index, phrase in
                    AskAIPhraseRow(phrase: phrase, copied: copied == index, motion: motion) { copy(index) }
                }
            }
            Hint(Self.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ index: Int) {
        FilePanels.copyToClipboard(Self.phrases[index])
        withAnimation(motion ? Motion.quick : nil) { copied = index }
        effects?.hint("已复制这句，粘到 Claude Code 里发出即可", icon: "checkmark.circle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copied == index { withAnimation(motion ? Motion.hover : nil) { copied = nil } }
        }
    }
}

/// 一句例句：整行可点（点即复制），悬停时浮起一层淡玉底、左侧一道金线、引号微微右移；行尾“复制 / 已复制”
private struct AskAIPhraseRow: View {
    var phrase: String
    var copied: Bool
    var motion: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "quote.opening")
                    .font(.system(size: TypeSize.micro, weight: .semibold))
                    .foregroundStyle(hover || copied ? Theme.gold : Theme.gold.opacity(0.55))
                    .offset(x: hover && motion ? 2 : 0)
                    .accessibilityHidden(true)
                Text(phrase)
                    .font(.ysCallout)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: TypeSize.caption, weight: .medium))
                    .foregroundStyle(copied ? Theme.positive : (hover ? Theme.jade : Theme.inkSoft.opacity(0.85)))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.mist.opacity(hover || copied ? 1 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.gold.opacity(0.75)).frame(width: 2)
                    .padding(.vertical, 5)
                    .opacity(hover || copied ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { on in withAnimation(motion ? Motion.hover : nil) { hover = on } }
        .help("复制这句，粘到 Claude Code 里发出")
        .accessibilityLabel("复制：\(phrase)")
    }
}
