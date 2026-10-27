import SwiftUI

// 岁月长卷的卷轴与特效：上下卷轴、青绫天头地头、纸面发丝边栏；展卷、数字升腾、曲线描画、柱子生长、
// 破境金光呼吸、卷尾落款、洞见点亮（设计稿 P1 §2.5 的 E1–E9）。
// 动效一律看 `annalsAnimate`（动效开关 + 系统“减少动态效果” + 窗口在前台，离屏截图与 PDF 打印时为 false）：
// 关掉时直接显示最终状态，循环的效果立即停。常驻循环的金光呼吸另看 `someoneWatching`：闲满 3 分钟、主窗口被挡住时原地停（#20）。
// “只播一次”的效果记在 AnnalsPlayLog（AnnalsView 持有）：LazyVStack 滚出视野会回收节视图，滚回来不重放。

// MARK: - 环境值

private struct AnnalsPrintKey: EnvironmentKey { static let defaultValue = false }
private struct AnnalsAnimateKey: EnvironmentKey { static let defaultValue = false }
private struct AnnalsPlayLogKey: EnvironmentKey { static let defaultValue: AnnalsPlayLog? = nil }
private struct AnnalsInnerWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 676 }
private struct AnnalsEffectDelayKey: EnvironmentKey { static let defaultValue: Double = 0 }

extension EnvironmentValues {
    /// PDF 打印模式：特效、悬停、懒加载都关掉，强制浅色（AnnalsPDF 排版时设为 true）
    var annalsPrint: Bool {
        get { self[AnnalsPrintKey.self] }
        set { self[AnnalsPrintKey.self] = newValue }
    }

    /// 长卷的特效开不开（AnnalsView 按动效开关、减少动态效果、离屏截图算好往下传；打印时为 false）
    var annalsAnimate: Bool {
        get { self[AnnalsAnimateKey.self] }
        set { self[AnnalsAnimateKey.self] = newValue }
    }

    /// 已经播过的“只播一次”特效（节 id）；切换时段时清空
    var annalsPlayLog: AnnalsPlayLog? {
        get { self[AnnalsPlayLogKey.self] }
        set { self[AnnalsPlayLogKey.self] = newValue }
    }

    /// 卷内宽度（纸面减去左右留白）：两栏 / 单栏、数字格几列、竖排题签显不显示都按它分档（见 AnnalsLayout）
    var annalsInnerWidth: CGFloat {
        get { self[AnnalsInnerWidthKey.self] }
        set { self[AnnalsInnerWidthKey.self] = newValue }
    }

    /// 卷内特效推迟多久开始（秒）：展卷途中出现的节先等卷轴滑过再播，不在遮罩底下悄悄播完
    var annalsEffectDelay: Double {
        get { self[AnnalsEffectDelayKey.self] }
        set { self[AnnalsEffectDelayKey.self] = newValue }
    }
}

/// 长卷里“只播一次”的特效记录。只是一张名单：改它不会让界面重算（所以不是 @Observable）
@MainActor
final class AnnalsPlayLog {
    private var played: Set<String> = []
    func has(_ id: String) -> Bool { played.contains(id) }
    func claim(_ id: String) { played.insert(id) }
    func reset() { played = [] }
}

/// 决定一块内容这次出现要不要播特效：第一次出现、且特效开着才播；播过的（滚出视野又滚回来）直接显示终态。
/// 决定只做一次（存在 @State 里），之后重算不会改变
struct PlayOnce<Content: View>: View {
    var id: String
    @ViewBuilder var content: (_ play: Bool) -> Content
    @Environment(\.annalsAnimate) private var animate
    @Environment(\.annalsPlayLog) private var log
    @State private var decided: Bool?

    var body: some View {
        let play = decided ?? (animate && !(log?.has(id) ?? true))
        content(play)
            .onAppear {
                guard decided == nil else { return }
                decided = play
                if play { log?.claim(id) }
            }
    }
}

// MARK: - 卷轴

