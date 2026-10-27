import SwiftUI
import SwiftData

// 首页落笔卡（JournalComposer 的 compact 形态）随时辰多出的几样（#4）：
// - 晨（05:00–10:59）：标题下一行“晨课 · 立今日一愿”，立了之后变成一行“今日一愿：…”（全天都在，可改）；
// - 全天：正文框上一行“问心签”，正文空着时框里的提示语就是当日签文，可“换一签”“答此签”；
// - 暮夜（18:00–04:59）：标题下一行（与晨课同一个位置）一枚“晚课 · 三省”签，开着时正文框换成三格，一键合成一篇日省入卷。
// 时段、题库、合成格式都是 Core/DailyPrompts.swift 的纯函数；这里只管画和存偏好（AppPreferences.defaults，不进数据模型）。
// 时刻一律取 SkyTime.fixedMinute ?? 现在：离屏渲染用 APT_RENDER_CLOCK 就能截到晨课、晚课。

// MARK: - 时刻

/// 落笔卡此刻的时辰：今天、当天第几分钟、哪一段、晚课记到哪天
struct DailyRiteMoment: Equatable {
    var today: LocalDay
    var minute: Int

    var phase: DailyRitePhase { DailyRite.phase(minute: minute) }
    /// 晚课记到哪天（00:00–04:59 是前一天，与暮夜同在 05:00 分界）；一愿也按这一天取（凌晨看到的还是昨天立的愿）
    var ritualDay: LocalDay { DailyRite.ritualDay(minute: minute, today: today) }
}

/// 给内容一个当前时刻：离屏时固定（SkyTime.fixedMinute），平时每分钟报一次时。只有落笔卡跟着重算，页面其余部分不动
struct DailyRiteClock<Content: View>: View {
    @ViewBuilder var content: (DailyRiteMoment) -> Content

    var body: some View {
        if let fixed = SkyTime.fixedMinute {
            content(DailyRiteMoment(today: .today(), minute: Int(fixed)))
        } else {
            TimelineView(.everyMinute) { context in
                content(DailyRiteMoment(today: LocalDay(date: context.date), minute: ClockTime.minutes(of: context.date)))
            }
        }
    }
}

// MARK: - 偏好读写

/// 问心签、一愿、过期清理：都读写 AppPreferences.defaults（与 @AppStorage 同一份；调试实例、离屏渲染各用各的）
@MainActor
enum DailyRiteStore {
    static func answered(_ defaults: UserDefaults = AppPreferences.defaults) -> [Int: LocalDay] {
        DailyPrompts.decodeAnswered(defaults.dictionary(forKey: DailyRite.answeredKey))
    }

    /// 那天的签（按那天“换一签”的次数与答过的签）
    static func slip(on day: LocalDay, defaults: UserDefaults = AppPreferences.defaults) -> DailyPrompt {
        DailyPrompts.pick(on: day, skips: defaults.integer(forKey: DailyRite.skipKey(day)), answered: answered(defaults))
    }

    /// 这一签是不是那天答的
    static func isAnswered(_ prompt: DailyPrompt, on day: LocalDay, defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        answered(defaults)[prompt.id] == day
    }

    /// 换一签：那天的次数 +1
    static func skip(on day: LocalDay, defaults: UserDefaults = AppPreferences.defaults) {
        defaults.set(defaults.integer(forKey: DailyRite.skipKey(day)) + 1, forKey: DailyRite.skipKey(day))
    }

    /// 入卷之后：正文以「签文」开头就记为那天答过（半年内不再抽到）。返回答的那一签
    @discardableResult
    static func noteAnswer(body: String, day: LocalDay, defaults: UserDefaults = AppPreferences.defaults) -> DailyPrompt? {
        guard let prompt = DailyPrompts.answered(in: body) else { return nil }
        defaults.set(DailyPrompts.recording(prompt.id, on: day, into: defaults.dictionary(forKey: DailyRite.answeredKey)),
                     forKey: DailyRite.answeredKey)
        return prompt
    }

