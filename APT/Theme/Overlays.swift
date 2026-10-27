import SwiftUI

// 仪式特效：落笔入卷的朱印、AI 传书的飞剑与传书笺、境界突破的渡劫。
// 都挂在窗口根视图上（RootView 的 .overlay），受 `spiritMotion` 与 EffectsCenter.motionEnabled 控制。

// MARK: - 落印

/// 落笔入卷时，一方朱印盖下：落在刚点的“落笔入卷”旁（按钮挂了 `.sealAnchor()` 时），像钤在这页纸的落款处；
/// 没有登记位置时（如问道页存档、随手记）盖在窗口正中。
struct SealStampOverlay: View {
    @Environment(EffectsCenter.self) private var effects

    var body: some View {
        GeometryReader { geo in
            // 动效开着、主窗口的仪式图层在时，朱印由 Core Animation 画（RitualOverlay），这里不再画一遍
            if let seal = effects.seal, !seal.drawnByRitualHost {
                SealStamp(text: seal.text, animated: effects.motionEnabled)
                    .id(seal.id)
                    .position(Self.center(for: seal, in: geo.frame(in: .global)))
                    .transition(.opacity.animation(.easeOut(duration: 0.4)))
            }
        }
        .allowsHitTesting(false)
    }

    /// 印的中心：正盖在刚点的按钮上（像钤在落款处），印的下沿略低于按钮，往上探进正文框的右下角——
    /// 入卷后正文已清空，那里是空的；不再往上够到标题行（会压住“日记 / 灵感 / 复盘”分段）。并留在窗口里
    private static func center(for seal: EffectsCenter.Seal, in frame: CGRect) -> CGPoint {
        guard let anchor = seal.anchor, frame.width > 0, frame.height > 0 else { return CGPoint(x: frame.width / 2, y: frame.height / 2) }
        let size = SealStamp.size(for: seal.text)
        let x = anchor.midX - frame.minX
        let y = anchor.maxY - frame.minY + 6 - size.height / 2
        let marginX = size.width / 2 + 16, marginY = size.height / 2 + 16
        return CGPoint(x: min(max(x, marginX), frame.width - marginX), y: min(max(y, marginY), frame.height - marginY))
    }
}

private struct SealStamp: View {
    /// 朱砂印泥：深浅色下都用同一种沉稳的朱红
    static let ink = Color(red: 0.70, green: 0.20, blue: 0.16)
    var text: String
    var animated: Bool
    @State private var landed = false
    @State private var ripple = false
    /// 落定片刻后淡成一枚印痕，再整体淡出（EffectsCenter 约 2.2 秒后撤下）
    @State private var settled = false

    static func size(for text: String) -> CGSize {
        let count = max(1, min(4, text.count))
        return CGSize(width: 64, height: 24 + CGFloat(count) * 36)
    }

    var body: some View {
        let size = Self.size(for: text)
        ZStack {
            // 涟漪只留一圈
            Circle()
                .strokeBorder(SealStamp.ink.opacity(0.45), lineWidth: 1.5)
                .frame(width: size.height, height: size.height)
                .scaleEffect(ripple ? 1.6 : 0.7)
                .opacity(ripple ? 0 : 0.7)
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(SealStamp.ink.opacity(0.92))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                    .padding(5)
                VStack(spacing: 0) {
                    ForEach(Array(text.prefix(4).enumerated()), id: \.offset) { _, ch in
                        Text(String(ch)).font(Theme.songti(28, .bold)).foregroundStyle(Color.white.opacity(0.95))
                            .frame(height: 36)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: SealStamp.ink.opacity(settled ? 0 : 0.45), radius: landed ? 12 : 0)
            .scaleEffect(landed ? 1 : 2.2)
            .rotationEffect(.degrees(landed ? -6 : -16))
            .opacity(landed ? (settled ? 0.32 : 0.96) : 0)
        }
        .onAppear {
            guard animated else { landed = true; return }
            withAnimation(Motion.ceremony) { landed = true }
            withAnimation(.easeOut(duration: 0.8).delay(0.16)) { ripple = true }
            // 落定后留约 1 秒淡淡的印痕
            withAnimation(.easeInOut(duration: 0.35).delay(0.85)) { settled = true }
        }
    }
}

// MARK: - 飞剑传书

/// AI 传书到达：一柄飞剑拖着灵光划过，随后展开传书笺。
struct CourierOverlay: View {
    var onOpen: () -> Void
    /// 真正执行撤销（传书笺上已经让用户点了两次确认）
    var onUndo: (String) -> Void
    /// 撤销前给用户看的说明，例如“将删除 2 条记录，恢复 1 个档案字段；保留你改过的 1 条记录。删除后无法找回。”（参数是 deliveryID）；不给时用通用说明
    var undoPreview: ((String) -> String?)? = nil
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 飞剑落地后才展开传书笺
    @State private var cardID: UUID?
    /// 这封传书要不要飞剑，到达那一刻就定下：之后窗口回到前台也不补飞（否则剑会飞过早已展开的笺）
    @State private var swordID: UUID?

