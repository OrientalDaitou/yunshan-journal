import SwiftUI
import AppKit
import ImageIO
import CoreImage

/// 旧版“云山”插画与小物（WebP，随应用打包）。
enum Scenery {
    /// 一页的山水：眉题、题词、画作与前景。页面名和小物插画只在 AppSection 写一份（title / ornament）
    struct PageScene {
        var eyebrow: String
        /// 横幅里的一句诗意短句（页面不传 description 时用它）
        var description: String
        /// 浅色插画；深色有专门的夜景时用 night，否则把晨景调成月色
        var light: String
        var night: String?
        /// 观山时显示的画名
        var sceneName: String
        /// 页首右上角伸入的前景花木（透明图层）
        var foliage: String = "yunshan-bamboo-layer-v1"
        /// 右下角是否再缀一枝玉兰
        var blossom: Bool = false

        func asset(dark: Bool) -> String { dark ? (night ?? light) : light }
        /// 深色下没有专门夜景，需要月色调色
        func needsMoonlight(dark: Bool) -> Bool { dark && night == nil }
    }

    static func scene(for page: AppSection) -> PageScene {
        switch page {
        case .overview:
            PageScene(eyebrow: "云山之间", description: "一日一修，亦留白给山河。",
                      light: "yunshan-court-dawn", night: "yunshan-court-night", sceneName: "云海群峰与山间洞府", blossom: true)
        case .chronicle:
            PageScene(eyebrow: "落笔成卷", description: "一笔一画，皆是来路。",
                      light: "yunshan-study-v1", night: "yunshan-study-night-v1", sceneName: "临崖书案与一卷留白", foliage: "yunshan-plum-layer-v1")
        case .profile:
            PageScene(eyebrow: "见己知心", description: "写下此时的自己，留一页给未来。",
                      light: "yunshan-bamboo-dawn", night: "yunshan-bamboo-night", sceneName: "竹林茶亭与静水石径", blossom: true)
        case .schedule:
            PageScene(eyebrow: "四时有序", description: "知晨昏，留余裕，每一程自有时辰。",
                      light: "yunshan-river-dawn", night: "yunshan-river-night", sceneName: "山间溪流与石桥亭阁", foliage: "yunshan-wisteria-layer-v1")
        case .routine:
            PageScene(eyebrow: "从容布阵", description: "先定起居的节律，再把日程安放其间。",
                      light: "yunshan-garden-dawn", night: "yunshan-garden-night", sceneName: "云中园圃与莲池石阶", foliage: "yunshan-pine-layer-v1")
        case .habits:
            PageScene(eyebrow: "持之以恒", description: "不求一日千里，只求日日有功。",
                      light: "yunshan-teahouse-v1", night: "yunshan-teahouse-night-v1", sceneName: "临瀑茶亭与一案清供", foliage: "yunshan-plum-layer-v1")
        case .finance:
            PageScene(eyebrow: "有度有余", description: "每一笔去向清晰，心中自然有数。",
                      light: "yunshan-vault-v1", night: "yunshan-vault-night-v1", sceneName: "洞府账房与温润算盘", foliage: "yunshan-pine-layer-v1")
        case .annals:
            // 还没有夜景：深色下自动调成月色（needsMoonlight）
            PageScene(eyebrow: "岁月成卷", description: "回望来路，一年自有章法。",
                      light: "yunshan-archive-v1", night: nil, sceneName: "云海书阁与一案长卷", foliage: "yunshan-plum-layer-v1")
        case .ai:
            PageScene(eyebrow: "借智明心", description: "借一盏明灯理清思路，落笔仍由你。",
                      light: "yunshan-observatory-v1", night: "yunshan-observatory-night-v1", sceneName: "观星台与浑天仪", foliage: "yunshan-wisteria-layer-v1")
        case .data:
            PageScene(eyebrow: "藏卷有凭", description: "晨光或月色，依你的节奏安置洞府。",
                      light: "yunshan-library-dawn", night: "yunshan-library-night", sceneName: "临崖书阁与经卷", blossom: true)
        }
    }

    /// 小图（前景花木、小物、境界徽记、观山时的整幅画）
    private static var cache: [String: NSImage] = [:]
    /// 已烘焙的页首横幅：每幅画只留最近一个比例；切换深浅色时放掉另一套。只在主线程读写
    @MainActor private static var heroes: [String: (aspect: CGFloat, image: NSImage)] = [:]
    /// 柔化小图（页面底色的氛围色），同样只在主线程读写。
    /// 每张只有 160px 宽（几十 KB），深浅两套都留着：切换外观时柔光不必先消失再淡入
    @MainActor private static var softs: [String: NSImage] = [:]
    /// 正在后台烘焙的画：同一幅画同时只烘一份
    @MainActor private static var baking: [String: Task<Void, Never>] = [:]
    /// 预热用：横幅的宽度（各页相同，随窗口变）。各页横幅的高度由 HeroSize 的档位与“窄窗口降一档”定，
    /// 降没降档看 HeroSize.lastCompact（页面骨架量正文区高度时记下）
    @MainActor private static var lastHeroWidth: CGFloat = 1100
    /// 柔光的宽度：放大到整页当底色，先模糊再放大，不会露出一格一格的像素
    private static let softWidth = 160

    /// 各幅画的纵向取景（0 贴顶、0.5 居中、1 贴底）：横幅很扁，只取得到原画中间的一条，
    /// 按画面要紧的部分（月亮、楼阁、书案）挑位置；没列出的居中
    private static let heroFocus: [String: CGFloat] = [
        "yunshan-court-dawn": 0.4, "yunshan-court-night": 0,
        // 藏卷书案：长卷与玉印在原画约 70–80% 高处，取 0.8 让书案、长卷、宝匣落在横幅不透明的中段（0.62 时正落进下沿淡出区）
        "yunshan-archive-v1": 0.8,
    ]

    /// 今日洞府（大幅 300）的两幅画：上沿保留较短的淡入（夜景的月亮贴着顶，压长了会被淡掉）
    private static let grandAssets: Set<String> = ["yunshan-court-dawn", "yunshan-court-night"]

