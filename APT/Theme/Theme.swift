import SwiftUI
import Combine
import AppKit

extension Color {
    /// 随浅色 / 深色自动切换的颜色。
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// 云山修习录配色，取自旧版 yunshan / atelier 样式：宣纸底、墨青字、松绿主色、淡金点缀；深色为墨夜。
enum Theme {
    /// 页面底色
    static let paper = Color.adaptive(light: 0xF2F3EC, dark: 0x0E191B)
    /// 卡片 / 侧栏（深色比页面底亮一档，卡片靠明暗而不是线框分层）
    static let card = Color.adaptive(light: 0xFFFDF8, dark: 0x172A2C)
    static let sidebar = Color.adaptive(light: 0xF7F7F1, dark: 0x111F21)
    /// 浅底色块（选中、输入框底）
    static let mist = Color.adaptive(light: 0xEDF2EC, dark: 0x1C2F30)
    static let line = Color.adaptive(light: 0xDCE1D4, dark: 0x2D4141)
    /// 标题墨色
    static let ink = Color.adaptive(light: 0x24493D, dark: 0xE8EEDD)
    /// 正文
    static let text = Color.adaptive(light: 0x35463E, dark: 0xCCDCD3)
    /// 次要文字
    static let inkSoft = Color.adaptive(light: 0x627367, dark: 0x9CB4AA)
    static let jade = Color.adaptive(light: 0x427560, dark: 0xA3C5AE)
    /// 玉色深一档（深色下仍是浅玉：有几处拿它当文字色、或配金底，所以深色值不改；玉色实底请用 jadeFill）
    static let jadeDeep = Color.adaptive(light: 0x3C6B59, dark: 0xA3C5AE)
    /// 压在 jadeDeep / 金色实底上的文字
    static let onJade = Color.adaptive(light: 0xFFFFFF, dark: 0x0E191B)
    static let gold = Color.adaptive(light: 0x9B7951, dark: 0xD2B682)
    static let goldSoft = Color.adaptive(light: 0xF3EAD6, dark: 0x2F2A1E)
    static let cinnabar = Color.adaptive(light: 0xA9483C, dark: 0xE39A8E)
    static let azure = Color.adaptive(light: 0x4C6E8E, dark: 0x93B3CF)

    // MARK: 按含义取色（新代码请用这几个名字）

    /// 玉：完成、进行中、主要操作
    static let positive = jade
    /// 金：修为、境界、当前选中、珍藏
    static let precious = gold
    /// 朱砂：警示（错误、超支、逾期）与落印
    static let warning = cinnabar
    /// 青：信息、AI 传书
    static let info = azure

    /// 玉色实底：主按钮、选中的勾选框 / 月历日 / 选项。浅色是松绿，深色是一块温玉（深玉渐变），不再是发白的浅薄荷贴片
    static let jadeFill = LinearGradient(colors: [Color.adaptive(light: 0x427560, dark: 0x386A56),
                                                  Color.adaptive(light: 0x3C6B59, dark: 0x2A5244)],
                                         startPoint: .top, endPoint: .bottom)
    /// 压在 jadeFill 上的文字与勾（深色为浅米色）
    static let onJadeFill = Color.adaptive(light: 0xFFFFFF, dark: 0xE8EEDD)

    /// 类别色板（日程、自定义类别按名字取色）。原第 5 色朱砂换成赭石：普通课程不再像警告；
    /// 只是原位替换，取模结果不变，只有原来落在朱砂上的类别改成赭石
    static let palette: [Color] = [
        Color.adaptive(light: 0x427560, dark: 0xA3C5AE),
        Color.adaptive(light: 0x4C6E8E, dark: 0x93B3CF),
        Color.adaptive(light: 0x9B7951, dark: 0xD2B682),
        Color.adaptive(light: 0x7D5C7E, dark: 0xC4A3C5),
        Color.adaptive(light: 0x8C6A5A, dark: 0xCDB1A0),
        Color.adaptive(light: 0x5E7D3A, dark: 0xB2CC8E),
        Color.adaptive(light: 0x3F7E8E, dark: 0x8CC5D2),
    ]