    private var animated: Bool { motion && !reduceMotion }

    /// 传书笺落在窗口右上角：离顶 70、离右 26（截图用的定格 CourierStills.card 摆在同一处）
    static let cardTop: CGFloat = 70
    static let cardTrailing: CGFloat = 26

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let notice = effects.courier {
                if swordID == notice.id && effects.motionEnabled {
                    FlyingSword().id(notice.id)
                }
                if cardID == notice.id {
                    CourierCard(notice: notice, onOpen: onOpen, onUndo: onUndo, undoPreview: undoPreview) { close(notice.id) }
                        .id("card-\(notice.id)")
                        // 鼠标停在笺上时暂停自动收起
                        .onHover { effects.courierHeld = $0 }
                        .padding(.top, Self.cardTop)
                        .padding(.trailing, Self.cardTrailing)
                        // 关闭动效或“减少动态效果”时只淡入淡出，不从右侧滑入
                        .transition(animated ? .move(edge: .trailing).combined(with: .opacity) : .opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(animated ? .spring(response: 0.5, dampingFraction: 0.8) : .easeOut(duration: 0.2), value: cardID)
        .onChange(of: effects.courier?.id, initial: true) { _, id in
            guard let id, let notice = effects.courier else { cardID = nil; swordID = nil; return }
            let flies = effects.motionEnabled && notice.flies && !notice.failed
            swordID = flies ? id : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (flies ? 1.35 : 0)) {
                if effects.courier?.id == id { cardID = id }
            }
        }
        .onChange(of: effects.motionEnabled) { _, on in
            if !on { swordID = nil }
        }
    }

    /// 只收起这一张：撤销后 RootView 可能已经换上了撤销结果的提示，不能一并清掉
    private func close(_ id: UUID) {
        if effects.courier?.id == id { effects.courier = nil }
        effects.courierHeld = false
    }
}

/// 截图用的定格：离屏窗口没有显示刷新的时钟，TimelineView 和滑入的转场都不往前走，等是等不到的，直接摆到那一刻
enum CourierStills {
    /// 飞剑飞到 elapsed 秒时
    static func flight(elapsed: Double) -> some View { FlyingSword(fixedElapsed: elapsed) }