/// 卷轴的木色与金钮（浅深两套；朱印深浅同色）
enum ScrollPalette {
    static let woodLight = Color.adaptive(light: 0x6B4A2F, dark: 0x8A6440)
    static let woodDark = Color.adaptive(light: 0x3E2A1A, dark: 0x4A3220)
    /// 朱印：与落印同一种朱红
    static let seal = Color(red: 0.70, green: 0.20, blue: 0.16)
    static let rollerHeight: CGFloat = 16
    static let knob: CGFloat = 22
    /// 卷轴比纸面每边多伸出的长度
    static let overhang: CGFloat = 14
    static let mountHeight: CGFloat = 28
}

/// 一根卷轴：圆柱形的木色渐变（上缘一线高光、下缘压暗），两端各一枚金色轴头。
struct ScrollRoller: View {
    var body: some View {
        let h = ScrollPalette.rollerHeight, k = ScrollPalette.knob
        ZStack {
            RoundedRectangle(cornerRadius: h / 2, style: .continuous)
                .fill(LinearGradient(stops: [.init(color: ScrollPalette.woodLight.opacity(0.85), location: 0),
                                             .init(color: ScrollPalette.woodLight, location: 0.28),
                                             .init(color: ScrollPalette.woodDark, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {
                    // 上缘一线高光：像上过漆的木轴
                    Capsule().fill(Color.white.opacity(0.22)).frame(height: 1.2).padding(.horizontal, k / 2 + 4).padding(.top, 3)
                }
                .padding(.horizontal, k / 2 - 2)
                .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
            HStack {
                ScrollKnob()
                Spacer(minLength: 0)
                ScrollKnob()
            }
        }
        .frame(height: k)
        .accessibilityHidden(true)
    }
}

/// 轴头：金色圆钮 + 内圈细线
private struct ScrollKnob: View {
    var body: some View {
        let k = ScrollPalette.knob
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(red: 0.96, green: 0.86, blue: 0.62), Theme.gold, Color(red: 0.42, green: 0.31, blue: 0.17)],
                                         center: UnitPoint(x: 0.36, y: 0.32), startRadius: 0, endRadius: k * 0.62))
            Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.7).padding(4)
            Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.6)
        }
        .frame(width: k, height: k)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

/// 青绫天头 / 地头：淡玉色绫子上织一行云纹，靠纸的一侧压一道金线（隔水）；天头另垂两条惊燕。
private struct ScrollMount: View {
    var top: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Theme.jade.opacity(dark ? 0.18 : 0.12)
            // 绫纹：极淡的菱格（“绫”本是织出菱纹的斜纹丝），格上间隔织一朵玉云（只取云头、不要底座，像暗花）
            DiamondLattice(spacing: 9)
                .stroke(Theme.gold.opacity(dark ? 0.16 : 0.13), lineWidth: 0.5)
            GeometryReader { geo in
                let size: CGFloat = 58
                let count = max(1, Int(geo.size.width / 96))
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        SceneryImage(name: "yunshan-ornament-texture-cloud-v1")
                            .frame(width: size, height: size)
                            .scaleEffect(x: index % 2 == 0 ? 1 : -1)
                            .offset(y: -size * 0.12)
                            .frame(width: size, height: geo.size.height, alignment: .top)
                            .clipped()
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .saturation(dark ? 0.3 : 0.6)
                .opacity(dark ? 0.16 : 0.2)
            }
            if top {
                // 惊燕：两条垂下的窄绫（立轴天头上的老规矩）
                GeometryReader { geo in
                    ForEach([0.36, 0.64], id: \.self) { x in
                        Rectangle()
                            .fill(LinearGradient(colors: [Theme.card.opacity(dark ? 0.35 : 0.75), Theme.card.opacity(dark ? 0.2 : 0.45)],
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay(Rectangle().strokeBorder(Theme.gold.opacity(0.35), lineWidth: 0.5))
                            .frame(width: 5, height: geo.size.height)
                            .position(x: geo.size.width * x, y: geo.size.height / 2)
                    }
                }
            }
        }
        .frame(height: ScrollPalette.mountHeight)
        .overlay(alignment: top ? .bottom : .top) {
            // 隔水：一道金线
            Rectangle().fill(Theme.gold.opacity(0.55)).frame(height: 1)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// 菱格：两组 45° 斜线交成的细格（天头地头的绫纹）
private struct DiamondLattice: Shape {
    var spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let h = rect.height
        var x = rect.minX - h
        while x < rect.maxX + h {
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x + h, y: rect.maxY))
            p.move(to: CGPoint(x: x + h, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing * 2
        }
        return p
    }
}

/// 长卷：上卷轴 → 天头 → 纸面（内缩 10 一圈金色发丝边栏）→ 地头 → 下卷轴。整幅不做悬停浮起。
/// E1 展卷：出现时下卷轴从上卷轴处向下滑约 900 pt，纸面随之由遮罩自上而下显出，卷轴背后衬一团随它移动的金色柔光；
/// 滑完撤掉遮罩与移动的那根轴（固定的下卷轴本来就在卷尾）。外层按时段 .id 换新时重放。
struct AnnalsScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.annalsAnimate) private var animate
    @Environment(\.annalsPrint) private var printing
    /// 展卷进度 0…1；nil 表示还没决定（第一次计算时按动效开关取 0 或 1）
    @State private var progress: CGFloat?
    @State private var finished = false
    /// 卷轴以下（纸面 + 下卷轴）的高度：展卷最多滑这么远
    @State private var bodyHeight: CGFloat = 0

