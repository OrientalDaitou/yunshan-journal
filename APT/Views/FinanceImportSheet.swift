import SwiftUI
import SwiftData

// MARK: - 导入

struct FinanceImportSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var raw: String?
    @State private var fileName = ""
    @State private var account = ""
    @State private var knownAccounts: [String] = []
    @State private var confirmPeriod = false
    @State private var periodStart = LocalDay.today().adding(days: -30).key
    @State private var periodEnd = LocalDay.today().key
    @State private var preview: FinanceEngine.ImportPreview?
    /// 有交易与别的账户名下完全相同时，必须另外勾选确认才能导入
    @State private var confirmCross = false
    @State private var error: String?
    @State private var done: String?
    /// 本次导入新建的导入记录（可撤销）；只是给旧记录补确认范围时为 nil
    @State private var imported: FinanceSource?
    @State private var confirmUndo = false
    /// 导入后疑似与手记重复的，逐笔让用户决定删掉手记那笔或保留
    @State private var matches: [FinanceEngine.ManualMatch] = []
    @State private var handled: [String: String] = [:]
    /// 刚才按疑似重复删掉的手记（配对 ID → 原样的那笔），可在这一行点“恢复”放回
    @State private var removed: [String: FinanceTransaction] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                SceneryImage(name: "yunshan-ornament-abacus-v1").frame(width: 48, height: 48)
                SheetHeader(eyebrow: "灵石账簿", title: "导入银行 CSV")
            }
            Hint("支持 CommBank 网银导出的 CSV（日期、金额、描述、余额四列）。原始文件完整保存在本机，重复导入会自动跳过已有交易。")
            Divider()
            if done == nil {
                form
            }
            if let error { Hint(error, tone: .error) }
            if let done {
                Label(done, systemImage: "checkmark.seal.fill").font(.ysCallout).foregroundStyle(Theme.positive)
                if !matches.isEmpty { matchList }
            }
            Spacer(minLength: 0)
            HStack {
                if done != nil, imported != nil {
                    Button("撤销这次导入…", role: .destructive) { confirmUndo = true }
                }
                Spacer()
                if done != nil {
                    Button("完成") { dismiss() }.buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("确认导入") { apply() }.buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction)
                        .disabled(preview == nil || (preview?.newCount ?? 0) == 0 && !confirmPeriod
                                  || (preview?.crossAccountCount ?? 0) > 0 && !confirmCross)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
        .frame(minHeight: 470)
        .yunshanSheet()
        .onAppear {
            let ledger = try? FinanceService.load(context)
            knownAccounts = Array(Set(ledger?.sources.map(\.account) ?? [])).sorted()
            // 只有一个账户时预填它；有多个账户时留空让你选，免得把 B 账户的文件记到上次用的 A 账户名下
            account = knownAccounts.count == 1 ? knownAccounts[0] : ""
        }
        .confirmationDialog("撤销这次导入？", isPresented: $confirmUndo, presenting: imported) { source in
            Button("撤销导入", role: .destructive) { undo(source) }
        } message: { source in
            let restore = source.removedManual?.count ?? 0
            Text("将删除这次新增的交易和这条导入记录，账本回到导入之前。"
                 + (restore > 0 ? "刚才删掉的 \(restore) 笔手记会一并放回。" : ""))
        }
    }

    @ViewBuilder
    private var form: some View {
        HStack {
            Button("选择 CSV 文件…") { pick() }
            Text(fileName.isEmpty ? "尚未选择" : fileName).font(.ysCallout).foregroundStyle(Theme.inkSoft).lineLimit(1)
        }
        HStack(spacing: 8) {
            TextField("账户名称（可只保留末四位，例如：CommBank Smart Access · 0123）", text: $account)
            if !knownAccounts.isEmpty {
                Menu("已有账户") {
                    ForEach(knownAccounts, id: \.self) { name in Button(name) { account = name } }
                }
                .menuStyle(.button)
                .fixedSize()
            }
        }
        // 账户名每输入一个字就整份重新解析会卡，停顿 0.3 秒再刷新预览
        .onChange(of: account) { _, _ in
            preview = nil
            confirmCross = false
        }
        .task(id: account) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { refresh() }
        }
        // 只有一个账户时预填了它：第一次导入第二个账户的文件时最容易忘了改名（内容不重合，跨账户检测发现不了）
        if knownAccounts.count == 1, account.trimmingCharacters(in: .whitespacesAndNewlines) == knownAccounts[0] {
            Hint("已按你唯一的账户「\(knownAccounts[0])」预填；如果这是另一个账户（例如储蓄账户）的文件，请改成新名字。", tone: .warning)
        }
        Toggle("确认银行导出的起止日期（用于判断是否覆盖整月）", isOn: $confirmPeriod)
            .onChange(of: confirmPeriod) { _, _ in refresh() }
        if confirmPeriod {
            HStack {
                DayField(label: "从", key: $periodStart)
                DayField(label: "到", key: $periodEnd)
            }
            .onChange(of: periodStart) { _, _ in refresh() }
            .onChange(of: periodEnd) { _, _ in refresh() }
            Hint("结束日期不能晚于今天；当月只确认已经过去的日子，否则半个月会被当成整月统计。")
        }
        if let preview {
            VStack(alignment: .leading, spacing: 4) {
                Label("共 \(preview.rows.count) 笔：新增 \(preview.newCount) 笔，已存在 \(preview.duplicateCount) 笔", systemImage: "checkmark.circle")
                    .font(.ysCallout)
                    .foregroundStyle(Theme.positive)
                if let s = preview.start, let e = preview.end { Hint("交易日期 \(s) 至 \(e)") }
                if !preview.manualMatches.isEmpty {
                    Hint("其中 \(preview.manualMatches.count) 笔与你手记的账金额相同、日期相差 3 天内，可能是同一笔；导入后可逐笔决定删不删手记那笔。", tone: .warning)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.mist.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            if preview.crossAccountCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Label("其中 \(preview.crossAccountCount) 笔与账户「\(preview.crossAccounts.joined(separator: "」「"))」已有的交易完全相同（日期、金额、描述、余额都一致），很可能是同一份文件填了不同的账户名，导入会重复计算。",
                          systemImage: "exclamationmark.triangle")
                        .font(.ysCallout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                    Toggle("我确认这是另一个账户，仍要导入", isOn: $confirmCross)
                }
            }
        }
    }

    /// 疑似与手记重复的银行流水：并排列出，删手记那笔或两笔都留
    private var matchList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hint("以下银行流水可能与你手记的账是同一笔（金额相同、日期相差 3 天内）。确认重复就删掉手记那笔，不是同一笔就保留。")
            ScrollIfLong(count: matches.count, limit: 4, height: 220) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { match in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("银行 \(match.bank.date.suffix(5)) · \(FinanceEngine.merchantDisplay(match.bank))").font(.ysCallout).lineLimit(1)
                                    .help(match.bank.description)
                                Text("手记 \(match.manual.date.suffix(5)) · \(match.manual.description)").font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                            }
                            Spacer()
                            AmountText(cents: match.bank.amountCents, kind: .flow, size: TypeSize.callout)
                            if let state = handled[match.id] {
                                Text(state).font(.ysCaption).foregroundStyle(Theme.inkSoft).frame(width: 110, alignment: .trailing)
                                if removed[match.id] != nil {
                                    Button("恢复") { restoreManual(match) }.buttonStyle(.yunshanCompact)
                                        .help("把刚才删掉的手记原样放回账上")
                                }
                            } else {
                                Button("删除手记这笔") { deleteManual(match) }.buttonStyle(.yunshanCompact)
                                Button("保留") { handled[match.id] = "两笔都保留" }.buttonStyle(.yunshanCompact)
                            }
                        }
                        .padding(.vertical, 6)
                        Divider().opacity(0.45)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.mist.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private var period: StatementPeriod? { confirmPeriod ? StatementPeriod(start: periodStart, end: periodEnd) : nil }

    private func pick() {
        guard let url = FilePanels.open(allowedExtensions: ["csv"], directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) else { return }
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
            fileName = url.lastPathComponent
            confirmCross = false
            refresh()
        } catch {
            self.error = "无法读取文件（需为 UTF-8 编码的 CSV）：\(error.localizedDescription)"
        }
    }

    private func refresh() {
        error = nil
        preview = nil
        guard let raw, !account.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let ledger = try FinanceService.load(context)
            preview = try FinanceEngine.previewImport(raw: raw, account: account, ledger: ledger, period: period)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply() {
        guard let raw else { return }
        error = nil
        do {
            let ledger = try FinanceService.load(context)
            let fresh = try FinanceEngine.previewImport(raw: raw, account: account, ledger: ledger, period: period)
            // 预览可能还没跟上刚改的账户名：以这次重算的结果为准，跨账户重复仍要先勾选确认
            if fresh.crossAccountCount > 0 && !confirmCross {
                preview = fresh
                return
            }
            var added = 0
            var appended: FinanceSource?
            _ = try FinanceService.mutate(context) { ledger in
                let before = ledger.sources.count
                added = FinanceEngine.applyImport(raw: raw, preview: fresh, period: period, to: &ledger)
                if ledger.sources.count > before { appended = ledger.sources.last }
            }
            imported = appended
            matches = fresh.manualMatches
            done = "已导入 \(added) 笔新交易" + (fresh.duplicateCount > 0 ? "，跳过 \(fresh.duplicateCount) 笔已有交易" : "")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 删掉手记那笔：原样记在这次导入记录下（撤销这次导入时放回），这一行随后可点“恢复”
    private func deleteManual(_ match: FinanceEngine.ManualMatch) {
        do {
            var deleted: (row: FinanceTransaction, source: FinanceSource?)?
            _ = try FinanceService.mutate(context) {
                deleted = try FinanceEngine.deleteDuplicateManual(in: &$0, id: match.manual.id, source: imported)
            }
            // 导入记录多了“删掉的手记”，换成新值，否则之后撤销导入会因“账本已变化”被拒
            if let source = deleted?.source { imported = source }
            removed[match.id] = deleted?.row ?? match.manual
            handled[match.id] = "已删除手记这笔"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restoreManual(_ match: FinanceEngine.ManualMatch) {
        guard let row = removed[match.id] else { return }
        do {
            var updated: FinanceSource?
            _ = try FinanceService.mutate(context) { updated = FinanceEngine.restoreDuplicateManual(in: &$0, row: row, source: imported) }
            if let updated { imported = updated }
            removed[match.id] = nil
            handled[match.id] = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func undo(_ source: FinanceSource) {
        do {
            var result = FinanceEngine.UndoImportResult(removed: 0, restoredManual: 0)
            _ = try FinanceService.mutate(context) { result = try FinanceEngine.undoLatestImportDetailed(in: &$0, expected: source) }
            imported = nil
            matches = []
            removed = [:]
            handled = [:]
            done = "已撤销这次导入，删除 \(result.removed) 笔交易"
                + (result.restoredManual > 0 ? "，放回 \(result.restoredManual) 笔刚才删掉的手记" : "")
        } catch {
            self.error = "撤销失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 导入记录与分类记忆（低频管理，从“导入银行 CSV”的下拉打开）

/// 已导入的银行文件：账户、日期范围、笔数；只能撤销最近一次导入（导入完成页本身也有撤销）。
struct FinanceSourcesSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var stores: [FinanceStore]
    @State private var undoTarget: FinanceSource?
    @State private var undoSummary = ""
    @State private var confirmUndo = false
    @State private var message: (text: String, isError: Bool)?
    /// 列表超出时底部渐隐的浓淡（与编辑弹窗同一套，见 EditorSheetFade）
    @State private var fade = 0.0

    /// “2026-07-02” → “7月2日”（不在今年时带年份），与全应用的日期写法一致
    private static func dayText(_ key: String) -> String {
        LocalDay(key: key)?.label(relativeTo: .today()) ?? key
    }

    var body: some View {
        // 读 updatedAt：账本一变（例如刚撤销）列表就跟着刷新
        let _ = stores.first?.updatedAt
        let ledger = try? FinanceService.load(context)
        let sources = ledger?.sources ?? []
        let latest = ledger.flatMap { FinanceEngine.latestImportIndex($0) }
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(eyebrow: "灵石账簿", title: "导入记录")
            Hint("原始 CSV 完整保存在本机。只能撤销最近一次导入：删掉那次新增的交易和这条记录。")
            if ledger == nil {
                Hint("账本读取失败，暂时看不到导入记录。", tone: .error)
            } else if sources.isEmpty {
                EmptyHint(symbol: "tray", text: "还没有导入过银行文件。")
            } else {
                ScrollIfLong(count: sources.count, limit: 6, height: 340) {
                    VStack(alignment: .leading, spacing: 0) {
                        // 新的在上；同一文件 + 同一账户可能有多条（例如空文件分别确认了不同月份），不能拿 sha256 当列表 ID
                        ForEach(Array(sources.enumerated().reversed()), id: \.offset) { index, source in
                            if index != sources.count - 1 { Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1) }
                            HStack(spacing: 10) {
                                Image(systemName: "doc.plaintext").foregroundStyle(Theme.inkSoft)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.account).font(.ysCallout).foregroundStyle(Theme.text)
                                    Text("\(source.range.map { "\(Self.dayText($0.0)) – \(Self.dayText($0.1))" } ?? "—") · \(source.rows) 笔\(source.statementPeriod == nil ? "" : " · 已确认导出范围")")
                                        .font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                                }
                                Spacer()
                                if index == latest {
                                    Button("撤销这次导入…", role: .destructive) { askUndo(index, in: ledger) }.buttonStyle(.yunshanCompact)
                                        .help("只能撤销最近一次导入：删掉这次新增的交易和这条导入记录")
                                }
                                Text(Self.dayText(FinanceEngine.localStamp(source.importedAt, format: "yyyy-MM-dd"))).font(.ysCaption).monospacedDigit().foregroundStyle(Theme.inkSoft)
                            }
                            .padding(.vertical, 9)
                        }
                    }
                    .measuresHiddenBelow($fade)
                }
                // 导入多了列表要滚：最后一行不再像被拦腰切断，底部渐隐提示下面还有
                .bottomFade(fade)
            }
            if let message { Hint(message.text, tone: message.isError ? .error : .success) }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .yunshanSheet()
        .confirmationDialog("撤销最近一次导入？", isPresented: $confirmUndo, presenting: undoTarget) { source in
            Button("撤销导入", role: .destructive) { undo(source) }
        } message: { _ in Text(undoSummary) }
    }

    private func askUndo(_ index: Int, in ledger: FinanceLedger?) {
        guard let ledger, ledger.sources.indices.contains(index) else { return }
        let source = ledger.sources[index]
        let rows = FinanceEngine.rowsAdded(bySource: index, in: ledger)
        let edited = rows.filter { $0.classification == "user" || !$0.note.isEmpty || $0.isIgnored }.count
        let restore = source.removedManual?.count ?? 0
        undoSummary = "将删除「\(source.account)」\(source.range.map { " \($0.0) 至 \($0.1)" } ?? "")这次导入新增的 \(rows.count) 笔交易"
            + (edited > 0 ? "（其中 \(edited) 笔你改过类别、备注或设为不计入，改动会一并删掉）" : "")
            + "，以及这条导入记录"
            + (restore > 0 ? "；导入后按疑似重复删掉的 \(restore) 笔手记会放回账上" : "")
            + "。应用里保存的这份 CSV 副本也会一并删除，需要时请用你手上的原文件重新导入。"
        undoTarget = source
        confirmUndo = true
    }

    private func undo(_ source: FinanceSource) {
        do {
            var result = FinanceEngine.UndoImportResult(removed: 0, restoredManual: 0)
            _ = try FinanceService.mutate(context) { result = try FinanceEngine.undoLatestImportDetailed(in: &$0, expected: source) }
            message = ("已撤销导入，删除 \(result.removed) 笔交易"
                       + (result.restoredManual > 0 ? "，放回 \(result.restoredManual) 笔手记" : ""), false)
        } catch {
            message = ("撤销失败：\(error.localizedDescription)", true)
        }
    }
}

/// 分类记忆：在交易明细里勾选“记住这个商户”后，以后导入自动归类；可逐条停用。
struct FinanceRulesSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var stores: [FinanceStore]
    @State private var error: String?
    /// 列表超出时底部渐隐的浓淡
    @State private var fade = 0.0

    var body: some View {
        let _ = stores.first?.updatedAt
        let rules = (try? FinanceService.load(context))?.merchantRules ?? []
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(eyebrow: "灵石账簿", title: "分类记忆")
            Hint("在交易明细里确认类别时勾选“记住这个商户”，以后导入银行 CSV 会自动归类；取消勾选即停用这一条。")
            if rules.isEmpty {
                EmptyHint(symbol: "lightbulb", text: "还没有分类记忆。")
            } else {
                ScrollIfLong(count: rules.count, limit: 7, height: 340) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                            if index > 0 { Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1) }
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(FinanceEngine.merchantDisplay(key: rule.merchant)).font(.ysCallout).foregroundStyle(Theme.text).lineLimit(1)
                                    Text("\(rule.merchant) → \(rule.category)").font(.ysCaption).foregroundStyle(Theme.inkSoft).lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { rule.enabled }, set: { toggle(rule.id, $0) }))
                                    // 玉印勾选（与全应用的勾选一致）：系统的灰色开关看上去像不可用。
                                    // 只画方框、不留与文字的间距，右缘才和分隔线右端对齐
                                    .toggleStyle(.yunshanBox)
                                    .accessibilityLabel("启用「\(rule.merchant)」的分类记忆")
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .measuresHiddenBelow($fade)
                }
                .bottomFade(fade)
            }
            if let error { Hint(error, tone: .error) }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.yunshanPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .yunshanSheet()
    }

    private func toggle(_ id: String, _ enabled: Bool) {
        do {
            _ = try FinanceService.mutate(context) { ledger in
                if let i = ledger.merchantRules.firstIndex(where: { $0.id == id }) {
                    ledger.merchantRules[i].enabled = enabled
                    ledger.merchantRules[i].revision += 1
                }
            }
            error = nil
        } catch {
            self.error = "分类记忆未能保存：\(error.localizedDescription)"
        }
    }
}