    /// 展开好的传书笺：与窗口里同一张笺（CourierCard）、同一处位置（右上角），铺满整窗大小，叠在页面截图上。
    /// armedDetail 不为 nil 时画第一次点“撤销此书”之后、“再点一次即撤销：…”那一刻
    static func card(_ notice: EffectsCenter.CourierNotice, armedDetail: String? = nil) -> some View {
        CourierCard(notice: notice, onOpen: {}, onUndo: { _ in }, undoPreview: nil, onClose: {}, stillArmedDetail: armedDetail)
            .padding(.top, CourierOverlay.cardTop)
            .padding(.trailing, CourierOverlay.cardTrailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

private struct FlyingSword: View {
    /// 离屏定格：直接画这一刻
    var fixedElapsed: Double? = nil
    @State private var start = Date()
    /// 飞完后停掉时钟（传书笺还会停留十几秒，不能一直空转）
    @State private var finished = false
    private let duration = 1.5

    var body: some View {
        Group {
            if let fixedElapsed {
                scene(fixedElapsed)
            } else {
                TimelineView(.animation(minimumInterval: nil, paused: finished)) { timeline in
                    scene(timeline.date.timeIntervalSince(start))
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard fixedElapsed == nil else { return }
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.7) { finished = true }
        }
    }

    private func scene(_ e: Double) -> some View {
        Canvas { gc, size in
            guard e < duration + 0.6 else { return }
            let p0 = CGPoint(x: size.width + 80, y: size.height * 0.05)
            let p1 = CGPoint(x: size.width * 0.62, y: size.height * 0.55)
            let p2 = CGPoint(x: size.width - 440, y: 150)
            func point(_ s: Double) -> CGPoint {
                let u = 1 - s
                return CGPoint(x: u * u * p0.x + 2 * u * s * p1.x + s * s * p2.x, y: u * u * p0.y + 2 * u * s * p1.y + s * s * p2.y)
            }
            let raw = min(1, e / duration)
            let s = 1 - pow(1 - raw, 3)
            // 灵光尾迹
            if raw < 1 {
                for k in stride(from: 26, through: 1, by: -1) {
                    let back = max(0, s - Double(k) * 0.012)
                    let q = point(back), r = point(max(0, back - 0.012))
                    var seg = Path()
                    seg.move(to: r)
                    seg.addLine(to: q)
                    let a = (1 - Double(k) / 27)
                    gc.stroke(seg, with: .color(Color(red: 0.95, green: 0.85, blue: 0.55).opacity(a * 0.8)),
                              style: StrokeStyle(lineWidth: 1 + a * 5, lineCap: .round))
                    gc.stroke(seg, with: .color(Color(red: 0.6, green: 0.95, blue: 0.85).opacity(a * 0.35)),
                              style: StrokeStyle(lineWidth: 2 + a * 14, lineCap: .round))
                }
            }
            let head = point(s)
            let ahead = point(min(1, s + 0.01))
            let angle = raw < 1 ? atan2(ahead.y - head.y, ahead.x - head.x) : atan2(p2.y - p1.y, p2.x - p1.x)
            // 到达时一圈灵光
            if raw >= 1 {
                let f = (e - duration) / 0.6
                let radius = 20 + f * 90
                gc.stroke(Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2)),
                          with: .color(Theme.gold.opacity(0.7 * (1 - f))), lineWidth: 2)
            }
            let fade = raw < 1 ? 1 : max(0, 1 - (e - duration) / 0.4)
            var sword = gc
            sword.translateBy(x: head.x, y: head.y)
            sword.rotate(by: .radians(angle))
            sword.opacity = fade
            sword.addFilter(.shadow(color: Color(red: 1, green: 0.85, blue: 0.5), radius: 8))
            if let art = sword.resolveSymbol(id: 0) {
                // 工笔飞剑插画：剑尖约在图宽 92.5% 处，对准飞行轨迹的前端
                let width: CGFloat = 180, height = width / 4
                sword.draw(art, in: CGRect(x: -width * 0.925, y: -height / 2, width: width, height: height))
            } else {
                sword.scaleBy(x: 1.7, y: 1.7)
                sword.fill(SwordShape.blade, with: .linearGradient(Gradient(colors: [Color(white: 0.75), .white]),
                                                                   startPoint: CGPoint(x: -14, y: 0), endPoint: CGPoint(x: 34, y: 0)))
                sword.fill(SwordShape.hilt, with: .color(Color(red: 0.85, green: 0.68, blue: 0.35)))
            }
        } symbols: {
            if Scenery.image("yunshan-flying-sword-v1") != nil {
                SceneryImage(name: "yunshan-flying-sword-v1").frame(width: 360, height: 90).tag(0)
            }
        }
    }
}

enum SwordShape {
    /// 剑尖朝 +x
    static let blade: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 36, y: 0))
        p.addLine(to: CGPoint(x: 26, y: -2.8))
        p.addLine(to: CGPoint(x: -12, y: -2.8))
        p.addLine(to: CGPoint(x: -12, y: 2.8))
        p.addLine(to: CGPoint(x: 26, y: 2.8))
        p.closeSubpath()
        return p
    }()
    static let hilt: Path = {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: -15, y: -8, width: 3.5, height: 16), cornerSize: CGSize(width: 1.5, height: 1.5))
        p.addRect(CGRect(x: -27, y: -1.6, width: 12, height: 3.2))
        p.addEllipse(in: CGRect(x: -32, y: -3, width: 6, height: 6))
        return p
    }()
}

/// 传书笺的尺寸与行文排版（自检核对）
enum CourierCardText {
    /// 笺宽：360 时“（每天，每次 10分钟，自 10月21日 起）”这类括注会在日期中间折开，放宽到 384
    static let width: CGFloat = 384

    /// 目标行里的“备注 +「…」”整段换到下一行显示：
    /// - 接在别的改动后面（“；备注 +「”）：去掉分号，“目标 · 论文：进度 60% → 65%；备注 +「第三章初稿完成」” →
    ///   “目标 · 论文：进度 60% → 65%\n备注 +「第三章初稿完成」”；
    /// - 只改了备注（“：备注 +「”）：冒号留在上一行，“目标 · 更新「论文」：备注 +「…」” → “目标 · 更新「论文」：\n备注 +「…」”。
    /// 没有备注的行原样返回。只改显示，传书摘要与自检核对的行文不变
    static func wrappingNote(_ line: String) -> String {
        if let range = line.range(of: "；备注 +「") {
            return String(line[..<range.lowerBound]) + "\n" + String(line[line.index(after: range.lowerBound)...])
        }
        if let range = line.range(of: "：备注 +「") {
            let colonEnd = line.index(after: range.lowerBound)
            return String(line[..<colonEnd]) + "\n" + String(line[colonEnd...])
        }
        return line
    }

    /// 一小句整体不折开（字与字之间夹 U+2060 字连接符，看不见）：朱砂的“删除后无法找回。”放不下时整句换到下一行，
    /// 不再折成“删除后无法 / 找回。”
    static func unbreakable(_ text: String) -> String {
        text.map(String.init).joined(separator: "\u{2060}")
    }

