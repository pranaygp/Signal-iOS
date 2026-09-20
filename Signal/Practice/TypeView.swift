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
    enum Source: String, CaseIterable { case sentences, words, own
        var label: String { switch self { case .sentences: "sentences"; case .words: "words"; case .own: "your text" } }
    }

    @AppStorage("Practice.source") var sourceRaw = Source.sentences.rawValue
    @AppStorage("Practice.seconds") var seconds = 30
    @AppStorage("Practice.ownText") var ownText = ""
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
    private var ownLines: [String] = []
    private var ownIndex = 0

    /// True while keys are landing: the chrome dims.
    var isTyping: Bool { focused && race?.startedAt != nil && !finished }

    init() {
        Task { await PracticeCorpus.shared.loadIfNeeded(); corpusReady = true; if race == nil { start() } }
        NotificationCenter.default.addObserver(forName: QiulingFonts.fontDidChange, object: nil, queue: .main) { [weak self] _ in
            QiulingSegmenter.clearCache(); self?.start()
        }
    }

    private func nextLine() -> String {
        switch source {
        case .sentences: return PracticeCorpus.shared.nextSentence()
        case .words: return PracticeCorpus.shared.nextWordLine()
        case .own:
            guard !ownLines.isEmpty else { return PracticeCorpus.shared.nextSentence() }
            defer { ownIndex = (ownIndex + 1) % ownLines.count }
            return ownLines[ownIndex]
        }
    }

    func start() {
        ticker?.invalidate()
        finished = false
        input = ""; lastInput = ""
        if source == .own {
            let words = QiulingSegmenter.normalise(ownText).split(separator: " ").map(String.init)
            ownLines = stride(from: 0, to: words.count, by: 8).map { words[$0..<min($0 + 8, words.count)].joined(separator: " ") }.filter { !$0.isEmpty }
            ownIndex = 0
        }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                if model.finished, let race = model.race {
                    ResultsView(race: race) { model.start() }
                } else {
                    raceArea
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboardIfAvailable()
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
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Passage", selection: Binding(get: { model.source }, set: { model.source = $0; model.start() })) {
                ForEach(RaceModel.Source.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Duration", selection: Binding(get: { model.seconds }, set: { model.seconds = $0; model.start() })) {
                ForEach([15, 30, 60, 120], id: \.self) { Text("\($0)s").tag($0) }
            }
            .pickerStyle(.segmented)
            if model.source == .own {
                OwnTextEditor(model: model)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var raceArea: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(Int(model.remaining.rounded(.up))))
                    .font(PracticeTheme.numeral).foregroundStyle(PracticeTheme.accent)
                Spacer()
                if let race = model.race, race.startedAt == nil {
                    Text("tap the passage and type what you read").font(.footnote).foregroundStyle(PracticeTheme.muted)
                }
            }
            .padding(.horizontal, 20)

            if let race = model.race {
                PassageView(race: race, generation: model.generation, focused: model.focused)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture { fieldFocused = true }
                    .overlay {
                        if !model.focused {
                            Text(race.startedAt == nil ? "tap to begin" : "tap to continue")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .practiceGlass()
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                Text("loading the corpus…").font(.system(size: 13)).foregroundStyle(PracticeTheme.muted).padding(.horizontal, 20)
            }

            HStack {
                Button("Restart", systemImage: "arrow.counterclockwise") { model.start() }.practiceSecondaryButton()
                Spacer()
                Text("\(QiulingFonts.buildId) · \(QiulingFonts.shared.blocks.count) ligatures · space skips a word")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(PracticeTheme.faint)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 20)
        }
    }
}

@available(iOS 16, *)
private extension View {
    @ViewBuilder func scrollDismissesKeyboardIfAvailable() -> some View {
        if #available(iOS 16, *) { self.scrollDismissesKeyboard(.interactively) } else { self }
    }
}

// MARK: - Passage