    /// 同一类别始终同一个颜色（不依赖 hashValue，跨次启动稳定）。
    static func color(for category: String) -> Color {
        guard !category.isEmpty else { return inkSoft }
        let sum = category.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }

    static func color(for kind: RoutineKind) -> Color {
        switch kind {
        case .sleep: azure
        case .meal: gold
        case .study: jade
        case .work: Color.adaptive(light: 0x3F7E8E, dark: 0x8CC5D2)
        // 运动用黛紫：朱砂只留给警示；赭石又和“用餐”的金色太近（运动常紧挨着晚餐），色相拉开 40° 以上
        case .exercise: Color.adaptive(light: 0x6F6496, dark: 0xB3A9D6)
        case .commute: Color.adaptive(light: 0x7A6A55, dark: 0xBCAA90)
        case .rest: Color.adaptive(light: 0x7D5C7E, dark: 0xC4A3C5)
        case .focus: Color.adaptive(light: 0x5E7D3A, dark: 0xB2CC8E)
        case .other: inkSoft
        }
    }

    /// 修行录三类的颜色：日记玉、灵感金、复盘青（节点、小图标、落笔框聚焦时的描边）
    static func color(for kind: JournalKind) -> Color {
        switch kind {
        case .diary: jade
        case .note: gold
        case .review: azure
        }
    }

    // MARK: 字体

    /// 宋体（旧版标题字体 Songti SC），系统没有时回退到衬线体。
    private static let hasSongti = NSFontManager.shared.availableMembers(ofFontFamily: "Songti SC") != nil

