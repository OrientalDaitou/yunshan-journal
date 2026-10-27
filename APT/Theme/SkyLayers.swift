import SwiftUI
import AppKit

// 天色随时辰：页面底、页首横幅的画、侧栏罩色与顶栏纸色按本机时间呈现晨 / 昼 / 暮 / 夜。
// “现在几点 → 四时权重 → 调色”都在 Core（SkyClock / SkyPalette），这里只把它画出来：
// - 只有 SkyTimeline 里面的视图每分钟重算一次，不牵动任何页面的 body；
// - 一直在动的（星的明灭、霞云、山脚晨雾）都是 Core Animation 层，在渲染进程里跑，动效关闭时原地停住；
// - 离屏截图时换成同样构图的 SwiftUI 静态版（星、星河、霞云、晨雾用同一批坐标和同一张图）。
// 白天（昼）调色表全是零：页面与原来逐像素一样。

extension SkyRGBA {
    /// SwiftUI 颜色（sRGB）
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    /// Core Animation 用的颜色（sRGB）
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

// MARK: - 时刻

/// 覆盖时刻：离屏截图（默认 12:00，也就是昼，与原来的截图一致）与调试用
@MainActor
enum SkyTime {
    /// 离屏时 = APT_RENDER_CLOCK（"HH:MM"）或 720；调试版另认 APT_SKY_CLOCK；正式运行为 nil。
    /// 离屏渲染可以在每张图之前改它（之后新建的页面按新时刻画）
    static var fixedMinute: Double? = {
        let env = ProcessInfo.processInfo.environment
        if RenderMode.offscreen { return Double(ClockTime.minutes(from: env["APT_RENDER_CLOCK"]) ?? 720) }
        #if DEBUG
        if let minute = ClockTime.minutes(from: env["APT_SKY_CLOCK"]) { return Double(minute) }
        #endif
        return nil
    }()

    /// 仅调试版：APT_SKY_CYCLE=<秒> 时，用这么多秒走完一整天，看过渡是否平滑（至少 10 秒）
    static let cycleSeconds: Double? = {
        #if DEBUG
        if let seconds = Double(ProcessInfo.processInfo.environment["APT_SKY_CYCLE"] ?? ""), seconds >= 10 { return seconds }
        #endif
        return nil
    }()

    /// 快进时这一刻对应当天第几分钟
    static func cycleMinute(at date: Date, seconds: Double) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: seconds) / seconds * 1440
    }
}

/// 给内容一个当前的 SkyMix。只有它里面的视图每分钟重算一次。
/// 每分钟的一小步（过渡段最多 2.5%）直接换，不做 SwiftUI 动画；一步变化 ≥ 5%（合盖一夜后打开、
/// 刚打开“随时辰”开关、调试快进）且动效开着时，2.5 秒渐变过去。第一次出现直接取当前值。
/// 用的地方不要再加 `.animation(value:)`：渐变只由时刻变化触发，切换深浅色时天色跟着纸色瞬间翻。
struct SkyTimeline<Content: View>: View {
    @AppStorage("sky.followsClock") private var follows = true
    @Environment(\.spiritMotion) private var motion
    @ViewBuilder var content: (SkyMix) -> Content
    /// 交给 content 的天色；nil = 刚出现，还没对过时
    @State private var shown: SkyMix? = nil

    init(@ViewBuilder content: @escaping (SkyMix) -> Content) {
        self.content = content
    }

    var body: some View {
        content(shown ?? target(at: Date()))
            .background { ticker }
    }