    /// 立愿 / 改愿：空的就撤去；改成了另一件事时，晚课里勾过的“已成 / 未成”作废。顺手清掉过期的按日记录
    static func setVow(_ text: String, on day: LocalDay, defaults: UserDefaults = AppPreferences.defaults) {
        let vow = DailyRite.cleanVow(text)
        if vow != defaults.string(forKey: DailyRite.vowKey(day)) {
            defaults.removeObject(forKey: DailyRite.vowDoneKey(day))
        }
        if vow.isEmpty {
            defaults.removeObject(forKey: DailyRite.vowKey(day))
        } else {
            defaults.set(vow, forKey: DailyRite.vowKey(day))
        }
        prune(today: day, defaults: defaults)
    }

    /// 删掉过期的一愿、已成与否、明日第一件事（60 天前）、往日的换签次数与前天以前的立愿草稿
    static func prune(today: LocalDay, defaults: UserDefaults = AppPreferences.defaults) {
        for key in DailyRite.staleKeys(defaults.dictionaryRepresentation().keys, today: today) {
            defaults.removeObject(forKey: key)
        }
    }

    /// 晚课三格是不是都空着（三格写了字时，跨过 05:00 也不把它收起）
    static func eveningDraftBlank(_ defaults: UserDefaults = AppPreferences.defaults) -> Bool {
        ["done", "stuck", "next"].allSatisfy {
            (defaults.string(forKey: DailyRite.eveningDraftKey($0)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 那天的晚课已毕没有：修行录里那天有一篇“晚课 · 三省”的复盘（删掉那篇就算没做）。只在判定开合时查一次（按日期谓词，数一数）
    static func eveningSaved(on day: LocalDay, context: ModelContext) -> Bool {
        ((try? context.fetchCount(DailyRite.eveningEntries(on: day))) ?? 0) > 0
    }
}

extension DailyRite {
    /// 那天修行录里由晚课合成的日省：按日期、标题、类型取（只有几篇，5 年数据也不整表取）
    static func eveningEntries(on day: LocalDay) -> FetchDescriptor<JournalEntry> {
        let key = day.key, title = eveningTitle, review = JournalKind.review.rawValue
        return FetchDescriptor<JournalEntry>(predicate: #Predicate<JournalEntry> {
            $0.dateKey == key && $0.title == title && $0.kind == review
        })
    }
}

// MARK: - 晚课合成入卷

@MainActor
enum DailyRiteActions {
    /// 晚课三格合成一篇日省入卷（复盘，周期“日省”，标题“晚课 · 三省”；修为与落笔仪式照常，走 JournalActions.save）。
    /// day 是 DailyRite.ritualDay（00:00–04:59 是前一天，那时不记钟点）。入卷后记下“明日第一件事”（次日晨课的“昨夜所定”；
    /// 这一篇没写时不动已有的——同一晚第二篇留空不会删掉第一篇定下的），并清空三格草稿。
    /// 晚课已毕不另记：修行录里那天有这一篇就是已毕。三格全空时什么都不做，返回 nil
    @discardableResult
    static func saveEvening(done: String, stuck: String, next: String, day: LocalDay, today: LocalDay = .today(), now: Date = Date(),
                            context: ModelContext, effects: EffectsCenter,
                            defaults: UserDefaults = AppPreferences.defaults) -> (entry: JournalEntry, gain: Int)? {
        let vow = defaults.string(forKey: DailyRite.vowKey(day)) ?? ""
        let flag = defaults.string(forKey: DailyRite.vowDoneKey(day))
        let vowDone: Bool? = flag == "1" ? true : (flag == "0" ? false : nil)
        guard let body = DailyRite.eveningReview(vow: vow, vowDone: vowDone, done: done, stuck: stuck, next: next) else { return nil }
        let entry = JournalEntry(kind: .review, title: DailyRite.eveningTitle, body: body, dateKey: day.key)
        entry.period = ReviewPeriod.day.rawValue
        if day == today { entry.minute = ClockTime.minutes(of: now) }
        let gain = JournalActions.save(entry, context: context, effects: effects)
        let first = DailyRite.cleanVow(next)
        if !first.isEmpty { defaults.set(first, forKey: DailyRite.nextFirstKey(day)) }
        for field in ["done", "stuck", "next"] { defaults.set("", forKey: DailyRite.eveningDraftKey(field)) }
        DailyRiteStore.prune(today: today, defaults: defaults)
        return (entry, gain)
    }
}

// MARK: - 小金印

/// 愿签上的小金印（“愿”“成”）：play 且动效开时，出现那一下从 2.2 倍、-16° 弹簧落到 1 倍、-6°，一圈金色涟漪散开；
/// 平时（关动效、或只是重新进页）直接是落定的样子
struct RiteGoldSeal: View {
    var glyph: String
    var play = false
    var size: CGFloat = 20
    @Environment(\.spiritMotion) private var motion
    @State private var landed: Bool?
    @State private var ripple = false

    var body: some View {
        let down = landed ?? true
        ZStack {
            if landed != nil {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.65), lineWidth: 1.2)
                    .frame(width: size, height: size)
                    .scaleEffect(ripple ? 2.3 : 0.9)
                    .opacity(ripple ? 0 : (down ? 0.85 : 0))
            }
            face
                .scaleEffect(down ? 1 : 2.2)
                .rotationEffect(.degrees(down ? -6 : -16))
                .opacity(down ? 1 : 0)
                .shadow(color: Theme.gold.opacity(down ? 0.35 : 0), radius: down ? 3 : 10)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard play, motion, landed == nil else { return }
            landed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(Motion.ceremony) { landed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.easeOut(duration: 0.7)) { ripple = true }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [Theme.gold, Theme.gold.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .strokeBorder(Theme.onJade.opacity(0.7), lineWidth: 0.8)
                .padding(size * 0.12)
            Text(glyph).font(Theme.songti(size * 0.52, .bold)).foregroundStyle(Theme.onJade)
        }
        .frame(width: size, height: size)
    }
}

/// 愿签、晨课的底：淡金纸笺（与卡片同族，比正文框轻）
private struct RiteSlipBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.goldSoft.opacity(0.55), in: shape)
            .overlay(shape.strokeBorder(Theme.gold.opacity(0.22)))
    }
}

