//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Charts
import SignalUI
import SwiftUI

// MARK: - Write

/// Type English, see it in the script, send it as a picture: the messaging
/// apps draw everything in the system font, so a message travels as an image.
@available(iOS 16, *)
struct WriteView: View {
    static let draftKey = "Practice.draft"

    @AppStorage(WriteView.draftKey) private var draft = ""
    @State private var rendered: UIImage?
    @State private var renderFailed = false
    @State private var copied = false
    @State private var renderTask: Task<Void, Never>?
    @State private var revertTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var previewSize: CGFloat = 44

    private var hasMessage: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canShare: Bool { hasMessage && rendered != nil }

    var body: some View {
        SignalList {
            SignalSection {
                PracticeEditor(text: $draft, placeholder: "Type in English")
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                Text("Your message")
            } footer: {
                Text("Letters and spaces are drawn. Numbers and punctuation are left out.")
            }

            SignalSection {
                preview
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview in Qiuling")
                    .accessibilityValue(draft)
            } header: {
                Text("In Qiuling")
            } footer: {
                Text("Other apps can't draw Qiuling, so your message is shared as a picture.")
            }

            Color.clear.frame(height: 88).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { actions }
        .onChange(of: draft) { _ in scheduleRender() }
        .onAppear { rendered = render() }
        .practiceSuccessHaptic(trigger: copied)
    }

    @ViewBuilder
    private var preview: some View {
        if renderFailed {
            Text("The script isn't available right now.").font(.subheadline).foregroundStyle(.secondary)
        } else if hasMessage {
            Text(draft).font(PracticeTheme.script(previewSize)).lineSpacing(8).foregroundStyle(Color.Signal.label)
        } else {
            Text("Your message appears here in Qiuling.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            ShareLink(
                item: Image(uiImage: rendered ?? UIImage()),
                preview: SharePreview("Qiuling message", image: Image(uiImage: rendered ?? UIImage())),
            ) {
                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .practicePrimaryButton()
            .controlSize(.large)

            Button { copy() } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity)
            }
            .practiceSecondaryButton()
            .controlSize(.large)
            .practiceSymbolReplace()
        }
        .disabled(!canShare)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }

    private func copy() {
        guard let rendered else { return }
        UIPasteboard.general.image = rendered
        copied = true
        UIAccessibility.post(notification: .announcement, argument: "Copied")
        revertTask?.cancel()
        revertTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { copied = false }
        }
    }

    /// Rendering waits for a pause in typing; a PNG per keystroke is wasted work.
    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !Task.isCancelled { rendered = render() }
        }
    }

    /// The message as a PNG at 2×, in the theme's colours, wrapped to a chat's width.
    @MainActor
    private func render() -> UIImage? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { renderFailed = false; return nil }
        let view = Text(text)
            .font(PracticeTheme.script(56)).lineSpacing(10)
            .foregroundStyle(Color.Signal.label)
            .padding(40)
            .frame(width: 900, alignment: .leading)
            .background(Color.Signal.background)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = renderer.uiImage
        renderFailed = image == nil
        return image
    }
}

// MARK: - Progress

/// The Progress tab answers one question first: what share of your English
/// read-aloud speed are you at, is it moving, and can the number be trusted
/// right now. Every reading section is drawn from one slice — the tests, or
/// every reading — and typing has its own screen behind a row.
@available(iOS 16, *)
struct ProgressTabView: View {
    /// Pops back to the passage, from the empty state.
    var race: () -> Void = {}
    /// Pushes Recall, from the empty state.
    var recall: () -> Void = {}
    /// Pushes the typing screen.
    var typing: () -> Void = {}
    /// Sets the test up — in English when true — and pops back to it.
    var readTest: (Bool) -> Void = { _ in }

    /// Which readings the reading sections are drawn from.
    enum ReadScope: String, CaseIterable, Identifiable {
        case tests, all
        var id: String { rawValue }
        var label: String { self == .tests ? "tests" : "all readings" }
    }

    @ObservedObject private var store = PracticeStore.shared
    @AppStorage("Progress.readScope") private var scopeRaw = ""
    @State private var blocks: [String] = QiulingFonts.shared.blocks
    @State private var detail: String?
    @State private var confirmReset = false
    @State private var showAbout = false
    @State private var selectedDate: Date?

    private struct Mark: Identifiable { let text: String; var id: String { text } }

