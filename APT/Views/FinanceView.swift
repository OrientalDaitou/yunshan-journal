import SwiftUI
import SwiftData
import Charts

struct FinanceView: View {
    /// 标签。原始值存在 @AppStorage("finance.tab")：月度仍存“月度总览”这个旧值（原来存的照样认得），界面上写“月度”；
    /// 已并进“月度”的“月度修习录”读不到时回退到月度。
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "月度总览", transactions = "交易明细", thrift = "节流与账单"
        var id: String { rawValue }
        var title: String { self == .overview ? "月度" : rawValue }
    }

    @Environment(\.modelContext) private var context
    @Query private var stores: [FinanceStore]
    @AppStorage("finance.tab") private var tabRaw = Tab.overview.rawValue
    @State private var month: String?
    @State private var showImport = false
    @State private var showManual = false
    @State private var showSources = false
    @State private var showRules = false
    @State private var editing: FinanceTransaction?
    /// 交易明细的筛选：全部 / 只看待确认 / 某个类别（待确认小标点过来时设成只看待确认）
    @State private var txFilter = TransactionsTab.all
    /// 交易明细看全部月份（月份列表的第一项）
    @State private var allMonths = false

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .overview }

    /// 账本随 FinanceStore 变化自动重新解码（FinanceService 内部按版本缓存，同一版本只解码一次）。
    /// 拿到的是账本连同它的派生数据：同一版账本是同一个对象，各月账目、月卷草稿等算过一次就记着。
    private var loaded: Result<FinanceLedgerIndex, Error> {
        _ = stores.first?.updatedAt
        return Result { try FinanceService.loadIndex(context) }
    }

    var body: some View {
        let result = loaded
        let readable = (try? result.get()) != nil
        // 全新的账本（没有交易、导入记录和分类记忆）：导入与手记都在正文的留白里，横幅不放。
        // 撤销过导入、只剩分类记忆时横幅照旧，下拉里还能管理它们
        let blank = (try? result.get()).map { $0.ledger.transactions.isEmpty && $0.ledger.sources.isEmpty && $0.ledger.merchantRules.isEmpty } ?? false
        PageScaffold(page: .finance) {
            switch result {
            case .failure(let failure):
                Hint("账本读取失败：\(failure.localizedDescription)。为避免丢失数据，没有做任何写入。", tone: .error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .xianCard()
            case .success(let index):
                content(index)
            }
        } actions: {
            // 横幅只留两个操作（账本读不出来时不放）：月份挪到标签行，低频的导入记录、分类记忆收进“导入银行 CSV”的下拉
            if readable && !blank {
                importMenu
                Button { showManual = true } label: { Label("手记一笔", systemImage: "square.and.pencil") }
                    .keyCommand(.newExpense)
                    .help(KeyCommand.newExpense.help("手记一笔"))
            }
        }
        .sheet(isPresented: $showImport) { FinanceImportSheet() }
        .sheet(isPresented: $showManual) { ManualExpenseSheet() }
        .sheet(isPresented: $showSources) { FinanceSourcesSheet() }
        .sheet(isPresented: $showRules) { FinanceRulesSheet() }
        .sheet(item: $editing) { row in TransactionEditor(row: row) }
        .onAppear { if AppRouter.shared.financeSearch != nil { tabRaw = Tab.transactions.rawValue } }
        .onChange(of: AppRouter.shared.financeSearch) { _, query in if query != nil { tabRaw = Tab.transactions.rawValue } }
    }

    @ViewBuilder
    private func content(_ index: FinanceLedgerIndex) -> some View {
        let months = index.months
        // 没手动选月份时：本月已有交易就看本月（刚记的账一打开就能看到），否则看最近一个已结束且覆盖整月的月份。
        // 三个标签同一条规则；月卷存在半个月上时，保存那一步会提醒
        let current = String(LocalDay.today().key.prefix(7))
        let hasCurrent = index.hasTransactions(in: current)
        let pinned = month.flatMap { months.contains($0) ? $0 : nil }
        let selected = pinned ?? (hasCurrent ? current : index.defaultMonth())
        let facts = index.monthFacts(selected)

        if index.ledger.transactions.isEmpty {
            // 一笔都没有：两个入口都在这张留白里，横幅不再放（一屏只放一处）
            OrnamentEmpty(.finance) {
                Button { showImport = true } label: { Label("导入银行 CSV", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(.yunshanPrimary)
                    .help("导入 CommBank 网银导出的 CSV；原始文件完整保存在本机")
                Button { showManual = true } label: { Label("手记一笔", systemImage: "square.and.pencil") }
                    // 全新账本时横幅不放，⌘N 由这颗按钮接（一览里写着灵石账簿 ⌘N 手记一笔）
                    .keyCommand(.newExpense)
                    .help(KeyCommand.newExpense.help("手记一笔"))
            }
            .xianCard()
            .ysEntrance(order: 0)
        } else {
            toolbar(index, months: months, selected: selected, facts: facts)
                .ysEntrance(order: 0)
            switch tab {
            case .overview:
                // 只依赖这一版账本与所选月份：页面上开关弹窗、点修改这类无关的变化不让整页重算
                FinanceOverviewTab(index: index, month: selected, onPickMonth: { month = $0 }).equatable()
            case .transactions:
                TransactionsTab(index: index, month: selected, filter: $txFilter, allMonths: $allMonths, onEdit: { editing = $0 })
            case .thrift:
                ThriftTab(index: index, month: selected)
            }
        }
    }

    /// 标签行即工具条：标签 · 月份切换（“‹ 2026年10月 ›”，没导全时挂带圆圈感叹号小图标的“未导全”）· 待确认小标。月份只在这里出现一次。
    private func toolbar(_ index: FinanceLedgerIndex, months: [String], selected: String, facts: MonthFacts) -> some View {
        let otherReview = index.awaitingReviewCount - index.awaitingReviewCount(in: selected)
        let total = facts.needsReviewCount + otherReview
        return HStack(spacing: 12) {
            SegmentedTabs(options: Tab.allCases.map { ($0.rawValue, $0.title) }, selection: $tabRaw)
            Spacer(minLength: 12)
            MonthStepper(months: months, selected: selected,
                         showsAll: tab == .transactions && allMonths, offersAll: tab == .transactions,
                         facts: facts, manualOnly: index.ledger.sources.isEmpty, pinned: month != nil,
                         onPick: { m in allMonths = false; month = m },
                         onAll: { allMonths = true })
            if total > 0 {
                let here = selected == String(LocalDay.today().key.prefix(7)) ? "本月" : MonthKey.label(selected)
                Button {
                    txFilter = TransactionsTab.review
                    // 这个月已清，待确认都在别的月份：直接看全部月份
                    if facts.needsReviewCount == 0 { allMonths = true }
                    tabRaw = Tab.transactions.rawValue
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.warning).frame(width: 6, height: 6)
                        Text("待确认 \(total)").monospacedDigit()
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .font(.system(size: TypeSize.callout, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.warning.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(here) \(facts.needsReviewCount) 笔 · 其他月份 \(otherReview) 笔；点一下只看待确认")
                .accessibilityLabel("待确认 \(total) 笔")
            }
        }
    }

    private var importMenu: some View {
        FinanceImportButton(onImport: { showImport = true }, onSources: { showSources = true }, onRules: { showRules = true })
    }
}

/// 页首的“导入银行 CSV”：主体点一下直接导入；右端“⌄”是下拉，收着低频的导入记录（可撤销最近一次）和分类记忆。
/// （套了自绘按钮样式的 Menu(primaryAction:) 不显示下拉箭头、只能长按，所以拼成一个分体按钮）
struct FinanceImportButton: View {
    var onImport: () -> Void
    var onSources: () -> Void
    var onRules: () -> Void

    var body: some View {
        Button(action: onImport) {
            HStack(spacing: 12) {
                Label("导入银行 CSV", systemImage: "tray.and.arrow.down")
                Rectangle().fill(Theme.onJadeFill.opacity(0.35)).frame(width: 1, height: 16)
                Image(systemName: "chevron.down").font(.system(size: TypeSize.micro, weight: .bold))
            }
        }
        .buttonStyle(.yunshanPrimary)
        .help("导入 CommBank 网银导出的 CSV")
        .overlay(alignment: .trailing) {
            // 盖在右端“⌄”上的下拉区
            Menu {
                Button("导入记录与撤销…", action: onSources)
                Button("分类记忆…", action: onRules)
            } label: {
                Color.clear.frame(width: 42, height: 40).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("导入记录（可撤销最近一次导入）、分类记忆")
            .accessibilityLabel("更多导入操作")
        }
    }
}

// MARK: - 月份切换

/// “‹ 2026年10月 ›”：箭头切到上 / 下一个有记录的月份，点中间弹出月份列表（交易明细多一项“全部月份”）。
/// 整月没导全时旁边挂一个灰色小标“! 未导全”（圆圈感叹号小图标 + 字；以前写“部分”，看不出是什么的部分），悬停看笔数和账户数。
/// 只记手记、从没导入过银行账单的账簿不挂（每个月都“没导全”，挂了像在催人去导账单）：与岁月长卷同一条判断（PartialMonthRule）。
private struct MonthStepper: View {
    static let all = "__all"
    /// 有记录的月份，新的在前
    var months: [String]
    var selected: String
    /// 交易明细正看全部月份
    var showsAll: Bool
    var offersAll: Bool
    var facts: MonthFacts
    /// 账簿从没导入过银行账单（只有手记）
    var manualOnly: Bool
    var pinned: Bool
    var onPick: (String) -> Void
    var onAll: () -> Void

    var body: some View {
        let index = months.firstIndex(of: selected)
        let older = index.flatMap { $0 + 1 < months.count ? months[$0 + 1] : nil }
        let newer = index.flatMap { $0 > 0 ? months[$0 - 1] : nil }
        let coverage = facts.coverageConfirmed ? "已确认银行导出范围覆盖整月" : facts.fullMonth ? "导入范围覆盖整月"
            : manualOnly ? "账目只含手记，还没导入银行账单" : "导入范围未覆盖整月"
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                arrow("chevron.left", label: "上一个月", target: older, command: .monthPrev)
                ChipPicker(selection: Binding(get: { showsAll ? Self.all : selected },
                                              set: { $0 == Self.all ? onAll() : onPick($0) }),
                           options: (offersAll ? [(Self.all, "全部月份")] : []) + months.map { ($0, MonthKey.label($0)) },
                           symbol: { $0 == Self.all ? "tray.full" : "calendar" })
                    .help(showsAll ? "交易明细正看全部月份" :
                            "\(MonthKey.label(selected)) · \(coverage) · \(facts.rowCount) 笔 · \(facts.accountCount) 个账户"
                            + (pinned ? "" : "\n未手动选月份：本月有交易就看本月，否则看最近一个已结束且覆盖整月的月份"))
                arrow("chevron.right", label: "下一个月", target: newer, command: .monthNext)
            }
            if !showsAll && PartialMonthRule.flags(full: facts.fullMonth, manualOnly: manualOnly) {
                // “! 未导全”（圆圈感叹号）：小图标说明这是一句提醒，字面直接说缺的是什么（悬停看笔数和账户数）
                HStack(spacing: 3) {
                    Image(systemName: FinanceHeadlineRule.partialSymbol)
                        .font(.system(size: TypeSize.micro, weight: .semibold))
                    Text(FinanceHeadlineRule.partialLabel)
                }
                .font(.ysCaption)
                .foregroundStyle(Theme.inkSoft)
                // 窗口窄时也不被挤成竖排的“未 / 导 / 全”
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.mist, in: Capsule())
                .help("导入范围未覆盖整月 · \(facts.rowCount) 笔 · \(facts.accountCount) 个账户")
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize()
    }

    private func arrow(_ symbol: String, label: String, target: String?, command: KeyCommand) -> some View {
        Button { if let target { onPick(target) } } label: {
            Image(systemName: symbol)
                .font(.system(size: TypeSize.caption, weight: .semibold))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.inkSoft.opacity(target == nil ? 0.3 : 1))
        .keyCommand(command)
        .disabled(target == nil)
        .help(command.help(label))
        .accessibilityLabel(label)
    }
}

// MARK: - 通用小件

/// 账簿的类别配色：12 个消费类各一种低饱和色（不用朱砂，免得和“超支 / 待确认”撞色），“消费之外”一律灰。
/// 只在账簿里用；日程、作息等仍按 Theme.color(for:) 的哈希取色。
private enum LedgerPalette {
    private static let table: [String: Color] = [
        "餐饮与外卖": .adaptive(light: 0x9A6B4F, dark: 0xD4AE92),
        "超市与食品": .adaptive(light: 0x5E7D3A, dark: 0xB2CC8E),
        "交通出行": .adaptive(light: 0x4C6E8E, dark: 0x93B3CF),
        "通讯与网络": .adaptive(light: 0x3F7E8E, dark: 0x8CC5D2),
        "软件与会员": .adaptive(light: 0x7D5C7E, dark: 0xC4A3C5),
        "教育与学费": .adaptive(light: 0x9B7951, dark: 0xD2B682),
        "购物": .adaptive(light: 0x9C6B7A, dark: 0xD3A9B6),
        "健康与健身": .adaptive(light: 0x427560, dark: 0xA3C5AE),
        "娱乐": .adaptive(light: 0x5A5F8E, dark: 0xA9AED6),
        "彩票": .adaptive(light: 0x8A7A3C, dark: 0xCDBF85),
        "银行手续费": .adaptive(light: 0x7A6A55, dark: 0xBCAA90),
        "待分类消费": .adaptive(light: 0x6F7F86, dark: 0xA8B7BD),
    ]

    static func color(_ category: String) -> Color {
        if FinanceEngine.nonSpend.contains(category) { return Theme.inkSoft }
        return table[category] ?? Theme.color(for: category)
    }
}

/// 账簿里的金额，统一一种“账房数字”（New York 等宽数字）。零值写灰色“—”。
/// .spend：花了多少（墨色、不带符号）；.flow：一笔流水（扣款墨色、不带负号，入账写“+$x”玉色）；
/// .change：比上月多花写“+$x”朱砂，少花写“−$x”玉色。
struct AmountText: View {
    enum Kind { case spend, flow, change }
    var cents: Int
    var kind: Kind = .spend
    var size: CGFloat = TypeSize.body
    var weight: Font.Weight = .medium
    var tint: Color? = nil
    var zeroDash = true
    var struck = false

    var body: some View {
        Text(Self.text(cents, kind, zeroDash: zeroDash))
            .font(Theme.money(size, weight))
            .strikethrough(struck)
            .foregroundStyle(tint ?? Self.color(cents, kind))
            .lineLimit(1)
            .fixedSize()
    }

    static func text(_ cents: Int, _ kind: Kind = .spend, zeroDash: Bool = true) -> String {
        if cents == 0 && zeroDash { return "—" }
        let body = FinanceEngine.money(abs(cents))
        switch kind {
        case .spend: return cents < 0 ? "−" + body : body
        case .flow: return cents > 0 ? "+" + body : body
        case .change: return cents > 0 ? "+" + body : cents < 0 ? "−" + body : body
        }
    }

    static func color(_ cents: Int, _ kind: Kind = .spend) -> Color {
        if cents == 0 { return Theme.inkSoft }
        switch kind {
        case .spend: return Theme.ink
        case .flow: return cents > 0 ? Theme.positive : Theme.ink
        case .change: return cents > 0 ? Theme.warning : Theme.positive
        }
    }
}

/// “名称 …… 金额”一行（另卷记载、大额支出等），字体、对齐、颜色统一
private struct LedgerRow: View {
    var label: String
    var cents: Int
    var kind: AmountText.Kind = .spend
    /// 名称前的小字（例如日期）
    var leading = ""
    var dot: Color?

    var body: some View {
        HStack(spacing: 8) {
            if !leading.isEmpty {
                Text(leading).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft).frame(width: 38, alignment: .leading)
            }
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(label).font(.ysCallout).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            AmountText(cents: cents, kind: kind, size: TypeSize.callout)
        }
    }
}

/// 分类条：纯色细条，条长是占消费总额的比例；金额和占比分两列右对齐
private struct CategoryBars: View {
    var items: [(String, Int)]
    var total: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(items, id: \.0) { name, cents in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(name).font(.ysCallout).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 8)
                        AmountText(cents: cents, size: TypeSize.callout)
                        Text(total > 0 ? String(format: "%.1f%%", Double(cents) / Double(total) * 100) : "—")
                            .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                            .frame(width: 46, alignment: .trailing)
                    }
                    ProgressBar(value: total > 0 ? Double(cents) / Double(total) : 0,
                                color: LedgerPalette.color(name).opacity(scheme == .dark ? 0.8 : 1), height: 4, solid: true)
                }
            }
        }
    }
}

