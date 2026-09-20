//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import SwiftUI

// MARK: - Model

/// One sitting at the flash cards. The store keeps the boxes; this keeps the
/// card on screen, the clock behind it and the running score for the sitting.
@available(iOS 16, *)
@MainActor
final class RecallModel: ObservableObject {
    struct Card {
        let mark: String
        let direction: Recall.Direction
        let options: [String]
        var picked: String?
        var right: Bool? { picked.map { $0 == mark } }
    }

    @AppStorage("Practice.recallMode") private var modeRaw = Recall.Mode.both.rawValue
    var mode: Recall.Mode {
        get { Recall.Mode(rawValue: modeRaw) ?? .both }
        set { modeRaw = newValue.rawValue; next() }
    }

    @Published private(set) var card: Card?
    @Published private(set) var seen = 0
    @Published private(set) var hit = 0
    private(set) var blocks = QiulingFonts.shared.blocks
    private var recent: [String] = []
    private var shownAt = Date()
    private var advance: Task<Void, Never>?
    private let store = PracticeStore.shared

    init() {
        NotificationCenter.default.addObserver(forName: QiulingFonts.fontDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.blocks = QiulingFonts.shared.blocks; self?.next() }
        }
    }

    func next() {
        advance?.cancel(); advance = nil
        guard let (mark, direction) = Recall.pick(blocks: blocks, mode: mode, book: store.book, recent: recent) else { card = nil; return }
        recent.append(mark); if recent.count > 3 { recent.removeFirst(recent.count - 3) }
        card = Card(mark: mark, direction: direction, options: ([mark] + Recall.decoys(for: mark, in: blocks)).shuffled(), picked: nil)
        shownAt = Date()
    }

    /// A tap on an answer. Later taps on the same card are ignored rather
    /// than the buttons disabled, which would dim the feedback colours.
    func pick(_ option: String) {
        guard var c = card, c.picked == nil else { return }
        c.picked = option; card = c
        let right = option == c.mark
        seen += 1; if right { hit += 1 }
        store.recallAnswer(mark: c.mark, direction: c.direction, picked: option, ms: Date().timeIntervalSince(shownAt) * 1000)
        advance = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((right ? 0.42 : 1.2) * 1e9))
            if !Task.isCancelled { self?.next() }
        }
    }
}

// MARK: - Screen

/// Duolingo-shaped: the prompt large in the upper half, the four answers in
/// a grid pinned to the bottom where a thumb already is.
@available(iOS 16, *)
struct RecallView: View {
    @StateObject private var model = RecallModel()