    /// 日期、数量与单位粘成一个词：“10月23日”“2027年2月17日”“8000步”“90分钟”“3 次”。
    /// 单位只认常见的几种（功法谱与传书里会出现的），数与单位之间最多隔一个空格（普通空格或摘要行里的不换行空格）。
    /// 消费行末尾的金额连类别“$18.00［餐饮与外卖］”（类别 10 字以内）也整个不折开：放不下时在“$”前的空格处折行，
    /// 下一行从“$”起、与上一行左边对齐（只粘类别时整块落到行首，全角“［”字形偏右，看着缩进了一截），也不折成“［餐饮与外 / 卖］”
    static let figurePattern = try! NSRegularExpression(
        pattern: #"(?:\d+年)?\d+月\d+日|\d+(?:\.\d+)?[ \x{00A0}]?(?:分钟|小时|公里|千米|毫升|步|个|页|杯|字|次|篇|章|遍|题|组|分|秒)|(?:\$\d+(?:\.\d+)?)?［[^［］\n]{1,10}］"#)

    /// 传书笺行文里的日期、数量与单位不折开（片段内字间夹 U+2060，看不见）：放不下时整段换到下一行，
    /// 不再折成“10月23 / 日”“90分 / 钟”。只改显示，去掉 U+2060 后与原行相同
    static func gluingFigures(_ line: String) -> String {
        let ns = line as NSString
        let matches = figurePattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += unbreakable(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }

    /// 传书笺上一行实际显示的样子：“备注 +「…」”另起一行（noteWrapped：多占一行），日期、数量与单位不折开
    static func display(_ line: String) -> (text: String, noteWrapped: Bool) {
        let wrapped = wrappingNote(line)
        return (gluingFigures(wrapped), wrapped != line)
    }

    /// 一行的颜色：整行警示色的（CourierLineDecor.isWarningLine：按条退回的打卡“未收 · …”、多封合并时整封没收录的
    /// “未收录 · …”）warning 为真；多封合并时某封那行冒号前的“1 条未收”拆出来（mark）单独用警示色，其余照常。
    /// lead + mark + body 就是原行
    static func tone(_ line: String) -> (lead: String, mark: String?, body: String, warning: Bool) {
        if CourierLineDecor.isWarningLine(line) { return ("", nil, line, true) }
        let ns = line as NSString
        if let match = unreceivedMark.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let mark = match.range(at: 1)
            return (ns.substring(to: mark.location), ns.substring(with: mark), ns.substring(from: NSMaxRange(mark)), false)
        }
        return ("", nil, line, false)
    }

    /// CourierLineDecor.batchLine 冒号前的“Claude · 2 条 · 1 条未收：”里的“1 条未收”
    private static let unreceivedMark = try! NSRegularExpression(pattern: "^[^\\n]*? · \\d+ 条 · (\\d+ 条未收)：")
}

private struct CourierCard: View {
    var notice: EffectsCenter.CourierNotice
    var onOpen: () -> Void
    var onUndo: (String) -> Void
    var undoPreview: ((String) -> String?)?
    var onClose: () -> Void
    /// 截图定格用：直接画成已预备撤销、显示这段说明的样子（CourierStills.card）
    var stillArmedDetail: String? = nil
    @Environment(\.spiritMotion) private var motion
    /// 撤销要点两次：第一次只“预备”并说明会删什么，几秒内再点才真的撤销
    @State private var armed: UUID?
    @State private var armedDetail: String?