/// 与上月比较：淡金小标题“较 8月 ——”、两个关键数字并排、带表头的对齐表格（金额列等宽右对齐，箭头不再左右跳）
private struct ComparisonSection: View {
    var comparison: MonthComparison?
    var month: String
    /// 这个月不能比较时，一步跳到最近一个整月（月度页给；已存月卷不给）
    var fullMonth: String? = nil
    var onPickMonth: ((String) -> Void)? = nil

    var body: some View {
        let today = LocalDay.today()
        VStack(alignment: .leading, spacing: 12) {
            if let c = comparison {
                SectionLabel(text: "较 \(MonthKey.label(c.previousMonth, relativeTo: today))")
                HStack(spacing: 32) {
                    keyFigure("总消费", c.spendChangeCents)
                    keyFigure("不含教育", c.nonEducationChangeCents)
                }
                VStack(spacing: 0) {
                    row(Text("类别"), Text(MonthKey.label(c.previousMonth, relativeTo: today)), Text(MonthKey.label(month, relativeTo: today)), Text("变化"))
                        .font(.ysCaption)
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.bottom, 6)
                    ForEach(c.categories.prefix(6), id: \.category) { change in
                        Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1)
                        row(Text(change.category).foregroundStyle(Theme.text),
                            Text(AmountText.text(change.previousCents)).foregroundStyle(Theme.inkSoft),
                            Text(AmountText.text(change.currentCents)).foregroundStyle(AmountText.color(change.currentCents)),
                            Text(AmountText.text(change.changeCents, .change)).foregroundStyle(AmountText.color(change.changeCents, .change)),
                            dot: LedgerPalette.color(change.category))
                            .font(Theme.money(TypeSize.callout, .regular))
                            .padding(.vertical, 7)
                    }
                }
            } else {
                SectionLabel(text: "与上月比较")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Hint("本月或上月未覆盖整月，暂不计算环比。")
                    if let fullMonth, let onPickMonth {
                        // 每月头几天本月还空着：一步看到上一个整月的完整比较
                        Button("看\(MonthKey.label(fullMonth, relativeTo: today))整月") { onPickMonth(fullMonth) }
                            .buttonStyle(.cardLink)
                            .help("最近一个已结束、导入范围覆盖整月的月份")
                    }
                }
            }
        }
    }

    private func keyFigure(_ label: String, _ cents: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ysCaption).foregroundStyle(Theme.inkSoft)
            AmountText(cents: cents, kind: .change, size: TypeSize.heading, weight: .semibold)
        }
    }

    private func row(_ name: Text, _ before: Text, _ after: Text, _ change: Text, dot: Color? = nil) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                name.font(.ysCallout).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            before.frame(width: 92, alignment: .trailing)
            after.frame(width: 92, alignment: .trailing)
            change.frame(width: 92, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

/// 账头与月份小标的几条写法（自检核对）
enum FinanceHeadlineRule {
    /// 整月没导全时月份旁的小标：以前写“部分”，看不出是什么的部分。
    /// 与岁月长卷卷首灵石格、逐月柱刻度下标、长卷导出逐月表同一个说法（都取 Core 的 PartialMonthRule.label）
    static let partialLabel = PartialMonthRule.label
    static let partialSymbol = "exclamationmark.circle"

    /// 账头第二行要不要写“扣款”：没有退款时扣款就等于净消费，同一个数不写两遍；
    /// 有退款（扣款 ≠ 净消费）或有教育支出（“其中教育”要接在扣款后面）时才写
    static func showsDebit(refundCents: Int, educationCents: Int) -> Bool {
        refundCents > 0 || educationCents > 0
    }
}

/// 账头（月度页与已存月卷共用）：大号“净消费”与同一基线上中号的“消费之外”，
/// 下面一行“扣款 $41.20 · 退款 +$0.86 · 其中教育 $… · 较上月 +$32.77（不含教育）”；退款、教育为 0 时不写，
/// 这时“扣款”与净消费是同一个数，也不写（FinanceHeadlineRule.showsDebit）；一段都没有时整行不占地方
private struct MonthHeadline: View {
    var facts: MonthFacts
    var comparison: MonthComparison?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("净消费").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                    Text(AmountText.text(facts.netSpendCents, zeroDash: false))
                        .font(Theme.figure(TypeSize.title))
                        .foregroundStyle(facts.netSpendCents == 0 ? Theme.inkSoft : Theme.ink)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("消费之外").font(.ysCaption).foregroundStyle(Theme.inkSoft)
                    AmountText(cents: facts.excludedCents, size: TypeSize.heading, zeroDash: false)
                }
                .help("转账、投资、取现等扣款单独记载，不计入消费")
            }
            if let detailLine {
                detailLine
                    .font(.ysCaption)
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detailLine: Text? {
        let f = facts
        func amount(_ text: String, _ color: Color? = nil) -> Text {
            let t = Text(text).font(Theme.money(TypeSize.caption))
            return color.map { t.foregroundStyle($0) } ?? t.foregroundStyle(Theme.text)
        }
        var parts: [Text] = []
        if FinanceHeadlineRule.showsDebit(refundCents: f.refundCents, educationCents: f.educationCents) {
            parts.append(Text("扣款 ") + amount(AmountText.text(f.spendCents, zeroDash: false)))
        }
        if f.refundCents > 0 { parts.append(Text("退款 ") + amount("+" + FinanceEngine.money(f.refundCents), Theme.positive)) }
        if f.educationCents > 0 { parts.append(Text("其中教育 ") + amount(FinanceEngine.money(f.educationCents))) }
        if let c = comparison {
            let change = c.nonEducationChangeCents
            parts.append(Text("较上月 ") + (change == 0 ? Text("持平") : amount(AmountText.text(change, .change), AmountText.color(change, .change)))
                         + Text("（不含教育）"))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text("  ·  ") + $1 }
    }
}