// MARK: - 晨课 · 今日一愿

/// 晨课与今日一愿：晨里没立愿时是“晨课 · 立今日一愿”一行框；立了之后（全天）是“今日一愿：…　改”。
/// 昼、暮夜没立愿时整块不显示（不催）；但框里正写着（有焦点或写了字）时，过了 11:00 也留着，不会打到一半整块消失。
/// 外面按 ritualDay 加 .id，跨过 05:00 换一天的键。自带上边距（不显示时不占空隙）
struct DailyVowStrip: View {
    var moment: DailyRiteMoment
    @AppStorage private var vow: String
    /// 晚课里勾过“已成”（"1"）：愿签上的小金印换成“成”字
    @AppStorage private var vowDone: String
    @AppStorage private var lastNight: String
    /// 立愿框写了一半的字：按这一天记，第二天早上不会预填昨天的（“不改了”也清掉）
    @AppStorage private var draft: String
    @Environment(\.spiritMotion) private var motion
    @FocusState private var inputFocused: Bool
    @State private var editing = false
    /// 刚在这里立的愿：小金印落一下
    @State private var justVowed = false

    init(moment: DailyRiteMoment) {
        self.moment = moment
        _vow = AppStorage(wrappedValue: "", DailyRite.vowKey(moment.ritualDay))
        _vowDone = AppStorage(wrappedValue: "", DailyRite.vowDoneKey(moment.ritualDay))
        _lastNight = AppStorage(wrappedValue: "", DailyRite.nextFirstKey(moment.ritualDay.adding(days: -1)))
        _draft = AppStorage(wrappedValue: "", DailyRite.vowDraftKey(moment.ritualDay))
    }

    var body: some View {
        let morning = moment.phase == .morning
        if !vow.isEmpty && !editing {
            vowLine.padding(.top, 12)
        } else if morning || editing || inputFocused || !DailyRite.cleanVow(draft).isEmpty {
            vowInput(suggestion: vow.isEmpty && !editing ? DailyRite.cleanVow(lastNight) : "").padding(.top, 12)
        }
    }