    /// 报时的小钟：时刻一变（或开关、调试时刻变了）就把新的目标交给 follow
    @ViewBuilder private var ticker: some View {
        if let fixed = SkyTime.fixedMinute {
            Color.clear.onChange(of: SkyClock.mix(minute: fixed), initial: true) { _, mix in follow(mix) }
        } else if !follows {
            Color.clear.onChange(of: SkyMix.noon, initial: true) { _, mix in follow(mix) }
        } else if let cycle = SkyTime.cycleSeconds {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Color.clear.onChange(of: SkyClock.mix(minute: SkyTime.cycleMinute(at: context.date, seconds: cycle)), initial: true) { _, mix in
                    follow(mix)
                }
            }
        } else {
            TimelineView(.everyMinute) { context in
                Color.clear.onChange(of: SkyClock.mix(at: context.date), initial: true) { _, mix in follow(mix) }
            }
        }
    }

    private func target(at date: Date) -> SkyMix {
        if let fixed = SkyTime.fixedMinute { return SkyClock.mix(minute: fixed) }
        if !follows { return .noon }
        if let cycle = SkyTime.cycleSeconds { return SkyClock.mix(minute: SkyTime.cycleMinute(at: date, seconds: cycle)) }
        return SkyClock.mix(at: date)
    }

    private func follow(_ target: SkyMix) {
        guard let current = shown else { shown = target; return }
        guard current != target else { return }
        if motion && current.maxDelta(to: target) >= 0.05 {
            withAnimation(.easeInOut(duration: 2.5)) { shown = target }
        } else {
            shown = target
        }
    }
}

// MARK: - 构图（Core Animation 与离屏静态版共用）

/// 星、星河、霞云、晨雾的位置与大小：动态图层和截图用的静态版都从这里取，构图对得上
enum SkyLayout {
    /// 星河斜过天顶（右端略高）
    static let galaxyAngle = -12 * Double.pi / 180

    /// 星河：宽 1.15 倍、高 0.42 倍，中心在 (0.5w, 0.22h)
    static func galaxy(in size: CGSize) -> CGRect {
        centered(CGPoint(x: size.width * 0.5, y: size.height * 0.22), CGSize(width: size.width * 1.15, height: size.height * 0.42))
    }

    /// 一颗星的图层边长：柔光点图的亮心约占一半，亮星的十字芒再长一些
    static func starSide(_ star: SkyStarField.Star) -> CGFloat {
        CGFloat(star.size) * (star.isBright ? 3.4 : 2.2)
    }

    /// 两条霞云：中心高度 0.30h / 0.48h，宽 0.9w / 0.75w，高 = 宽 / 3（流云图是 3:1）
    static func xiaCloud(_ index: Int, in size: CGSize) -> CGRect {
        let width = size.width * [0.9, 0.75][index]
        return centered(CGPoint(x: size.width * [0.58, 0.36][index], y: size.height * [0.30, 0.48][index]),
                        CGSize(width: width, height: width / 3))
    }

    /// 霞云左右漂 ±60pt，周期 80 / 96 秒
    static let xiaDrift: [(amplitude: CGFloat, period: Double)] = [(60, 80), (60, 96)]

    /// 山脚两条晨雾：中线在底边往上 140pt / 60pt，宽 1.1w + 100（最窄的正文区漂到头也露不出图边），压扁成 4.5:1
    static func fogBand(_ index: Int, in size: CGSize) -> CGRect {
        let width = size.width * 1.1 + 100
        return centered(CGPoint(x: size.width * 0.5, y: size.height - [140, 60][index]), CGSize(width: width, height: width / 4.5))
    }

    /// 晨雾左右漂 ±50pt，周期 70 / 90 秒；近处那条略淡
    static let fogDrift: [(amplitude: CGFloat, period: Double, opacity: Double)] = [(50, 70, 1), (50, 90, 0.8)]

    private static func centered(_ center: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// 往返漂移：position.x 上叠加的正弦偏移（从 0 起步，时刻为 0 时就在原位）
    static func drift(amplitude: CGFloat, period: Double, from start: CFTimeInterval, maxFrames: Float) -> CAKeyframeAnimation {
        let steps = 24
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = (0...steps).map { NSNumber(value: Double(amplitude) * sin(Double($0) / Double(steps) * 2 * .pi)) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.isAdditive = true
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = start
        // 每秒只移动一两个点，十几帧就够顺滑
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: maxFrames, preferred: maxFrames)
        return animation
    }
}

// MARK: - 小图（星点、星河、流云）

/// 天色用到的小图：第一次用到时用 CoreGraphics 烘好，之后常驻（星点几 KB，星河约 300 KB，染色的流云每张约 1 MB、最多四五张）
enum SkyArt {
    /// 180 颗星（固定种子）
    static let starField = SkyStarField.stars()
    /// 工笔流云（霞云、晨雾都从它染出来）
    static let cloud: CGImage? = Scenery.image("yunshan-cloud-band-v1")?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    private static var cache: [String: CGImage] = [:]