/// 下月三件事 + 大额支出（月度页与已存月卷共用）
private struct PlanList: View {
    var report: MonthlyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(report.suggestions.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)").font(Theme.figure(TypeSize.body)).foregroundStyle(Theme.precious).frame(width: 14)
                    Text(text).font(.ysCallout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !report.largePurchases.isEmpty {
                SectionLabel(text: "大额支出").padding(.top, 6)
                    .help("单笔 $300 以上的消费")
                ForEach(report.largePurchases, id: \.self) { p in
                    LedgerRow(label: FinanceEngine.merchantDisplay(key: p.merchant), cents: p.cents,
                              leading: LocalDay(key: p.date)?.axisLabel ?? String(p.date.suffix(5)))
                        .help("\(p.merchant) · \(p.category)")
                }
            }
        }
    }
}

/// 主栏 + 侧栏（宽 PageLayout.side）两栏；窗口窄到主栏不足 minMain 时改成上下排（侧栏挪到主栏下面、占满整行）。
/// 用 AnyLayout 切换，切换时卡片里的状态（正在写的备注、正在改的预算）不会丢。
private struct AdaptiveColumns<Main: View, Side: View>: View {
    var minMain: CGFloat
    @ViewBuilder var main: () -> Main
    @ViewBuilder var side: () -> Side
    @State private var width: CGFloat = 1200