    private var isArmed: Bool { armed != nil || stillArmedDetail != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // 传书是信息（青），失败是警示（朱砂）
                Image(systemName: notice.symbol ?? (notice.failed ? "exclamationmark.triangle" : "paperplane"))
                    .font(.system(size: TypeSize.body, weight: .semibold))
                    .foregroundStyle(notice.failed ? Theme.warning : Theme.info)
                    .frame(width: 30, height: 30)
                    .background((notice.failed ? Theme.warning : Theme.info).opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title).font(.ysHeading).tracking(1).foregroundStyle(Theme.ink)
                    Text(notice.detail).font(.ysCaption).foregroundStyle(Theme.inkSoft)
                }
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: TypeSize.micro, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.inkSoft)
                    .help("收起")
                    .accessibilityLabel("关闭")
            }
            if !notice.lines.isEmpty {
                // 目标进度有变化的行（“目标 · T：进度 a% → b%…”）下面衬细进度条，整张笺最多 2 根
                let moves = notice.lines.map(CourierLineDecor.progressMove)
                let bars = Set(moves.indices.filter { moves[$0] != nil }.prefix(2))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notice.lines.indices, id: \.self) { i in
                        if let move = moves[i] {
                            CourierGoalLine(text: notice.lines[i], move: move, showsBar: bars.contains(i))
                        } else {
                            // 传书摘要每行最多两行（“备注 +「…」”另起的那行另算）；撤销结果、失败原因这类说明不截断（最多四行）。
                            // 日期、数量与单位不在中间折开。按条退回的打卡（“未收 · …”）、整封没收录的（“未收录 · …”）整行警示色；
                            // 多封合并时某封冒号前的“1 条未收”只这几个字警示色（写在冒号前，行尾截断截不到）
                            let tone = CourierCardText.tone(notice.lines[i])
                            let shown = CourierCardText.display(tone.body)
                            (Text(CourierCardText.gluingFigures(tone.lead)).foregroundStyle(Theme.text)
                             + Text(tone.mark.map(CourierCardText.unbreakable) ?? "").foregroundStyle(Theme.warning)
                             + Text(shown.text).foregroundStyle(tone.warning ? Theme.warning : Theme.text))
                                .font(.ysCaption)
                                .lineLimit((notice.flies && !notice.failed ? 2 : 4) + (shown.noteWrapped ? 1 : 0))
                        }
                    }
                }
                .padding(.leading, 40)
            }
            if let id = notice.deliveryID {
                if isArmed {
                    // 正文用正文色，只有句末的“删除后无法找回。”用朱砂（朱砂只表示警示）
                    let parts = CourierUndoWording.splitWarning(stillArmedDetail ?? armedDetail ?? "再点一次“确认撤销”，这封传书写入的记录会被撤回")
                    (Text(parts.body).foregroundStyle(Theme.text)
                     + Text(parts.warning.map(CourierCardText.unbreakable) ?? "").foregroundStyle(Theme.cinnabar))
                        .font(.ysCaption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 40)
                }
                // 撤销做成左侧的次要文字按钮，与“查看”分开两端，免得误点
                HStack {
                    Button { tapUndo(id) } label: {
                        Label(isArmed ? "确认撤销？" : "撤销此书", systemImage: "arrow.uturn.backward")
                            .font(.system(size: TypeSize.caption, weight: isArmed ? .semibold : .regular))
                            .foregroundStyle(isArmed ? Theme.cinnabar : Theme.inkSoft)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isArmed ? "再点一次即撤销这封传书" : "撤销这封传书写入的记录（要再点一次确认）")
                    Spacer()
                    Button("查看") { open(); onClose() }.buttonStyle(YunshanButtonStyle(primary: true, compact: true))
                }
                .padding(.leading, 40)
            }
        }
        .padding(16)
        .frame(width: CourierCardText.width)
        .background(Theme.card.opacity(0.97), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Theme.gold.opacity(0.45)))
        .overlay { SpiritRim(cornerRadius: Radius.card).opacity(motion ? 1 : 0) }
        .shadow(color: Theme.gold.opacity(0.25), radius: 24, y: 6)
    }

    /// “查看”：整封只有目标时去修士名帖、只有新习惯和打卡时去每日功课（RootView 监听 AppRouter 切页），其余照旧去修行录
    private func open() {
        if let page = notice.openPage.flatMap(AppSection.init(rawValue:)) {
            AppRouter.shared.page = page
        } else {
            onOpen()
        }
    }

    /// 第一次点：预备撤销（4 秒内不再点就复原）；预备状态下再点：真的撤销
    private func tapUndo(_ id: String) {
        if armed != nil {
            armed = nil
            onUndo(id)
            onClose()
            return
        }
        let token = UUID()
        armedDetail = undoPreview?(id).map { "再点一次即撤销：\($0)" }
        armed = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if armed == token { armed = nil }
        }
    }
}

/// 传书笺里一条目标进度行：正下方衬一根 4pt 细进度条（不另写标题和数字），从旧值涨到新值；
/// 涨满 100% 时这一行掠过一道光、细条泛一下金光，行尾挂“达成”玉色小签。
/// - 有动效：笺展开后等 0.45 秒再涨（ProgressBar 自己按动效开关补间）；
/// - 关了动效或开了“减少动态效果”（窗口在前台）：直接画终值，不扫光，“达成”签照挂；
/// - 窗口在后台（RootView 此时把 spiritMotion 置假，飞剑也不飞）：停在旧值，等切回前台再走上面两条——传书多在后台到达，
///   用户回来时仍能看到涨的那一下；
/// - 离屏截图：一开始就画终值。
private struct CourierGoalLine: View {
    var text: String
    var move: CourierLineDecor.ProgressMove
    var showsBar: Bool
    @Environment(\.spiritMotion) private var motion
    @Environment(\.controlActiveState) private var activeState
    @State private var shown: Double
    /// 涨完了：之后窗口再进出后台都不重播
    @State private var played: Bool
    /// “达成”签（played 之后弹出；无动效时与 played 同时出现）
    @State private var badge: Bool
    @State private var glow = false