    var body: some View {
        VStack(spacing: 0) {
            if let c = model.card {
                prompt(c)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                note(c)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(c.options, id: \.self) { o in
                        Button { model.pick(o) } label: {
                            answerLabel(o, c.direction)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .optionButton(tint: tint(o, c))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.snappy, value: c.picked)
            } else {
                Text("This alphabet has no marks to drill.")
                    .font(.footnote).foregroundStyle(PracticeTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if model.card == nil { model.next() } }
    }

    private func prompt(_ c: RecallModel.Card) -> some View {
        VStack(spacing: 14) {
            if c.direction == .read {
                Text(c.mark).font(PracticeTheme.script(112)).foregroundStyle(PracticeTheme.ink)
            } else {
                Text(c.mark).font(.system(size: 48, weight: .semibold, design: .monospaced)).kerning(4).foregroundStyle(PracticeTheme.ink)
            }
            Text(c.direction.caption).font(.footnote).foregroundStyle(PracticeTheme.muted)
        }
        .padding(.horizontal, 20)
        .minimumScaleFactor(0.5)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("\(model.hit) / \(model.seen)").font(PracticeTheme.mono).monospacedDigit().foregroundStyle(PracticeTheme.muted)
            Picker("Direction", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                ForEach(Recall.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Button("Skip", systemImage: "forward") { model.next() }.labelStyle(.iconOnly).practiceSecondaryButton()
        }
    }

    /// One line under the controls, kept in the layout even when empty so
    /// the grid does not jump when a wrong answer lands.
    private func note(_ c: RecallModel.Card) -> some View {
        Group {
            if let picked = c.picked, picked != c.mark {
                Text("you picked \(picked) — it was \(c.mark)")
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 13, design: .monospaced)).foregroundStyle(PracticeTheme.accent)
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func answerLabel(_ o: String, _ d: Recall.Direction) -> some View {
        if d == .read {
            Text(o).font(.system(size: 22, weight: .semibold, design: .monospaced)).kerning(2)
        } else {
            Text(o).font(PracticeTheme.script(50))
        }
    }

    /// Neutral until an answer lands; then the answer goes green and a wrong pick red.
    private func tint(_ o: String, _ c: RecallModel.Card) -> Color? {
        guard let picked = c.picked else { return nil }
        if o == c.mark { return PracticeTheme.good }
        if o == picked { return PracticeTheme.accent }
        return nil
    }
}

@available(iOS 16, *)
private extension View {
    /// An answer card: a system bordered button (glass on iOS 26), tinted by result.
    @ViewBuilder
    func optionButton(tint: Color?) -> some View {
        if #available(iOS 26, *) {
            if let tint { self.buttonStyle(.glassProminent).tint(tint) } else { self.buttonStyle(.glass).tint(PracticeTheme.ink) }
        } else {
            if let tint { self.buttonStyle(.borderedProminent).tint(tint) } else { self.buttonStyle(.bordered).tint(PracticeTheme.ink) }
        }
    }
}

// MARK: - Progress

/// Where every mark stands: the four counts, a heat map of the alphabet,
/// the marks that keep slipping and the ones that are done. Tap a mark for
/// the numbers behind its colour.
@available(iOS 16, *)
struct RecallProgressSection: View {
    let book: PracticeStore.Book
    @State private var blocks: [String] = []
    @State private var detail: String?

    private struct Row: Identifiable {
        let mark: String; let label: Recall.Label; let item: PracticeStore.RecallItem?
        var id: String { mark }
        var seen: Int { (item?.read.seen ?? 0) + (item?.write.seen ?? 0) }
        var accuracy: Int? { seen > 0 ? Int((Double((item?.read.right ?? 0) + (item?.write.right ?? 0)) / Double(seen) * 100).rounded()) : nil }
        var meanMs: Int? {
            let ms = [item?.read.msMean, item?.write.msMean].compactMap { $0 }
            return ms.isEmpty ? nil : Int((ms.reduce(0, +) / Double(ms.count)).rounded())
        }
        var topConfusion: String? {
            var merged = item?.read.confusions ?? [:]
            for (k, v) in item?.write.confusions ?? [:] { merged[k, default: 0] += v }
            return merged.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        }
    }

    private var rows: [Row] { blocks.map { Row(mark: $0, label: Recall.label(book.recall[$0]), item: book.recall[$0]) } }

    var body: some View {
        let rows = self.rows
        let counts = Dictionary(grouping: rows, by: \.label).mapValues(\.count)
        VStack(alignment: .leading, spacing: 20) {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("recall").practiceLabel()
                    HStack(alignment: .firstTextBaseline, spacing: 22) {
                        ForEach([Recall.Label.mastered, .learning, .struggling, .new], id: \.self) { l in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(counts[l] ?? 0)").font(.system(size: 24, weight: .semibold, design: .monospaced)).monospacedDigit().foregroundStyle(PracticeTheme.ink)
                                Text(l.name).font(.system(size: 10, design: .monospaced)).foregroundStyle(Self.ink(l))
                            }
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], spacing: 6) {
                        ForEach(rows) { r in
                            Button { detail = r.mark } label: {
                                VStack(spacing: 2) {
                                    Text(r.mark).font(PracticeTheme.script(26)).foregroundStyle(PracticeTheme.ink)
                                    Text(r.mark).font(.system(size: 9, design: .monospaced)).foregroundStyle(PracticeTheme.muted).lineLimit(1).minimumScaleFactor(0.6)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(Self.fill(r.label), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18).practiceCard().padding(.horizontal, 16)

                let struggling = rows.filter { $0.label == .struggling }.sorted { ($0.accuracy ?? 0, -$0.seen) < ($1.accuracy ?? 0, -$1.seen) }
                if !struggling.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("struggling").practiceLabel()
                        ForEach(struggling.prefix(8)) { r in
                            Button { detail = r.mark } label: {
                                HStack(spacing: 12) {
                                    Text(r.mark).font(PracticeTheme.script(30)).foregroundStyle(PracticeTheme.ink).frame(width: 80, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.mark).font(PracticeTheme.mono).foregroundStyle(PracticeTheme.ink)
                                        if let c = r.topConfusion {
                                            Text("often picked \(c)").font(.system(size: 11, design: .monospaced)).foregroundStyle(PracticeTheme.accent)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(r.accuracy ?? 0)%").font(PracticeTheme.mono).foregroundStyle(PracticeTheme.accent)
                                        if let ms = r.meanMs { Text("\(ms) ms").font(.system(size: 11, design: .monospaced)).foregroundStyle(PracticeTheme.muted) }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(18).practiceCard().padding(.horizontal, 16)
                }

                let mastered = rows.filter { $0.label == .mastered }
                if !mastered.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("mastered").practiceLabel()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                            ForEach(mastered.prefix(12)) { r in
                                Button { detail = r.mark } label: {
                                    HStack(spacing: 6) {
                                        Text(r.mark).font(PracticeTheme.script(20)).foregroundStyle(PracticeTheme.ink)
                                        Text(r.mark).font(.system(size: 10, design: .monospaced)).foregroundStyle(PracticeTheme.muted).lineLimit(1)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Self.fill(.mastered), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(18).practiceCard().padding(.horizontal, 16)
                }
            }
        }
        .onAppear { if blocks.isEmpty { blocks = QiulingFonts.shared.blocks } }
        .sheet(item: Binding(get: { detail.map(Mark.init) }, set: { detail = $0?.text })) { m in
            RecallMarkDetail(mark: m.text, item: book.recall[m.text])
        }
    }

    private struct Mark: Identifiable { let text: String; var id: String { text } }

    static func fill(_ l: Recall.Label) -> Color {
        switch l {
        case .new: PracticeTheme.paper
        case .struggling: PracticeTheme.accent.opacity(0.18)
        case .learning: Color.orange.opacity(0.18)
        case .mastered: PracticeTheme.good.opacity(0.22)
        }
    }

    static func ink(_ l: Recall.Label) -> Color {
        switch l {
        case .new: PracticeTheme.muted
        case .struggling: PracticeTheme.accent
        case .learning: Color.orange
        case .mastered: PracticeTheme.good
        }
    }
}

/// The numbers behind one mark, each direction on its own.
@available(iOS 16, *)
struct RecallMarkDetail: View {
    let mark: String
    let item: PracticeStore.RecallItem?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 8) {
                        Text(mark).font(PracticeTheme.script(88)).foregroundStyle(PracticeTheme.ink)
                        Text(mark).font(.system(size: 20, weight: .semibold, design: .monospaced)).kerning(3).foregroundStyle(PracticeTheme.muted)
                        Text(Recall.label(item).name).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(RecallProgressSection.ink(Recall.label(item)))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20).practiceCard().padding(.horizontal, 16)
                    ForEach(Recall.Direction.allCases, id: \.self) { d in
                        direction(d, item?[d] ?? .init())
                    }
                }
                .padding(.top, 8)
            }
            .background(PracticeTheme.paper)
            .navigationTitle("Recall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func direction(_ d: Recall.Direction, _ r: PracticeStore.RecallRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(d.rawValue).practiceLabel()
            if r.seen == 0 {
                Text("not yet asked").font(PracticeTheme.mono).foregroundStyle(PracticeTheme.faint)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    stat("\(r.box)", "box of 5")
                    stat("\(r.accuracy ?? 0)%", "\(r.right) of \(r.seen)")
                    stat(r.msMean.map { "\(Int($0.rounded()))" } ?? "—", "mean ms")
                    stat("\(r.streak)", "streak")
                }
                let confusions = r.confusions.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                if !confusions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("picked instead").font(.system(size: 10, design: .monospaced)).foregroundStyle(PracticeTheme.muted)
                        ForEach(confusions.prefix(6), id: \.key) { k, v in
                            HStack(spacing: 10) {
                                Text(k).font(PracticeTheme.script(24)).foregroundStyle(PracticeTheme.ink).frame(width: 64, alignment: .leading)
                                Text(k).font(PracticeTheme.mono).foregroundStyle(PracticeTheme.accent)
                                Spacer()
                                Text("×\(v)").font(PracticeTheme.mono).foregroundStyle(PracticeTheme.muted)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).practiceCard().padding(.horizontal, 16)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .monospaced)).monospacedDigit().foregroundStyle(PracticeTheme.ink)
            Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(PracticeTheme.muted)
        }
    }
}