    var body: some View {
        let wide = width >= minMain + PageLayout.gutter + PageLayout.side
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: PageLayout.gutter))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: PageLayout.gutter))
        layout {
            main().frame(maxWidth: .infinity)
            side().frame(minWidth: wide ? PageLayout.side : 0, maxWidth: wide ? PageLayout.side : .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

/// 弹窗里的列表：条数少时直接排开，超过 limit 条才放进给定高度的滚动区
/// （弹窗按内容的理想尺寸定大小，滚动区自己没有理想高度，不给高度会被压扁）
struct ScrollIfLong<Content: View>: View {
    var count: Int
    var limit: Int
    var height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if count > limit {
            ScrollView { content() }.frame(height: height)
        } else {
            content()
        }
    }
}

private extension View {
    /// 有说明时才挂悬停提示
    @ViewBuilder
    func help(ifAny text: String) -> some View {
        if text.isEmpty { self } else { self.help(text) }
    }
}

// MARK: - 月度（原“月度总览”与“月度修习录”合成一页）

private struct FinanceOverviewTab: View, Equatable {
    var index: FinanceLedgerIndex
    var month: String
    var onPickMonth: (String) -> Void
    @Environment(\.modelContext) private var context
    @Environment(EffectsCenter.self) private var effects
    /// 正在只读查看的已存月卷
    @State private var viewing: MonthlyReport?
    @State private var confirmPartial = false
    @State private var error: String?

    /// 同一版账本（同一个对象）、同一个月就不必重算；onPickMonth 每次都是同一个动作（改所选月份）
    static func == (a: Self, b: Self) -> Bool { a.index === b.index && a.month == b.month }

    private var ledger: FinanceLedger { index.ledger }

    var body: some View {
        // 月卷草稿（按现在的账本），账头、分类、比较、三件事都取自它；同一版账本里每个月只算一次
        let draft = index.reportDraft(month)
        let saved = ledger.monthlyReports.filter { $0.month == month }.sorted { $0.version > $1.version }
        let f = draft.summary
        VStack(alignment: .leading, spacing: PageLayout.gutter) {
            headline(draft, saved: saved)
                .xianCard(padding: 20, tier: .jade)
                .ysEntrance(order: 1)
            // 主栏要放下比较表（类别 + 三列金额）
            AdaptiveColumns(minMain: 480) {
                VStack(spacing: PageLayout.gutter) {
                    categoriesCard(draft).ysEntrance(order: 2)
                    // 拆成独立视图：拖窗口改宽度时两栏重排，图表的输入没变就不重画
                    MonthlySpendChart(index: index, month: month, onPickMonth: onPickMonth).equatable().ysEntrance(order: 4)
                }
            } side: {
                VStack(spacing: PageLayout.gutter) {
                    if !f.excludedCategories.isEmpty { excludedCard(f).ysEntrance(order: 2) }
                    VStack(alignment: .leading, spacing: 12) {
                        CardTitle(title: "下月三件事", hint: "按这个月的账目生成；存为月卷时一并保存")
                        PlanList(report: draft)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .xianCard()
                    .ysEntrance(order: 3)
                    reflectionCard(saved).ysEntrance(order: 5)
                }
            }
        }
        .sheet(item: $viewing) { report in
            FinanceSavedReportSheet(report: report, stale: report.basisHash != draft.basisHash)
        }
        .confirmationDialog(partialTitle(f), isPresented: $confirmPartial, titleVisibility: .visible) {
            if let suggestion = suggestedMonth {
                Button("改存 \(MonthKey.label(suggestion))") {
                    onPickMonth(suggestion)
                    save(suggestion)
                }
            }
            Button("仍存 \(MonthKey.label(month))") { save(month) }
        } message: {
            Text("现在存下的月卷会按不完整的账目生成。"
                 + (suggestedMonth.map { "建议存 \(MonthKey.label($0))（最近一个已结束且覆盖整月的月份）。" } ?? ""))
        }
    }

    // MARK: 账头

    /// 账头：大号“净消费”与同一基线上的“消费之外”，下面一行扣款 / 退款 / 较上月；右上角“存为月卷 ⌄”
    private func headline(_ draft: MonthlyReport, saved: [MonthlyReport]) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                MonthHeadline(facts: draft.summary, comparison: draft.comparison)
                if let error { Hint(error, tone: .error).padding(.top, 2) }
            }
            Spacer(minLength: 16)
            saveMenu(draft, saved: saved)
        }
    }

    /// 最近一个已结束、导入范围覆盖整月的月份（不是 month 时）：本月不能比较时给一个“看 9月整月”的入口
    static func fullMonth(_ index: FinanceLedgerIndex, besides month: String) -> String? {
        let candidate = index.defaultMonth()
        guard candidate != month, index.monthFacts(candidate).fullMonth else { return nil }
        return candidate
    }

    /// “存为月卷”：保存这一版 / 导出 HTML / 查看已存的版本（只读弹窗）
    private func saveMenu(_ draft: MonthlyReport, saved: [MonthlyReport]) -> some View {
        Menu {
            Button("保存这一版") { isPartial(draft.summary) ? (confirmPartial = true) : save(month) }
            Button(saved.first.map { "导出第 \($0.version) 版 HTML…" } ?? "导出 HTML…") {
                if let latest = saved.first { export(latest) }
            }
            .disabled(saved.isEmpty)
            if !saved.isEmpty {
                Divider()
                ForEach(saved) { r in
                    Button("查看第 \(r.version) 版…" + (r.engine == nil ? "（旧版生成）" : r.basisHash != draft.basisHash ? "（账本已变化）" : "")) {
                        viewing = r
                    }
                }
            }
        } label: {
            // 带 ⌄：这是一个菜单（保存 / 导出 / 查看已存），不是点一下就保存
            HStack(spacing: 8) {
                Label(saved.isEmpty ? "存为月卷" : "存为月卷 · 已存 \(saved.count) 版", systemImage: "book.closed")
                Image(systemName: "chevron.down").font(.system(size: TypeSize.micro, weight: .bold)).foregroundStyle(Theme.inkSoft)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.yunshanCompact)
        .fixedSize()
        .help("把这个月的账目存成一卷（之后账本再变，已存的版本也保持原样），可导出 HTML、查看已存的版本")
    }

    // MARK: 卡片

    private func categoriesCard(_ draft: MonthlyReport) -> some View {
        let f = draft.summary
        let items = f.categories.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
        return VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "灵石去向", detail: items.isEmpty ? "" : "\(items.count) 类", hint: "本月消费扣款按类别；条长是占消费总额的比例")
            if items.isEmpty {
                EmptyHint(.noSpend)
            } else {
                CategoryBars(items: items, total: f.spendCents)
            }
            ComparisonSection(comparison: draft.comparison, month: month,
                              fullMonth: Self.fullMonth(index, besides: month), onPickMonth: onPickMonth)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .xianCard()
    }

    private func excludedCard(_ f: MonthFacts) -> some View {
        let rows = f.excludedCategories.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "另卷记载", detail: "\(rows.count) 类",
                      hint: "转账、投资、取现等扣款单独记载，不算作消费；转账的用途可在交易明细里逐笔确认")
            ForEach(Array(rows.enumerated()), id: \.element.key) { index, item in
                if index > 0 { Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1) }
                LedgerRow(label: item.key, cents: item.value, dot: LedgerPalette.color(item.key))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .xianCard()
    }

    private func reflectionCard(_ saved: [MonthlyReport]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "月末备注", hint: "按月自动保存草稿，切换标签、月份或重启都不丢；存为月卷时一并存入")
            ReflectionEditor(month: month, fallback: saved.first?.reflection ?? "").id(month)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .xianCard()
    }

    // MARK: 月卷

    /// 本月还没过完，或该月导入范围没覆盖整月
    private func isPartial(_ f: MonthFacts) -> Bool {
        month >= String(LocalDay.today().key.prefix(7)) || !f.fullMonth
    }

    private func partialTitle(_ f: MonthFacts) -> String {
        month >= String(LocalDay.today().key.prefix(7)) ? "本月未过完" : "\(MonthKey.label(month))的导入范围未覆盖整月"
    }

    /// 建议改存的月份：最近一个已结束且覆盖整月的月份（不是当前这个月时）
    private var suggestedMonth: String? {
        let candidate = index.defaultMonth()
        guard candidate != month, candidate < String(LocalDay.today().key.prefix(7)),
              index.monthFacts(candidate).fullMonth else { return nil }
        return candidate
    }

    private func save(_ target: String) {
        do {
            let latest = ledger.monthlyReports.filter { $0.month == target }.max { $0.version < $1.version }
            // 草稿备注为空时沿用最新一版的备注，新版本不会把之前写的备注弄丢
            let reflection = ReflectionDrafts.text(target) ?? latest?.reflection ?? ""
            var saved: MonthlyReport?
            var created = false
            _ = try FinanceService.mutate(context) { ledger in
                let result = FinanceEngine.saveReport(in: &ledger, month: target, reflection: reflection)
                saved = result.0
                created = result.1
            }
            ReflectionDrafts.set(nil, month: target)
            error = nil
            if let saved {
                effects.hint(created ? "已存为\(MonthKey.label(target))第 \(saved.version) 版月卷" : "与第 \(saved.version) 版相同，未重复保存",
                             icon: created ? "checkmark.circle" : nil)
            }
        } catch {
            self.error = "月卷未能保存：\(error.localizedDescription)"
        }
    }

    private func export(_ report: MonthlyReport) {
        if let url = FinanceSavedReportSheet.export(report) { effects.hint("已导出：\(url.lastPathComponent)", icon: "checkmark.circle") }
    }
}