    /// 横幅里画作的宽度：横幅宽的 80%，但不超过高度的 3.6 倍——窗口很宽时画面不被裁成细细一条，左侧多留白
    static func paintingWidth(heroWidth: CGFloat, height: CGFloat) -> CGFloat {
        min(heroWidth * 0.8, height * 3.6)
    }
    /// 最近一次预热用的深浅色（还没预热过时为 nil）、横幅宽度与降没降档：窗口宽度变了一档、或高度跨过降档线时按新尺寸补烘
    @MainActor private static var warmDark: Bool?
    @MainActor private static var warmedWidth: CGFloat = 0
    @MainActor private static var warmedCompact = false
    /// 窗口宽度停下后的补烘（防抖：宽度再变就取消重排）；rewarmWaiting 表示它还在等宽度停下、尚未开始烘
    @MainActor private static var rewarm: Task<Void, Never>?
    @MainActor private static var rewarmWaiting = false

    /// 横幅比例按 0.1 分档缓存
    static func heroBucket(_ aspect: CGFloat) -> CGFloat { max(1, (aspect * 10).rounded() / 10) }

    /// 预热在调用方（RootView 等 1 秒）之后再等这么久才开始：窗口出现后约 1.5 秒，启动头几秒的滚动、打字先走
    static let prewarmExtraDelay: UInt64 = 500_000_000
    /// 预热的后台烘焙用最低的优先级，尽量落到能效核上；切到某页时现烘的那幅仍用 .utility
    static let prewarmPriority: TaskPriority = .background

    /// 启动后空闲时在后台预先解码各页画作、烘焙横幅与柔光，第一次切到某页时不再卡一下。
    /// 横幅只保留当前深浅色这一套，另一套放掉，常驻内存约减半；柔光很小，两套都留着。
    @MainActor
    static func prewarm(dark: Bool) async {
        do { try await Task.sleep(nanoseconds: prewarmExtraDelay) } catch { return }
        // 调用方的任务已被取消（例如刚又切换了深浅色，旧任务带着旧的深浅色走到这里）：什么都不做，
        // 免得按旧的深浅色把刚切过去那一套横幅过滤掉
        guard !Task.isCancelled else { return }
        rewarm?.cancel()
        rewarm = nil
        rewarmWaiting = false
        warmDark = dark
        let current = Set(AppSection.allCases.map { scene(for: $0).asset(dark: dark) })
        heroes = heroes.filter { current.contains($0.key) }
        await warmPages(dark: dark)
    }

