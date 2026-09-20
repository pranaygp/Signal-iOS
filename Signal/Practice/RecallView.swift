//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import SwiftUI

// MARK: - Model

/// One sitting at the flash cards. The store keeps the levels; this keeps the
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
        set { modeRaw = newValue.rawValue; objectWillChange.send(); next() }
    }

    @Published private(set) var card: Card?
    @Published private(set) var seen = 0
    @Published private(set) var hit = 0
    @Published private(set) var blocks = QiulingFonts.shared.blocks
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

    /// "7 of 9 right"; empty before the first answer.
    var score: String { seen > 0 ? "\(hit) of \(seen) right" : "" }
}

@available(iOS 16, *)
extension Recall.Mode {
    var title: String {
        switch self { case .both: "Both directions"; case .read: "Read the mark"; case .write: "Write the mark" }
    }
}

// MARK: - Screen

/// The prompt large in the upper half, the four answers in a grid pinned to
/// the bottom where a thumb already is. The direction lives in the bar, set
/// up by the hosting controller.
@available(iOS 16, *)
struct RecallView: View {
    @ObservedObject var model: RecallModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 112
    @ScaledMetric(relativeTo: .title) private var optionMarkSize: CGFloat = 50
    @ScaledMetric(relativeTo: .subheadline) private var feedbackMarkSize: CGFloat = 28
    @ScaledMetric(relativeTo: .subheadline) private var feedbackHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            if let c = model.card {
                if #unavailable(iOS 26) {
                    Text(model.score)
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: model.seen)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .padding(.top, 8)
                        .opacity(model.seen > 0 ? 1 : 0)
                        .accessibilityHidden(model.seen == 0)
                }
                prompt(c)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                feedback(c)
                    .frame(maxWidth: .infinity, minHeight: feedbackHeight)
                    .padding(.horizontal, 20)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Signal.groupedBackground)
        .safeAreaInset(edge: .bottom) {
            if let c = model.card { answers(c) }
        }
        .onAppear { if model.card == nil { model.next() } }
    }

    @ViewBuilder
    private var empty: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView("No marks to practice", systemImage: "rectangle.stack", description: Text("This alphabet has nothing to drill yet."))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
                Text("No marks to practice").font(.title3.weight(.semibold))
                Text("This alphabet has nothing to drill yet.").font(.body).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func prompt(_ c: RecallModel.Card) -> some View {
        VStack(spacing: 12) {
            if c.direction == .read {
                Text(c.mark)
                    .font(PracticeTheme.script(markSize))
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.Signal.label)
                    .accessibilityLabel("Mark")
            } else {
                Text(c.mark)
                    .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                    .kerning(4)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.Signal.label)
                    .accessibilityLabel(PracticeFormat.spelled(c.mark))
            }
            Text(c.direction == .read ? "What does this say?" : "Which mark spells this?")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: c.mark)
    }

    /// Kept in the layout even when empty so the grid does not jump when a
    /// wrong answer lands.
    @ViewBuilder
    private func feedback(_ c: RecallModel.Card) -> some View {
        if let picked = c.picked, picked != c.mark {
            Group {
                if c.direction == .read {
                    Text("You picked \(picked). It was \(c.mark).")
                } else {
                    Text("You picked ") + Text(picked).font(PracticeTheme.script(feedbackMarkSize))
                        + Text(". It was ") + Text(c.mark).font(PracticeTheme.script(feedbackMarkSize)) + Text(".")
                }
            }
            .font(.subheadline)
            .foregroundStyle(PracticeTheme.wrong)
            .multilineTextAlignment(.center)
            .accessibilityLabel("You picked \(PracticeFormat.spelled(picked)). It was \(PracticeFormat.spelled(c.mark)).")
        }
    }

    private func answers(_ c: RecallModel.Card) -> some View {
        let columns = typeSize >= .accessibility3 ? 1 : 2
        return VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: columns), spacing: 12) {
                ForEach(c.options, id: \.self) { o in
                    Button { model.pick(o) } label: {
                        answerLabel(o, c.direction)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .contentShape(Rectangle())
                    }
                    .optionButton(tint: tint(o, c))
                    .accessibilityLabel(answerSpoken(o, c))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .animation(.snappy, value: c.picked)
            Button("Skip") { model.next() }
                .buttonStyle(.borderless)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .practiceHaptic(trigger: c.picked) { _, new in new.map { $0 == c.mark } }
    }

    @ViewBuilder
    private func answerLabel(_ o: String, _ d: Recall.Direction) -> some View {
        if d == .read {
            Text(o).font(.title3.monospaced().weight(.semibold)).kerning(2)
        } else {
            Text(o).font(PracticeTheme.script(optionMarkSize))
        }
    }

    private func answerSpoken(_ o: String, _ c: RecallModel.Card) -> String {
        var label = PracticeFormat.spelled(o)
        if c.picked != nil {
            if o == c.mark { label += ", correct" } else if o == c.picked { label += ", incorrect" }
        }
        return label
    }

    /// Neutral until an answer lands; then the answer goes green and a wrong pick red.
    private func tint(_ o: String, _ c: RecallModel.Card) -> Color? {
        guard let picked = c.picked else { return nil }
        if o == c.mark { return PracticeTheme.good }
        if o == picked { return PracticeTheme.wrong }
        return nil
    }
}