    /// 宋体，字号即最终大小（只给标题和需要书卷气的短语；正文、按钮、数据用无衬线）。
    /// 字号请从 7 级里取（Font.ysDisplay…ysMicro / TypeSize）
    static func songti(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if hasSongti { return Font.custom("Songti SC", size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// 大数字（修为、统计值、日期标题）：New York 衬线体 + 等宽数字，与宋体是经典的中西衬线搭配
    static func figure(_ size: CGFloat = TypeSize.title, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif).monospacedDigit()
    }

    /// 金额：与 figure 同一种数字字体，默认正文字号（表格、列表里右对齐用）
    static func money(_ size: CGFloat = TypeSize.body, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif).monospacedDigit()
    }
}

extension JournalKind {
    var color: Color { Theme.color(for: self) }
}

/// 7 级字号（pt，最终大小）。字距只用三档：0（正文）、1–2（标题）、6（眉题）。
enum TypeSize {
    /// 横幅标题
    static let display: CGFloat = 50
    /// 大数字、弹窗标题
    static let title: CGFloat = 26
    /// 卡片标题
    static let heading: CGFloat = 18
    /// 正文
    static let body: CGFloat = 14
    /// 次要正文、按钮（紧凑）、表单标签
    static let callout: CGFloat = 13
    /// 说明、标签、元信息
    static let caption: CGFloat = 12
    /// 坐标刻度、角标
    static let micro: CGFloat = 10.5
}

extension Font {
    /// 横幅标题：宋体 50 粗
    static let ysDisplay = Theme.songti(TypeSize.display, .bold)
    /// 弹窗标题：宋体 26 半粗（大数字请用 Theme.figure）
    static let ysTitle = Theme.songti(TypeSize.title, .semibold)
    /// 卡片标题：宋体 18 半粗（配 .tracking(1)）
    static let ysHeading = Theme.songti(TypeSize.heading, .semibold)
    /// 正文 14
    static let ysBody = Font.system(size: TypeSize.body)
    /// 次要正文 13
    static let ysCallout = Font.system(size: TypeSize.callout)
    /// 说明 12
    static let ysCaption = Font.system(size: TypeSize.caption)
    /// 刻度 10.5
    static let ysMicro = Font.system(size: TypeSize.micro)
}

/// 页面栅格。（不叫 Layout：会遮住 SwiftUI 的 Layout 协议，FlowLayout 等自定义布局就编不过了）
enum PageLayout {
    /// 页面左右边距
    static let page: CGFloat = 40
    /// 卡片之间、栏与栏之间的间距
    static let gutter: CGFloat = 24
    /// 侧栏（工具栏 / 列表栏）宽度
    static let side: CGFloat = 320
}

/// 圆角只用四种：卡片 18 / 控件 10 / 内嵌 8 / 胶囊
enum Radius {
    /// 卡片（玉简、纸笺）
    static let card: CGFloat = 18
    /// 按钮、输入框、分段、内嵌格、可点的块
    static let control: CGFloat = 10
    /// 控件里的小块（分段的选中块、格子）
    static let inner: CGFloat = 8
    /// 胶囊：能用 Capsule() 时直接用它；要数值时用这个（会被限制在短边的一半）
    static let pill: CGFloat = 999
}

// MARK: - 卡片与标题

/// 卡片分三级，层次一眼可辨。
enum CardTier {
    /// 玉简主卡（每屏 1–2 张，如落笔卡、修为卡）：描边、阴影、顶缘高光、四角回纹（平时淡，悬停才亮）
    case jade
    /// 纸笺卡（大多数卡）：描边加极淡阴影，平时没有回纹（悬停时才显出）
    case paper
    /// 内嵌格（卡里的统计小格、列表块）：浅雾底、控件圆角，没有描边和阴影
    case inset
}

/// 卡片：微透的纸面、细描边、顶缘一线高光；玉简主卡另有四角回纹。
/// 可在右下角衬一件小物插画。平时安静；悬停时每张卡都微微浮起、描边转金、外缘泛起金晕、四角回纹伸长亮起，
/// 能点的卡（interactive）再多铺一层淡玉底，和只装内容的卡区分开。内嵌格只在能点时才有悬停反馈。
struct XianCard: ViewModifier {
    var padding: CGFloat = 24
    var ornament: String?
    var tier: CardTier = .paper
    var interactive = false
    @Environment(\.spiritMotion) private var motion
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let radius = tier == .inset ? Radius.control : Radius.card
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // 外层卡片悬停都会亮起；内嵌格在卡片里面，只有能点时才亮
        let lit = hover && (tier != .inset || interactive)
        content
            .padding(padding)
            .background {
                switch tier {
                case .inset:
                    shape.fill(lit ? Theme.jade.opacity(dark ? 0.14 : 0.08) : Theme.mist.opacity(dark ? 0.6 : 0.75))
                case .jade, .paper:
                    // 阴影只投在底板形状上；悬停时外圈再泛一层金色柔光（同时只会有一张卡片亮起）
                    shape.fill(Theme.card)
                        .shadow(color: shadowColor(dark: dark), radius: shadowRadius(dark: dark), y: shadowY(dark: dark))
                        .shadow(color: Theme.gold.opacity(lit ? (dark ? 0.28 : 0.22) : 0), radius: lit ? 20 : 0)
                    if lit && interactive {
                        shape.fill(Theme.jade.opacity(dark ? 0.08 : 0.05))
                    }
                }
                if let ornament {
                    SceneryImage(name: ornament)
                        .frame(width: 118, height: 118)
                        .opacity(dark ? 0.13 : 0.2)
                        .saturation(dark ? 0.5 : 0.9)
                        .scaleEffect(lit ? 1.06 : 1, anchor: .bottomTrailing)
                        .offset(x: 14, y: 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .clipShape(shape)
                }
            }
            .overlay {
                if tier != .inset {
                    shape.strokeBorder(lit ? Theme.gold.opacity(dark ? 0.8 : 0.7) : Theme.line.opacity(dark ? 0.6 : 1),
                                       lineWidth: lit ? 1.4 : 1)
                } else if lit {
                    shape.strokeBorder(Theme.gold.opacity(0.45), lineWidth: 1)
                }
            }
            .overlay(alignment: .top) {
                if tier != .inset {
                    // 顶缘一线高光（深色下靠它勾出卡片上缘）
                    Capsule()
                        .fill(Color.white.opacity(dark ? (lit ? 0.14 : 0.1) : 0.75))
                        .frame(height: 1)
                        .padding(.horizontal, radius)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if tier != .inset {
                    // 四角回纹：平时玉简主卡淡淡显出、纸笺卡不显；悬停时向四角伸长、亮成金色
                    let rest = tier == .jade ? (dark ? 0.2 : 0.15) : 0
                    CornerFlourish(inset: lit ? 7 : 12, length: lit ? 18 : 10)
                        .stroke(Theme.gold.opacity(lit ? 0.95 : rest), style: StrokeStyle(lineWidth: lit ? 1.3 : 1, lineCap: .round))
                        .allowsHitTesting(false)
                }
            }
            // 悬停：微微上浮
            .offset(y: lit && motion ? -3 : 0)
            .modifier(CardHover(enabled: tier != .inset || interactive, hover: $hover,
                                animation: tier == .inset ? Motion.hover : Motion.standard))
    }

    private func shadowColor(dark: Bool) -> Color {
        switch tier {
        case .jade: dark ? Color.black.opacity(0.3) : Color(red: 0.2, green: 0.29, blue: 0.22).opacity(0.07)
        case .paper: dark ? Color.black.opacity(0.2) : Color(red: 0.2, green: 0.29, blue: 0.22).opacity(0.04)
        case .inset: .clear
        }
    }

    private func shadowRadius(dark: Bool) -> CGFloat { tier == .jade ? (dark ? 16 : 14) : (dark ? 12 : 10) }
    private func shadowY(dark: Bool) -> CGFloat { tier == .jade ? (dark ? 8 : 6) : (dark ? 5 : 3) }
}

/// 卡片 / 可点块的悬停追踪：正在滑动时不响应（卡片从鼠标下经过时不会一亮一灭地重绘），开始滑动时收起。
private struct CardHover: ViewModifier {
    var enabled: Bool
    @Binding var hover: Bool
    /// 卡片浮起用弹簧，可点小块的底色描边用短缓出
    var animation: Animation = Motion.hover
    @Environment(\.spiritMotion) private var motion