    private var vowLine: some View {
        HStack(spacing: 10) {
            RiteGoldSeal(glyph: vowDone == "1" ? "成" : "愿", play: justVowed)
            (Text(vowDone == "1" ? "今日一愿已成：" : "今日一愿：").font(.ysCaption).foregroundStyle(Theme.inkSoft)
             + Text(vow).font(Theme.songti(TypeSize.callout, .medium)).foregroundStyle(Theme.ink))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("改") {
                draft = vow
                justVowed = false
                withAnimation(motion ? Motion.standard : nil) { editing = true }
            }
            .buttonStyle(.inlineAction())
            .help("改写今天的一愿；清空后点“撤去”就不立了")
        }
        .modifier(RiteSlipBackground())
        .accessibilityElement(children: .combine)
        .accessibilityLabel((vowDone == "1" ? "今日一愿已成：" : "今日一愿：") + vow)
    }

    private func vowInput(suggestion: String) -> some View {
        let text = DailyRite.cleanVow(draft)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sunrise").font(.system(size: TypeSize.caption, weight: .medium)).foregroundStyle(Theme.gold)
                    .accessibilityHidden(true)
                Text(editing ? "改今日一愿" : "晨课 · 立今日一愿").font(Theme.songti(TypeSize.callout, .semibold)).tracking(1)
                    .foregroundStyle(Theme.gold)
                Spacer(minLength: 8)
                if editing {
                    // 不改了：草稿一并清掉，免得旧愿留在框里、哪天顺手又立一遍
                    Button("不改了") {
                        draft = ""
                        withAnimation(motion ? Motion.standard : nil) { editing = false }
                    }
                    .buttonStyle(.inlineAction())
                }
            }
            if !suggestion.isEmpty {
                // 昨夜晚课写的“明日第一件事”：点一下直接立为今日一愿（那篇晚课删掉了就不再提）
                LastNightSuggestion(day: moment.ritualDay.adding(days: -1), text: suggestion) { commit(suggestion) }
            }
            HStack(spacing: 8) {
                TextField("今天最想做成的一件事是？", text: $draft)
                    .focused($inputFocused)
                    .onSubmit { if !text.isEmpty || editing { commit(draft) } }
                Button(editing && text.isEmpty ? "撤去" : "立愿") { commit(draft) }
                    .buttonStyle(.yunshanCompact)
                    .disabled(text.isEmpty && !editing)
                    .help(editing && text.isEmpty ? "撤去今天的一愿" : "立下今天最想做成的一件事；晚课时可勾“已成 / 未成”")
            }
        }
        .modifier(RiteSlipBackground())
    }

    private func commit(_ text: String) {
        let clean = DailyRite.cleanVow(text)
        guard !clean.isEmpty || editing else { return }
        DailyRiteStore.setVow(clean, on: moment.ritualDay)
        draft = ""
        inputFocused = false
        justVowed = !clean.isEmpty
        withAnimation(motion ? Motion.standard : nil) { editing = false }
    }
}

/// “昨夜所定：先改第二节 · 立为今日一愿”：只在昨夜那篇“晚课 · 三省”还在修行录里时出现（删掉了就不再提）
private struct LastNightSuggestion: View {
    var text: String
    var onPick: () -> Void
    @Query private var evenings: [JournalEntry]

    init(day: LocalDay, text: String, onPick: @escaping () -> Void) {
        self.text = text
        self.onPick = onPick
        _evenings = Query(DailyRite.eveningEntries(on: day))
    }