    var body: some View {
        let typed = store.typedSessions
        let tests = store.readTests
        let stored = ReadScope(rawValue: scopeRaw)
        let scope: ReadScope = stored ?? (tests.count >= 2 ? .tests : .all)
        let readings = scope == .tests ? tests : store.readSessions
        let series = store.ratioSeries()
        let nothing = typed.isEmpty && store.readSessions.isEmpty && store.book.recall.isEmpty
        Group {
            if nothing {
                empty.transition(.opacity)
            } else {
                SignalList {
                    if store.readSessions.isEmpty {
                        readingEmpty
                    } else {
                        reading(readings, scope: scope, series: series)
                    }
                    if !readings.isEmpty {
                        ProgressCurveSection(runs: readings, label: scope.label, english: series.points.last?.baseline, header: "Learning curve · \(scope.label)")
                        ProgressBreaksSection(exposure: store.exposureSessions, series: readings, label: scope.label)
                    }
                    if !typed.isEmpty {
                        typingRow(typed)
                    }

                    RecallProgressSections(book: store.book, blocks: blocks, detail: $detail)

                    SignalSection {
                        Button { showAbout = true } label: {
                            Label("About these numbers", systemImage: "info.circle")
                        }
                        .foregroundStyle(Color.Signal.accent)
                    }

                    SignalSection {
                        Button(role: .destructive) { confirmReset = true } label: {
                            Text("Reset progress").font(.body).foregroundStyle(Color.Signal.red).frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("Removes every reading, race and recall record for this alphabet.")
                    }
                }
                .confirmationDialog("Reset all progress?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset progress", role: .destructive) { withAnimation { store.reset() } }
                } message: {
                    Text("Every reading, race and recall record for this alphabet will be removed. This can't be undone.")
                }
                .sheet(isPresented: $showAbout) { AboutNumbersView() }
                .transition(.opacity)
            }
        }
        .animation(.default, value: nothing)
        .background(Color.Signal.groupedBackground)
        .sheet(item: Binding(get: { detail.map(Mark.init) }, set: { detail = $0?.text })) { m in
            RecallMarkDetail(mark: m.text, item: store.book.recall[m.text])
        }
        .onReceive(NotificationCenter.default.publisher(for: QiulingFonts.fontDidChange)) { _ in blocks = QiulingFonts.shared.blocks }
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 20) {
            if #available(iOS 17, *) {
                ContentUnavailableView("No progress yet", systemImage: "chart.line.uptrend.xyaxis", description: Text("Read a passage, finish a race or answer a few recall cards and your numbers show up here."))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No progress yet").font(.title3.weight(.semibold))
                    Text("Read a passage, finish a race or answer a few recall cards and your numbers show up here.").font(.body).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            }
            HStack(spacing: 12) {
                Button("Read") { race() }.practicePrimaryButton()
                Button("Recall") { recall() }.practiceSecondaryButton()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Races or recall exist, but nothing has been read aloud yet.
    private var readingEmpty: some View {
        SignalSection {
            VStack(spacing: 16) {
                if #available(iOS 17, *) {
                    ContentUnavailableView("No readings yet", systemImage: "waveform", description: Text("Read a passage aloud and it shows up here."))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No readings yet").font(.title3.weight(.semibold))
                        Text("Read a passage aloud and it shows up here.").font(.body).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
                Button("Read") { race() }.practicePrimaryButton().controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        } header: {
            Text("Reading aloud")
        }
    }

    // MARK: Reading

    /// Reading aloud, from the scoped readings: the share of English as the
    /// hero, the ratio over time (tests) or the speed over time (all), the
    /// newest readings, and one honest sentence about the number.
    private func reading(_ readings: [PracticeStore.Session], scope: ReadScope, series: PracticeStore.RatioSeries) -> some View {
        let goal = store.readingGoal
        let valid = series.points.filter { $0.percent != nil }
        let englishMissing = store.englishReadings.isEmpty
        let age = series.englishAt.map { max(0, Int(Date().timeIntervalSince($0) / 86400)) }
        let pool = scope == .tests ? readings + store.englishReadings : readings
        let rows = Array(pool.sorted { $0.date < $1.date }.suffix(8).reversed())
        let percents = Dictionary(series.points.map { ($0.id, $0.percent) }, uniquingKeysWith: { _, last in last })
        return SignalSection {
            Picker("Runs", selection: Binding(get: { scope }, set: { scopeRaw = $0.rawValue })) {
                Text("Tests").tag(ReadScope.tests)
                Text("All readings").tag(ReadScope.all)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { readingTiles(readings, scope: scope, goal: goal) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) { readingTiles(readings, scope: scope, goal: goal) }
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

            if scope == .tests {
                if valid.count >= 2 {
                    VStack(alignment: .leading, spacing: 10) {
                        ratioChart(valid)
                        ratioLegend(series.slope)
                    }
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
                } else if valid.isEmpty {
                    Button(englishMissing ? "Take the English test" : "Take the Qiuling test", systemImage: "textformat") { readTest(englishMissing) }
                        .foregroundStyle(Color.Signal.accent)
                }
            } else if readings.count >= 2 {
                // Before the first Qiuling test the goal has no baseline yet;
                // the English readings themselves still draw the line to reach.
                let englishLine = goal.english ?? (store.englishReadings.isEmpty ? nil
                    : Int(PracticeStore.median(store.englishReadings.suffix(3).map { Double($0.wpm) }).rounded()))
                readingsChart(Array(readings.suffix(60)), english: englishLine)
            }

            ForEach(rows) { s in
                readingRow(s, percent: scope == .tests ? (percents[s.id] ?? nil) : nil)
            }

            if scope == .tests, let age, age > 14 {
                Button { readTest(true) } label: {
                    Label("English baseline is \(age) days old — read it again", systemImage: "exclamationmark.triangle")
                }
                .foregroundStyle(PracticeTheme.wrong)
            }
        } header: {
            Text("Reading aloud")
        } footer: {
            Text(scope == .tests
                 ? readingNote(series, goal: goal, valid: valid, age: age)
                 : "Every reading, tests and practice; diamonds are tests, hollow dots had no microphone. Switch to Tests for the like-for-like number.")
        }
    }

    @ViewBuilder
    private func readingTiles(_ readings: [PracticeStore.Session], scope: ReadScope, goal: PracticeStore.ReadingGoal) -> some View {
        let pct = goal.percent.map { "\($0)%" } ?? "—"
        let pctSpoken = goal.percent.map { "\($0) percent of your English reading speed, aloud" } ?? "No share of English yet"
        switch scope {
        case .tests:
            progressTile(pct, "of English speed, read aloud", spoken: pctSpoken, hero: true, delta: goal.delta)
            if let last = readings.last {
                let correct = last.listened == true
                progressTile("\(last.wpm)", "Last test, \(correct ? "words correct/min" : "words/min")",
                             spoken: "Last test, \(last.wpm) words\(correct ? " correct" : "") per minute")
            }
            progressTile(goal.misreadPercent.map { "\($0)%" } ?? "—", goal.misreadPercent == nil ? "Misread, mic off" : "Misread, mic tests",
                         spoken: goal.misreadPercent.map { "\($0) percent misread on microphone tests" } ?? "Misread not scored, microphone off")
        case .all:
            let last = readings.last?.wpm ?? 0
            let best = readings.map(\.wpm).max() ?? 0
            progressTile("\(last) wpm", "Last reading", spoken: "Last reading, \(last) words per minute")
            progressTile("\(best) wpm", "Best reading", spoken: "Best reading, \(best) words per minute")
            progressTile(pct, "of English speed, tests", spoken: pctSpoken)
        }
    }

    /// One test, one dot; the line is the trailing three-test mean and 100 is
    /// English. Hollow dots are tests whose baseline should be read loosely.
    private func ratioChart(_ valid: [PracticeStore.RatioPoint]) -> some View {
        let top = Double(valid.compactMap(\.percent).max() ?? 100)
        let last = valid.last!
        let picked = selectedDate.flatMap { d in valid.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } }
        let chart = Chart {
            ForEach(valid) { p in
                if valid.count >= 3 {
                    LineMark(x: .value("Date", p.date), y: .value("Percent", p.trend ?? 0))
                        .foregroundStyle(Color.Signal.label)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                PointMark(x: .value("Date", p.date), y: .value("Percent", p.percent ?? 0))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                    .symbol { ChartDot(hollow: p.hollow) }
            }
            PointMark(x: .value("Date", last.date), y: .value("Percent", last.percent ?? 0))
                .foregroundStyle(Color.Signal.secondaryLabel)
                .symbol { ChartDot(hollow: last.hollow) }
                .annotation(position: .trailing) { Text("\(last.percent ?? 0)%").font(.caption.weight(.semibold)) }
            RuleMark(y: .value("English", 100))
                .foregroundStyle(Color.Signal.secondaryLabel)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .trailing) { Text("English · 100%").font(.caption2).foregroundStyle(.secondary) }
            if let picked {
                RuleMark(x: .value("Selected", picked.date))
                    .foregroundStyle(Color.Signal.tertiaryLabel)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top) { ratioCard(picked) }
            }
        }
        .chartYScale(domain: 0...max(110, top * 1.1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Color.Signal.quaternaryFill)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(Color.Signal.secondaryLabel)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(Color.Signal.quaternaryFill)
                AxisValueLabel().font(.caption2.monospacedDigit()).foregroundStyle(Color.Signal.secondaryLabel)
            }
        }
        .chartLegend(.hidden)
        // Room for the label beside the last point.
        .chartPlotStyle { $0.padding(.trailing, 32) }
        .frame(height: 160)
        return Group {
            if #available(iOS 17, *) {
                chart.chartXSelection(value: $selectedDate)
            } else {
                chart
            }
        }
        .accessibilityLabel("Share of your English reading speed, aloud, over time")
        .accessibilityValue("Latest \(last.trend ?? 0) percent from \(valid.count) tests")
    }

    private func ratioCard(_ p: PracticeStore.RatioPoint) -> some View {
        Text("\(p.date, format: .dateTime.month(.abbreviated).day()) · \(p.percent ?? 0)% · \(p.wpm) vs \(p.baseline ?? 0) \(p.scored ? "wcpm" : "wpm") · baseline \(p.baselineN), \(p.ageDays) d")
            .font(.caption2).foregroundStyle(Color.Signal.label)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.Signal.groupedBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func ratioLegend(_ slope: Double?) -> some View {
        let slopeText = slope.map { "\($0 >= 0 ? "+" : "−")\(String(format: "%.1f", abs($0))) pts a week" } ?? "slope after 4 tests over 2 weeks"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { legendItems(slopeText) }
            VStack(alignment: .leading, spacing: 4) { legendItems(slopeText) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func legendItems(_ slopeText: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.Signal.label).frame(width: 14, height: 3)
            Text("3-test average · \(slopeText)")
        }
        HStack(spacing: 5) {
            Circle().fill(Color.Signal.secondaryLabel).frame(width: 8, height: 8)
            Text("each test")
        }
        HStack(spacing: 5) {
            Circle().strokeBorder(Color.Signal.secondaryLabel, lineWidth: 1.5).frame(width: 8, height: 8)
            Text("stale baseline, mic mismatch or English read later")
        }
    }

    /// Every reading, by date: diamonds are tests, hollow dots had no
    /// microphone, and the line is the centred nine-reading mean.
    private func readingsChart(_ recent: [PracticeStore.Session], english: Int?) -> some View {
        let best = recent.map(\.wpm).max() ?? 0
        let bestIndex = recent.firstIndex { $0.wpm == best }
        return Chart {
            ForEach(Array(recent.enumerated()), id: \.element.id) { i, s in
                PointMark(x: .value("Date", s.date), y: .value("Words per minute", s.wpm))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                    .symbol { ChartDot(diamond: s.mode == "read-test", hollow: s.listened == false) }
                if recent.count >= 5 {
                    LineMark(x: .value("Date", s.date), y: .value("Words per minute", centredTrend(recent, at: i)))
                        .foregroundStyle(Color.Signal.label)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
            }
            if let bestIndex {
                let b = recent[bestIndex]
                PointMark(x: .value("Date", b.date), y: .value("Words per minute", b.wpm))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                    .symbol { ChartDot(diamond: b.mode == "read-test", hollow: b.listened == false) }
                    .annotation(position: .top) { Text("best").font(.caption2).foregroundStyle(.secondary) }
            }
            if let e = english {
                RuleMark(y: .value("English", e))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing) { Text("English · \(e)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Color.Signal.quaternaryFill)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(Color.Signal.secondaryLabel)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(Color.Signal.quaternaryFill)
                AxisValueLabel().font(.caption2.monospacedDigit()).foregroundStyle(Color.Signal.secondaryLabel)
            }
        }
        .chartLegend(.hidden)
        .frame(height: 160)
        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        .accessibilityLabel("Words per minute across your last \(recent.count) readings, best \(best)")
    }

    private func readingRow(_ s: PracticeStore.Session, percent: Int?) -> some View {
        let kind = s.mode == "read-test" ? "Test" : s.mode == "read-english" ? "English test" : "Passage"
        var note = [String]()
        if s.listened == true { note.append("\(100 - s.accuracy)% misread") } else if s.listened == false { note.append("mic off") }
        if let percent { note.append("\(percent)% of English") }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.body)
                Text("\(kind) · \(s.words ?? 0) words · \(PracticeFormat.duration(s.seconds))").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(s.wpm) \(s.listened == true ? "wcpm" : "wpm")").font(.body.monospacedDigit())
                if !note.isEmpty {
                    Text(note.joined(separator: " · ")).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The footer under Reading aloud, first match wins: what to do next while
    /// the number cannot be computed, then the number and how far to trust it.
    private func readingNote(_ series: PracticeStore.RatioSeries, goal: PracticeStore.ReadingGoal, valid: [PracticeStore.RatioPoint], age: Int?) -> String {
        let english = store.englishReadings
        let last = valid.last
        let unit = (last?.scored ?? false) ? "words correct a minute" : "words a minute"
        let n = min(3, valid.count)
        let q = goal.qiuling ?? 0, e = goal.english ?? 0
        var note: String
        if series.tests == 0, english.isEmpty {
            note = "Read the test aloud once in Qiuling and once in English, and this becomes one number to move."
        } else if english.isEmpty {
            note = "Read the test aloud once in English for your baseline — the share appears here."
        } else if series.tests == 0 {
            let baseline = Int(PracticeStore.median(english.suffix(3).map { Double($0.wpm) }).rounded())
            note = "Now read the test aloud in Qiuling; your English baseline is \(baseline) \(unit)."
        } else if let pct = goal.percent, valid.count == 1 {
            note = "One test so far: \(pct)% of your English speed (\(q) vs \(e) \(unit)). The line starts at two."
        } else if let pct = goal.percent, pct >= 100 {
            note = "You read Qiuling aloud as fast as English: \(pct)% (\(q) vs \(e) \(unit), last \(n) tests). The daily-driver line."
        } else if let pct = goal.percent, let age, age > 14 {
            note = "Your English read-aloud test is \(age) days old — redo it so the share stays honest. Until then: \(pct)% on a stale baseline."
        } else if let pct = goal.percent, n < 3 || goal.baselineN < 3 {
            note = "\(pct)% of your English speed aloud, from \(n) of 3 tests against \(goal.baselineN) of 3 English readings — provisional until the third."
        } else if let pct = goal.percent {
            note = "Your last three read-aloud tests against your nearest English ones: \(pct)% (\(q) vs \(e) \(unit))"
            if let d = goal.delta { note += ", \(d >= 0 ? "+" : "−")\(abs(d)) points since the test before" }
            note += "."
            if let s = series.slope, let first = valid.first, let last {
                let weeks = max(1, Int((last.date.timeIntervalSince(first.date) / 604_800).rounded()))
                note += " \(s >= 0 ? "+" : "−")\(String(format: "%.1f", abs(s))) points a week over \(weeks) weeks."
            } else {
                note += " A trend appears after 4 tests over 2 weeks."
            }
            note += " A speed ratio, not comprehension: it says how fast you decode, not how much you took in."
        } else {
            note = "Read the test aloud once in Qiuling and once in English, and this becomes one number to move."
        }
        if last?.mixed == true {
            note += " Some of these were read without a microphone, so this is words read, not words correct."
        }
        if last != nil, let age {
            let mic = series.points.last?.listened == false ? " · mic off on the last test" : ""
            note += " English baseline · \(age) d old · \(goal.baselineN) of 3 readings\(mic)."
        }
        return note
    }

    // MARK: Typing

    private func typingRow(_ typed: [PracticeStore.Session]) -> some View {
        SignalSection {
            Button { typing() } label: {
                HStack {
                    Text("Typing").foregroundStyle(Color.Signal.label)
                    Spacer()
                    Text("\(store.best) wpm best · \(typed.count) race\(typed.count == 1 ? "" : "s")").foregroundStyle(Color.Signal.secondaryLabel)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.Signal.tertiaryLabel)
                }
            }
        } footer: {
            Text("Typed races, accuracy and the marks you mistype.")
        }
    }
}

// MARK: - Shared pieces

/// A number with its caption. The hero is the one figure the tab is for and
/// takes the large title; a delta beside it says which way the last test moved.
@available(iOS 16, *)
private func progressTile(_ value: String, _ caption: String, spoken: String, hero: Bool = false, delta: Int? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(hero ? .largeTitle : .title, design: .rounded, weight: .semibold))
            if let delta {
                Text(delta >= 0 ? "+\(delta)" : "−\(-delta)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(delta >= 0 ? PracticeTheme.good : PracticeTheme.wrong)
            }
        }
        Text(caption).font(.footnote).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken + (delta.map { ", \($0 >= 0 ? "up" : "down") \(abs($0)) points since the test before" } ?? ""))
}