    func body(content: Content) -> some View {
        if enabled {
            content
                .onHover { inside in
                    if inside && ScrollActivity.shared.isScrolling { return }
                    withAnimation(motion ? animation : nil) { hover = inside }
                }
                .onReceive(ScrollActivity.shared.began) { _ in
                    if hover { hover = false }
                }
        } else {
            content
        }
    }
}

/// 纸笺：纸色底加一圈发丝细边，不带阴影、回纹和浮起（时间线条目这类成列的小卡）。
/// interactive 时悬停只把边框换成淡金。
struct SlipCard: ViewModifier {
    var padding: CGFloat = 16
    var interactive = false
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(padding)
            .background(Theme.card.opacity(dark ? 0.92 : 0.88), in: shape)
            .overlay(shape.strokeBorder(hover && interactive ? Theme.gold.opacity(0.5) : Theme.line.opacity(dark ? 0.6 : 0.9), lineWidth: 1))
            .modifier(CardHover(enabled: interactive, hover: $hover))
    }
}

/// 能点的块（问法块、功课 / 作息 / 日程行、搜索结果）统一的悬停反馈：淡玉底 + 金色细描边，0.18 秒缓出。
/// 块里的小物插画加 `.tileOrnament()`，悬停时最多放大到 1.04。selected 为当前选中（金边常亮）。
struct YunshanTile: ViewModifier {
    var selected = false
    var cornerRadius: CGFloat = Radius.control
    @State private var hover = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(Theme.jade.opacity(selected ? 0.11 : hover ? 0.07 : 0)))
            .overlay(shape.strokeBorder(Theme.gold.opacity(selected ? 0.55 : hover ? 0.4 : 0), lineWidth: 1))
            .contentShape(shape)
            .environment(\.tileHovered, hover)
            .modifier(CardHover(enabled: true, hover: $hover))
    }
}

private struct TileHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 所在的可点块（.yunshanTile）是否正被悬停
    var tileHovered: Bool {
        get { self[TileHoveredKey.self] }
        set { self[TileHoveredKey.self] = newValue }
    }
}