@available(iOS 16, *)
private extension View {
    /// An answer card: a system bordered button (glass on iOS 26), tinted by result.
    @ViewBuilder
    func optionButton(tint: Color?) -> some View {
        if #available(iOS 26, *) {
            if let tint { self.buttonStyle(.glassProminent).tint(tint) } else { self.buttonStyle(.glass).tint(Color.Signal.label) }
        } else {
            if let tint { self.buttonStyle(.borderedProminent).tint(tint) } else { self.buttonStyle(.bordered).tint(Color.Signal.label) }
        }
    }
}

// MARK: - Progress

/// Where every mark stands, as sections of the Progress list: the four
/// counts and a heat map of the alphabet, the marks that keep slipping and
/// the ones that are done. Tap a mark for the numbers behind its colour.
@available(iOS 16, *)
struct RecallProgressSections: View {
    let book: PracticeStore.Book
    let blocks: [String]
    @Binding var detail: String?
    @ScaledMetric(relativeTo: .title) private var rowGlyph: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var mapGlyph: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var chipGlyph: CGFloat = 20

    struct Row: Identifiable {
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
        let struggling = rows.filter { $0.label == .struggling }.sorted { ($0.accuracy ?? 0, -$0.seen) < ($1.accuracy ?? 0, -$1.seen) }
        let mastered = rows.filter { $0.label == .mastered }