/// The current line in the script with your progress marked into it, the
/// Latin you have typed under it, and the next line waiting below.
@available(iOS 16, *)
struct PassageView: View {
    let race: Race
    let generation: Int
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            scriptLine(race.current, typed: race.typed, active: true)
            typedRow
            if race.lines.indices.contains(race.lineIndex + 1) {
                scriptLine(race.lines[race.lineIndex + 1], typed: "", active: false).opacity(0.28)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
        .blur(radius: focused ? 0 : 5)
        .opacity(focused ? 1 : 0.6)
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    /// Each drawn block is its own run so a colour change never splits a ligature.
    private func scriptLine(_ line: Race.Line, typed: String, active: Bool) -> some View {
        let typedChars = Array(typed)
        let text = Array(line.text)
        var out = AttributedString()
        for b in line.blocks {
            var run = AttributedString(b.text)
            run.font = PracticeTheme.script(active ? 40 : 30)
            if b.isSpace { run.foregroundColor = PracticeTheme.ink; out += run; continue }
            let typedHere = b.range.filter { $0 < typedChars.count }
            let isCurrent = active && b.range.contains(typedChars.count)
            if typedHere.count == b.range.count {
                let allRight = typedHere.allSatisfy { typedChars[$0] == text[$0] }
                run.foregroundColor = UIColor(allRight ? PracticeTheme.muted : PracticeTheme.accent)
                if !allRight { run.backgroundColor = PracticeTheme.wrongBackground }
            } else if isCurrent {
                run.backgroundColor = PracticeTheme.tint
            } else {
                run.foregroundColor = PracticeTheme.ink
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
                r.foregroundColor = UIColor(typed[i] == ch ? PracticeTheme.good : PracticeTheme.accent)
                if typed[i] != ch { r.backgroundColor = PracticeTheme.wrongBackground }
                out += r
            } else if ch == " " {
                out += AttributedString(" ")
            } else {
                var r = AttributedString("_"); r.foregroundColor = PracticeTheme.faint; out += r
            }
        }
        if !race.extra.isEmpty {
            var r = AttributedString(race.extra); r.foregroundColor = PracticeTheme.accent; out += r
        }
        return Text(out).font(.system(size: 14, weight: .semibold, design: .monospaced)).kerning(0.8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Your text

@available(iOS 16, *)
struct OwnTextEditor: View {
    @ObservedObject var model: RaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PracticeEditor(text: $model.ownText, minHeight: 88)
            HStack {
                Button("Race this text", systemImage: "flag.checkered") { model.start() }.practicePrimaryButton()
                Text("folded to a–z and spaces").font(.system(size: 11, design: .monospaced)).foregroundStyle(PracticeTheme.faint)
            }
        }
    }
}

// MARK: - Results

@available(iOS 16, *)
struct ResultsView: View {
    let race: Race
    let again: () -> Void

    var body: some View {
        let s = race.stats()
        let store = PracticeStore.shared
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                stat("\(s.wpm)", "wpm")
                stat("\(s.accuracy)", "accuracy %")
                stat(race.slowest(min: 1).isEmpty ? "—" : "\(medianDecode())", "median decode ms", small: true)
                stat("\(s.blocks)", "marks read", small: true)
            }
            .padding(.horizontal, 20)

            if s.wpm >= store.best, store.book.sessions.count > 1 {
                Text("personal best").practiceLabel().foregroundStyle(PracticeTheme.good).padding(.horizontal, 20)
            }

            if #available(iOS 16, *) { chart.padding(.horizontal, 16) }

            let misread = race.misreadings()
            if !misread.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("what you misread").practiceLabel()
                    ForEach(misread.prefix(8)) { m in
                        HStack(spacing: 14) {
                            Text(m.text).font(PracticeTheme.script(30)).frame(width: 88, alignment: .leading)
                            Text(m.got).font(PracticeTheme.mono).foregroundStyle(PracticeTheme.accent).bold()
                            Text("→").foregroundStyle(PracticeTheme.faint)
                            Text(m.text).font(PracticeTheme.mono).foregroundStyle(PracticeTheme.good).bold()
                            Spacer()
                            Text("×\(m.n)").font(PracticeTheme.mono).foregroundStyle(PracticeTheme.muted)
                        }
                    }
                }
                .padding(18).practiceCard().padding(.horizontal, 16)
            }

            let slow = race.slowest()
            if !slow.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("slowest to recognise").practiceLabel()
                    ForEach(slow.prefix(6)) { m in
                        HStack {
                            Text(m.text).font(PracticeTheme.script(30)).frame(width: 88, alignment: .leading)
                            Text(m.text).font(PracticeTheme.mono).foregroundStyle(PracticeTheme.muted)
                            Spacer()
                            Text("\(m.ms) ms").font(PracticeTheme.mono).foregroundStyle(PracticeTheme.ink)
                        }
                    }
                }
                .padding(18).practiceCard().padding(.horizontal, 16)
            }

            Button("Again", systemImage: "arrow.counterclockwise") { again() }.practicePrimaryButton().controlSize(.large).padding(.horizontal, 20)
        }
    }

    private func medianDecode() -> Int {
        let d = race.marks.compactMap { $0.clean ? $0.decode : nil }.sorted()
        return d.isEmpty ? 0 : Int((d[d.count / 2] * 1000).rounded())
    }

    private func stat(_ value: String, _ label: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: small ? 24 : 44, weight: .semibold, design: .monospaced)).monospacedDigit()
                .foregroundStyle(small ? PracticeTheme.muted : PracticeTheme.ink)
            Text(label).practiceLabel()
        }
    }

    @available(iOS 16, *)
    private var chart: some View {
        let series = race.series()
        return VStack(alignment: .leading, spacing: 8) {
            Text("this run, second by second").practiceLabel()
            Chart {
                ForEach(series, id: \.s) { p in
                    LineMark(x: .value("s", p.s), y: .value("raw", p.raw)).foregroundStyle(PracticeTheme.faint).interpolationMethod(.monotone)
                    LineMark(x: .value("s", p.s), y: .value("wpm", p.avg), series: .value("k", "avg")).foregroundStyle(PracticeTheme.ink).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                    if p.err > 0 {
                        PointMark(x: .value("s", p.s), y: .value("raw", p.raw)).foregroundStyle(PracticeTheme.accent).symbolSize(30)
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(PracticeTheme.line); AxisValueLabel().font(.system(size: 9, design: .monospaced)).foregroundStyle(PracticeTheme.muted) } }
            .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 9, design: .monospaced)).foregroundStyle(PracticeTheme.muted) } }
            .frame(height: 150)
            HStack(spacing: 14) {
                legend(PracticeTheme.ink, "wpm so far"); legend(PracticeTheme.faint, "raw, that second"); legend(PracticeTheme.accent, "mistakes")
            }
        }
        .padding(18).practiceCard()
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Rectangle().fill(c).frame(width: 12, height: 2); Text(t).font(.system(size: 10, design: .monospaced)).foregroundStyle(PracticeTheme.muted) }
    }
}