// MARK: - 各月消费

/// 各月消费：选中的月份全亮并在柱顶标金额，其他月份淡下去；没导全的月份更淡。点柱子切到那个月。
/// 各月账目取自账本派生数据（同一版账本只算一次）；只依赖账本版本与所选月份，拖窗口时两栏重排不重画。
/// 横轴标签按绘图区宽度抽稀（MonthAxis：跨年时年初写“2025年”，选中的月份始终标出）：几年的账一屏放不下每月的字。
/// 抽稀的结果只在“标哪几个月”变了时才改，拖窗口时不跟着每一点宽度重画。
/// 最早一根柱的标签（跨年时写全“2024年10月”）比柱宽还宽时右挪到与绘图区左边齐，不伸出绘图区
private struct MonthlySpendChart: View, Equatable {
    var index: FinanceLedgerIndex
    var month: String
    var onPickMonth: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    /// 横轴要标的月份与最早一根柱的标签右挪多少；还没量到绘图区宽度时为 nil，先按 560 点估
    @State private var axisPlan: AxisFit?

    /// 横轴要标的月份（键 → 写什么），以及最早一根柱的标签右挪的点数（0 = 不挪）
    struct AxisFit: Equatable {
        var plan: [String: String]
        var firstShift: Double
    }

    /// 按绘图区宽度定横轴：先由 MonthAxis 抽稀；最早一根柱的标签比柱宽还宽、会伸出绘图区左边时，右挪到与左边齐，
    /// 挪过去会碰到右边下一个标签时就不标它（选中的月份照标、照挪）
    static func fitAxis(months: [String], selected: String, today: LocalDay, width: Double) -> AxisFit {
        var plan = MonthAxis.labels(months: months, selected: selected, today: today, width: width)
        guard let first = months.first, let text = plan[first], width > 0 else { return AxisFit(plan: plan, firstShift: 0) }
        func labelWidth(_ key: String, _ text: String) -> Double {
            MonthAxis.textWidth(text, fontSize: Double(TypeSize.micro)) * (key == selected ? 1.06 : 1)
        }
        let slot = width / Double(months.count)
        let firstWidth = labelWidth(first, text)
        let shift = max(0, (firstWidth - slot) / 2).rounded(.up)
        guard shift > 0 else { return AxisFit(plan: plan, firstShift: 0) }
        if first != selected,
           let next = months.indices.dropFirst().first(where: { plan[months[$0]] != nil }),
           let nextText = plan[months[next]],
           (Double(next) + 0.5) * slot - labelWidth(months[next], nextText) / 2 - (slot / 2 - firstWidth / 2 + shift + firstWidth) < MonthAxis.gap / 2 {
            plan[first] = nil
            return AxisFit(plan: plan, firstShift: 0)
        }
        return AxisFit(plan: plan, firstShift: shift)
    }

    static func == (a: Self, b: Self) -> Bool { a.index === b.index && a.month == b.month }

    var body: some View {
        let today = LocalDay.today()
        let facts = index.months.reversed().map { index.monthFacts($0) }
        let keys = Dictionary(facts.map { (MonthKey.label($0.month, relativeTo: today), $0.month) }, uniquingKeysWith: { first, _ in first })
        // 深色下选中的柱子也略收一点，不是大块浅色平涂
        let dim = scheme == .dark ? 0.9 : 1.0
        let hasPartial = facts.contains { !$0.fullMonth }
        let monthKeys = facts.map(\.month)
        let fit = axisPlan ?? Self.fitAxis(months: monthKeys, selected: month, today: today, width: 560)
        let plan = fit.plan
        let firstCategory = monthKeys.first.map { MonthKey.label($0, relativeTo: today) }
        // 横轴的值是柱子的类别名（“2025年3月”，今年的写“3月”），只给要标的那几个月挂标签
        let shown = facts.compactMap { f in plan[f.month].map { (category: MonthKey.label(f.month, relativeTo: today), text: $0, selected: f.month == month) } }
        let shownText = Dictionary(shown.map { ($0.category, (text: $0.text, selected: $0.selected)) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "各月消费", hint: "点柱子切到那个月")
            Chart {
                ForEach(facts, id: \.month) { f in
                    let x = MonthKey.label(f.month, relativeTo: today)
                    // 选中的月份最亮；其余按是否导全分两档淡下去（深色下淡得少一些，不至于褪成一片泥色）
                    let alpha = f.month == month ? dim : f.fullMonth ? (scheme == .dark ? 0.55 : 0.42) : (scheme == .dark ? 0.3 : 0.22)
                    BarMark(x: .value("月份", x), y: .value("金额", Double(f.nonEducationCents) / 100))
                        .foregroundStyle(by: .value("类型", "日常消费"))
                        .opacity(alpha)
                        .cornerRadius(f.educationCents > 0 ? 0 : 4)
                    if f.educationCents > 0 {
                        BarMark(x: .value("月份", x), y: .value("金额", Double(f.educationCents) / 100))
                            .foregroundStyle(by: .value("类型", "教育支出"))
                            .opacity(alpha)
                            .cornerRadius(4)
                    }
                    if f.month == month {
                        // 柱顶的金额：挂在一个看不见的点上（叠放的柱子不好单独挂）
                        PointMark(x: .value("月份", x), y: .value("金额", Double(f.spendCents) / 100))
                            .symbolSize(0)
                            // 最右一根（多是本月）时金额不压到右侧的纵轴刻度上：横向收进绘图区
                            // 金额衬一块纸色小签：被收进绘图区、压到左边几根柱子上时也读得清，不像是那几个月的数
                            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .plot), y: .disabled)) {
                                Text(FinanceEngine.money(f.spendCents))
                                    .font(Theme.money(TypeSize.caption, .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background {
                                        Capsule().fill(Theme.card.opacity(0.96))
                                            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.45), lineWidth: 0.6))
                                            .shadow(color: Theme.ink.opacity(scheme == .dark ? 0 : 0.08), radius: 2, y: 1)
                                    }
                            }
                    }
                }
            }
            .chartForegroundStyleScale(["日常消费": Theme.jade, "教育支出": Theme.gold])
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text("$\(Int(value.as(Double.self) ?? 0))") } } }
            // 选中的月份在横轴上也标出来（柱子很矮时也看得出选的是哪个月）；别的按宽度抽稀，标签已互不重叠，不再让图表自己挑
            .chartXAxis {
                AxisMarks(values: shown.map(\.category)) { value in
                    AxisValueLabel(collisionResolution: .disabled) {
                        if let label = value.as(String.self), let tick = shownText[label] {
                            Text(tick.text)
                                .font(.system(size: TypeSize.micro, weight: tick.selected ? .semibold : .regular))
                                .foregroundStyle(tick.selected ? Theme.precious : Theme.inkSoft)
                                .fixedSize()
                                // 最早一根柱的标签：右挪到与绘图区左边齐（见 fitAxis）
                                .offset(x: label == firstCategory ? fit.firstShift : 0)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    // 量绘图区宽度，算横轴标哪几个月；结果没变就不改状态
                    let width = proxy.plotFrame.map { geo[$0].width } ?? geo.size.width
                    let fitted = Self.fitAxis(months: monthKeys, selected: month, today: today, width: width)
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            if let label: String = proxy.value(atX: x), let key = keys[label] { onPickMonth(key) }
                        }
                        .onChange(of: fitted, initial: true) { _, value in
                            if axisPlan != value { axisPlan = value }
                        }
                }
            }
            .frame(height: 200)
            if hasPartial {
                Hint("颜色更淡的月份导入范围未覆盖整月")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .xianCard()
    }
}