        SignalSection {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { countTiles(counts) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) { countTiles(counts) }
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                ForEach(rows) { r in
                    Button { detail = r.mark } label: {
                        VStack(spacing: 2) {
                            Text(r.mark).font(PracticeTheme.script(mapGlyph)).foregroundStyle(Color.Signal.label)
                            Text(r.mark).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, 6)
                        .background(PracticeTheme.statusFill(r.label), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(PracticeFormat.spelled(r.mark)), \(r.label.title.lowercased())")
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        } header: {
            Text("Recall")
        } footer: {
            Text("Tap a mark to see its record.")
        }

        if !struggling.isEmpty {
            SignalSection {
                ForEach(struggling.prefix(8)) { r in
                    Button { detail = r.mark } label: {
                        HStack(spacing: 12) {
                            Text(r.mark).font(PracticeTheme.script(rowGlyph)).foregroundStyle(Color.Signal.label).frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.mark).font(.system(.body, design: .monospaced)).foregroundStyle(Color.Signal.label)
                                if let c = r.topConfusion {
                                    Text("Often picked \(c)").font(.footnote).foregroundStyle(PracticeTheme.wrong)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(r.accuracy ?? 0)%").font(.subheadline.monospacedDigit()).foregroundStyle(PracticeTheme.wrong)
                                if let ms = r.meanMs {
                                    Text(PracticeFormat.seconds(ms: ms)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            Image(systemName: "chevron.right").foregroundStyle(Color.Signal.tertiaryLabel).imageScale(.small)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Struggling")
            }
        }

        if !mastered.isEmpty {
            SignalSection {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(mastered.prefix(12)) { r in
                        Button { detail = r.mark } label: {
                            HStack(spacing: 6) {
                                Text(r.mark).font(PracticeTheme.script(chipGlyph)).foregroundStyle(Color.Signal.label)
                                Text(r.mark).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(PracticeTheme.statusFill(.mastered), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(PracticeFormat.spelled(r.mark)), mastered")
                    }
                }
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } header: {
                Text("Mastered")
            } footer: {
                if mastered.count > 12 {
                    Text("And \(mastered.count - 12) more. All are in the map above.")
                } else {
                    Text("Marks you get right every time, in both directions.")
                }
            }
        }
    }

    @ViewBuilder
    private func countTiles(_ counts: [Recall.Label: Int]) -> some View {
        ForEach([Recall.Label.mastered, .learning, .struggling, .new], id: \.self) { l in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(counts[l] ?? 0)")
                    .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Color.Signal.label)
                Text(l.title).font(.footnote).foregroundStyle(PracticeTheme.statusColor(l))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(counts[l] ?? 0) \(l.title.lowercased())")
        }
    }
}

// MARK: - Mark detail

/// The numbers behind one mark, each direction on its own.
@available(iOS 16, *)
struct RecallMarkDetail: View {
    let mark: String
    let item: PracticeStore.RecallItem?
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var heroGlyph: CGFloat = 88
    @ScaledMetric(relativeTo: .body) private var rowGlyph: CGFloat = 24

    private var label: Recall.Label { Recall.label(item) }

    var body: some View {
        NavigationStack {
            SignalList(presented: true) {
                SignalSection {
                    VStack(spacing: 8) {
                        Text(mark).font(PracticeTheme.script(heroGlyph)).foregroundStyle(Color.Signal.label)
                        Text(mark).font(.title3.monospaced().weight(.semibold)).kerning(3).foregroundStyle(.secondary)
                        Text(label.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PracticeTheme.statusColor(label))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(PracticeTheme.statusFill(label), in: Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(PracticeFormat.spelled(mark)), \(label.title.lowercased())")
                }

                direction(.read, item?.read ?? .init(), header: "Reading the mark", footer: "You see the mark and choose its letters.")
                direction(.write, item?.write ?? .init(), header: "Writing the mark", footer: "You see the letters and choose the mark.")

                SignalSection {
                    EmptyView()
                } footer: {
                    Text("Levels go up one with each right answer and down two with a wrong one. Level 5 is mastered.")
                }
            }
            .navigationTitle(mark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func direction(_ d: Recall.Direction, _ r: PracticeStore.RecallRecord, header: String, footer: String) -> some View {
        SignalSection {
            if r.seen == 0 {
                Text("Not asked yet").foregroundStyle(.secondary)
            } else {
                detailRow("Level", r.box >= 5 ? "Mastered" : "\(r.box) of 5")
                detailRow("Right", "\(r.right) of \(r.seen)")
                detailRow("Streak", r.streak > 0 ? "\(r.streak) in a row" : "None yet")
                if let ms = r.msMean { detailRow("Time to answer", PracticeFormat.seconds(ms: ms)) }
                let confusions = r.confusions.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                if !confusions.isEmpty {
                    Text("Picked instead").font(.footnote).foregroundStyle(.secondary)
                    ForEach(confusions.prefix(6), id: \.key) { k, v in
                        HStack(spacing: 12) {
                            Text(k).font(PracticeTheme.script(rowGlyph)).foregroundStyle(Color.Signal.label).frame(width: 48, alignment: .leading)
                            Text(k).font(.system(.body, design: .monospaced)).foregroundStyle(PracticeTheme.wrong)
                            Spacer()
                            Text(v == 1 ? "1 time" : "\(v) times").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Picked \(PracticeFormat.spelled(k)) \(v == 1 ? "1 time" : "\(v) times")")
                    }
                }
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).font(.body.monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.body)
    }
}