    static var travel: CGFloat { 900 }
    private static var duration: Double { 1.1 }
    /// 展卷途中出现的内容，特效推迟这么久（卷轴约在这时滑过卷首与第一节）
    private static var effectDelay: Double { 0.45 }

    var body: some View {
        let unrolling = animate && !finished
        let reach = max(0, min(Self.travel, bodyHeight - ScrollPalette.knob))
        let revealed = (progress ?? (unrolling ? 0 : 1)) * reach
        VStack(spacing: -3) {
            ScrollRoller().zIndex(2)
            VStack(spacing: -3) {
                paper
                    .environment(\.annalsEffectDelay, unrolling ? Self.effectDelay : 0)
                    .zIndex(1)
                ScrollRoller().zIndex(2)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                // 展完以后只在长出很多时才记（懒加载的节滚到才建，高度会一直变；不必每次都让卷轴重算）
                if !finished || height > bodyHeight + 500 { bodyHeight = height }
            }
            // 自上而下显出：用裁切而不是 mask（mask 要把整幅长卷离屏合成一遍，展完也一直挂着；裁切只是一条路径）。
            // 展完后裁切范围放到很大，等于不裁；始终挂着同一个修饰，长卷内容不会因展完而重建
            .clipShape(TopReveal(height: unrolling ? revealed + ScrollPalette.knob / 2 : max(bodyHeight, 1) + 1_000))
            .overlay(alignment: .top) {
                if unrolling {
                    ZStack {
                        SoftGlow(color: Theme.gold.opacity(0.35))
                            .frame(height: 110)
                            .padding(.horizontal, 60)
                        ScrollRoller()
                    }
                    // 只占卷轴那么高（柔光向上下溢出）：卷轴正好压在纸面显出的那条边上
                    .frame(height: ScrollPalette.knob)
                    .offset(y: revealed)
                    .allowsHitTesting(false)
                }
            }
        }
        .task {
            guard animate, !finished, progress == nil else {
                finished = true
                return
            }
            progress = 0
            // 等一帧量出高度，再开始滑
            try? await Task.sleep(nanoseconds: 40_000_000)
            withAnimation(.easeOut(duration: Self.duration)) { progress = 1 }
            try? await Task.sleep(nanoseconds: UInt64((Self.duration + 0.05) * 1_000_000_000))
            finished = true
        }
        .onChange(of: animate) { _, on in
            // 展卷途中关掉动效：直接展开
            if !on { finished = true }
        }
    }