// MARK: - 交易明细

private struct TransactionsTab: View {
    static let all = "全部"
    static let review = "__review"
    var index: FinanceLedgerIndex
    var month: String
    @Binding var filter: String
    @Binding var allMonths: Bool
    var onEdit: (FinanceTransaction) -> Void
    /// 生效的搜索词（搜索框停顿约 0.25 秒才交过来）
    @State private var search = ""

    /// 按日分组（列表已按日期从新到旧排好）；每行带着它在账本里的下标，商户名从派生数据里取
    private static func days(_ list: [Int], in transactions: [FinanceTransaction]) -> [(day: String, rows: [(index: Int, row: FinanceTransaction)])] {
        var result: [(day: String, rows: [(index: Int, row: FinanceTransaction)])] = []
        for index in list {
            let row = transactions[index]
            if result.last?.day == row.date { result[result.count - 1].rows.append((index, row)) } else { result.append((row.date, [(index, row)])) }
        }
        return result
    }

    /// 全局搜索带来的关键词：预填搜索并看全部月份
    private func applyRoute() {
        guard let query = AppRouter.shared.financeSearch else { return }
        search = query
        allMonths = true
        filter = Self.all
        AppRouter.shared.financeSearch = nil
    }

    var body: some View {
        let transactions = index.ledger.transactions
        let raw = search.trimmingCharacters(in: .whitespaces)
        let category = filter
        // 排序、每笔的大写搜索文字与商户名都按账本版本记着，打字时只是比一遍字符串
        let list = index.rows(month: allMonths ? nil : month, query: raw) {
            category == Self.all || (category == Self.review ? $0.awaitingReview : $0.category == category)
        }
        let reviewCount = allMonths ? index.awaitingReviewCount : index.awaitingReviewCount(in: month)
        let filtered = filter != Self.all || !raw.isEmpty
        let today = LocalDay.today()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FinanceSearchField(text: $search).frame(maxWidth: 280)
                ChipPicker(selection: $filter,
                           options: [(Self.all, "全部交易"), (Self.review, "待确认（\(reviewCount)）")] + FinanceEngine.categories.map { ($0, $0) },
                           symbol: { $0 == Self.review ? "exclamationmark.circle" : "line.3.horizontal.decrease" })
                Spacer(minLength: 8)
                // 合计只在筛选生效时显示（不筛选时笔数就在月份的悬停说明里）
                if filtered {
                    let debit = list.map { transactions[$0] }.filter { $0.amountCents < 0 && !$0.isIgnored }.reduce(0) { $0 - $1.amountCents }
                    Text("\(list.count) 笔 · 扣款 \(FinanceEngine.money(debit))").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                }
            }
            .padding(.bottom, 4)

            if list.isEmpty {
                EmptyHint(filter == Self.review ? .reviewClear : .noTransactions)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.days(list, in: transactions).enumerated()), id: \.element.day) { position, group in
                    dayHeader(group.day, rows: group.rows.map(\.row), today: today)
                        .padding(.top, position == 0 ? 6 : 18)
                        .padding(.bottom, 2)
                    ForEach(Array(group.rows.enumerated()), id: \.element.row.id) { i, item in
                        EditableRow(dividerAbove: i > 0, editLabel: "修改", action: { onEdit(item.row) }) {
                            TransactionRow(row: item.row, display: index.merchantDisplay(at: item.index))
                        }
                    }
                }
            }
        }
        .xianCard()
        .ysEntrance(order: 1)
        .onAppear(perform: applyRoute)
        .onChange(of: AppRouter.shared.financeSearch) { _, _ in applyRoute() }
    }

    /// 日期头：“10月1日 · 周四 ———— $41.20”（右侧是当日扣款合计）
    private func dayHeader(_ key: String, rows: [FinanceTransaction], today: LocalDay) -> some View {
        let day = LocalDay(key: key)
        let debit = rows.filter { $0.amountCents < 0 && !$0.isIgnored }.reduce(0) { $0 - $1.amountCents }
        return HStack(spacing: 10) {
            Text(day.map { "\($0.label(relativeTo: today)) · \($0.weekdayName)" } ?? key)
                .font(Theme.songti(TypeSize.callout, .semibold))
                .foregroundStyle(Theme.ink)
            Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1)
            if debit > 0 {
                AmountText(cents: debit, size: TypeSize.caption, tint: Theme.inkSoft)
            }
        }
        // 与行内金额右对齐：EditableRow 右端留着悬停才出现的“›”
        .padding(.trailing, 18)
        .accessibilityElement(children: .combine)
    }
}

/// 交易明细的搜索框：外观与原来的输入框相同，停顿约 0.25 秒再把关键词交给列表（照修行录的搜索框），
/// 打字时不必每个字都把全部交易筛一遍。清空时立即生效；外面改了关键词（全局搜索跳过来）就同步回来。
private struct FinanceSearchField: View {
    @Binding var text: String
    @State private var input: String

    init(text: Binding<String>) {
        _text = text
        _input = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        TextField("搜索商户、备注或类别", text: $input)
            .onChange(of: text) { _, value in if value != input { input = value } }
            .task(id: input) {
                guard input != text else { return }
                if !input.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                guard !Task.isCancelled else { return }
                text = input
            }
    }
}

/// 交易一行：好读的商户名 + 状态小标（待确认、退款、手记……）｜ ● 类别 ｜ 金额（扣款不带负号，入账“+$x”玉色）
private struct TransactionRow: View {
    var row: FinanceTransaction
    /// 好读的商户名（FinanceEngine.merchantDisplay，账本派生数据里按版本记着）
    var display: String