    init(text: String, move: CourierLineDecor.ProgressMove, showsBar: Bool) {
        self.text = text
        self.move = move
        self.showsBar = showsBar
        let still = RenderMode.offscreen
        _shown = State(initialValue: Double(still ? move.to : move.from))
        _played = State(initialValue: still)
        _badge = State(initialValue: still)
    }

    private struct Trigger: Equatable { var motion: Bool; var active: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // 文字占满一行：“达成”签挂在行尾（右缘与细条对齐），不夹在句子中间
                // “备注 +「…」”整段另起一行（不在“备注 +”和引号中间折开），另起的那行不占原来两行的额度；日期、数量与单位不折开
                let shown = CourierCardText.display(text)
                let line = Text(shown.text).font(.ysCaption).foregroundStyle(Theme.text).lineLimit(shown.noteWrapped ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if move.completed {
                    // ShimmerSweep 只在出现时扫一次：played 变真时用 id 让它重新出现、扫一道就撤
                    line.shimmerSweep(motion && played).id(played)
                } else {
                    line
                }
                if move.completed && badge {
                    Chip(text: "达成", color: Theme.positive)
                        .fixedSize()
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .accessibilityLabel("目标已达成")
                }
            }
            if showsBar {
                ProgressBar(value: shown / 100, height: 4)
                    .shadow(color: Theme.gold.opacity(glow ? 0.6 : 0), radius: glow ? 5 : 0)
                    .accessibilityElement()
                    .accessibilityLabel("目标 \(move.title) 进度从 \(move.from)% 到 \(move.to)%")
                    // 细条贴着自己那一行，和下一行之间多留一点：一眼看出它属于上面那条目标
                    .padding(.bottom, 3)
            }
        }
        .task(id: Trigger(motion: motion, active: activeState != .inactive)) { await play() }
    }

    private func play() async {
        guard !played, activeState != .inactive else { return }
        guard motion else {
            shown = Double(move.to)
            played = true
            badge = true
            return
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        shown = Double(move.to)
        played = true
        guard move.completed else { return }
        // 细条涨到头（Motion.gentle 0.5 秒）时挂签，并泛一下金光
        withAnimation(Motion.ceremony.delay(0.45)) { badge = true }
        withAnimation(.easeOut(duration: 0.3).delay(0.45)) { glow = true }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        withAnimation(.easeIn(duration: 0.9)) { glow = false }
    }
}

// MARK: - 渡劫突破

/// 境界突破：天雷三落、金光通天、灵气四溅，境界名由虚化实。点击任意处关闭。
struct TribulationOverlay: View {
    @Environment(EffectsCenter.self) private var effects

    var body: some View {
        if let realm = effects.breakthrough {
            Group {
                let emblem = RealmBadge.emblem(for: effects.breakthroughEmblemIndex(for: realm))
                if effects.motionEnabled {
                    TribulationScene(realm: realm, emblem: emblem).id(realm)
                } else {
                    StaticBreakthrough(realm: realm, emblem: emblem)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { effects.breakthrough = nil }
            // Esc 也能关闭（键盘用户不必等它自己散去）
            .background {
                Button("继续") { effects.breakthrough = nil }
                    .keyCommand(.breakthroughClose)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityAction(.escape) { effects.breakthrough = nil }
            // 动效关闭时直接出现（静态卡不跟着半透明淡入，下面的页面不会透过卡片和字叠在一起）
            .transition(effects.motionEnabled ? .opacity : .identity)
        }
    }
}

/// 动效关闭时的境界突破：一张静态卡（徽记背后一个静止的八卦符环）
struct StaticBreakthrough: View {
    var realm: String
    /// 新境界的徽记（按境界序号取，自定义境界名时也对）
    var emblem: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 10) {
                SceneryImage(name: emblem)
                    .frame(width: 110, height: 110)
                    // 静止的八卦符环，缩到 0.6 倍（192 × 192），正好收在卡片 40pt 的上内边距里
                    .background { RuneRing(progress: 1, elapsed: 0).scaleEffect(0.6) }
                Text("境界突破").font(Theme.songti(TypeSize.heading, .medium)).tracking(6).foregroundStyle(Theme.gold)
                Text(realm).font(.ysDisplay).foregroundStyle(Theme.ink)
                Text("道心坚定，再进一步").font(.ysCallout).foregroundStyle(Theme.inkSoft)
                Text("点击任意处或按 Esc 继续").font(.ysCaption).foregroundStyle(Theme.inkSoft.opacity(0.7)).padding(.top, 4)
            }
            .padding(.horizontal, 60).padding(.vertical, 40)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Theme.gold.opacity(0.5)))
        }
    }
}

struct TribulationScene: View {
    var realm: String
    var emblem: String
    /// 离屏定格：直接摆到这一刻（离屏窗口没有显示刷新的时钟，TimelineView 不往前走，截到的会是第一帧）
    var fixedElapsed: Double? = nil
    @State private var start = Date()
    private static let strikes: [Double] = [0.2, 0.62, 1.0]