    private var paper: some View {
        let dark = scheme == .dark
        return VStack(spacing: 0) {
            ScrollMount(top: true)
            content()
                .padding(.horizontal, 32)
                .padding(.top, 34)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    // 纸面：卡纸色，四边极淡的暖晕，像一幅旧宣
                    Theme.card
                        .overlay(LinearGradient(colors: [Theme.goldSoft.opacity(dark ? 0.12 : 0.35), .clear, .clear, Theme.goldSoft.opacity(dark ? 0.12 : 0.35)],
                                                startPoint: .leading, endPoint: .trailing))
                }
                .overlay {
                    // 内缩 10 pt 一圈金色发丝边栏，四角各一枚小回纹
                    ZStack {
                        Rectangle().strokeBorder(Theme.gold.opacity(0.35), lineWidth: 0.8)
                        CornerFlourish(inset: 4, length: 9)
                            .stroke(Theme.gold.opacity(0.5), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                }
            ScrollMount(top: false)
        }
        // 阴影只投在底板上（直接给整组加阴影会给每行字都投一遍，或者要整幅离屏合成）
        .background {
            Rectangle()
                .fill(Theme.card)
                .shadow(color: printing ? .clear : (dark ? Color.black.opacity(0.3) : Color(red: 0.2, green: 0.29, blue: 0.22).opacity(0.08)),
                        radius: dark ? 16 : 14, y: dark ? 8 : 6)
        }
        .padding(.horizontal, ScrollPalette.overhang)
    }
}

/// 展卷的裁切：只留上面 height 那一段（左右、上方多留出余地，卷轴两端的金钮和阴影不被切掉）
private struct TopReveal: Shape {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 80, y: rect.minY - 80, width: rect.width + 160, height: max(0, height) + 80))
    }
}

/// 卷轴合拢（数据还在算）：两根卷轴叠在一起，下面一行“展卷中……”
struct ClosedScroll: View {
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: -6) {
                ScrollRoller()
                ScrollMount(top: true).padding(.horizontal, ScrollPalette.overhang).frame(height: 10).clipped()
                ScrollRoller()
            }
            Text("展卷中……").font(Theme.songti(TypeSize.caption)).tracking(2).foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("展卷中")
    }
}

// MARK: - 卷内的小件

/// 节标题：本节小物 + 金色宋体“其一” + 墨色宋体“· 笔墨” + 向右淡出的金线（照修行录时间线日期行的线另画一份）
struct AnnalsSectionTitle: View {
    var number: String
    var title: String
    var ornament: String
    @Environment(\.annalsPrint) private var printing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SceneryImage(name: ornament)
                .frame(width: 28, height: 28)
            HStack(alignment: .center, spacing: 7) {
                Text(verbatim: number).font(Theme.songti(TypeSize.heading, .semibold)).tracking(2).foregroundStyle(Theme.gold)
                Circle().fill(Theme.gold.opacity(0.75)).frame(width: 3.5, height: 3.5)
                Text(verbatim: title).font(Theme.songti(TypeSize.heading, .semibold)).tracking(2).foregroundStyle(Theme.ink)
            }
            .fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill").font(.system(size: 5)).foregroundStyle(Theme.gold.opacity(0.8))
                Rectangle()
                    .fill(AnnalsFade.style(LinearGradient(colors: [Theme.gold.opacity(0.45), Theme.gold.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing),
                                           print: Theme.gold.opacity(0.3), printing: printing))
                    .frame(height: 1)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 节里的小标题（“珍藏”“最长的日记”“各项功课”）：宋体小字 + 淡线
struct AnnalsSubheading: View {
    var text: String
    var detail: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(Theme.songti(TypeSize.callout, .semibold)).tracking(2).foregroundStyle(Theme.gold)
            if !detail.isEmpty { Text(detail).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft) }
            Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1)
        }
    }
}