/// A chart marker: a circle, or a diamond for a test; hollow when the point
/// should be read loosely. A symbol view does not take the mark's foreground
/// style, so the colour is its own.
@available(iOS 16, *)
private struct ChartDot: View {
    var diamond = false
    var hollow = false
    var color = Color.Signal.secondaryLabel

    var body: some View {
        if diamond {
            if hollow {
                Rectangle().rotation(.degrees(45)).strokeBorder(color, lineWidth: 1.5).frame(width: 7, height: 7)
            } else {
                Rectangle().rotation(.degrees(45)).fill(color).frame(width: 7, height: 7)
            }
        } else {
            if hollow {
                Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 9, height: 9)
            } else {
                Circle().fill(color).frame(width: 9, height: 9)
            }
        }
    }
}

/// A centred nine-run average, so the line says where you are going rather
/// than how the last run went.
private func centredTrend(_ s: [PracticeStore.Session], at i: Int) -> Double {
    let lo = max(0, i - 4), hi = min(s.count - 1, i + 4)
    let w = s[lo...hi].map(\.wpm); return Double(w.reduce(0, +)) / Double(w.count)
}

// MARK: - Learning curve

/// Every run at its cumulative minutes of exposure, both axes logarithmic,
/// the power-law fit through them, and the English speed as the line to
/// reach. Kolers' result is that this is straight; the section shows whether
/// yours is and where it meets English.
@available(iOS 16, *)
private struct ProgressCurveSection: View {
    let runs: [PracticeStore.Session]
    /// The noun in the copy: "tests", "all readings" or "races".
    let label: String
    let english: Int?
    let header: String
    @ObservedObject private var store = PracticeStore.shared