    /// 霞云：流云图先洗白一半（青灰的阴影染上色会发浑），再按左右两端的颜色横向正片叠底，
    /// 留着云里淡淡的明暗纹理，透明度仍取原图。
    /// 颜色按 1/255 取整做缓存键：过渡途中调色表给的颜色不变，不会每分钟重烘
    static func xiaCloud(left: SkyRGBA, right: SkyRGBA) -> CGImage? {
        func key(_ c: SkyRGBA) -> String { [c.r, c.g, c.b].map { String(Int(($0 * 255).rounded())) }.joined(separator: ",") }
        return cached("xia|\(key(left))|\(key(right))") { bakeCloud(left: left.with(a: 1), right: right.with(a: 1), wash: 0.5) }
    }

    /// 晨雾：流云图洗白一些（原图的青灰阴影在杏色的纸上会显脏），像山脚的白雾
    static var fog: CGImage? {
        cached("fog") { bakeCloud(left: nil, right: nil, wash: 0.55) }
    }

    /// 一颗星：16×16 的柔光点，亮心约占一半
    static func dot(_ tone: SkyRGBA) -> CGImage? {
        cached("dot|\(tone.r)|\(tone.g)|\(tone.b)") { bakeStar(tone, size: 16, sparkle: false) }
    }

    /// 亮星：32×32，柔光点加一道细十字芒
    static func sparkle(_ tone: SkyRGBA) -> CGImage? {
        cached("sparkle|\(tone.r)|\(tone.g)|\(tone.b)") { bakeStar(tone, size: 32, sparkle: true) }
    }

    static func star(_ star: SkyStarField.Star, dark: Bool) -> CGImage? {
        let tone = SkyStarField.tones(dark: dark)[min(2, max(0, star.tone))]
        return star.isBright ? sparkle(tone) : dot(tone)
    }

    /// 星河：512×160，深浅各一张
    static func galaxy(dark: Bool) -> CGImage? {
        cached("galaxy|\(dark)") { bakeGalaxy(dark: dark) }
    }

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let hit = cache[key] { return hit }
        let image = make()
        if let image { cache[key] = image }
        return image
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func gradient(_ tone: SkyRGBA, alphas: [Double], at locations: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: space, colors: alphas.map { tone.with(a: $0).cgColor } as CFArray, locations: locations)
    }