    /// 按当前横幅宽度把各页的横幅、柔光与小物依次备好（每页之间歇一下，不和界面抢 CPU）
    @MainActor
    private static func warmPages(dark: Bool) async {
        warmedWidth = lastHeroWidth
        warmedCompact = HeroSize.lastCompact
        for page in AppSection.allCases {
            let scene = scene(for: page)
            let height = max(1, HeroSize(page: page).height(compact: warmedCompact))
            await prepare(scene.asset(dark: dark), heroAspect: paintingWidth(heroWidth: lastHeroWidth, height: height) / height,
                          priority: prewarmPriority)
            for asset in [scene.foliage, page.ornament] { await preload(asset, priority: prewarmPriority) }
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }   // 被取消（例如切换了深浅色）就停下
        }
    }

    /// 页首横幅记下自己的尺寸，供下次预热按各页实际比例烘焙。
    /// 宽度比上次预热时变了一成以上（例如进出全屏、拉宽窗口），或窗口高度跨过了降档线（各页横幅一起变矮 / 变高）：
    /// 停下约 1.2 秒后按新尺寸把其余各页补烘，之后切到别的页不再先留白。
    @MainActor
    static func noteHero(page: AppSection, width: CGFloat, height: CGFloat) {
        guard width > 10, height > 10 else { return }
        lastHeroWidth = width
        scheduleRewarm(compact: height < HeroSize(page: page).height(compact: false) - 0.5)
    }

    /// 页面骨架量到正文区跨过降档线时直接告诉这里（PageScaffold 的 onGeometryChange）。
    /// 窗口很宽时（横幅宽约 990 以上，即窗口约 1371 以上）标准页降档前后画作比例都封顶在 3.6，
    /// 横幅的 .task(id:) 不变、不会走 noteHero；没有这一下，补烘不会排上，之后第一次进首页画作会先空着再淡入
    @MainActor
    static func noteCompact(_ compact: Bool) {
        scheduleRewarm(compact: compact)
    }

    /// 要不要按新尺寸补烘：横幅宽度比上次预热时变了一成以上，或降没降档与预热时不同
    static func needsRewarm(width: CGFloat, compact: Bool, warmedWidth: CGFloat, warmedCompact: Bool) -> Bool {
        abs(width / max(1, warmedWidth) - 1) > 0.1 || compact != warmedCompact
    }

    /// noteHero / noteCompact 共用：尺寸与预热时不同就排一次补烘（防抖：1.2 秒内再有变化就重新计时）
    @MainActor
    private static func scheduleRewarm(compact: Bool) {
        guard warmDark != nil, warmedWidth > 0 else { return }   // 还没预热过：交给预热本身
        if needsRewarm(width: lastHeroWidth, compact: compact, warmedWidth: warmedWidth, warmedCompact: warmedCompact) {
            rewarm?.cancel()
            rewarmWaiting = true
            rewarm = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                rewarmWaiting = false
                guard let dark = warmDark else { return }
                await warmPages(dark: dark)
            }
        } else if rewarmWaiting {
            // 还在等窗口停下时又回到了预热时的尺寸附近：不必补烘（已经开始的补烘不打断，切页也会走到这里）
            rewarm?.cancel()
            rewarm = nil
            rewarmWaiting = false
        }
    }

    /// 自检用：假装已按给定尺寸预热过，跑完 body 后撤掉排上的补烘、恢复原状（不烘任何画）。
    /// body 拿到的闭包读“补烘是否已排上、还在等窗口停下”
    @MainActor
    static func withSimulatedWarmState(width: CGFloat, compact: Bool, _ body: (_ rewarmPending: () -> Bool) -> Void) {
        let saved = (warmDark, warmedWidth, warmedCompact, lastHeroWidth)
        rewarm?.cancel()
        rewarm = nil
        rewarmWaiting = false
        warmDark = false
        warmedWidth = width
        warmedCompact = compact
        lastHeroWidth = width
        body { rewarmWaiting }
        rewarm?.cancel()
        rewarm = nil
        rewarmWaiting = false
        (warmDark, warmedWidth, warmedCompact, lastHeroWidth) = saved
    }

    /// 主线程只取缓存：这幅画最近烘好的横幅（比例可能与要的不同，由调用方决定先拉伸着用还是等新的）。
    @MainActor
    static func cachedHero(_ name: String) -> (aspect: CGFloat, image: NSImage)? { heroes[name] }

    @MainActor
    static func cachedSoft(_ name: String) -> NSImage? { softs[name] }

    /// 确保这幅画的柔光（以及给定比例的横幅）已在缓存里：缺什么就交给后台解码、烘焙，回到主线程只写缓存。
    /// priority：后台解码、烘焙的优先级（预热用 prewarmPriority；切到某页现烘的用默认 .utility）。
    /// 切到某页时那幅画正被预热烘着：照旧等它烘完（一幅只要零点几秒），不另开一份
    @MainActor
    static func prepare(_ name: String, heroAspect rawAspect: CGFloat?, priority: TaskPriority = .utility) async {
        let aspect = rawAspect.map(heroBucket)
        for _ in 0..<3 {
            // 请求已被取消（例如窗口又换了一档比例、离开了这一页）：不再新开烘焙，免得烘出过时的比例覆盖缓存。
            // 等完别人的烘焙后 continue 也会回到这里。已经开始的烘焙照常做完、写缓存，其他等待者照常拿到结果
            if Task.isCancelled { return }
            let needHero = aspect != nil && heroes[name]?.aspect != aspect
            let needSoft = softs[name] == nil
            guard needHero || needSoft else { return }
            if let running = baking[name] {
                // 同一幅画正在烘：等它做完再看还缺什么
                await running.value
                continue
            }
            guard let url = Bundle.main.url(forResource: name, withExtension: "webp") else { return }
            let job = Task { @MainActor in
                let baked = await Task.detached(priority: priority) {
                    renderScene(url: url, heroAspect: needHero ? aspect : nil, soft: needSoft)
                }.value
                store(name, aspect: aspect, baked)
                baking[name] = nil
            }
            baking[name] = job
            await job.value
            return
        }
    }

    /// 在后台解码一张小图放进缓存（前景花木、小物），第一次显示时不必在主线程解码。
    @MainActor
    static func preload(_ name: String, priority: TaskPriority = .utility) async {
        guard cache[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "webp") else { return }
        let decoded = await Task.detached(priority: priority) { BakedScene(hero: decode(url), soft: nil) }.value
        guard cache[name] == nil, let cg = decoded.hero else { return }
        cache[name] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 同步烘焙横幅（离屏截图用；界面里用 HeroPainting 的后台烘焙）。aspect 按 0.1 分档缓存。
    @MainActor
    static func heroImage(_ name: String, aspect rawAspect: CGFloat) -> NSImage? {
        let aspect = heroBucket(rawAspect)
        if let hit = heroes[name], hit.aspect == aspect { return hit.image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp") else { return nil }
        let baked = renderScene(url: url, heroAspect: aspect, soft: softs[name] == nil)
        store(name, aspect: aspect, baked)
        return baked.hero == nil ? nil : heroes[name]?.image
    }

    /// 缩小并模糊过的柔化版本：当背景氛围色用，界面里只贴一张静态小图，几乎不耗 GPU。
    /// 同步版（离屏截图用）；界面里用 cachedSoft + prepare。
    @MainActor
    static func softImage(_ name: String, width: Int? = nil) -> NSImage? {
        let width = width ?? softWidth
        if width == softWidth, let cached = softs[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp"), let cg = decode(url),
              let small = bakeSoft(cg, width: width) else { return nil }
        let result = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
        if width == softWidth { softs[name] = result }
        return result
    }

    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    // MARK: 解码与烘焙（纯 CoreGraphics，可在后台线程调用；不碰上面的缓存）

    @MainActor
    private static func store(_ name: String, aspect: CGFloat?, _ baked: BakedScene) {
        if let aspect, let hero = baked.hero {
            heroes[name] = (aspect, NSImage(cgImage: hero, size: NSSize(width: hero.width, height: hero.height)))
        }
        if let soft = baked.soft {
            softs[name] = NSImage(cgImage: soft, size: NSSize(width: soft.width, height: soft.height))
        }
    }

    /// 读图并立即解出像素；用完即放，不留整幅原图的解码在内存里
    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// 解码一次，按需烘出横幅与柔光
    private static func renderScene(url: URL, heroAspect: CGFloat?, soft: Bool) -> BakedScene {
        guard let cg = decode(url) else { return BakedScene() }
        let name = url.deletingPathExtension().lastPathComponent
        let focus = heroFocus[name] ?? 0.5
        let gentleTop = !grandAssets.contains(name)
        return BakedScene(hero: heroAspect.flatMap { bakeHero(cg, aspect: $0, focus: focus, gentleTop: gentleTop) },
                          soft: soft ? bakeSoft(cg, width: softWidth) : nil)
    }

    /// 页首横幅用的画：按显示比例裁好，并把“左侧留白、上下与右缘化入纸面”的晕边直接烘焙进透明度。
    /// 这样界面只需贴一张静态图，不必每次切页都用 CPU 重新合成遮罩。focus 是纵向取景（见 heroFocus）。
    /// gentleTop：标准档（220 高）的画，上沿淡入拉长，柱头、竹竿、帘幔不会在半空被一刀截断。
    private static func bakeHero(_ cg: CGImage, aspect: CGFloat, focus: CGFloat, gentleTop: Bool) -> CGImage? {
        let width = 1600, height = max(1, Int(CGFloat(width) / aspect))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 晕边：横向（图左缘对应横幅 20% 处）× 纵向，两段折线渐变相乘
        func ramp(_ x: CGFloat, _ stops: [(CGFloat, CGFloat)]) -> CGFloat {
            guard let first = stops.first, x > first.0 else { return stops.first?.1 ?? 1 }
            for (a, b) in zip(stops, stops.dropFirst()) where x <= b.0 {
                let t = (x - a.0) / max(0.0001, b.0 - a.0)
                let s = t * t * (3 - 2 * t)
                return a.1 + (b.1 - a.1) * s
            }
            return stops.last?.1 ?? 1
        }
        // 右缘留足 16% 慢慢化开，不在画边留一道竖向硬边
        let across: [(CGFloat, CGFloat)] = [(0, 0), (0.075, 0), (0.34, 0.7), (0.5, 1), (0.84, 1), (1, 0)]
        // 纵向仍是上下化入纸面。原先横幅上沿一格一格的亮斑出在页面底色的柔光（见 bakeSoft），不在画里。
        // 今日洞府保留较短的上沿淡入（压长了会把夜景顶上的月亮淡掉）；其余八页的横幅矮，画里的柱子、竹竿
        // 直穿上沿，淡入拉长到约三分之一高，像隐入云雾
        let down: [(CGFloat, CGFloat)] = gentleTop
            ? [(0, 0), (0.05, 0), (0.36, 1), (0.72, 1), (1, 0)]
            : [(0, 0), (0.1, 0.35), (0.28, 1), (0.72, 1), (1, 0)]
        var maskBytes = [UInt8](repeating: 0, count: width * height)
        let column = (0..<width).map { ramp(CGFloat($0) / CGFloat(width - 1), across) }
        for y in 0..<height {
            // 遮罩图的数据第 0 行是画面顶部
            let v = ramp(CGFloat(y) / CGFloat(max(1, height - 1)), down)
            for x in 0..<width { maskBytes[y * width + x] = UInt8(max(0, min(255, column[x] * v * 255))) }
        }
        guard let provider = CGDataProvider(data: Data(maskBytes) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                 decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask)
        // 等比填满（靠右对齐，略放大 5%）；纵向按 focus 取景（CoreGraphics 的 y 从底边算起）
        let scale = max(CGFloat(width) / CGFloat(cg.width), CGFloat(height) / CGFloat(cg.height)) * 1.05
        let drawW = CGFloat(cg.width) * scale, drawH = CGFloat(cg.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: CGFloat(width) - drawW, y: (CGFloat(height) - drawH) * (1 - focus), width: drawW, height: drawH))
        return ctx.makeImage()
    }

    /// 柔光底色用的 CoreImage 上下文（线程安全，后台烘焙共用一个）。
    /// 用软件渲染：只模糊一张 160px 的小图，CPU 几毫秒就够；默认的 GPU 上下文第一次用就要备下近 200 MB 的显卡资源
    private static let blurContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    /// 缩成小图再高斯模糊：放大几十倍铺满整页时是一片柔和的色雾，不会出现马赛克方块
    private static func bakeSoft(_ cg: CGImage, width: Int) -> CGImage? {
        let height = max(1, Int(Double(width) * Double(cg.height) / Double(max(1, cg.width))))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = ctx.makeImage() else { return nil }
        // 先把边缘向外延展再模糊，模糊后裁回原尺寸：四边不会被模糊成半透明
        let input = CIImage(cgImage: small)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(width) / 20).cropped(to: input.extent)
        return blurContext.createCGImage(blurred, from: input.extent, format: .RGBA8,
                                         colorSpace: small.colorSpace ?? CGColorSpaceCreateDeviceRGB()) ?? small
    }
}