    var body: some View {
        // “待分类消费”这类待确认类别本身就是状态：类别写成朱砂小标，不再另挂“待确认”
        let reviewCategory = row.awaitingReview && FinanceEngine.reviewCategories.contains(row.category)
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(display)
                    .font(.ysBody)
                    .foregroundStyle(row.isIgnored ? Theme.inkSoft : Theme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                    // 悬停看银行原文
                    .help(ifAny: row.isManual ? "" : row.description)
                if row.awaitingReview && !reviewCategory { Chip(text: "待确认", color: Theme.warning).fixedSize() }
                if row.kind == "退款" { Chip(text: "退款", color: Theme.positive).fixedSize() }
                if row.isManual { Chip(text: "手记", color: Theme.precious).fixedSize() }
                if row.isIgnored { Chip(text: "不计入统计", color: Theme.inkSoft).fixedSize() }
                if row.classification == "rule" { Chip(text: "按记忆归类", color: Theme.info).fixedSize() }
                if !row.note.isEmpty {
                    Label(row.note, systemImage: "text.bubble").font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1).help(row.note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if reviewCategory {
                    Chip(text: row.category, color: Theme.warning).fixedSize()
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(LedgerPalette.color(row.category)).frame(width: 7, height: 7)
                        Text(row.category).font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                    }
                }
            }
            .frame(width: 124, alignment: .leading)
            AmountText(cents: row.amountCents, kind: .flow, size: TypeSize.body,
                       tint: row.isIgnored ? Theme.inkSoft : nil, zeroDash: false, struck: row.isIgnored)
                .frame(minWidth: 84, alignment: .trailing)
        }
    }
}

// MARK: - 节流与账单

private struct ThriftTab: View {
    var index: FinanceLedgerIndex
    var month: String
    @Environment(\.modelContext) private var context
    @Environment(\.spiritMotion) private var motion
    @State private var showKept = false
    @State private var error: String?

    private var ledger: FinanceLedger { index.ledger }

    var body: some View {
        // 同一版账本里每个月只算一次（账单分组的正则只在换新版账本后跑一遍）
        let budgets = index.budgetStatus(month)
        let services = index.serviceChecks(month)
        // 主栏要放下账单表（服务名 + 两列金额 + 状态）
        AdaptiveColumns(minMain: 440) {
            servicesCard(services).ysEntrance(order: 2)
        } side: {
            budgetCard(budgets).ysEntrance(order: 1)
        }
    }

    // MARK: 预算

    /// 预算就地编辑：点一行改金额，回车或移开焦点就存，旁边闪一下“已存”
    private func budgetCard(_ budgets: [BudgetStatus]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "可选消费预算",
                      hint: "预算只对餐饮、打车、娱乐与彩票三项可选消费设置，额度由你决定。点一行填金额，回车或移开即保存；清空表示不设预算") {
                if let previous = FinanceEngine.previousMonth(month), let limits = ledger.budgets[previous], !limits.isEmpty, ledger.budgets[month] == nil {
                    Button("沿用上月") { saveAll(limits) }
                        .buttonStyle(.cardLink)
                        .help("把上个月的预算原样用到这个月")
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(budgets.enumerated()), id: \.element.key) { index, b in
                    // 换月份时整行重建，正在改的金额不会带到另一个月
                    BudgetRow(status: b, dividerAbove: index > 0, onSave: { saveBudget(b.key, $0) })
                        .id("\(month)-\(b.key)")
                }
            }
            if let error { Hint(error, tone: .error) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .xianCard()
    }

    /// 存一项预算（nil 为不设）；失败时返回出错说明（FinanceService 已把存储恢复原样）
    private func saveBudget(_ key: String, _ cents: Int?) -> String? {
        do {
            _ = try FinanceService.mutate(context) { ledger in
                var limits = ledger.budgets[month] ?? [:]
                limits[key] = cents
                ledger.budgets[month] = limits
            }
            error = nil
            return nil
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
    }

    private func saveAll(_ limits: [String: Int]) {
        do {
            _ = try FinanceService.mutate(context) { $0.budgets[month] = limits }
            error = nil
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: 固定账单

    /// 固定账单：服务 | 上月 | 本月 | 状态 的紧凑表格。状态小标点一下在“待核对 / 保留”间切换，已保留的收在底部
    private func servicesCard(_ services: [ServiceCheck]) -> some View {
        let pending = services.filter { $0.status != "keep" }
        let kept = services.filter { $0.status == "keep" }
        let today = LocalDay.today()
        let previous = FinanceEngine.previousMonth(month)
        return VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: "固定账单检查", detail: services.isEmpty ? "" : "\(services.count) 项",
                      hint: "订阅与通讯费。点右侧状态在“待核对 / 保留”间切换；标记保留的服务不会出现在节流建议里")
            if services.isEmpty {
                EmptyHint(.noBills)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    serviceLine(Text("服务"), Text(previous.map { MonthKey.label($0, relativeTo: today) } ?? "上月"),
                                Text(MonthKey.label(month, relativeTo: today)), Text("状态"))
                        .font(.ysCaption)
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                    ForEach(pending, id: \.key) { s in
                        Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1)
                        serviceRow(s)
                    }
                    if !kept.isEmpty {
                        Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1)
                        Button {
                            withAnimation(motion ? Motion.standard : nil) { showKept.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Text("已保留 \(kept.count) 项")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: TypeSize.micro, weight: .bold))
                                    .rotationEffect(.degrees(showKept ? 90 : 0))
                            }
                            .font(.system(size: TypeSize.caption, weight: .medium))
                            .foregroundStyle(Theme.inkSoft)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showKept ? "已展开" : "已收起")
                        if showKept {
                            ForEach(kept, id: \.key) { s in
                                Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1)
                                serviceRow(s)
                            }
                        }
                    }
                }
            }
            if let error { Hint(error, tone: .error) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 这一页的主表是玉简主卡；侧栏的预算是纸笺卡
        .xianCard(tier: .jade)
    }

    private func serviceLine(_ name: some View, _ before: some View, _ now: some View, _ status: some View) -> some View {
        HStack(spacing: 12) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            before.frame(width: 88, alignment: .trailing)
            now.frame(width: 88, alignment: .trailing)
            status.frame(width: 72, alignment: .trailing)
        }
    }

    private func serviceRow(_ s: ServiceCheck) -> some View {
        let keep = s.status == "keep"
        return serviceLine(
            HStack(spacing: 6) {
                Text(s.label).font(.ysCallout.weight(.medium)).foregroundStyle(keep ? Theme.inkSoft : Theme.ink).lineLimit(1)
                if !s.signals.isEmpty {
                    let text = s.signals.map(\.text).joined(separator: "\n")
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: TypeSize.caption))
                        .foregroundStyle(Theme.warning)
                        .help(text)
                        .accessibilityLabel(text)
                }
            },
            AmountText(cents: s.previousCents ?? 0, size: TypeSize.callout, weight: .regular, tint: Theme.inkSoft)
                .help(ifAny: s.previousCents == nil ? "上月导入范围未覆盖整月，不比较" : ""),
            AmountText(cents: s.debitCents, size: TypeSize.callout)
                .help(ifAny: s.count > 1 ? "\(s.count) 笔" : ""),
            // “待核对”是中性的待办（淡雾底、墨色字），不再整列朱砂：朱砂只留给有异常信号（⚠）的行
            Button { setPreference(s.preferenceKey, keep ? "review" : "keep") } label: {
                HStack(spacing: 3) {
                    if keep { Image(systemName: "checkmark").font(.system(size: TypeSize.micro - 1, weight: .bold)) }
                    Text(keep ? "保留" : "待核对")
                }
                .font(.system(size: TypeSize.caption, weight: .medium))
                .foregroundStyle(keep ? Theme.inkSoft : Theme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(keep ? Color.clear : Theme.mist, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(keep ? "已标记保留：常用服务，不出现在节流建议里。点一下改回待核对" : "待核对：点一下标记为保留（常用服务，不再出现在节流建议里）")
            .accessibilityLabel("\(s.label)：\(keep ? "保留" : "待核对")")
        )
        .padding(.vertical, 8)
    }

    private func setPreference(_ key: String, _ value: String) {
        do {
            _ = try FinanceService.mutate(context) { $0.reviewPreferences[key] = value }
            error = nil
        } catch {
            self.error = "偏好未能保存：\(error.localizedDescription)"
        }
    }
}

