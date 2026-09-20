//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Charts
import SignalUI
import SwiftUI

// MARK: - Model

/// One sitting at the passage: source, clock, the race, and what the keyboard
/// sends. Owned by the tab so switching sections mid-race keeps it.
@available(iOS 16, *)
@MainActor
final class RaceModel: ObservableObject {
    enum Source: String, CaseIterable { case sentences, words
        var label: String { switch self { case .sentences: "Sentences"; case .words: "Words" } }
    }

    static let durations = [15, 30, 60, 120]

    @AppStorage("Practice.source") var sourceRaw = Source.sentences.rawValue
    @AppStorage("Practice.seconds") var seconds = 30
    var source: Source { get { Source(rawValue: sourceRaw) ?? .sentences } set { sourceRaw = newValue.rawValue } }

    @Published private(set) var race: Race?
    @Published private(set) var remaining: TimeInterval = 30
    @Published private(set) var finished = false
    @Published var focused = false
    @Published private(set) var corpusReady = false
    @Published var input = ""          // the hidden field's text; diffed into keys
    /// Bumped per keystroke so views holding the `Race` reference re-render.
    @Published private(set) var generation = 0
    private var lastInput = ""
    private var ticker: Timer?

    /// True once the first key has landed and until the clock runs out.
    var isRunning: Bool { race?.startedAt != nil && !finished }

    init() {
        // Earlier builds offered a "your text" source; a saved choice of it
        // falls back to sentences, and the text it kept is let go.
        if Source(rawValue: sourceRaw) == nil { sourceRaw = Source.sentences.rawValue }
        UserDefaults.standard.removeObject(forKey: "Practice.ownText")
        Task { await PracticeCorpus.shared.loadIfNeeded(); corpusReady = true; if race == nil { start() } }
        NotificationCenter.default.addObserver(forName: QiulingFonts.fontDidChange, object: nil, queue: .main) { [weak self] _ in
            QiulingSegmenter.clearCache(); self?.start()
        }
    }

    private func nextLine() -> String {
        switch source {
        case .sentences: return PracticeCorpus.shared.nextSentence()
        case .words: return PracticeCorpus.shared.nextWordLine()
        }
    }

    func start() {
        ticker?.invalidate(); ticker = nil
        finished = false
        input = ""; lastInput = ""
        race = Race(seconds: TimeInterval(seconds), next: nextLine)
        remaining = TimeInterval(seconds)
    }

    /// The hidden text field changed: turn the difference into keystrokes.
    func inputChanged(_ new: String) {
        guard let race, !finished else { return }
        let old = lastInput
        if new.count < old.count {
            for _ in 0..<(old.count - new.count) { if race.key(nil) { finish() } }
        } else if new.hasPrefix(old) {
            for ch in new.dropFirst(old.count) {
                let c = Character(String(ch).lowercased())
                if c == "\n" { if race.key(" ") { finish() } } else if race.key(c) { finish() }
            }
        } else {
            // The keyboard rewrote the field (a smart replacement slipped
            // through); treat it as a fresh keystroke of the last character.
            if let last = new.last, race.key(Character(String(last).lowercased())) { finish() }
        }
        lastInput = new
        if new.count > 200 { input = ""; lastInput = "" }
        if race.startedAt != nil, ticker == nil { startTicking() }
        generation += 1
    }

    private func startTicking() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let race = self.race else { return }
                self.remaining = race.remaining()
                if self.remaining <= 0 { self.finish() }
            }
        }
    }

    func finish() {
        guard let race, !finished else { return }
        ticker?.invalidate(); ticker = nil
        race.finish()
        finished = true
        focused = false
        PracticeStore.shared.record(race: race, mode: source.rawValue)
    }
}

// MARK: - Screen

@available(iOS 16, *)
struct TypeView: View {
    @ObservedObject var model: RaceModel
    @FocusState private var fieldFocused: Bool
    /// Results wait one beat after the clock shows 0, so the end of the race
    /// is seen before the numbers land.
    @State private var showResults = false
    @AccessibilityFocusState private var passageFocused: Bool