/// 后台烘焙的结果（CGImage 不可变，交回主线程是安全的）
private struct BakedScene: @unchecked Sendable {
    var hero: CGImage?
    var soft: CGImage?
}

/// 显示一张随应用打包的插画；找不到时留空，不影响布局。
/// 都是装饰插画，对 VoiceOver 隐藏（需要读出含义的地方由外层容器给标签）。
struct SceneryImage: View {
    var name: String
    var body: some View {
        Group {
            if let image = Scenery.image(name) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// 把晨景调成月色：降饱和、偏青蓝、压暗。
    @ViewBuilder
    func moonlit(_ on: Bool) -> some View {
        if on {
            self.saturation(0.55)
                .colorMultiply(Color(red: 0.62, green: 0.74, blue: 0.9))
                .brightness(-0.12)
                .contrast(1.06)
        } else {
            self
        }
    }
}

/// 前景花木：竹枝 / 玉兰（旧版 yunshan-foliage / yunshan-blossom），静止、略斜一点。
/// 不做摆动：摆幅仅约 1°，常驻动画的开销不值得。
struct SwayingBranch: View {
    var asset: String
    var anchor: UnitPoint
    var degrees: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SceneryImage(name: asset)
            .brightness(scheme == .dark ? -0.3 : 0)
            .saturation(scheme == .dark ? 0.6 : 1)
            .opacity(scheme == .dark ? 0.5 : 0.85)
            .rotationEffect(.degrees(-degrees * 0.5), anchor: anchor)
        .allowsHitTesting(false)
    }
}

/// 页首横幅的两档高度：今日洞府是门面（大幅），其余八页统一（标准）。
/// 各页不必再传高度；标题字号、留白、前景花木都随这两档按比例变化。
/// 窗口矮（正文区不到 compactBelow）时两档各降一档：首页 300→220、其余 220→160，首屏多露出卡片；
/// 画作只是缩小，雾气、灵气、前景花木一样不少。
enum HeroSize {
    case grand, standard

    init(page: AppSection) { self = page == .overview ? .grand : .standard }

    /// 正文区（页面滚动区）矮于这个高度就降一档：1180×780 的窗口降，1440×920 不降
    static let compactBelow: CGFloat = 820

