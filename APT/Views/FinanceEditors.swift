import SwiftUI
import SwiftData

// MARK: - 交易编辑

/// 逐笔确认类别与备注。手记（手动记账、随手记、飞剑传书）还能改日期、金额、说明，也能删除；
/// 银行导入的交易与网银流水一一对应，金额日期不能改，但可以设为“不计入统计”。
struct TransactionEditor: View {
    var row: FinanceTransaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var category = ""
    @State private var note = ""
    @State private var remember = false
    @State private var applyToSame = true
    @State private var ignored = false
    @State private var dayKey = ""
    @State private var amountText = ""
    @State private var descriptionText = ""
    /// 同商户的其他记录：只在打开时和换类别时算一次（打字不重算整本账）
    @State private var same: [FinanceTransaction] = []
    @State private var confirmDelete = false
    @State private var error: String?

    /// 手记一定是扣款；“手记”名下的正数行（误用这个账户名导入的银行退款 / 入账）按银行流水处理，免得一改就变成扣款
    private var isManual: Bool { row.isManual && row.amountCents < 0 }
    private var canSave: Bool {
        !isManual || ((try? FinanceEngine.manualCents(amountText)) != nil && !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        let canRemember = FinanceEngine.canRemember(row, category: category)
        let display = FinanceEngine.merchantDisplay(row)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SheetHeader(eyebrow: row.isManual ? "灵石账簿 · 手记" : "灵石账簿 · 银行流水", title: display)
                    // 银行原文只在这里显示（交易明细里写的是好读的商户名）
                    if display != row.description {
                        Text(row.description).font(.ysCaption).foregroundStyle(Theme.inkSoft).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                AmountText(cents: row.amountCents, kind: .flow, size: TypeSize.title, weight: .semibold,
                           tint: row.isIgnored ? Theme.inkSoft : nil, zeroDash: false, struck: row.isIgnored)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if !isManual {
                    GridRow { Text("日期").foregroundStyle(Theme.inkSoft); Text(LocalDay(key: row.date)?.longLabel ?? row.date) }
                }
                GridRow { Text("账户").foregroundStyle(Theme.inkSoft); Text(row.account) }
                // 手记没有银行余额，不显示“当时余额 $0.00”
                if !isManual {
                    GridRow { Text("当时余额").foregroundStyle(Theme.inkSoft); Text(FinanceEngine.money(row.balanceCents)).font(Theme.money(TypeSize.callout)) }
                }
                GridRow { Text(isManual ? "来源" : "分类依据").foregroundStyle(Theme.inkSoft); Text(row.reason) }
            }
            .font(.ysCallout)
            if isManual {
                FormSection(title: "手记内容") {
                    FormRow(label: "日期") { DayField(label: "", key: $dayKey) }
                    FormRow(label: "金额", top: true) { AmountField(text: $amountText) }
                    FormRow(label: "说明") { TextField("", text: $descriptionText, prompt: Text("例如：午饭 拉面")) }
                }
            }
            Divider()
            FormRow(label: "类别") {
                ChipPicker(selection: $category,
                           options: FinanceEngine.spendCategories.map { ($0, $0) }
                               + FinanceEngine.categories.filter { FinanceEngine.nonSpend.contains($0) }.map { ($0, "\($0)（不计入消费）") })
            }
            TextField("备注（例如：给室友的房租、退回的押金）", text: $note, axis: .vertical).lineLimit(1...3)
            if canRemember {
                // 分类记忆只在导入银行 CSV 时生效，对“手记”账户没有用处
                if !isManual {
                    Toggle("记住这个商户：以后导入时自动归为「\(category)」", isOn: $remember)
                }
                if !same.isEmpty {
                    Toggle("同商户另外 \(same.count) 笔一起归为「\(category)」", isOn: $applyToSame)
                    let courier = same.filter { $0.id.hasPrefix("courier-") }.count
                    if applyToSame && courier > 0 {
                        Hint("其中 \(courier) 笔是飞剑传书代记的；一起归类后算作你确认过，之后撤销那封传书时默认会保留它们。")
                    }
                }
            } else if FinanceEngine.nonSpend.contains(category) || FinanceEngine.reviewCategories.contains(category) {
                Hint("个人转账、取现等请逐笔确认，不会批量归类或记忆。")
            }
            if !isManual {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("不计入统计（重复入账或与你无关的流水）", isOn: $ignored)
                    Hint("银行流水与网银一一对应，金额和日期不能改。设为不计入后，它不再算进消费、退款、预算与月卷，交易本身保留，可随时改回。")
                }
            }
            if let error { Hint(error, tone: .error) }
            HStack {
                if isManual { Button("删除这笔…", role: .destructive) { confirmDelete = true } }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认") { save() }.buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 560)
        .yunshanSheet()
        .onAppear {
            category = row.category
            note = row.note
            ignored = row.isIgnored
            dayKey = row.date
            amountText = String(format: "%.2f", Double(abs(row.amountCents)) / 100)
            descriptionText = row.description
            refreshSame()
        }
        .onChange(of: category) { _, _ in refreshSame() }
        .confirmationDialog("删除这笔手记？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { delete() }
        } message: {
            Text("\(row.date) · \(row.description) · \(FinanceEngine.money(row.amountCents))。删除后无法恢复，月度统计随之更新。"
                 + (row.id.hasPrefix("courier-") ? "这笔来自飞剑传书，之后撤销那封传书时会自动跳过它。" : ""))
        }
    }

    private func refreshSame() {
        guard let ledger = try? FinanceService.load(context) else { same = []; return }
        same = FinanceEngine.sameMerchant(in: ledger, as: row, category: category)
    }

    private func save() {
        do {
            let cents = isManual ? try FinanceEngine.manualCents(amountText) : 0
            _ = try FinanceService.mutate(context) { ledger in
                if isManual {
                    try FinanceEngine.editManual(in: &ledger, id: row.id, date: dayKey, cents: cents, description: descriptionText)
                }
                try FinanceEngine.updateTransaction(in: &ledger, id: row.id, category: category, note: note,
                                                    remember: !isManual && remember && FinanceEngine.canRemember(row, category: category))
                if !isManual { try FinanceEngine.setIgnored(in: &ledger, id: row.id, ignored: ignored) }
                if applyToSame && FinanceEngine.canRemember(row, category: category) && !same.isEmpty {
                    FinanceEngine.batchClassify(in: &ledger, ids: Set(same.map(\.id)), category: category)
                }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() {
        do {
            _ = try FinanceService.mutate(context) { try FinanceEngine.deleteTransaction(in: &$0, id: row.id) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 手记一笔

/// 手记一笔：现金、他人代付或银行还没出账的消费。之后同一笔若又随 CSV 导入，导入时会列出疑似重复让你删掉手记那笔；
/// 账上已有金额相同、日期相近的银行流水（先导入、后补记）时，入账前就在这里提醒。也可以在交易明细里点开这笔修改或删除。
struct ManualExpenseSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var dayKey = LocalDay.today().key
    @State private var amountText = ""
    @State private var category = "餐饮与外卖"
    @State private var description = ""
    @State private var note = ""
    @State private var error: String?
    /// 账上已有的、可能就是这一笔的银行扣款（金额相同、日期相差 3 天内）；只提醒，不拦着入账
    @State private var bankMatches: [FinanceTransaction] = []

    /// 金额规则与随手记、飞剑传书相同（最多两位小数，"18,5" 当 18.50 而不是 $185）；没填或写错时为 nil
    private var cents: Int? { try? FinanceEngine.manualCents(amountText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(eyebrow: "灵石账簿", title: "手记一笔")
            Hint("记现金、他人代付或银行尚未出账的消费。刷卡的消费月底会随 CSV 导入；之后导入的银行流水若与它金额相同、日期相差 3 天内会提示，删掉手记那笔即可；账上已有这样的流水时，这里入账前就会提醒（交易明细里点开手记也能改、能删）。")
            FormSection {
                FormRow(label: "日期") { DayField(label: "", key: $dayKey) }
                FormRow(label: "金额", top: true) { AmountField(text: $amountText, prompt: "例如：18.5") }
                FormRow(label: "类别") {
                    ChipPicker(selection: $category, options: FinanceEngine.spendCategories.map { ($0, $0) })
                }
                FormRow(label: "说明") { TextField("", text: $description, prompt: Text("例如：午饭 拉面")) }
                FormRow(label: "备注") { TextField("", text: $note, prompt: Text("可不填")) }
            }
            if !bankMatches.isEmpty { BankMatchHint(matches: bankMatches) }
            if let error { Hint(error, tone: .error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("入账") { save() }
                    .buttonStyle(.yunshanPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cents == nil || description.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .yunshanSheet()
        .onAppear(perform: refreshMatches)
        .onChange(of: dayKey) { _, _ in refreshMatches() }
        .onChange(of: amountText) { _, _ in refreshMatches() }
    }

    /// 金额或日期变了就重新比一次（账本按版本缓存，只是在内存里筛一遍）
    private func refreshMatches() {
        guard let cents, let day = LocalDay(key: dayKey), let ledger = try? FinanceService.load(context) else { bankMatches = []; return }
        let probe = ManualExpense.transaction(day: day, cents: cents, category: category, description: "", note: "", reason: "")
        bankMatches = FinanceEngine.existingBankMatches(for: probe, in: ledger)
    }

    private func save() {
        guard let cents, let day = LocalDay(key: dayKey) else { return }
        let row = ManualExpense.transaction(day: day, cents: cents, category: category,
                                            description: description.trimmingCharacters(in: .whitespaces), note: note, reason: "手动记账")
        do {
            _ = try FinanceService.mutate(context) { $0.transactions.append(row) }
            dismiss()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }
}