    var body: some View {
        let fit = LearningCurve.powerLaw(runs)
        SignalSection {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { tiles(fit) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) { tiles(fit) }
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

            if let f = fit {
                if f.r2 < 0.3 || f.points.count < 5 {
                    Label("Too few or too scattered points to trust the line yet", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                chart(f)
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                    .accessibilityLabel(verdict(f))
            }
        } header: {
            Text(header)
        } footer: {
            Text(fit.map(verdict) ?? "After three \(label) a line is fitted through your speed against cumulative practice, both on log scales.")
        }
    }

    @ViewBuilder
    private func tiles(_ f: LearningCurve.Fit?) -> some View {
        progressTile(store.exposureText, "Practice so far, all modes", spoken: "\(store.exposureText) of practice so far, all modes")
        if let f {
            let tenfold = String(format: "%+d%%", Int(((pow(10, f.k) - 1) * 100).rounded()))
            let quality = f.r2 < 0.3 ? "loose" : f.r2 < 0.6 ? "fair" : "tight"
            progressTile(tenfold, "Speed per 10× practice", spoken: "\(tenfold) speed per tenfold practice")
            progressTile(quality, "Fit", spoken: "Fit \(quality)")
        }
    }

    private func chart(_ f: LearningCurve.Fit) -> some View {
        let xs = f.points.map(\.minutes), ys = f.points.map { Double($0.wpm) }
        let xLo = xs.min()! / 1.15, xHi = xs.max()! * 1.15
        let reach = english.flatMap { f.minutesTo($0) }
        // The fit runs to the edge of the data; beyond it a dashed forecast
        // to where it meets English, when that is within sight.
        let showReach = reach.map { $0 > xs.max()! && $0 <= xs.max()! * 8 } ?? false
        let xTop = showReach ? reach! * 1.15 : xHi
        let yLo = ys.min()! / 1.2, yHi = max(ys.max()!, Double(english ?? 0)) * 1.2
        let samples = stride(from: log(xs.min()!), through: log(showReach ? reach! : xs.max()!), by: (log(showReach ? reach! : xs.max()!) - log(xs.min()!)) / 24)
            .map { exp($0) }
        // Minutes below the hour, whole hours above it, so the labels read as
        // "20m … 2h … 10h" rather than as fractions of an hour.
        // A tick in the last few percent of a log axis has no room for its
        // label and shows as "1…"; leave that edge bare.
        let xTicks = ([1.0, 2, 5, 10, 20, 30] + [1.0, 2, 5, 10, 20, 50, 100, 200].map { $0 * 60 }).filter { $0 >= xLo && $0 <= xTop / 1.08 }
        return Chart {
            ForEach(f.points) { p in
                PointMark(x: .value("Minutes", p.minutes), y: .value("Words per minute", p.wpm))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                    .symbolSize(64)
            }
            ForEach(Array(samples.enumerated()), id: \.offset) { _, m in
                LineMark(x: .value("Minutes", m), y: .value("Fit", f.predict(m)), series: .value("Line", m <= xs.max()! * 1.0001 ? "fit" : "forecast"))
                    .foregroundStyle(Color.Signal.label)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: m <= xs.max()! * 1.0001 ? [] : [4, 4]))
            }
            if let e = english {
                RuleMark(y: .value("English", e))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("English · \(e)").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: xLo...xTop, type: .log)
        .chartYScale(domain: yLo...yHi, type: .log)
        .chartXAxis {
            AxisMarks(values: xTicks) { v in
                AxisGridLine().foregroundStyle(Color.Signal.quaternaryFill)
                AxisValueLabel {
                    if let m = v.as(Double.self) {
                        Text(m < 60 ? "\(Int(m))m" : "\(Int((m / 60).rounded()))h").font(.caption2.monospacedDigit()).foregroundStyle(Color.Signal.secondaryLabel)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [5, 10, 15, 20, 30, 50, 70, 100, 150, 200, 300, 500].filter { Double($0) > yLo && Double($0) < yHi }) {
                AxisGridLine().foregroundStyle(Color.Signal.quaternaryFill)
                AxisValueLabel().font(.caption2.monospacedDigit()).foregroundStyle(Color.Signal.secondaryLabel)
            }
        }
        .chartLegend(.hidden)
    }

    /// One sentence on what the line says.
    private func verdict(_ f: LearningCurve.Fit) -> String {
        let most = f.points.map(\.minutes).max()!
        let tenfold = Int(((pow(10, f.k) - 1) * 100).rounded())
        if f.k <= 0.01 {
            return "Over \(LearningCurve.minutes(most)) of exposure these \(label) are not getting faster — change what you practise before adding more of it."
        }
        guard let e = english else {
            return label == "races"
                ? "Ten times the practice buys about \(tenfold)% more speed on this line."
                : "Ten times the practice buys about \(tenfold)% more speed on this line; take the English test aloud and it will say when the line meets it."
        }
        guard let reach = f.minutesTo(e), reach > most else {
            return "The fitted line is already at or past your English speed of \(e) words correct a minute."
        }
        return "Ten times the practice buys about \(tenfold)% more speed; extended, the line meets your English speed of \(e) at about \(LearningCurve.minutes(reach)) of exposure — \(LearningCurve.minutes(reach - most)) from here."
    }
}

// MARK: - After a break

/// What each break of two days or more in practice cost, scored on the
/// series: the first back and the three after it, against the three before.
@available(iOS 16, *)
private struct ProgressBreaksSection: View {
    let exposure: [PracticeStore.Session]
    let series: [PracticeStore.Session]
    let label: String

    var body: some View {
        let rows = LearningCurve.breaks(exposure: exposure, series: series)
        let since = exposure.last.map { Int(Date().timeIntervalSince($0.date) / 86400) } ?? 0
        SignalSection {
            if rows.isEmpty {
                Text(since >= 2
                     ? "No break of two days or more yet — the current one is \(since) days, so your next run is the first row here."
                     : "No break of two days or more yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(rows.suffix(8).reversed()) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.date, format: .dateTime.month(.abbreviated).day()).font(.body)
                            Text("\(b.days) days away · \(b.before) wpm before").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(b.first) wpm back").font(.body.monospacedDigit())
                            Text("\(b.firstPercent)% · then \(b.afterPercent)%").font(.footnote.monospacedDigit())
                                .foregroundStyle(b.firstPercent >= 100 ? PracticeTheme.good : b.firstPercent >= 90 ? Color.secondary : PracticeTheme.wrong)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Back after \(b.days) days at \(b.first) words per minute, \(b.firstPercent) percent of the \(b.before) before; the next three \(b.afterPercent) percent")
                }
            }
        } header: {
            Text("After a break")
        } footer: {
            if rows.isEmpty {
                Text("Gaps of two days or more anywhere in your practice will show here, scored with your \(label): the first back against the three before.")
            } else {
                let avg = Int((Double(rows.map(\.firstPercent).reduce(0, +)) / Double(rows.count)).rounded())
                Text("Gaps of two days or more anywhere in your practice, scored with your \(label): the first back averaged \(avg)% of the speed before.")
            }
        }
    }
}

// MARK: - Typing progress

/// The typed race's numbers, pushed from the Typing row: a different scale
/// from reading aloud, so it never shares a chart with it.
@available(iOS 16, *)
struct TypingProgressView: View {
    @ObservedObject private var store = PracticeStore.shared
    @ScaledMetric(relativeTo: .title) private var rowGlyph: CGFloat = 30

    var body: some View {
        let typed = store.typedSessions
        SignalList {
            if typed.isEmpty {
                SignalSection {
                    Text("No races yet.").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                typing(typed)
                recent(typed)
                misread
                ProgressCurveSection(runs: typed, label: "races", english: nil, header: "Learning curve · races")
                ProgressBreaksSection(exposure: store.exposureSessions, series: typed, label: "races")
            }
        }
        .background(Color.Signal.groupedBackground)
    }

    private func typing(_ sessions: [PracticeStore.Session]) -> some View {
        let last = sessions.last!
        let accuracy = Int((Double(sessions.suffix(10).map(\.accuracy).reduce(0, +)) / Double(min(10, sessions.count))).rounded())
        let recent = Array(sessions.suffix(60))
        return SignalSection {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { typingTiles(last: last.wpm, accuracy: accuracy) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) { typingTiles(last: last.wpm, accuracy: accuracy) }
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

            Chart {
                ForEach(Array(recent.enumerated()), id: \.element.id) { i, s in
                    PointMark(x: .value("Race", i), y: .value("Words per minute", s.wpm))
                        .foregroundStyle(s.wpm >= store.best ? PracticeTheme.good : Color.Signal.secondaryLabel)
                        .symbolSize(64)
                    if recent.count >= 3 {
                        LineMark(x: .value("Race", i), y: .value("Words per minute", centredTrend(recent, at: i)))
                            .foregroundStyle(Color.Signal.label)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(Color.Signal.quaternaryFill)
                    AxisValueLabel().font(.caption2.monospacedDigit()).foregroundStyle(Color.Signal.secondaryLabel)
                }
            }
            .frame(height: 160)
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            .accessibilityLabel("Words per minute across your last \(recent.count) races, best \(store.best)")
        } header: {
            Text("Typing")
        } footer: {
            Text("Each dot is a race and the green dot is your best. Accuracy is your average over the last 10 races.")
        }
    }

    @ViewBuilder
    private func typingTiles(last: Int, accuracy: Int) -> some View {
        progressTile("\(last) wpm", "Last race", spoken: "Last race, \(last) words per minute")
        progressTile("\(store.best) wpm", "Best", spoken: "Best, \(store.best) words per minute")
        progressTile("\(accuracy)%", "Accuracy", spoken: "Accuracy, \(accuracy) percent")
    }

    private func recent(_ sessions: [PracticeStore.Session]) -> some View {
        SignalSection {
            ForEach(sessions.suffix(8).reversed()) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.body)
                        Text("\(s.mode.capitalized) · \(PracticeFormat.duration(s.seconds))").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(s.wpm) wpm").font(.body.monospacedDigit())
                        Text("\(s.accuracy)%").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Recent typing")
        }
    }

    @ViewBuilder
    private var misread: some View {
        let hard = store.hardest()
        if !hard.isEmpty {
            SignalSection {
                ForEach(hard.prefix(8), id: \.text) { m in
                    HStack(spacing: 12) {
                        Text(m.text).font(PracticeTheme.script(rowGlyph)).frame(width: 56, alignment: .leading)
                        Text(m.text).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text("\(m.record.wrong) of \(m.record.seen) times").font(.subheadline.monospacedDigit()).foregroundStyle(PracticeTheme.wrong)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(PracticeFormat.spelled(m.text)), mistyped \(m.record.wrong) of \(m.record.seen) times")
                }
            } header: {
                Text("Often mistyped")
            }
        }
    }
}

// MARK: - About these numbers

/// The research behind the tab, in one sheet, so the live surfaces can stay
/// at a sentence or two each.
@available(iOS 16, *)
struct AboutNumbersView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignalList(presented: true) {
                section("% of English speed",
                        "Words correct per minute reading a Qiuling passage aloud, divided by the median of your last three English readings; 100 is reading Qiuling as fast as English. A speed ratio, not comprehension. Your voice is in both, so what is left is the script. The English readings used are the nearest before the test (or in the same sitting after it), within two weeks; hollow dots are tests whose baseline was older than that, taken with a different microphone setting, or read only afterwards — read those loosely. Typing caps out far below reading speed, so the typed test can never show more than your hands allow; reading aloud is how reading research measures fluency, and speech runs at 150–200 words a minute.")
                section("Two tests, two jobs",
                        "The spoken test is one real passage of about 60 words, timed by you, because reading aloud is how reading research measures fluency. The typed test is 60 seconds of the same 1,500 common words in random order, so English cannot guess the marks for you — the stricter check on the eyes alone, and your fingers are in both so typing skill cancels. Both are the same size every time, so the only thing that can move the number is you.")
                section("Misread %",
                        "Speed bought with misreadings is skimming, not reading: hold the test under 2% misread before pushing for speed. Without a microphone misreadings are not counted, so those runs show blank here, not 0.")
                section("The learning curve",
                        "In a 1975 study, students reading up to 160 pages of upside-down text got faster as a power of pages read — a straight line on log axes — and neared normal speed inside those pages. Here your speed is fitted as a power of the minutes you have practised; the fit quality says how straight your line is.")
                section("After a break",
                        "In a 1976 study, readers of upside-down text kept their skill across a year away; Beatrix Potter, who wrote a private cipher fluently for sixteen years, could not read it back after decades. Every gap of two days or more in your practice is a row in After a break: the first run back as a share of the three before. Near 100% means the marks live in long-term memory; a dip the next three recover is warm-up; a dip that stays is forgetting.")
                section("Weather and climate",
                        "A run is weather, the line is climate: judge by the 3-test average and by the test, never by one good run.")
            }
            .navigationTitle("About these numbers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        SignalSection {
            Text(text).font(.body)
        } header: {
            Text(title)
        }
    }
}

// MARK: - Read the web

/// How to read any page in Qiuling: the Safari extension does the work, and
/// this page only says where its switch is.
@available(iOS 16, *)
struct ReadWebView: View {
    var body: some View {
        SignalList {
            SignalSection {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.Signal.secondaryFill).frame(width: 64, height: 64)
                        Image(systemName: "safari").font(.system(size: 28)).foregroundStyle(Color.Signal.label)
                    }
                    .accessibilityHidden(true)
                    Text("Read the web in Qiuling").font(.title3.weight(.semibold))
                    Text("Qiuling adds a button to Safari. Tap it to set the page you're reading in your script, and tap it again to put the page back.")
                        .font(.body).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 24, trailing: 16))
                .listRowBackground(Color.clear)
            }

            SignalSection {
                step(1, "Open Settings, then Apps, then Safari, then Extensions.")
                step(2, "Turn on Qiuling.")
                step(3, "Choose Allow for all websites, or Ask each time.")
                step(4, "If Safari is already open, quit it from the app switcher and open it again so it picks up the new extension.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.body)
                .foregroundStyle(Color.Signal.accent)
            } header: {
                Text("Turn it on once")
            } footer: {
                Text("Open Settings lands on Qiuling's own page; Safari's extensions are two taps further. You can also turn it on in Safari: tap the ⋯ button in the address bar, choose Manage Extensions, then Qiuling.")
            }

            SignalSection {
                step(1, "In Safari, tap the ⋯ button at the end of the address bar, then Qiuling. The page switches to your script.")
                step(2, "Tap it again to switch back.")
            } header: {
                Text("Read a page")
            } footer: {
                Text("The extension reads with the same alphabet as this app and works offline.")
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "\(n).circle.fill").foregroundStyle(Color.Signal.accent).imageScale(.large)
                .accessibilityHidden(true)
            Text(text).font(.body)
        }
    }
}