    var body: some View {
        if let fixedElapsed {
            frame(fixedElapsed)
        } else {
            TimelineView(.animation) { timeline in
                frame(timeline.date.timeIntervalSince(start))
            }
            .onAppear { start = Date() }
        }
    }

    /// 截图用的定格（PageRenderer 用 ImageRenderer 叠在深色首页上）
    static func still(realm: String, emblem: String, elapsed: Double) -> some View {
        TribulationScene(realm: realm, emblem: emblem, fixedElapsed: elapsed)
    }

    private func frame(_ e: Double) -> some View {
        ZStack {
            Color.black.opacity(min(0.62, e / 0.35 * 0.62)).ignoresSafeArea()
            // 劫云压顶：黑幕之上、天雷之下
            Canvas { gc, size in TribulationExtras.drawClouds(&gc, size: size, e: e, strikes: Self.strikes) }
                .ignoresSafeArea()
            // 徽记与文字背后一圈径向暗晕（黑 0.55、半径 280、边缘渐隐）：夹在劫云与光柱之间，只压暗透过黑幕的页面字样
            // （“翻开修行录 / 日记 灵感”），不再和“渡劫功成”叠在同一行；金光柱、灵气、金雨仍画在它上面，不被压暗。
            // 与标题同一个 p：跟着一起由虚化实
            halo(e)
            Canvas { gc, size in draw(&gc, size: size, e: e) }
                .ignoresSafeArea()
            // 雷光闪白
            Color.white.opacity(flash(e)).ignoresSafeArea().blendMode(.plusLighter)
            title(e)
        }
    }

    /// 雷光闪白：只在第一道天雷时闪一下、亮度 0.2（三连闪接近光敏安全上限，也偏吵；高潮留给金光通天与境界名）
    private func flash(_ e: Double) -> Double {
        let d = e - Self.strikes[0]
        return d >= 0 && d < 0.35 ? 0.2 * (1 - d / 0.35) : 0
    }

    /// 标题由虚化实的进度（暗晕与标题共用）
    private static func titleProgress(_ e: Double) -> Double { max(0, min(1, (e - 1.35) / 0.9)) }