    /// 量到的正文区高度要不要降档（还没量到、为 0 时不降）
    static func isCompact(viewport: CGFloat) -> Bool { viewport > 1 && viewport < compactBelow }

    /// 最近一次量到的结果：新进的页先按它排，不先按高一档排一帧再跳；预热也按它烘没进过的页
    @MainActor static var lastCompact = false

    var height: CGFloat { height(compact: false) }

    func height(compact: Bool) -> CGFloat {
        switch self {
        case .grand: compact ? 220 : 300
        case .standard: compact ? 160 : 220
        }
    }

    /// 文字块的上沿：有没有按钮都从这里排起，切页时眉题、标题不跳
    func textTop(compact: Bool) -> CGFloat {
        switch self {
        case .grand: compact ? 22 : 30
        case .standard: compact ? 12 : 18
        }
    }

    /// 大标题字号：大幅用横幅标题字号（宋体 50），标准档 36；降档时各小一号，排得下眉题、标题、题词与按钮
    func titleSize(compact: Bool) -> CGFloat {
        switch self {
        case .grand: compact ? 44 : TypeSize.display
        case .standard: compact ? 30 : 36
        }
    }

    /// 页面骨架的上下内边距：降档时 32→20
    static func pageInset(compact: Bool) -> CGFloat { compact ? 20 : 32 }
}

/// 页首横幅滚到了哪里：SceneHero 量出自己在正文里的位置上报，RootView 据此调整顶栏。
/// - scrolled：横幅上缘已滚到正文上缘之上（内容开始从顶栏底下经过）：顶栏垫上纸色底和底线；
/// - passed：横幅滚上去过半，大标题已被遮住：顶栏淡入小号页名。
/// 两项都是“页面”的集合：切页过渡时新旧两页同时在场，各报各的，顶栏只看当前页。
struct HeroScrollReport: Equatable {
    var scrolled: Set<AppSection> = []
    var passed: Set<AppSection> = []
}

/// macOS 14 没有 onScrollGeometryChange，所以用 GeometryReader + PreferenceKey；
/// 值只在越过阈值时变化，滚动时根视图不会每帧重算。
struct HeroScrollKey: PreferenceKey {
    static let defaultValue = HeroScrollReport()
    static func reduce(value: inout HeroScrollReport, nextValue: () -> HeroScrollReport) {
        let next = nextValue()
        value.scrolled.formUnion(next.scrolled)
        value.passed.formUnion(next.passed)
    }
}

/// 正文区的坐标空间名：RootView 挂在正文上，SceneHero 在里面量自己的位置
enum HeroScroll {
    static let space = "APT.detail"
}

/// 页首山水横幅：没有边框，工笔山水自右侧铺开、四周如水墨般晕入纸面；
/// 前景衬竹枝 / 玉兰，画上一团静态雾气与一层灵气光点，标题进页时掠过一道光。
/// 画面随天色调色（晨略暖、暮透夕照、夜偏蓝），只有画面部分每分钟重算，文字和按钮不跟着重算。
/// 横幅里只放眉题、大标题、一句短句和按钮；鼠标在横幅上停一会儿才浮现“观山”，点画面也能观赏整幅。
struct SceneHero<Actions: View>: View {
    var page: AppSection
    /// 眉题；不传用本页的眉题（首页把问候放在这里）
    var eyebrow: String?
    /// 一句短句；不传用本页的题词。最多两行，操作说明请放到用到它的地方
    var description: String?
    /// 首页问候（称呼 + 今天）：给了就在眉题位置显示每分钟刷新的问候，代替 eyebrow
    var greeting: HeroGreeting? = nil
    /// 窗口矮时降一档（见 HeroSize）；由 PageScaffold 量正文区高度后传入
    var compact: Bool = false
    @ViewBuilder var actions: () -> Actions

    @Environment(\.colorScheme) private var scheme
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    /// 主窗口有没有人在看（#20 能耗，RootView 注入）：横幅光点闲满 3 分钟、被挡住时原地停
    @Environment(\.someoneWatching) private var watched
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showGallery = false
    /// 鼠标在横幅上；停够 0.4 秒 peek 才为 true，“观山”淡入
    @State private var hovering = false
    @State private var peek = false

    private var scene: Scenery.PageScene { Scenery.scene(for: page) }
    private var dark: Bool { scheme == .dark }
    /// 高度按 HeroSize 取两档（今日洞府 300，其余 220；窗口矮时 220 / 160）
    private var h: CGFloat { HeroSize(page: page).height(compact: compact) }
    /// 大幅（今日洞府）：标题更大、留白更多
    private var grand: Bool { HeroSize(page: page) == .grand }

    /// 文字区约占横幅宽度的 34%，不压到画上；窗口很窄时至少留 300（短句排得下一行，不会只把两三个字挤到第二行）
    private static func textWidth(_ heroWidth: CGFloat) -> CGFloat { max(300, min(580, heroWidth * 0.34)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            painting
            GeometryReader { geo in
                let width = Self.textWidth(geo.size.width)
                HeroTextColumn(page: page, eyebrow: eyebrow, description: description, greeting: greeting, compact: compact,
                               shimmer: effects.motionEnabled, maxWidth: width, actions: actions)
                    .background(alignment: .leading) { veil(width: width) }
            }
        }
        .frame(height: h)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard hovering else { setPeek(false); return }
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            setPeek(true)
        }
        .background { scrollReporter }
        .sheet(isPresented: $showGallery) { SceneGallery(page: page) }
    }

    private func setPeek(_ value: Bool) {
        guard peek != value else { return }
        withAnimation(motion && !reduceMotion ? .easeOut(duration: 0.25) : nil) { peek = value }
    }