/// 预算一行：“餐饮与外卖  $120 / $300”加细进度条；没设预算时写“设预算”。点整行就地改金额。
private struct BudgetRow: View {
    var status: BudgetStatus
    var dividerAbove: Bool
    /// 存一个预算（nil 为不设）；失败时返回出错说明
    var onSave: (Int?) -> String?
    @Environment(\.spiritMotion) private var motion
    @State private var editing = false
    @State private var text = ""
    @State private var problem: String?
    @State private var saved = false
    @FocusState private var focused: Bool

    private var over: Bool { (status.remainingCents ?? 0) < 0 }

    var body: some View {
        if editing {
            editor
        } else {
            EditableRow(dividerAbove: dividerAbove, editLabel: status.limitCents == nil ? "设预算" : "改预算",
                        onDelete: status.limitCents == nil ? nil : { _ = onSave(nil) },
                        action: begin) { summary }
                .help(ifAny: status.remainingCents.map { $0 < 0 ? "超出 \(FinanceEngine.money(-$0))" : "还剩 \(FinanceEngine.money($0))" } ?? "")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(status.label).font(.ysCallout).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if saved {
                    Text("已存").font(.ysCaption).foregroundStyle(Theme.positive).transition(.opacity)
                }
                AmountText(cents: status.spentCents, size: TypeSize.callout, tint: over ? Theme.warning : nil, zeroDash: false)
                if let limit = status.limitCents {
                    Text("/ \(FinanceEngine.money(limit))").font(Theme.money(TypeSize.callout, .regular)).foregroundStyle(Theme.inkSoft)
                } else {
                    Text("设预算").font(.system(size: TypeSize.caption, weight: .medium)).foregroundStyle(Theme.gold)
                }
            }
            if let limit = status.limitCents, limit > 0 {
                ProgressBar(value: Double(status.spentCents) / Double(limit), color: over ? Theme.warning : Theme.positive, height: 4, solid: true)
                if over {
                    Text("超出 \(FinanceEngine.money(-(status.remainingCents ?? 0)))").font(.ysCaption).monospacedDigit().foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 5) {
            if dividerAbove { Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1) }
            HStack(spacing: 6) {
                Text(status.label).font(.ysCallout).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text("$").font(Theme.money(TypeSize.callout, .semibold)).foregroundStyle(Theme.inkSoft)
                // 自己管焦点，不用带焦点描边的 .yunshan 输入框样式（两层 .focused 会打架）
                TextField("", text: $text, prompt: Text("不设"))
                    .textFieldStyle(.plain)
                    .font(Theme.money(TypeSize.callout))
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .frame(width: 86)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).strokeBorder(Theme.gold.opacity(0.6), lineWidth: 1.2))
                    .onSubmit(commit)
                    .onExitCommand { editing = false; problem = nil }
                    .accessibilityLabel("\(status.label)预算")
            }
            .padding(.vertical, 6)
            if let problem { Hint(problem, tone: .error) }
        }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func begin() {
        text = status.limitCents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
        problem = nil
        editing = true
    }

    private func commit() {
        guard editing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var cents: Int?
        if !trimmed.isEmpty {
            guard let value = try? FinanceEngine.cents(trimmed), value >= 0 else {
                problem = "「\(trimmed)」不是有效金额，请写成 300 或 120.50"
                return
            }
            cents = value
        }
        guard cents != status.limitCents else { editing = false; problem = nil; return }
        if let failure = onSave(cents) { problem = failure; return }
        problem = nil
        editing = false
        withAnimation(motion ? Motion.quick : nil) { saved = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(motion ? Motion.standard : nil) { saved = false }
        }
    }
}

// MARK: - 已存的月卷（只读）

/// 已存的一版月卷：保存时的账目快照，只读，可导出 HTML。从月度页“存为月卷”菜单打开。
struct FinanceSavedReportSheet: View {
    var report: MonthlyReport
    /// 账本在保存之后有变化（这一版与当前账目不同）
    var stale: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var exported: String?

    var body: some View {
        let f = report.summary
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(eyebrow: "灵石账簿 · 月卷", title: "\(MonthKey.label(report.month)) · 第\(report.version)版（只读）")
            Hint("保存于 \(Self.savedAt(report.generatedAt))"
                 + (report.engine == nil ? " · 旧版应用生成" : stale ? " · 账本之后有变化，这一版保持保存时的样子" : ""))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 与月度页同一种账头（不再是四张等大的金额格）
                    MonthHeadline(facts: f, comparison: report.comparison)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.mist.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "灵石去向")
                        CategoryBars(items: f.categories.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) },
                                     total: f.spendCents)
                    }
                    ComparisonSection(comparison: report.comparison, month: report.month)
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "下月三件事")
                        PlanList(report: report)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "月末备注")
                        Text(report.reflection.isEmpty ? "未填写" : report.reflection)
                            .font(.ysCallout)
                            .foregroundStyle(report.reflection.isEmpty ? Theme.inkSoft : Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 12)
            }
            // 弹窗按内容的理想尺寸定大小，滚动区要给定高度，否则会被压扁
            .frame(height: 520)
            // 底边淡出一截，再画一条分隔线：看得出下面还有内容可以往下滚
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92),
                                         .init(color: .black.opacity(0.15), location: 1)], startPoint: .top, endPoint: .bottom))
            Divider()
            HStack {
                if let exported { Hint(exported, tone: .success) }
                Spacer()
                Button("导出 HTML…") { if let url = Self.export(report) { exported = "已导出：\(url.lastPathComponent)" } }
                Button("关闭") { dismiss() }.buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .yunshanSheet()
    }

    /// 保存时间：“10月2日 21:33”，不在今年时带年份
    private static func savedAt(_ iso: String) -> String {
        guard let date = LegacyMapper.timestamp(iso) else { return iso }
        let sameYear = Calendar.current.component(.year, from: date) == LocalDay.today().year
        return sameYear ? DateText.display(date) : DateText.string(date, format: "yyyy年M月d日 HH:mm")
    }

    /// 把一版月卷导出成 HTML（文件名与旧版一致）
    static func export(_ report: MonthlyReport) -> URL? {
        let html = FinanceReportHTML.render(report)
        return FilePanels.save(data: Data(html.utf8), suggestedName: "灵石账簿_\(report.month)_第\(report.version)版.html", allowedExtensions: ["html"])
    }
}

/// 月末备注草稿：按月份存在偏好设置（AppPreferences，切标签、切月份、重启都不丢），保存成月卷后清掉该月草稿。
/// 没有草稿（nil）与“故意清空”（空字符串）分开记。
enum ReflectionDrafts {
    static let key = "draft.finance.reflection"

    static func text(_ month: String) -> String? {
        (AppPreferences.defaults.dictionary(forKey: key) as? [String: String])?[month]
    }

    static func set(_ text: String?, month: String) {
        var all = (AppPreferences.defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[month] = text
        AppPreferences.defaults.set(all, forKey: key)
    }
}

/// 月末备注输入框：自己持有文字，打字只重绘这个小框，不会让整页重算。
/// 空着时显示提示语；高度随内容在 72–176 之间变化（超过后框内滚动），聚焦时描边转金。
private struct ReflectionEditor: View {
    var month: String
    @State private var text: String

    init(month: String, fallback: String) {
        self.month = month
        _text = State(initialValue: ReflectionDrafts.text(month) ?? fallback)
    }

    var body: some View {
        PaperEditor(text: $text, placeholder: "这个月最想记住的一件事……", font: .ysCallout, height: 72...176)
            .onChange(of: text) { _, value in ReflectionDrafts.set(value, month: month) }
            .accessibilityLabel("月末备注")
    }
}