private struct TileOrnament: ViewModifier {
    @Environment(\.tileHovered) private var hovered
    @Environment(\.spiritMotion) private var motion
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered && motion ? 1.04 : 1)
            .animation(motion ? Motion.hover : nil, value: hovered)
    }
}

/// 记录“是否正在滑动”：滚轮 / 触控板事件到来时置为 true，停下 0.18 秒后恢复。
@MainActor
final class ScrollActivity {
    static let shared = ScrollActivity()
    private(set) var isScrolling = false
    /// 开始滑动时通知卡片收起悬停效果
    let began = PassthroughSubject<Void, Never>()
    private var monitor: Any?
    private var endWork: DispatchWorkItem?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.noteScroll()
            return event
        }
    }

    func noteScroll() {
        if !isScrolling {
            isScrolling = true
            began.send()
        }
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isScrolling = false }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}

extension View {
    /// 卡片。tier 默认纸笺卡；每屏 1–2 张主卡用 .jade，卡里的小格用 .inset；整张卡能点时 interactive: true
    func xianCard(padding: CGFloat = 24, ornament: String? = nil, tier: CardTier = .paper, interactive: Bool = false) -> some View {
        modifier(XianCard(padding: padding, ornament: ornament, tier: tier, interactive: interactive))
    }

    /// 纸笺（成列的轻卡片，如时间线条目）
    func slipCard(padding: CGFloat = 16, interactive: Bool = false) -> some View {
        modifier(SlipCard(padding: padding, interactive: interactive))
    }

    /// 能点的块：悬停时淡玉底 + 金色细描边
    func yunshanTile(selected: Bool = false, cornerRadius: CGFloat = Radius.control) -> some View {
        modifier(YunshanTile(selected: selected, cornerRadius: cornerRadius))
    }

    /// 可点块里的小物插画：块被悬停时放大到 1.04
    func tileOrnament() -> some View { modifier(TileOrnament()) }
}

/// 卡片标题：淡金细竖线 + 宋体。标题旁只放数字或状态（detail）；操作说明放 hint（悬停标题才显示）；
/// 卡内链接（如“时辰卷 →”，用 .buttonStyle(.cardLink)）放 trailing，排在标题行最右。
struct CardTitle<Trailing: View>: View {
    var title: String
    var detail: String = ""
    var hint: String = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(LinearGradient(colors: [Theme.gold.opacity(0.9), Theme.gold.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1.5, height: 16)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Self.styled(title).foregroundStyle(Theme.ink)
                    if !detail.isEmpty {
                        Text(detail).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                    }
                }
            }
            .contentShape(Rectangle())
            .modifier(HelpText(text: hint))
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing()
        }
    }

    /// 标题按拉丁字母 / 数字与汉字切段：汉字用宋体加字距，字母用系统字体、数字用 New York，都不加字距
    /// （宋体自带的西文字形和字距会把“AI”拆成“A I”）。默认卡片标题字号；弹窗标题等传 size / tracking
    static func styled(_ title: String, size: CGFloat = TypeSize.heading, tracking: CGFloat = 1) -> Text {
        typealias Run = TitleRun
        func kind(_ ch: Character) -> Run {
            guard ch.isASCII else { return .han }
            if ch.isNumber { return .digit }
            return ch.isLetter ? .latin : .han
        }
        func piece(_ text: String, _ run: Run) -> Text {
            switch run {
            case .han: Text(verbatim: text).font(Theme.songti(size, .semibold)).tracking(tracking)
            case .latin: Text(verbatim: text).font(.system(size: size - 1, weight: .semibold))
            case .digit: Text(verbatim: text).font(.system(size: size - 1, weight: .semibold, design: .serif).monospacedDigit())
            }
        }
        var result: Text?
        var buffer = ""
        var current: Run?
        for ch in title {
            // 空格与间隔号跟着前一段走：“Tong Lin Li · Chatswood”整段是西文，不会被宋体字距拉开
            let run = (ch == " " || ch == "·") ? (current ?? .han) : kind(ch)
            if let c = current, c != run, !buffer.isEmpty {
                result = result.map { $0 + piece(buffer, c) } ?? piece(buffer, c)
                buffer = ""
            }
            current = run
            buffer.append(ch)
        }
        if let c = current, !buffer.isEmpty { result = result.map { $0 + piece(buffer, c) } ?? piece(buffer, c) }
        return result ?? Text(verbatim: "")
    }
}