    @ViewBuilder
    private func title(_ e: Double) -> some View {
        let p = Self.titleProgress(e)
        VStack(spacing: 14) {
            // 新境界的徽记由虚化实
            SceneryImage(name: emblem)
                .frame(width: 150, height: 150)
                .shadow(color: Color(red: 1, green: 0.8, blue: 0.4).opacity(0.8), radius: 26)
                // 八卦符环托在徽记背后（不吃徽记的金色阴影）；缩放、模糊、淡入都跟着标题走
                .background { RuneRing(progress: p, elapsed: e) }
            // 主标题的第二层：宋体 22pt、字距 10、金色（画面总在黑幕上，取 Theme.gold 深色那一档，浅色模式下也够亮）
            Text("渡劫功成").font(Theme.songti(22, .medium)).tracking(10)
                .foregroundStyle(Theme.gold)
                .environment(\.colorScheme, .dark)
                // 一圈很淡的墨影：透过黑幕的页面字样再淡，也不会和这四个字咬在一起
                .shadow(color: .black.opacity(0.7), radius: 6)
            Text(realm)
                // 仪式特效可以大：境界名比横幅标题更大
                .font(Theme.songti(84, .heavy)).tracking(10)
                .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.98, green: 0.84, blue: 0.5)], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color(red: 1, green: 0.8, blue: 0.4).opacity(0.9), radius: 24)
            Text("道心坚定，再进一步").font(.ysCallout).tracking(4).foregroundStyle(Color.white.opacity(0.75))
            Text("点击任意处或按 Esc 继续").font(.ysCaption).foregroundStyle(Color.white.opacity(0.45)).padding(.top, 8)
                .opacity(e > 3 ? 1 : 0)
        }
        .scaleEffect(1.35 - 0.35 * p)
        .blur(radius: (1 - p) * 18)
        .opacity(p)
    }

    /// 标题背后的暗晕：中心黑 0.55，往外渐淡，到半径 280 处全透明。画面正中（与居中的标题同心），
    /// 缩放、模糊、淡入与标题同一个公式
    static let haloRadius: CGFloat = 280
    private func halo(_ e: Double) -> some View {
        let p = Self.titleProgress(e)
        return RadialGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black.opacity(0.48), location: 0.4),
                                      .init(color: .black.opacity(0.2), location: 0.75), .init(color: .clear, location: 1)],
                              center: .center, startRadius: 0, endRadius: Self.haloRadius)
            .frame(width: Self.haloRadius * 2, height: Self.haloRadius * 2)
            .scaleEffect(1.35 - 0.35 * p)
            .blur(radius: (1 - p) * 18)
            .opacity(p)
            .allowsHitTesting(false)
    }

    private func draw(_ gc: inout GraphicsContext, size: CGSize, e: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // 天雷
        for (index, s) in Self.strikes.enumerated() {
            let d = e - s
            guard d >= 0, d < 0.28 else { continue }
            let bolt = Self.bolt(index: index, size: size, target: center)
            let a = 1 - d / 0.28
            gc.stroke(bolt, with: .color(Color(red: 0.7, green: 0.85, blue: 1).opacity(0.5 * a)), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            gc.stroke(bolt, with: .color(Color.white.opacity(a)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
        // 雷落之处：冲击光与火花
        TribulationExtras.drawImpacts(&gc, e: e, strikes: Self.strikes, target: center)
        // 金光通天
        if e > 1.05 {
            let g = min(1, (e - 1.05) / 0.5)
            let settle = e > 2.2 ? max(0.55, 1 - (e - 2.2) * 0.3) : 1
            let width = 190 * g * settle
            let rect = CGRect(x: center.x - width / 2, y: 0, width: width, height: size.height)
            gc.fill(Path(rect), with: .linearGradient(
                Gradient(stops: [.init(color: .clear, location: 0), .init(color: Color(red: 1, green: 0.8, blue: 0.4).opacity(0.35), location: 0.3),
                                 .init(color: Color.white.opacity(0.7), location: 0.5), .init(color: Color(red: 1, green: 0.8, blue: 0.4).opacity(0.35), location: 0.7),
                                 .init(color: .clear, location: 1)]),
                startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
            // 光柱里灵气上涌
            TribulationExtras.drawPillarMotes(&gc, size: size, e: e, center: center, width: width, strength: g * settle)
        }
        // 光环
        for i in 0..<4 {
            let d = e - 1.1 - Double(i) * 0.22
            guard d > 0, d < 1.6 else { continue }
            let f = d / 1.6
            let r = 60 + f * max(size.width, size.height) * 0.55
            gc.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r * 0.42, width: r * 2, height: r * 0.84)),
                      with: .color(Color(red: 1, green: 0.84, blue: 0.5).opacity(0.7 * (1 - f))), lineWidth: 2.5 * (1 - f) + 0.5)
        }
        // 灵气四溅
        let burst = e - 1.1
        if burst > 0 {
            let colors = SpiritPalette.motes(dark: true)
            for i in 0..<90 {
                let angle = spiritNoise(i, 40) * 2 * .pi
                let speed = 140 + spiritNoise(i, 41) * 420
                let travel = speed * (1 - exp(-burst * 1.6)) / 1.6
                let x = center.x + cos(angle) * travel
                let y = center.y + sin(angle) * travel * 0.75 - burst * burst * 8 * spiritNoise(i, 42)
                let a = max(0, 1 - burst / (1.8 + spiritNoise(i, 43) * 1.4))
                guard a > 0 else { continue }
                let r = 1 + spiritNoise(i, 44) * 2.6
                let c = colors[i % colors.count]
                gc.fill(Path(ellipseIn: CGRect(x: x - r * 4, y: y - r * 4, width: r * 8, height: r * 8)),
                        with: .radialGradient(Gradient(colors: [c.opacity(a * 0.5), .clear]), center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 4))
                gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(c.opacity(a)))
            }
        }
        // 功成之后金雨徐落
        TribulationExtras.drawBlessingRain(&gc, size: size, e: e)
    }

    /// 一道折线天雷（带分叉），每次突破形状固定。从劫云的云底劈出
    private static func bolt(index: Int, size: CGSize, target: CGPoint) -> Path {
        var path = Path()
        let origin = TribulationExtras.cloudAnchor(index: index, size: size)
        var point = origin
        path.move(to: point)
        let steps = 14
        for step in 1...steps {
            let f = Double(step) / Double(steps)
            let base = CGPoint(x: point.x + (target.x - point.x) / Double(steps - step + 1), y: origin.y + (target.y - origin.y) * f)
            let jitter = (spiritNoise(index * 31 + step, 51) - 0.5) * 70 * (1 - f * 0.6)
            point = CGPoint(x: base.x + jitter, y: base.y)
            path.addLine(to: point)
            if step % 4 == 2 {
                var branch = point
                var b = Path()
                b.move(to: branch)
                for k in 1...4 {
                    branch = CGPoint(x: branch.x + (spiritNoise(index * 7 + step * 3 + k, 52) - 0.3) * 50 * (index % 2 == 0 ? 1 : -1),
                                     y: branch.y + 18 + spiritNoise(k + step, 53) * 22)
                    b.addLine(to: branch)
                }
                path.addPath(b)
                path.move(to: point)
            }
        }
        return path
    }
}