/// 竖排题签“岁月长卷”：宋体 14、字距 4、金色双线细框
struct VerticalTitleSlip: View {
    var text: String = "岁月长卷"

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                Text(String(ch)).font(Theme.songti(14, .semibold)).foregroundStyle(Theme.ink)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Theme.goldSoft.opacity(0.5))
        .overlay(Rectangle().strokeBorder(Theme.gold.opacity(0.7), lineWidth: 0.8))
        .overlay(Rectangle().strokeBorder(Theme.gold.opacity(0.35), lineWidth: 0.5).padding(3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - 打印（PDF）的替代画法

/// 排进 PDF 时（ImageRenderer → PDF 上下文）渐变里的透明度会丢掉：淡出到 .clear 的线变成黑线、柔光变成实心方块。
/// 打印时这些地方换成半透明的纯色，或先画成位图再贴（RasterInPrint）
enum AnnalsFade {
    static func style<S: ShapeStyle>(_ normal: S, print fallback: Color, printing: Bool) -> AnyShapeStyle {
        printing ? AnyShapeStyle(fallback) : AnyShapeStyle(normal)
    }
}

/// 打印时先把内容画成 3 倍位图再贴进 PDF（带柔光的境界徽记等）；平时照常显示
struct RasterInPrint<Content: View>: View {
    var size: CGSize
    @ViewBuilder var content: () -> Content
    @Environment(\.annalsPrint) private var printing

    var body: some View {
        if printing, let image = raster() {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
        } else {
            content()
        }
    }

    @MainActor
    private func raster() -> NSImage? {
        let renderer = ImageRenderer(content: content().frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.scale = 3
        return renderer.nsImage
    }
}

// MARK: - E2 数字升腾

/// 数字从 0 升到目标值（约 0.9 秒），走完换回静态文字（TimelineView 必须停）。
/// text(值) 给出每一帧的写法；text(target) 就是最终的样子
struct RisingText: View {
    var target: Double
    var play: Bool
    var text: (Double) -> String
    @Environment(\.annalsEffectDelay) private var delay
    @State private var started: Date?
    @State private var finished = false

    private static var duration: Double { 0.9 }

    var body: some View {
        if finished || !play {
            Text(text(target))
        } else {
            TimelineView(.animation) { context in
                let t = started.map { min(1, max(0, context.date.timeIntervalSince($0) / Self.duration)) } ?? 0
                let eased = 1 - pow(1 - t, 3)
                Text(text(target * eased))
            }
            .task {
                started = Date().addingTimeInterval(delay)
                try? await Task.sleep(nanoseconds: UInt64((Self.duration + delay + 0.03) * 1_000_000_000))
                finished = true
            }
        }
    }
}

// MARK: - E3 曲线描画 / E4 柱子生长

/// 遮罩从左到右约 0.9 秒显出图表（play 为 false 时直接整幅显示）
struct DrawOn: ViewModifier {
    var play: Bool
    @Environment(\.annalsEffectDelay) private var delay
    @State private var progress: CGFloat?

    func body(content: Content) -> some View {
        let shown = progress ?? (play ? 0 : 1)
        content
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: max(0.001, shown), y: 1, anchor: .leading)
            }
            .onAppear {
                guard progress == nil else { return }
                guard play else { progress = 1; return }
                progress = 0
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.9).delay(delay)) { progress = 1 }
                }
            }
    }
}

/// 柱子生长：先给 0 值再换成真值，让 Charts 自带插值长高（Motion.gentle）
struct Growing<Content: View>: View {
    var play: Bool
    @ViewBuilder var content: (_ grown: Bool) -> Content
    @Environment(\.annalsEffectDelay) private var delay
    @State private var grown: Bool?

    var body: some View {
        content(grown ?? !play)
            .onAppear {
                guard grown == nil else { return }
                guard play else { grown = true; return }
                grown = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + delay) {
                    withAnimation(.easeOut(duration: 0.8)) { grown = true }
                }
            }
    }
}