/// 卡片标题里的一段：汉字 / 拉丁字母 / 数字
private enum TitleRun { case han, latin, digit }

extension CardTitle where Trailing == EmptyView {
    init(title: String, detail: String = "", hint: String = "") {
        self.init(title: title, detail: detail, hint: hint) { EmptyView() }
    }
}

/// 有说明时才挂悬停提示（空字符串不挂，读屏也不多读）
private struct HelpText: ViewModifier {
    var text: String
    func body(content: Content) -> some View {
        if text.isEmpty { content } else { content.help(text).accessibilityHint(text) }
    }
}

/// 侧栏与页面里的小分组标签：“常用空间 ——”
struct SectionLabel: View {
    var text: String
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(Theme.songti(TypeSize.callout, .medium)).tracking(2).foregroundStyle(Theme.gold.opacity(0.85))
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

// 空状态（大号留白 OrnamentEmpty、一行小字 EmptyHint）在 Views/Shared.swift 的“空状态”一节，文案在 Core/EmptyCopy.swift

/// 小标签：只有一层淡底色，不描边。
struct Chip: View {
    var text: String
    var color: Color = Theme.jade
    var body: some View {
        Text(text)
            .font(.ysCaption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.1), in: Capsule())
    }
}

// MARK: - 按钮与输入框

/// 云山按钮：主按钮为玉色实底（深色是一块温玉，加一线淡金边），次按钮为纸色底细边。
/// 不可用的主按钮仍是一块淡玉（字也是淡的），一眼看得出这是“填好了才能点”的主动作，不退成白底次按钮；
/// 不可用的次按钮走纸色底、细边、浅色字。`role: .destructive` 的次按钮（删除、撤销导入）是朱砂字、淡朱砂边。
struct YunshanButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// 普通按钮的字距。按钮的字是调用方给的整块视图，没法像 CardTitle.styled 那样把汉字、字母分开排，
    /// 只好取一个两边都过得去的值：汉字仍略疏朗，“CSV”“Claude Code”里的字母不再被拉成“C S V”
    static let tracking: CGFloat = 0.5

    /// 按钮的四种样子：主按钮、不可用的主按钮、删除类、普通（含不可用的普通按钮）
    private enum Look { case solid, dimPrimary, destructive, plain }

    private func look(_ role: ButtonRole?) -> Look {
        if primary { return isEnabled ? .solid : .dimPrimary }
        return role == .destructive && isEnabled ? .destructive : .plain
    }

    private func textColor(_ look: Look) -> Color {
        switch look {
        case .solid: Theme.onJadeFill
        case .dimPrimary: Theme.onJadeFill.opacity(scheme == .dark ? 0.7 : 0.9)
        case .destructive: Theme.cinnabar
        case .plain: isEnabled ? Theme.ink : Theme.inkSoft.opacity(0.7)
        }
    }

    private func fill(_ look: Look) -> AnyShapeStyle {
        switch look {
        case .solid: AnyShapeStyle(Theme.jadeFill)
        // 淡玉：浅色 25% 太淡、白字几乎读不出，深色 25% 又与卡片底分不开，都加深一档
        case .dimPrimary: AnyShapeStyle(Theme.jadeFill.opacity(scheme == .dark ? 0.36 : 0.42))
        case .destructive, .plain: AnyShapeStyle(Theme.card.opacity(isEnabled ? 0.92 : 0.6))
        }
    }

    private func stroke(_ look: Look) -> Color {
        let dark = scheme == .dark
        switch look {
        case .solid: return dark ? Theme.gold.opacity(0.5) : Color.clear
        case .dimPrimary: return dark ? Theme.gold.opacity(0.2) : Color.clear
        case .destructive: return Theme.cinnabar.opacity(0.4)
        case .plain: return Theme.line.opacity(isEnabled ? 1 : 0.7)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let look = look(configuration.role)
        let solid = look == .solid
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: compact ? TypeSize.callout : TypeSize.body, weight: .medium))
            .tracking(compact ? 0 : Self.tracking)
            .padding(.horizontal, compact ? 13 : 20)
            .padding(.vertical, compact ? 7 : 10)
            .foregroundStyle(textColor(look))
            .background(shape.fill(fill(look)))
            .overlay(shape.strokeBorder(stroke(look), lineWidth: 1))
            .shadow(color: solid ? (dark ? Color.black.opacity(0.35) : Theme.jadeDeep.opacity(0.25)) : .clear,
                    radius: solid ? 6 : 0, y: solid ? 3 : 0)
            .opacity(configuration.isPressed ? 0.82 : 1)
            // 关闭动效或“减少动态效果”时按下只变淡、不缩放
            .scaleEffect(configuration.isPressed && motion && !reduceMotion ? 0.97 : 1)
            .animation(motion && !reduceMotion ? Motion.quick : nil, value: configuration.isPressed)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == YunshanButtonStyle {
    static var yunshan: YunshanButtonStyle { YunshanButtonStyle() }
    static var yunshanPrimary: YunshanButtonStyle { YunshanButtonStyle(primary: true) }
    static var yunshanCompact: YunshanButtonStyle { YunshanButtonStyle(compact: true) }
}

