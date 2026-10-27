import SwiftUI
import SwiftData
import AppKit

/// 帮助菜单“快捷键一览…（⌘/）”与洞府设置里那一行打开的小窗：取数据库里的动效开关、外观设置，交给 KeyGuideView。
/// 没打开数据库（被单实例锁拦下、数据库打不开）时也能看，只是不放动效。
struct KeyGuideWindow: View {
    var container: ModelContainer?
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        Group {
            if let container {
                KeyGuideLive().modelContainer(container)
            } else {
                KeyGuideView(motion: false)
            }
        }
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.scheme)
    }
}

/// 数据库开着时：动效跟着洞府设置的开关、系统“减少动态效果”、窗口在不在前台走
private struct KeyGuideLive: View {
    @Query private var settingsList: [AppSettings]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        KeyGuideView(motion: (settingsList.first?.motionEnabled ?? true) && !reduceMotion && activeState != .inactive)
    }
}

/// 快捷键一览：一张小卷（与岁月长卷同一套卷轴：上下木轴、青绫天头地头、纸面金色发丝边栏），按 KeyGuide 分组列出全部快捷键。
/// 打开时展卷，各组随卷轴依次浮现，卷尾落一方“心手相应”朱印；悬停一行，键帽浮起、背后泛金光；
/// 卷开着时按下任意一个快捷键，卷中用到这个键的各行一齐亮起一道金光（只看不拦：菜单里的快捷键照常生效）。
/// 动效都看 motion（洞府设置的动效开关、系统“减少动态效果”、离屏截图时为 false）：关掉时直接显示终态，亮起改为静态的金边。
struct KeyGuideView: View {
    var motion: Bool
    /// 整卷铺开、不放进滚动区（离屏渲染整幅长图用）
    var fullLength = false
    /// 正亮着的行（KeyGuide.Row.id）与这一次亮起的序号（连按时后一次接着亮）
    @State private var lit: Set<String> = []
    @State private var litSerial = 0

    private var animate: Bool { motion && !RenderMode.offscreen }