    var body: some View {
        if !evenings.isEmpty {
            Button(action: onPick) {
                HStack(spacing: 6) {
                    Image(systemName: "moon.stars").font(.system(size: TypeSize.micro, weight: .semibold)).accessibilityHidden(true)
                    (Text("昨夜所定：").foregroundStyle(Theme.inkSoft) + Text(text).foregroundStyle(Theme.ink))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("· 立为今日一愿").foregroundStyle(Theme.gold).fixedSize()
                }
                .font(.ysCaption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.card.opacity(0.85), in: Capsule())
                .overlay(CapsuleRing().fill(Theme.gold.opacity(0.35), style: FillStyle(eoFill: true)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("把昨夜晚课写的“明日第一件事”立为今日一愿")
        }
    }
}

// MARK: - 问心签

/// 正文框上的一行小字：“问心签 · 心境”（正文空着，签文就是框里的提示语）或“问心签 · 今天哪一刻最专注？”（写了字之后）。
/// 右侧就地两个小操作：换一签 ↻（动效开时签文淡入淡出、↻ 转一圈）、答此签（在正文开头插「签文」）；今天答过写“今日已答”
struct AskSlipLine: View {
    var prompt: DailyPrompt
    /// 正文空着：签文已在框里当提示语，这一行只写类别，不重复
    var bodyEmpty: Bool
    var answeredToday: Bool
    var onSkip: () -> Void
    var onAnswer: () -> Void
    @Environment(\.spiritMotion) private var motion
    @State private var spin = 0.0

    var body: some View {
        HStack(spacing: 8) {
            SlipTag()
            HStack(spacing: 0) {
                Text("问心签").font(Theme.songti(TypeSize.callout, .semibold)).tracking(1).foregroundStyle(Theme.gold).fixedSize()
                Group {
                    if bodyEmpty {
                        Text(" · \(prompt.category.label)").foregroundStyle(Theme.inkSoft.opacity(0.85)).fixedSize()
                    } else {
                        Text(" · \(prompt.text)").foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.ysCaption)
                .id(prompt.id)
                .transition(.opacity)
            }
            .help("今日问心签：\(prompt.text)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("今日问心签：\(prompt.text)")
            Spacer(minLength: 6)
            Button {
                withAnimation(motion ? .easeInOut(duration: 0.45) : nil) { spin += 360 }
                withAnimation(motion ? Motion.reveal : nil) { onSkip() }
            } label: {
                HStack(spacing: 3) {
                    Text("换一签")
                    Image(systemName: "arrow.clockwise").rotationEffect(.degrees(spin)).accessibilityHidden(true)
                }
            }
            .buttonStyle(.inlineAction())
            .help("换一支签（今天换过的不会再出现，答过的半年内不再抽到）")
            if answeredToday {
                Label("今日已答", systemImage: "checkmark").labelStyle(.titleAndIcon)
                    .font(.system(size: TypeSize.caption, weight: .medium)).foregroundStyle(Theme.positive)
                    .fixedSize()
            } else {
                Button("答此签", action: onAnswer)
                    .buttonStyle(.inlineAction(Theme.gold))
                    .help("在正文开头写上「\(prompt.text)」，接着写你的回答")
            }
        }
    }
}

/// 一支竹签的小样：淡金竖签，写一个“签”字
private struct SlipTag: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        Text("签")
            .font(Theme.songti(9.5, .bold))
            .foregroundStyle(Theme.gold)
            .frame(width: 13, height: 19)
            .background(Theme.goldSoft, in: shape)
            .overlay(shape.strokeBorder(Theme.gold.opacity(0.45), lineWidth: 0.8))
            .rotationEffect(.degrees(-4))
            .accessibilityHidden(true)
    }
}

// MARK: - 晚课 · 三省

/// 暮夜时标题下一行（与晨课同一个位置，标题行三个时段都一样）：一枚“晚课 · 三省”签加一句说明。
/// 这一晚修行录里已有“晚课 · 三省”时签写“晚课已毕”（删掉那篇就回到“晚课 · 三省”）；开着三格时签是金底。自带上边距
struct EveningRiteRow: View {
    var day: LocalDay
    var open: Bool
    /// 点签：要开（true）还是收（false）
    var onToggle: (Bool) -> Void
    @Query private var saved: [JournalEntry]

    init(day: LocalDay, open: Bool, onToggle: @escaping (Bool) -> Void) {
        self.day = day
        self.open = open
        self.onToggle = onToggle
        _saved = Query(DailyRite.eveningEntries(on: day))
    }

    var body: some View {
        let mode: EveningRiteChip.Mode = open ? .open : (saved.isEmpty ? .closed : .done)
        HStack(spacing: 10) {
            EveningRiteChip(state: mode) { onToggle(!open) }
            if let note = note(mode) {
                Text(note).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    private func note(_ mode: EveningRiteChip.Mode) -> String? {
        switch mode {
        case .closed: "三格写完，一键合成日省"
        case .done: saved.count > 1 ? "今晚已合成 \(saved.count) 篇日省 · 点签再写一篇" : "今晚的日省已入卷 · 点签再写一篇"
        case .open: nil
        }
    }
}

/// 晚课的签：收着时淡金“晚课 · 三省”，开着时金底，今晚已合成入卷时写“晚课已毕”
struct EveningRiteChip: View {
    enum Mode { case closed, open, done }
    var state: Mode
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        let on = state == .open
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: state == .done ? "checkmark" : "moon.stars")
                    .font(.system(size: TypeSize.micro, weight: .semibold))
                    .accessibilityHidden(true)
                Text(label).font(.system(size: TypeSize.caption, weight: on ? .semibold : .medium)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(on ? Theme.onJade : (state == .done ? Theme.positive : Theme.gold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // 柔光只加在底色胶囊上（描边不带阴影）：胶囊描边连着阴影交给图层画时两侧会多出两截细竖线，
            // 又不用 .drawingGroup()（会逼应用起一套 Metal 渲染，启动内存暴涨，见 audit-energy P0-2）
            .background {
                Capsule()
                    .fill(on ? AnyShapeStyle(LinearGradient(colors: [Theme.gold, Theme.gold.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                             : AnyShapeStyle(Theme.goldSoft.opacity(hover ? 0.95 : (scheme == .dark ? 0.8 : 0.65))))
                    .shadow(color: on ? Theme.gold.opacity(0.3) : .clear, radius: on ? 5 : 0)
            }
            .overlay(CapsuleRing().fill(Theme.gold.opacity(on ? 0.6 : 0.4), style: FillStyle(eoFill: true)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var label: String {
        state == .done ? "晚课已毕" : "晚课 · 三省"
    }

    private var help: String {
        switch state {
        case .closed: "晚课 · 三省：今日所成、卡在何处、明日第一件事，填完一键合成日省入卷"
        case .open: "收起三省，回到普通正文框（三格里写的会留着）"
        case .done: "今晚的日省已入卷；点一下再写一篇"
        }
    }
}

/// 晚课三格：今日所成 / 卡在何处 / 明日第一件事（草稿 draft.dashboard.evening.*，切页、重启都不丢）。
/// 有今日一愿时最上面一行可勾“已成 / 未成”（勾已成时愿签上落一枚“成”字小金印）。
/// “合成日省入卷”（⌘↩）生成带【所得】【所失】【下一步】的日省；“改写一段话”回到普通正文框，三格内容留在草稿里。
/// 外面按 day（ritualDay）加 .id
struct EveningRitePanel: View {
    var day: LocalDay
    var today: LocalDay
    /// ⌘N 落笔、刚打开三格时 +1：光标进第一格
    var focusTick: Int
    var onClose: () -> Void
    var onSaved: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    @Environment(\.spiritMotion) private var motion
    @AppStorage(DailyRite.eveningDraftKey("done")) private var done = ""
    @AppStorage(DailyRite.eveningDraftKey("stuck")) private var stuck = ""
    @AppStorage(DailyRite.eveningDraftKey("next")) private var next = ""
    @AppStorage private var vow: String
    /// "1" 已成、"0" 未成、"" 没勾
    @AppStorage private var vowDone: String
    @FocusState private var focus: Field?
    @State private var stamped = false

    enum Field: Hashable { case done, stuck, next }

    init(day: LocalDay, today: LocalDay, focusTick: Int, onClose: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.day = day
        self.today = today
        self.focusTick = focusTick
        self.onClose = onClose
        self.onSaved = onSaved
        _vow = AppStorage(wrappedValue: "", DailyRite.vowKey(day))
        _vowDone = AppStorage(wrappedValue: "", DailyRite.vowDoneKey(day))
    }

    private var canSave: Bool {
        DailyRite.eveningReview(vow: "", vowDone: nil, done: done, stuck: stuck, next: next) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !vow.isEmpty { vowCheck }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                row("今日所成", "今天做成了什么？哪怕一小步。", text: $done, field: .done, then: .stuck)
                row("卡在何处", "哪里卡住了？为什么？", text: $stuck, field: .stuck, then: .next)
                row("明日第一件事", "明天醒来先做的那一件。", text: $next, field: .next, then: nil)
            }
            // 入卷时纸笺从三格这里卷起飞走（与正文框同一个锚点；两者不会同时在屏上）
            .ritualAnchor(.composer)
            WrapTrailingRow {
                HStack(spacing: 12) {
                    Button { onClose() } label: { Label("改写一段话", systemImage: "text.alignleft") }
                        .buttonStyle(.inlineAction())
                        .help("回到普通正文框；三格里写的会留着")
                    if day != today {
                        Text("记在 \(day.label(relativeTo: today))").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                            .fixedSize()
                            .help("凌晨五点以前写的晚课，算前一天的三省")
                    }
                }
                submitButton
            }
        }
        .onChange(of: focusTick, initial: false) { _, _ in focus = .done }
        .onAppear { if focusTick > 0 { focus = .done } }
    }

    private var vowCheck: some View {
        HStack(spacing: 10) {
            let glyph = vowDone == "1" ? "成" : "愿"
            RiteGoldSeal(glyph: glyph, play: stamped && glyph == "成").id(glyph)
            (Text("今日一愿：").font(.ysCaption).foregroundStyle(Theme.inkSoft)
             + Text(vow).font(Theme.songti(TypeSize.callout, .medium)).foregroundStyle(Theme.ink))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                choice("已成", value: "1")
                choice("未成", value: "0")
            }
            .fixedSize()
        }
        .modifier(RiteSlipBackground())
    }

    /// 已成 / 未成：选中再点一下取消
    private func choice(_ label: String, value: String) -> some View {
        let on = vowDone == value
        let tint = value == "1" ? Theme.gold : Theme.inkSoft
        return Button {
            stamped = value == "1" && !on
            withAnimation(motion ? Motion.quick : nil) { vowDone = on ? "" : value }
        } label: {
            Text(label)
                .font(.system(size: TypeSize.caption, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? Theme.onJade : tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(on ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.card.opacity(0.85)), in: Capsule())
                .overlay(CapsuleRing().fill(on ? Color.clear : tint.opacity(0.4), style: FillStyle(eoFill: true)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(value == "1" ? "今日一愿已成：合成日省时写“（已成）”" : "今日一愿未成：合成日省时写“（未成）”，明天再来")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(_ label: String, _ placeholder: String, text: Binding<String>, field: Field, then nextField: Field?) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.songti(TypeSize.callout, .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize()
                .gridColumnAlignment(.trailing)
            RiteField(placeholder: placeholder, text: text, focused: focus == field)
                .focused($focus, equals: field)
                .onSubmit { focus = nextField }
                .accessibilityLabel(label)
        }
    }

    private var submitButton: some View {
        Button(action: save) {
            Label("合成日省入卷", systemImage: "seal").lineLimit(1)
        }
        .buttonStyle(.yunshanPrimary)
        .fixedSize()
        .keyCommand(.composeSubmit)
        // 朱印盖在这颗按钮旁边
        .sealAnchor()
        .help(KeyCommand.composeSubmit.help("合成日省入卷：带【所得】【所失】【下一步】，修为 +15"))
        .disabled(!canSave)
    }

    private func save() {
        guard canSave else { return }
        guard DailyRiteActions.saveEvening(done: done, stuck: stuck, next: next, day: day, today: today,
                                           context: context, effects: effects) != nil else { return }
        // 偏好已在 saveEvening 里清空；这里同步一下本视图的草稿
        done = ""
        stuck = ""
        next = ""
        focus = nil
        onSaved()
    }
}

/// 三格用的单行（可长到 4 行）输入框：外观同云山输入框，焦点由外面的 .focused 控制（不再套一层自带焦点的样式）
private struct RiteField: View {
    var placeholder: String
    @Binding var text: String
    var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .font(.ysCallout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.paper.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(focused ? Theme.azure.opacity(0.65) : Theme.line, lineWidth: focused ? 1.3 : 1))
            .frame(maxWidth: .infinity)
    }
}

/// 胶囊细边（1pt）：用“外胶囊减内胶囊”的填充来画，不用 strokeBorder——
/// 胶囊描边交给图层画时，两侧会多出两截细竖线（离屏渲染里可复现；心境按钮那里是用 .drawingGroup() 绕开的，那会起一套 Metal 渲染）
struct CapsuleRing: Shape {
    var width: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        let inner = rect.insetBy(dx: width, dy: width)
        if inner.width > 0, inner.height > 0 {
            path.addRoundedRect(in: inner, cornerSize: CGSize(width: inner.height / 2, height: inner.height / 2))
        }
        return path
    }
}