struct YunshanFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        YunshanField(field: configuration)
    }
}

/// 输入框外观。`.plain` 去掉了系统焦点环，所以聚焦时自己把描边换成金色，用 Tab 切换时看得出焦点在哪。
/// （样式内部已用 .focused 跟踪焦点；调用方如需程序控制焦点，请改用不带此样式的输入框，避免两层 .focused 叠加）
private struct YunshanField<Field: View>: View {
    var field: Field
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        field
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.paper.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(focused ? Theme.gold.opacity(0.6) : Theme.line, lineWidth: focused ? 1.3 : 1))
    }
}

extension TextFieldStyle where Self == YunshanFieldStyle {
    static var yunshan: YunshanFieldStyle { YunshanFieldStyle() }
}

/// 自绘分段选择（旧版的“列表 / 时间轴 / 周 / 月”样式）。
struct SegmentedTabs<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: TypeSize.callout, weight: on ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(on ? Theme.ink : Theme.inkSoft)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(on ? Theme.card : Color.clear, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).strokeBorder(on ? Theme.line : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.mist.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.line.opacity(0.7)))
    }
}

/// 勾选框（玉色方印）：取代系统的灰色复选框。
struct YunshanToggleStyle: ToggleStyle {
    /// 只画方框：不放文字、也不留方框与文字之间的 9pt（列表行尾的勾选用它，右缘才和分隔线对齐；
    /// 用 `.labelsHidden()` 藏文字时这 9pt 间距还在）。调用方自己补 `.accessibilityLabel`
    var boxOnly = false
    /// 方框边长
    static let boxSize: CGFloat = 18
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.jadeFill) : AnyShapeStyle(Theme.card))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(configuration.isOn ? Theme.gold.opacity(0.5) : Theme.inkSoft.opacity(0.45), lineWidth: 1)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.onJadeFill)
                        .opacity(configuration.isOn ? 1 : 0)
                }
                .frame(width: Self.boxSize, height: Self.boxSize)
                if !boxOnly {
                    configuration.label.foregroundStyle(Theme.text)
                }
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        // 画成按钮后要自己补上开关的语义，VoiceOver 才会读出“开 / 关”
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "开" : "关")
        .animation(motion && !reduceMotion ? Motion.quick : nil, value: configuration.isOn)
    }
}

extension ToggleStyle where Self == YunshanToggleStyle {
    static var yunshan: YunshanToggleStyle { YunshanToggleStyle() }
    /// 只有方框、没有文字和间距的玉印勾选（列表行尾用）
    static var yunshanBox: YunshanToggleStyle { YunshanToggleStyle(boxOnly: true) }
}