    var body: some View {
        Group {
            if fullLength {
                content.frame(width: 620)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { content }
                        .scrollIndicators(.hidden)
                        .background(KeyGuideFlashMonitor { combo in flash(combo, proxy: proxy) }.frame(width: 0, height: 0))
                }
                .frame(width: 620)
                .frame(minHeight: 520, idealHeight: 780, maxHeight: .infinity)
            }
        }
        .background { KeyGuideBackdrop(animated: animate) }
        .environment(\.annalsAnimate, animate)
        .environment(\.spiritMotion, animate)
        .foregroundStyle(Theme.text)
        .font(.ysBody)
    }

    /// 卷首题字 + 小卷（各组 + 卷尾）
    private var content: some View {
        VStack(spacing: 18) {
            header
            AnnalsScroll {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(KeyGuide.sections.enumerated()), id: \.element.id) { index, section in
                        KeyGuideSectionView(section: section, index: index, lit: lit, motion: animate)
                    }
                    colophon
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 24)
    }

    private var header: some View {
        VStack(spacing: 8) {
            SceneryImage(name: "yunshan-ornament-compass-v1")
                .frame(width: 54, height: 54)
                .background(SoftGlow(color: Theme.gold.opacity(0.28)).frame(width: 120, height: 120))
            Text("云山　·　指诀").font(Theme.songti(TypeSize.caption, .medium)).tracking(6).foregroundStyle(Theme.gold)
            Text("快捷键一览").font(Theme.songti(TypeSize.title, .bold)).tracking(4).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.gold)
                Text("按下任一快捷键，卷中那一行会亮起").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
            // “◇”的意思放在卷首：第一次在键帽后见到它之前就读到了
            HStack(spacing: 6) {
                BareMark()
                Text("标了它的键，光标在输入框里时不起作用（留给打字）").font(.ysCaption).foregroundStyle(Theme.inkSoft)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("标了菱形记号的键，光标在输入框里时不起作用（留给打字）")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// 卷尾：落一方朱印（“◇”的说明在卷首）
    private var colophon: some View {
        HStack(alignment: .bottom, spacing: 14) {
            Spacer(minLength: 8)
            KeyGuideSeal(play: animate)
        }
        .padding(.top, 4)
    }

    /// 按下了一个组合键：用到它的行亮起约 1 秒；带 ⌘ ⌥ ⌃ 的键顺带把第一行滚进视野
    private func flash(_ combo: KeyCombo, proxy: ScrollViewProxy) {
        let rows = KeyGuide.rows(matching: combo)
        guard !rows.isEmpty else { return }
        litSerial += 1
        let serial = litSerial
        withAnimation(animate ? .easeOut(duration: 0.18) : nil) { lit = rows }
        if !combo.isBare, let first = KeyGuide.sections.flatMap(\.rows).first(where: { rows.contains($0.id) }) {
            withAnimation(animate ? Motion.gentle : nil) { proxy.scrollTo(first.id, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard serial == litSerial else { return }
            withAnimation(animate ? .easeIn(duration: 0.5) : nil) { lit = [] }
        }
    }
}

// MARK: - 一组

/// 一组：节标题（本页小物 + “其一 · 全局”）+ 各行；随卷轴依次浮现
private struct KeyGuideSectionView: View {
    var section: KeyGuide.Section
    var index: Int
    var lit: Set<String>
    var motion: Bool
    @Environment(\.annalsEffectDelay) private var delay
    @State private var shown: Bool?

    private var ornament: String {
        section.page.flatMap { AppSection(rawValue: $0)?.ornament } ?? section.ornament ?? "yunshan-ornament-scroll-v1"
    }

    var body: some View {
        let visible = shown ?? !motion
        VStack(alignment: .leading, spacing: 6) {
            AnnalsSectionTitle(number: "其" + ChineseNumerals.ordinal(index + 1), title: section.title, ornament: ornament)
                .padding(.bottom, 4)
            ForEach(section.rows) { row in
                KeyGuideRowView(row: row, lit: lit.contains(row.id), motion: motion)
                    .id(row.id)
            }
        }
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 10)
        .onAppear {
            guard shown == nil else { return }
            guard motion else { shown = true; return }
            shown = false
            withAnimation(.easeOut(duration: 0.4).delay(delay + 0.05 + Double(min(index, 8)) * 0.07)) { shown = true }
        }
    }
}

// MARK: - 一行

/// 一行：左边一列键帽（成对的用“/”隔开；页面按键在键帽后紧跟一枚“◇”），右边是做什么与小字说明。
/// 悬停：整行淡玉底，键帽浮起、背后泛起金光（不画金边：这一行不能点）。亮起：一道金光从左扫到右，键帽镀金
private struct KeyGuideRowView: View {
    var row: KeyGuide.Row
    var lit: Bool
    var motion: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            caps
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.ysBody).foregroundStyle(lit ? Theme.jadeDeep : Theme.ink)
                if let note = row.note {
                    // 说明长（合成一行的两句、空格打卡那句）时折行，不截成省略号
                    Text(note).font(.ysCaption).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { wash }
        .overlay { litFrame }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(motion ? Motion.hover : nil) { hover = inside }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// 键帽一列：悬停或亮起时浮起，背后泛起金光
    private var caps: some View {
        let raised = hover || lit
        return HStack(spacing: 6) {
            ForEach(Array(row.caps.enumerated()), id: \.offset) { index, cap in
                if index > 0 { Text("/").font(.ysCaption).foregroundStyle(Theme.inkSoft.opacity(0.7)) }
                KeyCap(text: cap, raised: raised, gilded: lit)
            }
            // 不带 ⌘ 的页面按键：“◇”紧跟在键帽后（不再被推到行尾，离键太远）
            if row.bare { BareMark().padding(.leading, 2) }
        }
        .frame(width: 150, alignment: .leading)
        .background(alignment: .leading) {
            SoftGlow(color: Theme.gold.opacity(lit ? 0.5 : 0.3))
                .frame(width: 170, height: 56)
                .opacity(raised ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private var wash: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Theme.jade.opacity(lit ? 0.12 : hover ? 0.07 : 0))
    }

    @ViewBuilder
    private var litFrame: some View {
        if lit {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            shape.strokeBorder(Theme.gold.opacity(0.55), lineWidth: 1)
            if motion { GoldSweep().clipShape(shape) }
        }
    }

    /// 读屏：“上一篇 / 下一篇：↑，↓”，页面按键另说明光标在输入框里时不起作用
    private var spoken: String {
        let keys = row.caps.joined(separator: "，")
        let note = row.note.map { "。" + $0 } ?? ""
        return row.title + "：" + keys + note + (row.bare ? "。光标在输入框里时不起作用" : "")
    }
}

/// 一枚键帽：玉色小牌，金色发丝边，底下压一线深色（像一枚立着的玉牌）；悬停浮起 1.5 pt，亮起时镀一层金
private struct KeyCap: View {
    var text: String
    var raised: Bool
    var gilded: Bool
    @Environment(\.spiritMotion) private var motion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(text)
            .font(.system(size: TypeSize.callout, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(gilded ? Theme.onJadeFill : Theme.ink)
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 24)
            .background {
                ZStack {
                    // 底边：一线深色，键帽像立着的玉牌
                    shape.fill(Theme.inkSoft.opacity(0.35)).offset(y: 1.5)
                    shape.fill(gilded
                               ? AnyShapeStyle(LinearGradient(colors: [Theme.gold.opacity(0.95), Theme.gold.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(LinearGradient(colors: [Theme.card, Theme.mist], startPoint: .top, endPoint: .bottom)))
                }
            }
            .overlay(shape.strokeBorder(Theme.gold.opacity(raised ? 0.7 : 0.4), lineWidth: 0.8))
            .shadow(color: Theme.gold.opacity(gilded ? 0.45 : 0), radius: 6)
            .offset(y: raised && motion ? -1.5 : 0)
            .animation(motion ? Motion.hover : nil, value: raised)
            .animation(motion ? Motion.quick : nil, value: gilded)
    }
}

/// “◇”：不带 ⌘ 的页面按键，光标在输入框里时不起作用
private struct BareMark: View {
    var body: some View {
        Image(systemName: "diamond")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.gold.opacity(0.85))
            .help("光标不在输入框里时才起作用")
            .accessibilityHidden(true)
    }
}

/// 亮起时扫过一行的金光：一道斜向的光带从左到右走一遍（0.7 秒，一次）
private struct GoldSweep: View {
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Theme.gold.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.35)
                .rotationEffect(.degrees(12))
                .offset(x: geo.size.width * phase)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { phase = 1.1 } }
        .accessibilityHidden(true)
    }
}

// MARK: - 卷尾朱印

/// 2×2 朱印“心手 / 相应”：传统右起竖读（右列“心手”、左列“相应”），与长卷的落款同一种朱红、同一种落法：
/// 2 倍、-14° 弹簧落到 1 倍、-6°，一圈涟漪散去（动效关掉时直接落定）
private struct KeyGuideSeal: View {
    var play: Bool
    var size: CGFloat = 58
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
            seal
                .scaleEffect(down ? 1 : 2)
                .rotationEffect(.degrees(down ? -6 : -14))
                .opacity(down ? 1 : 0)
                .shadow(color: ScrollPalette.seal.opacity(0.25), radius: down ? 2 : 12)
        }
        .frame(width: size * 1.3, height: size * 1.3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("朱印：心手相应")
        .onAppear {
            guard landed == nil else { return }
            guard play else { landed = true; return }
            landed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + delay) {
                withAnimation(Motion.ceremony) { landed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.easeOut(duration: 0.8)) { ripple = true }
                }
            }
        }
    }

    private var seal: some View {
        let char = size * 0.34
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous).fill(ScrollPalette.seal)
            RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: max(1, size * 0.022))
                .padding(size * 0.07)
            HStack(spacing: size * 0.04) {
                VStack(spacing: size * 0.02) { glyph("相", char); glyph("应", char) }
                VStack(spacing: size * 0.02) { glyph("心", char); glyph("手", char) }
            }
        }
        .frame(width: size, height: size)
    }

    private func glyph(_ text: String, _ size: CGFloat) -> some View {
        Text(text).font(Theme.songti(size, .heavy)).foregroundStyle(Color.white.opacity(0.95)).frame(width: size * 1.05, height: size * 1.05)
    }
}