extension View {
    func drawOn(_ play: Bool) -> some View { modifier(DrawOn(play: play)) }
}

// MARK: - E5 破境金光呼吸

/// 期末徽记背后的金光：0.9 ↔ 1.15 倍、2.4 秒往返（MotionGate.Breath）。
/// 由 Core Animation 在渲染进程里呼吸（原来是 SwiftUI 每秒 30 次在主线程改倍数，约占 5% CPU、每秒唤醒 120 次），样子不变：
/// 同一团径向柔光、同一条余弦曲线、30 帧。动效关掉、窗口到后台、没人看（someoneWatching）时停在当前那一下（setPaused），
/// 恢复时接着呼吸、不跳；一直关着动效时停在 1 倍。离屏截图与 PDF 照旧给静态版
struct BreathingGlow: View {
    var size: CGFloat
    @Environment(\.annalsAnimate) private var animate
    @Environment(\.annalsPrint) private var printing
    @Environment(\.colorScheme) private var scheme
    /// 主窗口有没有人在看（RootView 注入）：只停这一层常驻呼吸，长卷别的特效照旧看 annalsAnimate
    @Environment(\.someoneWatching) private var watched

    var body: some View {
        if printing {
            // PDF 里柔光会变成实心方块（见 AnnalsFade），不画
            EmptyView()
        } else if RenderMode.offscreen {
            // 离屏截图：静态的一团（软件渲染画不了动画，也不画径向渐变层）
            SoftGlow(color: Theme.gold.opacity(0.5)).frame(width: size, height: size)
        } else {
            // 图层比金光大一圈：放大到 1.15 倍时不被视图边界裁掉；外框仍是 size，排版不变
            BreathingGlowLayer(dark: scheme == .dark, animate: animate && watched)
                .frame(width: size * 1.25, height: size * 1.25)
                .frame(width: size, height: size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct BreathingGlowLayer: NSViewRepresentable {
    var dark: Bool
    var animate: Bool

    func makeNSView(context: Context) -> BreathingGlowHostView { BreathingGlowHostView() }
    func updateNSView(_ view: BreathingGlowHostView, context: Context) { view.configure(dark: dark, animate: animate) }
}

final class BreathingGlowHostView: NSView {
    /// 那一团金光（自检看它的颜色与动画）
    let glow = CAGradientLayer()
    private var dark: Bool?
    /// 图层边长占视图的比例（视图大一圈，见 BreathingGlow）
    private static let inset: CGFloat = 1 / 1.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // 与 SoftGlow 同一团光：中心实、35% 处剩 55%、边缘全透（EllipticalGradient 的 0.5 半径 = 径向渐变的 (0.5,0.5)→(1,1)）
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 0.35, 1]
        layer?.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // 视网膜屏上按屏幕倍率出图，边缘不发糊
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glow.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height) * Self.inset
        glow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func configure(dark: Bool, animate: Bool) {
        if self.dark != dark {
            self.dark = dark
            // Theme.gold 按深浅色取色，再乘 SoftGlow 的透明度（0.5 / 0.5×0.55 / 0）
            var gold = NSColor.clear
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                gold = NSColor(Theme.gold).usingColorSpace(.sRGB) ?? .clear
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let alphas: [CGFloat] = [0.5, 0.5 * 0.55, 0]
            glow.colors = alphas.map { gold.withAlphaComponent($0).cgColor }
            CATransaction.commit()
        }
        // 第一次开动效时才挂上呼吸：从 1 倍那一点接着长（一直关着动效就一直停在 1 倍）
        if animate, glow.animation(forKey: "breath") == nil {
            layer?.setPaused(false)
            glow.add(Self.breath(), forKey: "breath")
        }
        layer?.setPaused(!animate)
    }

    /// 呼吸：照 MotionGate.Breath 的余弦曲线取 25 个点，平滑连起来（与原来逐帧算的倍数一致），30 帧合成
    static func breath() -> CAKeyframeAnimation {
        let b = MotionGate.Breath.self
        let steps = 24
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = (0...steps).map { b.scale(at: b.period * Double($0) / Double(steps)) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.calculationMode = .cubic
        animation.duration = b.period
        animation.repeatCount = .infinity
        animation.timeOffset = b.restOffset
        animation.isRemovedOnCompletion = false
        // 一团柔光放大缩小，30 帧足够顺滑，不必按屏幕最高刷新率合成
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        return animation
    }
}

// MARK: - E6 卷尾落款

/// 2×2 朱印“岁月 / 成卷”：传统右起竖读（右列“岁月”、左列“成卷”），朱红实底、白色细内框
struct AnnalsSeal: View {
    var size: CGFloat = 74

    var body: some View {
        let char = size * 0.34
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous).fill(ScrollPalette.seal)
            RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: max(1, size * 0.022))
                .padding(size * 0.07)
            HStack(spacing: size * 0.04) {
                VStack(spacing: size * 0.02) { glyph("成", char); glyph("卷", char) }
                VStack(spacing: size * 0.02) { glyph("岁", char); glyph("月", char) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("朱印：岁月成卷")
    }

    private func glyph(_ text: String, _ size: CGFloat) -> some View {
        Text(text).font(Theme.songti(size, .heavy)).foregroundStyle(Color.white.opacity(0.95)).frame(width: size * 1.05, height: size * 1.05)
    }
}

/// 落款：朱印 2 倍、-14° 弹簧落到 1 倍、-6°（Motion.ceremony），一圈涟漪 0.8 秒散去；落定后保持实色
struct LandingSeal: View {
    var play: Bool
    var size: CGFloat = 74
    @Environment(\.annalsEffectDelay) private var delay
    @State private var landed: Bool?
    @State private var ripple = false

    var body: some View {
        let down = landed ?? !play
        ZStack {
            if play {
                RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                    .strokeBorder(ScrollPalette.seal.opacity(0.5), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(ripple ? 1.9 : 0.9)
                    .opacity(ripple ? 0 : (down ? 0.8 : 0))
            }
            AnnalsSeal(size: size)
                .scaleEffect(down ? 1 : 2)
                .rotationEffect(.degrees(down ? -6 : -14))
                .opacity(down ? 1 : 0)
                .shadow(color: ScrollPalette.seal.opacity(0.25), radius: down ? 2 : 12)
        }
        .onAppear {
            guard landed == nil else { return }
            guard play else { landed = true; return }
            landed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + delay) {
                withAnimation(Motion.ceremony) { landed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.easeOut(duration: 0.8)) { ripple = true }
                }
            }
        }
    }
}

// MARK: - E7 洞见点亮

/// 一条洞见依次淡入（错开 80 ms），图标处一颗金色小星一闪（0.6 秒，一次）
struct InsightLight: ViewModifier {
    var play: Bool
    var index: Int
    @Environment(\.annalsEffectDelay) private var startDelay
    @State private var shown: Bool?
    @State private var spark = false

    func body(content: Content) -> some View {
        let visible = shown ?? !play
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)
            .overlay(alignment: .topLeading) {
                if play {
                    Image(systemName: "sparkle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.gold)
                        .shadow(color: Theme.gold.opacity(0.8), radius: 4)
                        .scaleEffect(spark ? 1.3 : 0.2)
                        .opacity(spark ? 0 : (visible ? 1 : 0))
                        .offset(x: 32, y: 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onAppear {
                guard shown == nil else { return }
                guard play else { shown = true; return }
                shown = false
                let delay = startDelay + 0.15 + Double(index) * 0.08
                withAnimation(.easeOut(duration: 0.35).delay(delay)) { shown = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) {
                    withAnimation(.easeOut(duration: 0.6)) { spark = true }
                }
            }
    }
}

extension View {
    func insightLight(_ play: Bool, index: Int) -> some View { modifier(InsightLight(play: play, index: index)) }
}
