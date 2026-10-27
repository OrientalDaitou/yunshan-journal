import Foundation
import SwiftUI
import AppKit

// #22 横幅的运行时自检：窄窗口降一档的高度与判定、文字块（眉题 + 标题 + 题词 + 按钮）在各档横幅里排得下、
// 按钮行按量出的高度算（调用方按数据什么都不放时与没有按钮一样）、柔光改软件渲染后照样烘得出且四边不透、预热降优先级。
// 只在内存里排版、解码随应用打包的画，不读写任何数据。

extension SelfTest {
    static func bannerChecks(_ check: (Bool, String) -> Void) throws {
        // 1. 降档：正文区矮于 820 时首页 300→220、其余 220→160，页面上下内边距 32→20；还没量到（0）时不降
        let grand = HeroSize(page: .overview), standard = HeroSize(page: .habits)
        check(grand.height(compact: false) == 300 && grand.height(compact: true) == 220
              && standard.height(compact: false) == 220 && standard.height(compact: true) == 160
              && grand.height == 300 && standard.height == 220,
              "横幅：首页 300 / 窄窗口 220，其余 220 / 窄窗口 160")
        check(HeroSize.isCompact(viewport: 728) && !HeroSize.isCompact(viewport: 868) && !HeroSize.isCompact(viewport: 0)
              && HeroSize.pageInset(compact: true) == 20 && HeroSize.pageInset(compact: false) == 32,
              "横幅：1180×780 的正文区（约 728）降档、1440×920（约 868）不降，未量到时不降；页面上下内边距 32→20")

        // 2. 文字块排得下：各页、两档、有无按钮，文字块（含上沿）都不超出横幅，最少留 6pt
        func columnHeight<A: View>(_ page: AppSection, compact: Bool, @ViewBuilder actions: @escaping () -> A) -> CGFloat {
            let view = HeroTextColumn(page: page, eyebrow: nil, description: nil, greeting: nil, compact: compact,
                                      shimmer: false, maxWidth: 300, actions: actions)
                .frame(width: 520)
                .environment(\.spiritMotion, false)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 520, height: 600)
            host.layoutSubtreeIfNeeded()
            // 按钮行的高度经 PreferenceKey 回写一次状态，再排一遍才是最终的样子
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        func buttons() -> some View {
            HStack(spacing: 10) {
                Button {} label: { Label("导入银行 CSV", systemImage: "square.and.arrow.down") }.buttonStyle(.yunshanPrimary)
                Button {} label: { Label("手记一笔", systemImage: "square.and.pencil") }
            }
        }
        var tight: [String] = []
        var worst: CGFloat = .infinity
        for page in AppSection.allCases {
            for compact in [false, true] {
                let limit = HeroSize(page: page).height(compact: compact)
                for withButtons in [false, true] {
                    let h = withButtons ? columnHeight(page, compact: compact) { buttons() }
                                        : columnHeight(page, compact: compact) { EmptyView() }
                    worst = min(worst, limit - h)
                    if h > limit - 6 { tight.append("\(page.title)\(compact ? "·窄" : "")\(withButtons ? "·有按钮" : "") \(Int(h.rounded()))/\(Int(limit))") }
                }
            }
        }
        check(tight.isEmpty, "横幅：各页两档、有无按钮，眉题 + 标题 + 题词 + 按钮都排得下（最少余 \(Int(worst.rounded())) pt）"
              + (tight.isEmpty ? "" : "；超出：\(tight.joined(separator: "、"))"))

        // 3. 按钮行按量出的高度算：按数据什么都不放（还没有功课时）与没有按钮一样高；有按钮只在下面多出按钮那一排，
        //    上面的眉题、标题、题词不挪（标题位置有无按钮一致）
        let noHabits: [String] = []
        for compact in [false, true] {
            let bare = columnHeight(.habits, compact: compact) { EmptyView() }
            // 照每日功课页的写法：还没有功课时横幅不放按钮（类型上仍“有按钮”）
            let blank = columnHeight(.habits, compact: compact) {
                if !noHabits.isEmpty { Button {} label: { Label("新立功课", systemImage: "plus") } }
            }
            let one = columnHeight(.habits, compact: compact) {
                Button {} label: { Label("新立功课", systemImage: "plus") }.buttonStyle(.yunshanPrimary)
            }
            let row = NSHostingView(rootView: Button {} label: { Label("新立功课", systemImage: "plus") }
                .buttonStyle(.yunshanPrimary).environment(\.spiritMotion, false)).fittingSize.height
            let gap = one - bare - row
            check(abs(blank - bare) < 0.5 && gap >= 8 && gap <= 16,
                  "横幅\(compact ? "（窄窗口）" : "")：按钮行什么都不放时与没有按钮同高（\(Int(blank.rounded())) / \(Int(bare.rounded())) pt），"
                  + "有按钮只多出按钮一排与 \(Int(gap.rounded())) pt 间距，标题不挪")
        }

        // 4. 柔光改用软件渲染的 CoreImage：照样烘得出指定宽度，四角不透明（先延展再模糊，边缘不发虚）
        let soft = Scenery.softImage("yunshan-archive-v1", width: 161)
        var corners: [UInt8] = []
        if let cg = soft?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                corners = [0, w - 1, (h - 1) * w, h * w - 1].map { px[$0 * 4 + 3] }
            }
        }
        check(soft.map { Int($0.size.width) == 161 } == true && corners.count == 4 && corners.allSatisfy { $0 > 250 },
              "横幅：柔光改软件渲染后照样烘得出（宽 \(Int(soft?.size.width ?? 0))），四角不透明（\(corners.map(String.init).joined(separator: "/"))）")

        // 5. 预热：最低优先级、窗口出现后约 1.5 秒（RootView 等 1 秒 + 这里 0.5 秒）才开始
        check(Scenery.prewarmPriority == .background && Scenery.prewarmExtraDelay >= 400_000_000,
              "横幅：预热用 .background 优先级，窗口出现后约 1.5 秒才开始")

        // 6. 宽窗口跨过降档线也补烘：窗口 1480×920 时横幅宽约 1100，标准页 220 / 160 两档的画作比例都封顶在 3.6
        //    （HeroPainting 的 .task(id:) 不变、不会去报尺寸），首页却从 2.9 变成 3.6、差了一成五以上（会先空着再淡入），
        //    所以页面骨架量到跨线时要直接通知 Scenery.noteCompact 排上补烘；回到预热时的档位就撤掉
        func bucket(_ page: AppSection, _ compact: Bool, width: CGFloat = 1100) -> CGFloat {
            let h = HeroSize(page: page).height(compact: compact)
            return Scenery.heroBucket(Scenery.paintingWidth(heroWidth: width, height: h) / h)
        }
        let homeDrift = abs(bucket(.overview, false) / bucket(.overview, true) - 1)
        check(bucket(.habits, false) == bucket(.habits, true) && homeDrift > 0.15,
              "横幅：宽窗口（横幅宽 1100）标准页降档前后比例相同（\(bucket(.habits, false))），首页 \(bucket(.overview, false))→\(bucket(.overview, true))"
              + "（差 \(Int((homeDrift * 100).rounded()))%），只靠画作自己报尺寸排不上补烘")
        check(Scenery.needsRewarm(width: 1100, compact: true, warmedWidth: 1100, warmedCompact: false)
              && Scenery.needsRewarm(width: 1100, compact: false, warmedWidth: 1100, warmedCompact: true)
              && Scenery.needsRewarm(width: 1250, compact: false, warmedWidth: 1100, warmedCompact: false)
              && !Scenery.needsRewarm(width: 1150, compact: false, warmedWidth: 1100, warmedCompact: false),
              "横幅：降没降档与预热时不同、或宽度变了一成以上才补烘，宽度只差 5% 不补")
        var compactFlow: [Bool] = []
        Scenery.withSimulatedWarmState(width: 1100, compact: false) { pending in
            Scenery.noteCompact(false)
            compactFlow.append(pending())   // 与预热时同档：不排
            Scenery.noteCompact(true)
            compactFlow.append(pending())   // 高度拖矮跨线：排上补烘（1.2 秒防抖）
            Scenery.noteCompact(false)
            compactFlow.append(pending())   // 停下前又拖回去：撤掉
        }
        Scenery.withSimulatedWarmState(width: 1100, compact: true) { pending in
            Scenery.noteCompact(false)
            compactFlow.append(pending())   // 反方向（从矮拖高）一样排上
        }
        check(compactFlow == [false, true, false, true],
              "横幅：页面骨架量到跨过降档线就排上补烘（不等画作报尺寸），拖回预热时的档位就撤掉，从矮拖高也一样（\(compactFlow)）")
    }
}
