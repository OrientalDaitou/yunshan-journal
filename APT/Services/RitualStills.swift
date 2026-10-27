import SwiftUI
import AppKit

/// 仪式的离屏定格（PageRenderer 的 `rituals` / `effects` 组）：离屏窗口没有显示刷新的时钟，动画根本不往前走，
/// 所以不等动画，而是用与实际播放同一套时间函数（RitualTimeline）把图层直接摆到指定时刻，叠在那次渲染的页面上出 PNG。
/// 锚点用底图那次渲染里实际登记的位置（离屏时 `.ritualAnchor` / `.sealAnchor` 照常登记），缺哪个就按窗口尺寸估一个。
/// 定格用的是 render(in:)：不画滤镜，所以纸笺上的字被墨洇开的模糊在定格里看不到，构图与实际一致。
@MainActor
enum RitualStills {
    /// 落笔入卷的三个时刻：墨迹晕开、纸卷合拢、飞入修行录
    static let inscriptionTimes: [Double] = [0.25, 0.6, 1.1]
    /// 功课圆满的三个时刻：灵光汇聚、丹田一亮符箓展开、金符停住
    static let consummationTimes: [Double] = [0.4, 0.8, 1.2]
    /// 纸笺上的示例正文
    static let samplePreview = "下午把实验部分的图重画了一遍，终于顺眼。晚上和导师对了一下结构，第三章可以收尾了。有点累，但心里踏实。"

    /// 出 7 张：effect-inscription-250ms / 600ms / 1100ms、effect-consummation-400ms / 800ms / 1200ms、effect-seal（0.6 秒）。
    /// prefix 区分深浅色（深色 "effect-"，浅色 "effect-light-"）
    static func write(over base: NSBitmapImageRep, size: CGSize, dark: Bool, anchors: [RitualAnchor: CGRect], seal: CGRect?,
                      to directory: URL, prefix: String = "effect-") {
        let composer = anchors[.composer] ?? CGRect(x: 340, y: size.height * 0.48, width: max(300, size.width * 0.42), height: 62)
        let sealAnchor = seal ?? CGRect(x: composer.maxX - 120, y: composer.maxY + 12, width: 120, height: 38)
        let chronicle = anchors[.chronicleNav] ?? CGRect(x: 18, y: size.height * 0.33, width: 264, height: 58)
        let dantian = anchors[.dantian] ?? CGRect(x: 30, y: 150, width: 64, height: 64)
        let inscription = EffectsCenter.Inscription(preview: RitualRules.inscriptionPreview(samplePreview), kind: .diary,
                                                    slip: composer, seal: sealAnchor, target: chronicle)
        let consummation = EffectsCenter.Consummation(dantian: dantian, source: nil)
        let stamp = EffectsCenter.Seal(text: "入卷", anchor: sealAnchor)
        var shots: [(String, (RitualHostView) -> Void)] = []
        for t in inscriptionTimes {
            shots.append(("inscription-\(Int((t * 1000).rounded()))ms", { host in
                host.pose(.inscription(inscription), at: t)
                host.poseSeal(stamp, at: t)
            }))
        }
        for t in consummationTimes {
            shots.append(("consummation-\(Int((t * 1000).rounded()))ms", { $0.pose(.consummation(consummation), at: t) }))
        }
        shots.append(("seal", { $0.poseSeal(stamp, at: 0.6) }))
        // APT_RENDER_RITUAL_FRAMES=1：另出逐帧（每 50 ms 一张）到 effect-frames/ 与 effect-light-frames/，逐帧看分镜
        if ProcessInfo.processInfo.environment["APT_RENDER_RITUAL_FRAMES"] == "1" {
            for step in 0...31 {
                let t = Double(step) * 0.05
                let ms = String(format: "%04d", Int((t * 1000).rounded()))
                shots.append(("frames/inscription-\(ms)", { host in
                    host.pose(.inscription(inscription), at: t)
                    host.poseSeal(stamp, at: t)
                }))
                shots.append(("frames/consummation-\(ms)", { $0.pose(.consummation(consummation), at: t) }))
            }
            try? FileManager.default.createDirectory(at: directory.appendingPathComponent("\(prefix)frames"), withIntermediateDirectories: true)
        }
        for (label, pose) in shots {
            guard let rep = compose(base: base, size: size, dark: dark, pose: pose),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("\(prefix)\(label).png")
            try? png.write(to: url)
            print("已渲染 \(url.lastPathComponent)")
        }
    }

    /// 底图上叠一层仪式图层（真的 RitualHostView，与窗口里同一条代码路径），整体截一张
    static func compose(base: NSBitmapImageRep, size: CGSize, dark: Bool, pose: (RitualHostView) -> Void) -> NSBitmapImageRep? {
        let bounds = CGRect(origin: .zero, size: size)
        let container = NSView(frame: bounds)
        let backdrop = NSImageView(frame: bounds)
        let image = NSImage(size: size)
        image.addRepresentation(base)
        backdrop.image = image
        backdrop.imageScaling = .scaleAxesIndependently
        let host = RitualHostView(frame: bounds)
        container.addSubview(backdrop)
        container.addSubview(host)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        pose(host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        defer { window.close() }
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }

    /// 把一张 SwiftUI 画面（例如渡劫定格）叠在底图上：ImageRenderer 出透明底的图，再与底图合成
    static func overlay<V: View>(_ view: V, on base: NSBitmapImageRep, size: CGSize, dark: Bool) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = CGFloat(base.pixelsWide) / max(1, size.width)
        guard let top = renderer.cgImage,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.current = context
        base.draw(in: CGRect(origin: .zero, size: size))
        context.cgContext.draw(top, in: CGRect(origin: .zero, size: size))
        context.flushGraphics()
        return out
    }
}