    /// 上报横幅滚到了哪里（见 HeroScrollReport）：滚上去过半时大标题已被正文上缘遮住
    private var scrollReporter: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(HeroScroll.space))
            Color.clear.preference(key: HeroScrollKey.self,
                                   value: HeroScrollReport(scrolled: frame.minY < 0 ? [page] : [],
                                                           passed: frame.maxY < frame.height * 0.45 ? [page] : []))
        }
    }

    // MARK: 画面

    private var painting: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // 只有画面这一组随天色每分钟重算
            SkyTimeline { mix in
                let look = SkyLook.look(mix, dark: dark)
                ZStack(alignment: .trailing) {
                    // 画作在后台烘焙，主线程只取缓存；显示时按天色调色（烘焙不动）
                    HeroPainting(page: page, asset: scene.asset(dark: dark),
                                 size: CGSize(width: Scenery.paintingWidth(heroWidth: w, height: h), height: h), heroWidth: w,
                                 moonlit: scene.needsMoonlight(dark: dark), sky: look)
                    // 雾气（静态柔光）；清晨画面下部再多一层薄雾
                    SoftGlow(color: Color.white.opacity((dark ? 0.06 : 0.35) + look.heroFog * (dark ? 0.12 : 0.45)))
                        .frame(width: w * 0.5, height: h * 0.4)
                        .offset(x: -w * 0.1, y: h * 0.28)
                    // 横幅里另有一层灵气（深色时也偶有流星，浅色入夜后也有）
                    SpiritField(count: grand ? 16 : 12, animated: effects.motionEnabled && watched, meteors: dark || look.meteors,
                                intensity: dark ? 1.2 : 0.9)
                        .frame(width: w * 0.6, height: h)
                }
            }
            // 整组贴右：画自右侧铺开，右缘直接化入页边（不贴右时整组居中，右边空出一截、画边成了一道硬边）
            .frame(width: w, height: h, alignment: .trailing)
            // 前景花木（每页不同）：随横幅高度等比缩放，矮横幅也保留
            .overlay(alignment: .topTrailing) {
                SwayingBranch(asset: scene.foliage, anchor: UnitPoint(x: 0.96, y: 0.28), degrees: 1.1)
                    .frame(width: h * 0.95, height: h * 0.95)
                    .offset(x: h * 0.18, y: -h * 0.08)
            }
            .overlay(alignment: .bottomTrailing) {
                if scene.blossom {
                    SwayingBranch(asset: "yunshan-magnolia-layer-v1", anchor: UnitPoint(x: 0.95, y: 0.95), degrees: 0.7)
                        .frame(width: h * 0.7, height: h * 0.4)
                        .offset(x: h * 0.16, y: h * 0.06)
                        .opacity(0.75)
                }
            }
            // 文字区以右的画面：点一下观赏整幅；“观山”平时隐去，悬停片刻才浮现
            .overlay(alignment: .trailing) {
                viewingArea.frame(width: max(0, w - Self.textWidth(w) - 24))
            }
        }
    }

    private var viewingArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { showGallery = true }
            .overlay(alignment: .bottomTrailing) {
                Button { showGallery = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "mountain.2").font(.ysMicro)
                        Text("观山")
                        Image(systemName: "arrow.up.right").font(.system(size: 9))
                    }
                    .font(.ysCaption)
                    .tracking(1)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.card.opacity(0.9), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .opacity(peek ? 1 : 0)
                .allowsHitTesting(peek)
                // 有玉兰的页让开右下角的花枝
                .padding(.trailing, scene.blossom ? h * 0.42 : h * 0.14)
                .padding(.bottom, h * 0.07)
            }
            .help("观赏整幅：\(scene.sceneName)")
            // 读屏：整块画面是一个“观山”按钮
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("观山：\(scene.sceneName)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showGallery = true }
    }

    /// 文字后面垫的纸色淡晕：画边伸到字下时也看得清。四边都化开，不成一块方形：
    /// 左缘从全透明起（那里本来就没有画，不必垫），到文字区右半段最浓，再向画面淡出。
    /// 深色下字本来就清楚，垫得更淡（浓了像在标题后贴一块暗板）
    private func veil(width: CGFloat) -> some View {
        let a = dark ? 0.45 : 0.8
        return LinearGradient(stops: [.init(color: Theme.paper.opacity(0), location: 0),
                                      .init(color: Theme.paper.opacity(a), location: 0.45),
                                      .init(color: Theme.paper.opacity(a * 0.85), location: 0.72),
                                      .init(color: Theme.paper.opacity(0), location: 1)],
                              startPoint: .leading, endPoint: .trailing)
            .frame(width: width + 140)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                         .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .offset(x: -30)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 横幅文字用的颜色（SceneHero 是泛型，不能有静态存储属性）
private enum HeroInk {
    /// 自定义眉题（首页的问候与日期）：浅色深一档的金（淡金小字在纸面上只有约 3.5:1），深色仍是淡金
    static let eyebrow = Color.adaptive(light: 0x7A5C3C, dark: 0xD2B682)
}

/// 横幅按钮行量出的实际高度（0 即没有按钮）。调用方的 actions 会按数据什么都不放
/// （例如还没有功课时，空状态卡里已有同一个按钮），只看类型会误以为有按钮
struct HeroActionsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 横幅左侧的文字块：眉题、大标题、一句题词，按钮行（如有）紧跟在题词后。
/// 各页不论有没有按钮都从同一个 top 排起（首页 30、其余 18；降档时 22 / 12），切页时眉题、标题不跳。
/// 按钮行量出实际高度：为 0 时不留它上面的间距；降档且有按钮时题词只排一行，给按钮让位
struct HeroTextColumn<Actions: View>: View {
    var page: AppSection
    var eyebrow: String?
    var description: String?
    var greeting: HeroGreeting?
    var compact: Bool
    /// 进页时标题掠过的一道光（跟动效开关）
    var shimmer: Bool
    /// 题词的最大宽度（文字区宽度，见 SceneHero.textWidth）
    var maxWidth: CGFloat
    @ViewBuilder var actions: () -> Actions

    @Environment(\.colorScheme) private var scheme
    /// 按钮行量出的高度（见 HeroActionsHeightKey）
    @State private var actionsHeight: CGFloat = 0

    private var size: HeroSize { HeroSize(page: page) }
    private var grand: Bool { size == .grand }
    private var dark: Bool { scheme == .dark }
    private var hasActions: Bool { actionsHeight > 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(LinearGradient(colors: [Theme.gold.opacity(0), Theme.gold], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 34, height: 1)
                if let greeting {
                    // 首页问候：每分钟刷新（样式与自定义眉题相同）
                    LiveGreetingText(greeting: greeting)
                        .font(Theme.songti(TypeSize.callout, .semibold))
                        .tracking(2)
                        .foregroundStyle(HeroInk.eyebrow)
                        .lineLimit(1)
                } else {
                    Text(eyebrow ?? Scenery.scene(for: page).eyebrow)
                        .font(Theme.songti(TypeSize.callout, eyebrow == nil ? .medium : .semibold))
                        // 眉题字距 6；自定义眉题（例如首页的问候和日期）通常更长，字距收窄。
                        // 它带着要读的信息，浅色下用深一档的金（淡金小字在纸面上只有约 3.5:1）
                        .tracking(eyebrow == nil ? 6 : 2)
                        .foregroundStyle(eyebrow == nil ? Theme.gold : HeroInk.eyebrow)
                        .lineLimit(1)
                }
            }
            Text(page.title)
                // 大幅用横幅标题字号（宋体 50），标准档 36，降档各小一号；字距按字号取同一比例（约 0.12em）
                .font(Theme.songti(size.titleSize(compact: compact), .bold))
                .tracking(grand ? (compact ? 5 : 6) : (compact ? 3.5 : 4))
                .lineLimit(1)
                .foregroundStyle(
                    LinearGradient(colors: [Theme.ink, dark ? Color(red: 0.85, green: 0.78, blue: 0.6) : Theme.jadeDeep],
                                   startPoint: .top, endPoint: .bottom))
                .shadow(color: dark ? Theme.gold.opacity(0.25) : .white.opacity(0.9), radius: dark ? 12 : 6)
                // 每次进页掠过一道光
                .shimmerSweep(shimmer)
                .ysEntrance(order: -1)
                .padding(.top, grand ? (compact ? 12 : 16) : (compact ? 6 : 10))
            Text(description ?? Scenery.scene(for: page).description)
                .font(.ysBody)
                .lineSpacing(4)
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(compact && hasActions ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, grand ? (compact ? 10 : 14) : (compact ? 5 : 8))
                .frame(maxWidth: maxWidth, alignment: .leading)
            HStack(spacing: 10) { actions() }
                .buttonStyle(.yunshan)
                .background {
                    GeometryReader { Color.clear.preference(key: HeroActionsHeightKey.self, value: $0.size.height) }
                }
                .padding(.top, hasActions ? (grand ? 18 : (compact ? 10 : 14)) : 0)
        }
        .onPreferenceChange(HeroActionsHeightKey.self) { actionsHeight = $0 }
        .padding(.leading, 6)
        .padding(.trailing, 38)
        .padding(.top, size.textTop(compact: compact))
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 页首画作：缓存里有就直接贴；没有就交给后台烘焙，烘好后淡入（不在主线程解码、烘焙）。
/// 拖动窗口改变比例时先把旧图略微拉伸着用，尺寸停下 0.2 秒后再烘新的一档；
/// 切换深浅色换了画时，新画烘好前先留着旧画，烘好后交叉淡入，不先留白。
private struct HeroPainting: View {
    var page: AppSection
    var asset: String
    /// 画作本身的尺寸（横幅宽的 80% 左右，见 Scenery.paintingWidth）
    var size: CGSize
    /// 整幅横幅的宽度：记给预热，按各页的高度算出各页画作的比例
    var heroWidth: CGFloat
    var moonlit: Bool
    /// 天色：显示时调色（乘色、右上角一层光），昼时原样
    var sky: SkyLook
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 这个横幅最近显示过的画（新的一档还没烘好时先用着，不闪）
    @State private var shown: (asset: String, image: NSImage)?
    /// 进页时画作从 1.02 倍缩回 1（与背景柔光、标题上浮同一条进页时间线）
    @State private var settled = false

    private var aspect: CGFloat { Scenery.heroBucket(size.width / max(1, size.height)) }

    var body: some View {
        ZStack {
            if let image = currentImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .moonlit(moonlit)
                    .skyTinted(sky, image: image)
                    // 深色下借晨景调成月色的画（岁月长卷还没有夜景）：天空那一片自上而下压暗一层夜色。
                    // 只落在画上（按画的透明度遮），夜景画补上后自然不走这里。
                    // 标准档横幅的画上沿约 5% 全透明、到约 36% 高才完全不透明（见 bakeHero 的 gentleTop），
                    // 所以最浓的一段放在约 25% 高、画已大半不透明的地方：乘上画的透明度后，落在天空上约 0.6，
                    // 接近设计稿的“纸色 70%”（浓处停在顶上会被透明度遮掉，实际只压约 0.3）；
                    // 到 75% 高淡尽，书案、长卷、玉印不跟着变暗
                    .overlay {
                        if moonlit {
                            LinearGradient(stops: [.init(color: Theme.paper.opacity(0.6), location: 0),
                                                   .init(color: Theme.paper.opacity(0.85), location: 0.25),
                                                   .init(color: Theme.paper.opacity(0.45), location: 0.5),
                                                   .init(color: Theme.paper.opacity(0), location: 0.75)],
                                           startPoint: .top, endPoint: .bottom)
                                .mask(Image(nsImage: image).resizable())
                        }
                    }
                    .transition(.opacity)
                    // 换了一张图就当作新视图：在动画里换图时旧图淡出、新图淡入（交叉淡入），不动画时直接替换
                    .id(ObjectIdentifier(image))
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(settled ? 1 : 1.02, anchor: .trailing)
        .accessibilityHidden(true)
        .onAppear {
            guard !settled else { return }
            guard motion, !reduceMotion, !RenderMode.offscreen else { settled = true; return }
            withAnimation(Motion.reveal) { settled = true }
        }
        .task(id: "\(asset)#\(aspect)") { await load() }
    }

    private var currentImage: NSImage? {
        if RenderMode.offscreen { return Scenery.heroImage(asset, aspect: aspect) }   // 离屏截图：同步烘好
        let hit = Scenery.cachedHero(asset)
        if let hit, hit.aspect == aspect { return hit.image }
        // 已经在显示这幅画（只是比例变了）：先拉伸着用，等新的一档烘好
        if shown?.asset == asset, let image = shown?.image { return image }
        // 刚出现：缓存里的比例相差不到 15% 才先拉伸着用（免得明显变形）
        if let hit, abs(hit.aspect / aspect - 1) <= 0.15 { return hit.image }
        // 换了画（例如切换深浅色）：新画烘好前先留着旧画；刚出现又没有可用的缓存时留白，烘好再淡入
        return shown?.image
    }

    private func load() async {
        guard !RenderMode.offscreen, size.width > 10, size.height > 10 else { return }
        Scenery.noteHero(page: page, width: heroWidth, height: size.height)
        if let hit = Scenery.cachedHero(asset), hit.aspect == aspect {
            if shown?.asset != asset || shown?.image !== hit.image { shown = (asset, hit.image) }
            return
        }
        // 同一幅画只是比例变了（例如正在拖动窗口）：尺寸停下 0.2 秒后再烘新的一档，换上时不动画；
        // 换了画或什么都没显示：立即烘，烘好后淡入（有旧画时交叉淡入）
        let sameAsset = shown?.asset == asset
        let wasEmpty = currentImage == nil
        if sameAsset && !wasEmpty {
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
        }
        await Scenery.prepare(asset, heroAspect: aspect)
        guard !Task.isCancelled, let hit = Scenery.cachedHero(asset), hit.aspect == aspect else { return }
        let fadeIn = (!sameAsset || wasEmpty) && motion && !reduceMotion
        withAnimation(fadeIn ? Motion.reveal : nil) { shown = (asset, hit.image) }
    }
}

extension SceneHero where Actions == EmptyView {
    init(page: AppSection, eyebrow: String? = nil, description: String? = nil, greeting: HeroGreeting? = nil, compact: Bool = false) {
        self.init(page: page, eyebrow: eyebrow, description: description, greeting: greeting, compact: compact) { EmptyView() }
    }
}

/// 页面骨架：整页一起滚动，页首横幅在上、正文在下，页边距与卡距统一用 PageLayout。
/// 九个页面共用，以后调页边距、横幅与正文的间距只改这里。横幅要在页面主 ScrollView 里，顶栏才知道它滚到了哪里。
/// 用法：`PageScaffold(page: .habits) { 正文 } actions: { 横幅里的按钮 }`；没有按钮时省掉 actions。
struct PageScaffold<Content: View, Actions: View>: View {
    var page: AppSection
    /// 横幅与正文、正文各块之间的间距
    var spacing: CGFloat
    /// 横幅眉题；nil 用本页的眉题（首页的问候请用 greeting，每分钟刷新）
    var eyebrow: String?
    /// 横幅短句；nil 用本页的题词（静态题词写在 Scenery.PageScene 里，这里只传随数据变化的）
    var description: String?
    /// 首页问候（每分钟刷新）；给了就代替 eyebrow
    var greeting: HeroGreeting?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    /// 正文区矮（窄窗口）：横幅降一档、上下内边距收窄。只在跨过降档线时变，拖动窗口时正文不跟着每帧重排
    @State private var compact: Bool

    init(page: AppSection, spacing: CGFloat = PageLayout.gutter, eyebrow: String? = nil, description: String? = nil,
         greeting: HeroGreeting? = nil,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder actions: @escaping () -> Actions) {
        self.page = page
        self.spacing = spacing
        self.eyebrow = eyebrow
        self.description = description
        self.greeting = greeting
        self.content = content
        self.actions = actions
        // 切页时新页先按上一页量到的排，不先排成高一档再跳
        _compact = State(initialValue: HeroSize.lastCompact)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                SceneHero(page: page, eyebrow: eyebrow, description: description, greeting: greeting, compact: compact, actions: actions)
                content()
            }
            .padding(.horizontal, PageLayout.page)
            .padding(.vertical, HeroSize.pageInset(compact: compact))
        }
        // 量正文区（滚动区）的高度：矮于 HeroSize.compactBelow 就降一档
        .onGeometryChange(for: Bool.self) { HeroSize.isCompact(viewport: $0.size.height) } action: { value in
            HeroSize.lastCompact = value
            if compact != value { compact = value }
            // 跨过降档线时直接通知补烘：窗口很宽时横幅画作比例不变、HeroPainting 不会重跑 load 去报尺寸
            Scenery.noteCompact(value)
        }
    }
}

extension PageScaffold where Actions == EmptyView {
    init(page: AppSection, spacing: CGFloat = PageLayout.gutter, eyebrow: String? = nil, description: String? = nil,
         greeting: HeroGreeting? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(page: page, spacing: spacing, eyebrow: eyebrow, description: description, greeting: greeting,
                  content: content) { EmptyView() }
    }
}

/// “观山”：整幅画卷（旧版“云山 · 一窗清景”）。
struct SceneGallery: View {
    var page: AppSection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let scene = Scenery.scene(for: page)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SceneryImage(name: page.ornament).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("云山　·　一窗清景").font(Theme.songti(TypeSize.caption, .medium)).tracking(6).foregroundStyle(Theme.gold)
                    Text(scene.sceneName).font(.ysTitle).foregroundStyle(Theme.ink)
                }
                Spacer()
                Button("归卷") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            SceneryImage(name: scene.asset(dark: scheme == .dark))
                .moonlit(scene.needsMoonlight(dark: scheme == .dark))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            Text("风过山间，静观片刻。").font(.ysCallout).foregroundStyle(Theme.inkSoft)
        }
        .padding(26)
        .frame(width: 960)
        .yunshanSheet()
    }
}