/// 弹出编辑窗口统一样式。
struct YunshanSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card)
            .buttonStyle(.yunshan)
            .toggleStyle(.yunshan)
            .textFieldStyle(.yunshan)
            .disclosureGroupStyle(.yunshan)
            .scrollContentBackground(.hidden)
            .font(.ysBody)
            .tint(Theme.jade)
    }
}

extension View {
    func yunshanSheet() -> some View { modifier(YunshanSheet()) }
}

// MARK: - 背景

/// 页面背景：宣纸 / 墨夜底色上晕开本页山水的色调，远处三重水墨山峦各自缓缓漂移，
/// 流云、灵气浮动，四周压一圈暗角，让页面像置身画中。
/// 天色随时辰（SkyTimeline）：清晨有朝霞和山脚薄雾，黄昏有霞光霞云，入夜有星河与明灭的星；白天与原来一样。
/// 每分钟只有这一组背景层按新的天色重算（不碰数据），页面本身不跟着重算
struct PaperBackground: View {
    var page: AppSection
    @Environment(\.colorScheme) private var scheme
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 最近一次后台烘好的柔光（缓存被清掉时也先用着）
    @State private var wash: (asset: String, image: NSImage)?

    var body: some View {
        let dark = scheme == .dark
        let scene = Scenery.scene(for: page)
        let asset = scene.asset(dark: dark)
        // 天色的渐变只由时刻变化触发（见 SkyTimeline），这里不要再加 .animation(value:)
        SkyTimeline { mix in
            let look = SkyLook.look(mix, dark: dark)
            ZStack(alignment: .top) {
                Theme.paper
                if let soft = washImage(asset) {
                    Image(nsImage: soft)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .moonlit(scene.needsMoonlight(dark: dark))
                        .frame(height: 760)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        // 深色下借月色调色的页（还没有专门夜景画，如岁月长卷）柔光减半，免得整页蒙一层灰雾
                        .opacity(dark ? (scene.needsMoonlight(dark: dark) ? 0.2 : 0.4) : 0.22)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.55), location: 0.45),
                                                 .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .transition(.opacity)
                    // 换了一张柔光就当作新视图：烘好后在动画里换上时与旧的交叉淡入
                    .id(ObjectIdentifier(soft))
                }
                // 天色：罩色、天光带、霞光、朝阳 / 夕照 / 月华、星河、星、霞云（都在远山后面）
                SkyBackdrop(look: look, animated: motion)
                InkMountains(animated: motion, ink: look.ridgeInk)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                // 山脚晨雾（清晨最浓）
                SkyFog(amount: look.fog, animated: motion)
                MistDrift(animated: motion, sunTint: look.sunTint)
                // 灵气光点；深色时偶有流星（约 11 秒一颗），浅色入夜后也有淡金流星
                SpiritField(count: 36, animated: motion, meteors: dark || look.meteors)
                // 暗角（昼 = 原来的颜色）
                RadialGradient(colors: [.clear, look.vignette.color], center: UnitPoint(x: 0.55, y: 0.4), startRadius: 300, endRadius: 1100)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: asset) {
            // 没烘好的柔光交给后台解码（第一次切到某页时不在主线程卡一下），烘好后淡入
            guard !RenderMode.offscreen else { return }
            if Scenery.cachedSoft(asset) == nil {
                // 稍等一下，让本页横幅先开始烘（它会顺带烘好柔光），同一幅画不必解码两次
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                await Scenery.prepare(asset, heroAspect: nil)
            }
            guard !Task.isCancelled, let soft = Scenery.cachedSoft(asset) else { return }
            let fadeIn = wash?.asset != asset && motion && !reduceMotion
            withAnimation(fadeIn ? Motion.reveal : nil) { wash = (asset, soft) }
        }
    }

    private func washImage(_ asset: String) -> NSImage? {
        if RenderMode.offscreen { return Scenery.softImage(asset) }   // 离屏截图：同步做好
        // 本页（或刚切换的深浅色）的柔光还没烘好：先留着上一张，烘好后淡入替换，不先消失
        return Scenery.cachedSoft(asset) ?? wash?.image
    }
}