// MARK: - 底色与按键监听

/// 小窗的底：纸色上一层缓缓飘过的雾、几点上浮的灵气，四周压一圈淡淡的暗角（动效关掉时都静止）。
/// 暗角用固定的深墨色：Theme.ink 深色下是浅色，拿它压角会把四角提亮成灰白雾
private struct KeyGuideBackdrop: View {
    var animated: Bool
    @Environment(\.colorScheme) private var scheme
    /// 暗角的颜色：深浅色都用同一种深墨绿（只调不透明度）
    static let vignette = Color(red: 0.03, green: 0.07, blue: 0.06)

    var body: some View {
        ZStack {
            Theme.paper
            LinearGradient(colors: [Theme.goldSoft.opacity(scheme == .dark ? 0.25 : 0.55), .clear], startPoint: .top, endPoint: .center)
            MistDrift(animated: animated)
            SpiritField(count: 18, animated: animated, meteors: scheme == .dark)
            RadialGradient(colors: [.clear, Self.vignette.opacity(scheme == .dark ? 0.4 : 0.07)], center: .center, startRadius: 240, endRadius: 620)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 一览小窗里的按键：认出组合键交给 onKey（亮起对应的行）。菜单里的快捷键（⌘/、⌘,、⌘W……）照常交给菜单；
/// 别的认得出的键就此吞掉（小窗里没有别的东西要用它们，免得每按一下都“嘟”一声）
private struct KeyGuideFlashMonitor: NSViewRepresentable {
    var onKey: (KeyCombo) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.onKey = onKey
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        weak var view: NSView?
        var onKey: (KeyCombo) -> Void = { _ in }
        private var monitor: Any?

        @MainActor
        func install() {
            guard monitor == nil, !RenderMode.offscreen else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window, let combo = KeyCombo(event: event) else { return event }
                self.onKey(combo)
                // 菜单里有这个键（含系统的 ⌘W、⌘Q）：交给菜单
                if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return nil }
                return KeyGuide.rows(matching: combo).isEmpty ? event : nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }
}