    var body: some View {
        Group {
            if showResults, let race = model.race {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, OWSTableViewController2.defaultHOuterMargin)
                        .padding(.vertical, 12)
                    ResultsView(race: race) { model.start(); passageFocused = true }
                }
                .transition(.opacity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        header
                        passageCard
                        stateSlot
                    }
                    .padding(.horizontal, OWSTableViewController2.defaultHOuterMargin)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: showResults)
        .background(Color.Signal.groupedBackground)
        .background {
            // The keyboard's target. Invisible; a tap on the passage focuses it.
            TextField("", text: $model.input)
                .focused($fieldFocused)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .opacity(0.02)
                .frame(width: 1, height: 1)
                .onChange(of: model.input) { model.inputChanged($0) }
                .onChange(of: fieldFocused) { model.focused = $0 }
                .onChange(of: model.focused) { if $0 != fieldFocused { fieldFocused = $0 } }
        }
        .onChange(of: model.finished) { finished in
            if finished {
                Task { try? await Task.sleep(nanoseconds: 400_000_000); if model.finished { showResults = true } }
            } else {
                showResults = false
            }
        }
    }

    // MARK: Header

    private var secondsLeft: Int { model.finished ? 0 : Int(model.remaining.rounded(.up)) }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                if !showResults { countdown }
                Spacer()
                optionsMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                if !showResults { countdown }
                optionsMenu
            }
        }
    }

    private var countdown: some View {
        Text("\(secondsLeft)")
            .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
            .contentTransition(.numericText())
            .animation(.default, value: secondsLeft)
            .foregroundStyle(model.isRunning ? Color.Signal.accent : Color.Signal.secondaryLabel)
            .accessibilityLabel("\(secondsLeft) seconds left")
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Passage", selection: Binding(get: { model.source }, set: { model.source = $0; model.start() })) {
                ForEach(RaceModel.Source.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Duration", selection: Binding(get: { model.seconds }, set: { model.seconds = $0; model.start() })) {
                ForEach(RaceModel.durations, id: \.self) { Text(PracticeFormat.durationSpelled($0)).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New passage", systemImage: "arrow.clockwise") { model.start() }
        } label: {
            HStack(spacing: 4) {
                Text("\(model.source.label) · \(PracticeFormat.duration(model.seconds))")
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.subheadline.weight(.medium))
        }
        .practiceSecondaryButton()
        .controlSize(.small)
        .disabled(model.race == nil)
        .accessibilityLabel("Race options")
    }

    // MARK: Passage

    @ViewBuilder
    private var passageCard: some View {
        if let race = model.race {
            let dimmed = !model.focused && !model.finished
            PassageView(race: race, generation: model.generation)
                .blur(radius: dimmed ? 5 : 0)
                .opacity(dimmed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = true }
                .overlay {
                    if dimmed {
                        Text(race.startedAt == nil ? "Tap to start" : "Tap to continue")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .practiceGlass()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: dimmed)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Passage")
                .accessibilityHint("Double tap, then type what you read.")
                .accessibilityAddTraits(.isButton)
                .accessibilityFocused($passageFocused)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading passages…").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(20)
            .practiceCardBackground()
        }
    }

    private var stateSlot: some View {
        ZStack {
            if model.finished {
                EmptyView()
            } else if model.race != nil, !model.isRunning {
                Text("Type what you read. Press space to skip a word you can't make out.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            } else if model.isRunning {
                Button("Start over", systemImage: "arrow.counterclockwise") { model.start() }
                    .practiceSecondaryButton()
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

// MARK: - Passage

/// The current line in the script with your progress marked into it, the
/// Latin you have typed under it, and the next line waiting below.
@available(iOS 16, *)
struct PassageView: View {
    let race: Race
    let generation: Int
    @ScaledMetric(relativeTo: .title) private var scriptSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            scriptLine(race.current, typed: race.typed, active: true)
            typedRow
            if race.lines.indices.contains(race.lineIndex + 1) {
                scriptLine(race.lines[race.lineIndex + 1], typed: "", active: false).opacity(0.28)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCardBackground()
    }

    /// Each drawn mark is its own run so a colour change never splits a glyph.
    private func scriptLine(_ line: Race.Line, typed: String, active: Bool) -> some View {
        let typedChars = Array(typed)
        let text = Array(line.text)
        var out = AttributedString()
        for b in line.blocks {
            var run = AttributedString(b.text)
            run.font = PracticeTheme.script(active ? scriptSize : scriptSize * 0.75)
            if b.isSpace { run.foregroundColor = Color.Signal.label; out += run; continue }
            let typedHere = b.range.filter { $0 < typedChars.count }
            let isCurrent = active && b.range.contains(typedChars.count)
            if typedHere.count == b.range.count {
                let allRight = typedHere.allSatisfy { typedChars[$0] == text[$0] }
                run.foregroundColor = allRight ? Color.Signal.secondaryLabel : PracticeTheme.wrong
                if !allRight { run.backgroundColor = PracticeTheme.wrongBackground }
            } else if isCurrent {
                run.foregroundColor = Color.Signal.label
                run.backgroundColor = PracticeTheme.tint
            } else {
                run.foregroundColor = Color.Signal.label
            }
            out += run
        }
        return Text(out).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
    }

    /// What you typed, letter for letter: green right, red wrong, a rule for
    /// what is still to come — the answer is never on the page.
    private var typedRow: some View {
        let text = Array(race.current.text)
        let typed = Array(race.typed)
        var out = AttributedString()
        for (i, ch) in text.enumerated() {
            if i < typed.count {
                var r = AttributedString(typed[i] == raceSkip ? "·" : String(typed[i]))
                r.foregroundColor = typed[i] == ch ? PracticeTheme.good : PracticeTheme.wrong
                if typed[i] != ch { r.backgroundColor = PracticeTheme.wrongBackground }
                out += r
            } else if ch == " " {
                out += AttributedString(" ")
            } else {
                var r = AttributedString("_"); r.foregroundColor = Color.Signal.tertiaryLabel; out += r
            }
        }
        if !race.extra.isEmpty {
            var r = AttributedString(race.extra); r.foregroundColor = PracticeTheme.wrong; out += r
        }
        return Text(out).font(.system(.footnote, design: .monospaced).weight(.semibold)).kerning(0.8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Results

@available(iOS 16, *)
struct ResultsView: View {
    let race: Race
    let again: () -> Void
    @State private var celebrate = false
    @ScaledMetric(relativeTo: .title) private var glyphSize: CGFloat = 30

    private var stats: Race.Stats { race.stats() }

    /// Ties or beats the best saved race, once there is more than one to
    /// compare against; a race too short to be saved never counts.
    private var isBest: Bool {
        let store = PracticeStore.shared
        return stats.seconds >= 5 && stats.wpm >= store.best && store.book.sessions.count > 1
    }

    private var medianDecodeMs: Int? {
        let d = race.marks.compactMap { $0.clean ? $0.decode : nil }.sorted()
        return d.isEmpty ? nil : Int((d[d.count / 2] * 1000).rounded())
    }

    var body: some View {
        let s = stats
        let misread = race.misreadings()
        let slow = race.slowest()
        SignalList {
            SignalSection {
                hero(s)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } footer: {
                if s.seconds < 5 { Text("Races shorter than 5 seconds aren't saved to Progress.") }
            }

            SignalSection {
                chart(s)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } header: {
                Text("Second by second")
            } footer: {
                Text("Pace is your speed so far at each second. Dots mark seconds with a mistake.")
            }

            if !misread.isEmpty {
                SignalSection {
                    ForEach(misread.prefix(8)) { m in
                        HStack(spacing: 12) {
                            Text(m.text).font(PracticeTheme.script(glyphSize)).frame(width: 72, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.text).font(.system(.body, design: .monospaced)).foregroundStyle(Color.Signal.label)
                                Text(typedLine(m.got)).font(.footnote)
                            }
                            Spacer()
                            Text("×\(m.n)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(PracticeFormat.spelled(m.text)), typed as \(PracticeFormat.spelled(m.got)), \(m.n) times")
                    }
                } header: {
                    Text("What you misread")
                }
            }

            if !slow.isEmpty {
                SignalSection {
                    ForEach(slow.prefix(6)) { m in
                        HStack(spacing: 12) {
                            Text(m.text).font(PracticeTheme.script(glyphSize)).frame(width: 72, alignment: .leading)
                            Text(m.text).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(PracticeFormat.seconds(ms: m.ms)).font(.body.monospacedDigit()).foregroundStyle(Color.Signal.label)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(PracticeFormat.spelled(m.text)), \(PracticeFormat.secondsSpoken(ms: m.ms)) to read")
                    }
                } header: {
                    Text("Slowest to read")
                }
            }

            Color.clear.frame(height: 88).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        .safeAreaInset(edge: .bottom) {
            Button("Race again", systemImage: "arrow.counterclockwise") { again() }
                .practicePrimaryButton()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        }
        .onAppear { celebrate = isBest }
        .practiceSuccessHaptic(trigger: celebrate)
    }

    private func typedLine(_ got: String) -> AttributedString {
        var out = AttributedString("You typed ")
        var typed = AttributedString(got); typed.foregroundColor = PracticeTheme.wrong
        out += typed
        return out
    }

    // MARK: Hero

    private func hero(_ s: Race.Stats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(s.wpm)")
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                    if celebrate {
                        Label("New personal best", systemImage: "trophy.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PracticeTheme.good)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(PracticeTheme.good.opacity(0.14), in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text("Words per minute").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(s.wpm) words per minute\(celebrate ? ", new personal best" : "")")

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { tiles(s) }
                VStack(alignment: .leading, spacing: 12) { tiles(s) }
            }
        }
        .animation(.snappy, value: celebrate)
    }

    @ViewBuilder
    private func tiles(_ s: Race.Stats) -> some View {
        tile("\(s.accuracy)%", "Accuracy", spoken: "\(s.accuracy) percent accuracy")
        tile("\(s.blocks)", "Marks read", spoken: "\(s.blocks) marks read")
        tile(
            medianDecodeMs.map { PracticeFormat.seconds(ms: $0) } ?? "—",
            "Time to read a mark",
            spoken: medianDecodeMs.map { "\(PracticeFormat.secondsSpoken(ms: $0)) to read a mark" } ?? "No clean marks to time",
        )
    }

    private func tile(_ value: String, _ caption: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    // MARK: Chart

    private func chart(_ s: Race.Stats) -> some View {
        let series = race.series()
        let mistakes = series.reduce(0) { $0 + $1.err }
        return Chart {
            ForEach(series, id: \.s) { p in
                LineMark(x: .value("Second", p.s), y: .value("Words per minute", p.raw))
                    .foregroundStyle(by: .value("Series", "This second"))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Second", p.s), y: .value("Words per minute", p.avg))
                    .foregroundStyle(by: .value("Series", "Pace"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                if p.err > 0 {
                    PointMark(x: .value("Second", p.s), y: .value("Words per minute", p.raw))
                        .foregroundStyle(by: .value("Series", "Mistakes"))
                        .symbolSize(30)
                }
            }
        }
        .chartForegroundStyleScale([
            "Pace": Color.Signal.label,
            "This second": Color.Signal.tertiaryLabel,
            "Mistakes": PracticeTheme.wrong,
        ])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(Color.Signal.quaternaryFill)
                AxisValueLabel().font(.caption2.monospacedDigit()).foregroundStyle(Color.Signal.secondaryLabel)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v) s") }
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(Color.Signal.secondaryLabel)
            }
        }
        .font(.caption2)
        .frame(height: 160)
        .accessibilityLabel("Pace over the race, \(s.wpm) words per minute at the end, \(mistakes) mistakes")
    }
}