    /// 流云图缩到 900×300 再加工：wash 给了就先叠一层白（只落在云上），left / right 给了再横向正片叠底染色
    private static func bakeCloud(left: SkyRGBA?, right: SkyRGBA?, wash: Double?) -> CGImage? {
        guard let source = cloud else { return nil }
        let w = 900, h = 300
        guard let ctx = context(w, h) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(source, in: rect)
        if let wash {
            ctx.saveGState()
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(CGColor(gray: 1, alpha: wash))
            ctx.fill(rect)
            ctx.restoreGState()
        }
        if let left, let right,
           let tint = CGGradient(colorsSpace: space, colors: [left.cgColor, right.cgColor] as CFArray, locations: [0, 1]) {
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.drawLinearGradient(tint, start: .zero, end: CGPoint(x: w, y: 0), options: [])
            ctx.restoreGState()
            // 正片叠底会把透明处也染上：按原图的透明度裁回云的形状
            ctx.saveGState()
            ctx.setBlendMode(.destinationIn)
            ctx.draw(source, in: rect)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private static func bakeStar(_ tone: SkyRGBA, size: Int, sparkle: Bool) -> CGImage? {
        guard let ctx = context(size, size) else { return nil }
        let s = CGFloat(size), c = CGPoint(x: s / 2, y: s / 2)
        let locations: [CGFloat] = sparkle ? [0, 0.14, 0.32, 1] : [0, 0.3, 0.55, 1]
        if let glow = gradient(tone, alphas: [1, 0.85, 0.22, 0], at: locations) {
            ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        }
        if sparkle, let ray = gradient(tone, alphas: [0, 0.85, 0], at: [0, 0.5, 1]) {
            // 十字芒：横竖两道 1px 的细光，从中心向两端淡去
            for horizontal in [true, false] {
                ctx.saveGState()
                ctx.clip(to: horizontal ? CGRect(x: 0, y: c.y - 0.5, width: s, height: 1) : CGRect(x: c.x - 0.5, y: 0, width: 1, height: s))
                ctx.drawLinearGradient(ray, start: horizontal ? CGPoint(x: 0, y: c.y) : CGPoint(x: c.x, y: 0),
                                       end: horizontal ? CGPoint(x: s, y: c.y) : CGPoint(x: c.x, y: s), options: [])
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }

    /// 中线两侧高斯分布的约 900 粒细尘 + 一条柔和的椭圆亮带 + 三道略暗的尘带，两端淡出。本身就是糊的，拉伸也看不出来
    private static func bakeGalaxy(dark: Bool) -> CGImage? {
        let w = 512, h = 160
        guard let ctx = context(w, h) else { return nil }
        let W = CGFloat(w), H = CGFloat(h)
        let tone = SkyStarField.galaxyTone(dark: dark)
        // 椭圆亮带：半径 80 的圆横向拉 3.2 倍
        if let band = gradient(tone, alphas: [0.55, 0.22, 0], at: [0, 0.45, 1]) {
            ctx.saveGState()
            ctx.translateBy(x: W / 2, y: H / 2)
            ctx.scaleBy(x: 3.2, y: 1)
            ctx.drawRadialGradient(band, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: H / 2, options: [])
            ctx.restoreGState()
        }
        // 细尘：深色偏白（像一河碎星），浅色仍是墨蓝
        let dust = dark ? tone.mixed(with: .white, 0.5) : tone
        for i in 0..<900 {
            let u = spiritNoise(i, 901), v1 = spiritNoise(i, 902), v2 = spiritNoise(i, 903)
            let gauss = sqrt(-2 * log(max(1e-6, v1))) * cos(2 * .pi * v2)
            let spread = 22 * (1 - 0.45 * abs(u - 0.5) * 2)
            let x = u * Double(w), y = Double(h) / 2 + gauss * spread
            let r = 0.45 + spiritNoise(i, 904) * 0.9
            let alpha = (0.35 + spiritNoise(i, 905) * 0.6) * exp(-abs(gauss) * 0.5)
            ctx.setFillColor(dust.with(a: alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        // 三道略暗的尘带：沿带子起伏的一串柔边墨团，用 destinationOut 把亮带挖淡
        if let blob = gradient(SkyRGBA.white, alphas: [0.22, 0.1, 0], at: [0, 0.5, 1]) {
            ctx.setBlendMode(.destinationOut)
            for (lane, offset) in [-7.0, 3.0, 12.0].enumerated() {
                let phase = Double(lane) * 1.7
                for step in stride(from: 0, through: w, by: 4) {
                    let x = Double(step)
                    let y = Double(h) / 2 + offset + sin(x / Double(w) * 2 * .pi * 1.3 + phase) * 6
                    let radius = 5 + 3 * sin(x / 37 + phase)
                    let c = CGPoint(x: x, y: y)
                    ctx.drawRadialGradient(blob, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
                }
            }
        }
        // 两端淡出
        if let ends = gradient(SkyRGBA.white, alphas: [0, 1, 1, 0], at: [0, 0.25, 0.75, 1]) {
            ctx.setBlendMode(.destinationIn)
            ctx.drawLinearGradient(ends, start: .zero, end: CGPoint(x: W, y: 0), options: [])
        }
        return ctx.makeImage()
    }
}

// MARK: - 页面底的天色

/// 页面底的天色层（PaperBackground 里，放在本页山水柔光之上、远山之后）：
/// 整页罩色、顶部天光带、贴着山脊的霞光带、朝阳 / 夕照 / 月华，加上星河、星点、霞云（Core Animation）。
/// 远山画在它前面，所以远山会衬在霞光和星河前面。
struct SkyBackdrop: View {
    var look: SkyLook
    var animated: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .top) {
            if look.veil.a > 0 { look.veil.color }
            if look.horizonTop.a > 0 || look.horizonMid.a > 0 {
                // 天光带：顶端 → 35% 高处中段 → 70% 高处归零
                LinearGradient(stops: [.init(color: look.horizonTop.color, location: 0),
                                       .init(color: look.horizonMid.color, location: 0.35),
                                       .init(color: look.horizonMid.with(a: 0).color, location: 0.7)],
                               startPoint: .top, endPoint: .bottom)
            }
            if look.xiaLow.a > 0 || look.xiaHigh.a > 0 {
                // 霞光带：贴底部 560pt，从上往下 透明 → 上段 → 贴山脊那段 → 略淡
                LinearGradient(stops: [.init(color: look.xiaHigh.with(a: 0).color, location: 0),
                                       .init(color: look.xiaHigh.color, location: 0.5),
                                       .init(color: look.xiaLow.color, location: 0.85),
                                       .init(color: look.xiaLow.with(a: look.xiaLow.a * 0.6).color, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 560)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if look.glow.a > 0 {
                GeometryReader { geo in
                    SoftGlow(color: look.glow.color)
                        .frame(width: look.glowSize, height: look.glowSize)
                        .position(x: geo.size.width * look.glowX, y: geo.size.height * look.glowY)
                }
            }
            if RenderMode.offscreen {
                SkyStill(look: look, dark: dark)
            } else {
                SkyLayerView(look: look, dark: dark, animated: animated)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SkyLayerView: NSViewRepresentable {
    var look: SkyLook
    var dark: Bool
    var animated: Bool

    func makeNSView(context: Context) -> SkyHostView { SkyHostView() }
    func updateNSView(_ view: SkyHostView, context: Context) {
        view.configure(look: look, dark: dark, animated: animated, transition: animated)
    }
}

/// 天色里会动的部分：星河、星点（约 36 颗会明灭）、两条霞云。
/// 星按相对坐标逐颗摆，拉宽窗口时不会被拉成椭圆；不透明度为 0 的层隐藏并摘掉动画，白天这块的开销等于零。
final class SkyHostView: NSView {
    private let galaxy = CALayer()
    private let starField = CALayer()
    private let starFade = CAGradientLayer()
    private let starLayers: [CALayer]
    private let clouds = [CALayer(), CALayer()]
    /// 霞云当前用的染色图
    private var cloudArt: CGImage?
    private var dark: Bool?
    private var look: SkyLook?
    private var lastSize = CGSize.zero
    /// 明灭、漂移的起点（本层时间）：隐藏后再出现、窗口尺寸变化时都接着原来的节奏
    private var clockStart: CFTimeInterval?

    override init(frame: NSRect) {
        starLayers = SkyArt.starField.map { _ in CALayer() }
        super.init(frame: frame)
        wantsLayer = true
        galaxy.contentsGravity = .resize
        layer?.addSublayer(galaxy)
        for (star, dot) in zip(SkyArt.starField, starLayers) {
            dot.contentsGravity = .resize
            dot.opacity = Float(star.brightness)
            starField.addSublayer(dot)
        }
        // 竖向渐隐：顶部 1 → 65% 高处 0
        starFade.colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)]
        starFade.locations = [0, 0.65]
        starFade.startPoint = CGPoint(x: 0.5, y: 0)
        starFade.endPoint = CGPoint(x: 0.5, y: 1)
        starField.mask = starFade
        layer?.addSublayer(starField)
        for cloud in clouds {
            // 被染了色的流云（SkyArt.xiaCloud）
            cloud.contentsGravity = .resize
            layer?.addSublayer(cloud)
        }
        for item in [galaxy, starField] + clouds {
            item.opacity = 0
            item.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize, bounds.width > 0, bounds.height > 0 else { return }
        lastSize = bounds.size
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let g = SkyLayout.galaxy(in: size)
        galaxy.setAffineTransform(.identity)
        galaxy.bounds = CGRect(origin: .zero, size: g.size)
        galaxy.position = CGPoint(x: g.midX, y: g.midY)
        galaxy.setAffineTransform(CGAffineTransform(rotationAngle: SkyLayout.galaxyAngle))
        starField.frame = bounds
        starFade.frame = starField.bounds
        for (star, dot) in zip(SkyArt.starField, starLayers) {
            let side = SkyLayout.starSide(star)
            dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            dot.position = CGPoint(x: star.x * size.width, y: star.y * size.height)
        }
        for (index, cloud) in clouds.enumerated() {
            let frame = SkyLayout.xiaCloud(index, in: size)
            cloud.bounds = CGRect(origin: .zero, size: frame.size)
            cloud.position = CGPoint(x: frame.midX, y: frame.midY)
        }
        CATransaction.commit()
    }

    /// transition：换色、显隐走 2.5 秒渐变（在渲染进程里做，不占主线程）；第一次与切换深浅色时直接换
    func configure(look: SkyLook, dark: Bool, animated: Bool, transition: Bool) {
        let flipped = self.dark != dark
        if flipped || self.look != look {
            CATransaction.begin()
            if flipped || !transition {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(2.5)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            }
            CATransaction.setCompletionBlock { [weak self] in self?.hideTransparent() }
            if flipped {
                self.dark = dark
                galaxy.contents = SkyArt.galaxy(dark: dark)
                for (star, dot) in zip(SkyArt.starField, starLayers) { dot.contents = SkyArt.star(star, dark: dark) }
            }
            self.look = look
            reveal(galaxy, opacity: look.galaxy * (dark ? 0.55 : 0.35))
            reveal(starField, opacity: look.stars * (dark ? 0.95 : 0.6))
            let cloudOpacity = look.xiaClouds * (dark ? 0.35 : 0.8)
            // 全透明时调色表给的是“无”，不拿它换色（免得淡出途中染黑）
            if cloudOpacity > 0, let tinted = SkyArt.xiaCloud(left: look.xiaCloudLeft, right: look.xiaCloudRight), tinted !== cloudArt {
                cloudArt = tinted
                for cloud in clouds { cloud.contents = tinted }
            }
            for cloud in clouds { reveal(cloud, opacity: cloudOpacity) }
            CATransaction.commit()
        }
        // 暂停 / 继续时保持当前画面，不跳回起点
        layer?.setPaused(!animated)
        refreshAnimations()
    }

    /// 设目标不透明度；从隐藏变为显示时先以 0 现身，再按当前事务淡上去
    private func reveal(_ item: CALayer, opacity: Double) {
        let value = Float(min(1, max(0, opacity)))
        if value > 0 && item.isHidden {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            item.opacity = 0
            item.isHidden = false
            CATransaction.commit()
        }
        item.opacity = value
    }

    /// 淡到 0 的层在渐变走完后隐藏，并摘掉动画
    private func hideTransparent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [galaxy, starField] + clouds where item.opacity == 0 { item.isHidden = true }
        CATransaction.commit()
        refreshAnimations()
    }

    /// 看得见的层挂上动画（星的明灭、霞云漂移），隐藏的层摘掉
    private func refreshAnimations() {
        guard let host = layer else { return }
        let start = clockStart ?? host.convertTime(CACurrentMediaTime(), from: nil)
        clockStart = start
        let starsOn = !starField.isHidden
        for (star, dot) in zip(SkyArt.starField, starLayers) where star.twinkles {
            if !starsOn {
                dot.removeAnimation(forKey: "twinkle")
            } else if dot.animation(forKey: "twinkle") == nil {
                let b = star.brightness
                let twinkle = CAKeyframeAnimation(keyPath: "opacity")
                twinkle.values = [b, b * 0.35, b].map { NSNumber(value: $0) }
                twinkle.keyTimes = [0, 0.5, 1]
                twinkle.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                twinkle.duration = star.period
                twinkle.repeatCount = .infinity
                // 各颗错开起点
                twinkle.beginTime = start - star.phase * star.period
                twinkle.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
                dot.add(twinkle, forKey: "twinkle")
            }
        }
        for (cloud, spec) in zip(clouds, SkyLayout.xiaDrift) {
            if cloud.isHidden {
                cloud.removeAnimation(forKey: "drift")
            } else if cloud.animation(forKey: "drift") == nil {
                cloud.add(SkyLayout.drift(amplitude: spec.amplitude, period: spec.period, from: start, maxFrames: 15), forKey: "drift")
            }
        }
    }
}

/// 离屏截图用的静态版：与 SkyHostView 同一批星、同一张星河图、同样的霞云构图（不眨、不漂）
private struct SkyStill: View {
    var look: SkyLook
    var dark: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if look.galaxy > 0, let image = SkyArt.galaxy(dark: dark) {
                    let frame = SkyLayout.galaxy(in: size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .rotationEffect(.radians(SkyLayout.galaxyAngle))
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(look.galaxy * (dark ? 0.55 : 0.35))
                }
                if look.stars > 0 {
                    let images = SkyArt.starField.map { SkyArt.star($0, dark: dark) }
                    Canvas { context, canvas in
                        for (star, image) in zip(SkyArt.starField, images) {
                            guard let image else { continue }
                            let side = SkyLayout.starSide(star)
                            context.opacity = star.brightness
                            context.draw(Image(decorative: image, scale: 1),
                                         in: CGRect(x: star.x * canvas.width - side / 2, y: star.y * canvas.height - side / 2, width: side, height: side))
                        }
                    }
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.65)],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(look.stars * (dark ? 0.95 : 0.6))
                }
                if look.xiaClouds > 0, let cloud = SkyArt.xiaCloud(left: look.xiaCloudLeft, right: look.xiaCloudRight) {
                    ForEach(0..<2, id: \.self) { index in
                        let frame = SkyLayout.xiaCloud(index, in: size)
                        Image(decorative: cloud, scale: 1)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    .opacity(look.xiaClouds * (dark ? 0.35 : 0.8))
                }
            }
        }
    }
}

// MARK: - 山脚晨雾

/// 山脚两条白雾缓缓横移（放在远山之前）：不透明度 = amount × (浅 0.7 / 深 0.25)，为 0 时隐藏
struct SkyFog: View {
    var amount: Double
    var animated: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let opacity = min(1, max(0, amount)) * (dark ? 0.25 : 0.7)
        Group {
            if RenderMode.offscreen {
                if opacity > 0, let cloud = SkyArt.fog {
                    GeometryReader { geo in
                        ForEach(0..<2, id: \.self) { index in
                            let frame = SkyLayout.fogBand(index, in: geo.size)
                            Image(decorative: cloud, scale: 1)
                                .resizable()
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                                .opacity(opacity * SkyLayout.fogDrift[index].opacity)
                        }
                    }
                }
            } else {
                SkyFogLayerView(opacity: opacity, dark: dark, animated: animated)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SkyFogLayerView: NSViewRepresentable {
    var opacity: Double
    var dark: Bool
    var animated: Bool

    func makeNSView(context: Context) -> SkyFogHostView { SkyFogHostView() }
    func updateNSView(_ view: SkyFogHostView, context: Context) {
        view.configure(opacity: opacity, dark: dark, animated: animated)
    }
}

final class SkyFogHostView: NSView {
    private let bands = [CALayer(), CALayer()]
    private var dark: Bool?
    private var opacity: Double?
    private var lastSize = CGSize.zero
    private var driftStart: CFTimeInterval?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for band in bands {
            band.contents = SkyArt.fog
            band.contentsGravity = .resize
            band.opacity = 0
            band.isHidden = true
            layer?.addSublayer(band)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize, bounds.width > 0, bounds.height > 0 else { return }
        lastSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, band) in bands.enumerated() {
            let frame = SkyLayout.fogBand(index, in: bounds.size)
            band.bounds = CGRect(origin: .zero, size: frame.size)
            band.position = CGPoint(x: frame.midX, y: frame.midY)
        }
        CATransaction.commit()
    }

    func configure(opacity: Double, dark: Bool, animated: Bool) {
        let flipped = self.dark != dark
        if flipped || self.opacity != opacity {
            self.dark = dark
            self.opacity = opacity
            CATransaction.begin()
            if flipped || !animated {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(2.5)
            }
            CATransaction.setCompletionBlock { [weak self] in self?.hideTransparent() }
            for (band, spec) in zip(bands, SkyLayout.fogDrift) {
                let value = Float(opacity * spec.opacity)
                if value > 0 && band.isHidden {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    band.opacity = 0
                    band.isHidden = false
                    CATransaction.commit()
                }
                band.opacity = value
            }
            CATransaction.commit()
        }
        layer?.setPaused(!animated)
        refreshDrift()
    }

    private func hideTransparent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for band in bands where band.opacity == 0 { band.isHidden = true }
        CATransaction.commit()
        refreshDrift()
    }

    /// 有雾时才漂：相位从同一个起点算，隐藏后再出现接着原来的节奏
    private func refreshDrift() {
        guard let host = layer else { return }
        let start = driftStart ?? host.convertTime(CACurrentMediaTime(), from: nil)
        driftStart = start
        for (band, spec) in zip(bands, SkyLayout.fogDrift) {
            if band.isHidden {
                band.removeAnimation(forKey: "drift")
            } else if band.animation(forKey: "drift") == nil {
                band.add(SkyLayout.drift(amplitude: spec.amplitude, period: spec.period, from: start, maxFrames: 20), forKey: "drift")
            }
        }
    }
}

// MARK: - 侧栏与顶栏

/// 侧栏的天色罩色：只罩页面 veil 的一部分（strength），侧栏和正文的色调连得上，侧栏比正文浅一档的层次还在
struct SkyVeil: View {
    var strength: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        SkyTimeline { mix in
            let veil = SkyLook.look(mix, dark: dark).veil
            if veil.a > 0 {
                veil.with(a: veil.a * strength).color
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 顶栏滚动后垫的纸色：取页面最顶端的实际纸色（纸 + 罩色 + 天光带顶端），上浓下淡。
/// 不换的话浅色夜里往下滚时，顶栏会是一条发白的带子
struct SkyPaperFill: View {
    var top: Double
    var bottom: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        SkyTimeline { mix in
            let paper = SkyPaper.effectivePaper(SkyLook.look(mix, dark: dark), dark: dark, atTop: true)
            LinearGradient(colors: [paper.with(a: top).color, paper.with(a: bottom).color], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 首页问候

/// 首页横幅眉题的问候：称呼与页面的“今天”（日期由页面传进来，与页面其余部分一致）
struct HeroGreeting: Equatable {
    var name: String
    var today: LocalDay
}

/// 每分钟刷新的问候：“晚上好，青岚 · 10月20日 周二 · 酉时”。只出一个 Text，字体、字距、颜色由 SceneHero 在外面加；
/// 每分钟只重算这一行，首页的 body（修为、功课统计）不跟着重算。离屏截图按 SkyTime.fixedMinute（默认“午安”）
struct LiveGreetingText: View {
    var greeting: HeroGreeting

    var body: some View {
        if let fixed = SkyTime.fixedMinute {
            line(minute: Int(fixed))
        } else {
            TimelineView(.everyMinute) { context in
                line(minute: Int(SkyClock.minute(of: context.date)))
            }
        }
    }

    private func line(minute: Int) -> Text {
        Text(verbatim: SkyClock.greetingLine(name: greeting.name, today: greeting.today, minute: minute))
    }
}

// MARK: - 横幅画作调色

extension View {
    /// 横幅画作按天色调色：乘色（只压暗、不提亮，保留画作的透明度，晕边不会冒出方框），
    /// 再叠一层从右上往左下渐隐的光，用同一张图的透明度做遮罩，光只落在画上。昼时原样不动
    func skyTinted(_ look: SkyLook, image: NSImage) -> some View {
        modifier(SkyTint(look: look, image: image))
    }
}

private struct SkyTint: ViewModifier {
    var look: SkyLook
    var image: NSImage

    func body(content: Content) -> some View {
        if look.heroMultiply == .white && look.heroGlow.a <= 0 {
            content
        } else {
            content
                .colorMultiply(look.heroMultiply.color)
                .overlay {
                    if look.heroGlow.a > 0 {
                        LinearGradient(colors: [look.heroGlow.color, look.heroGlow.with(a: 0).color],
                                       startPoint: .topTrailing, endPoint: .bottomLeading)
                            .mask(Image(nsImage: image).resizable())
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
