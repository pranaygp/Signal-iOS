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

@available(iOS 16, *)
struct ProgressTabView: View {
    /// Pops back to the race, from the empty state.
    var race: () -> Void = {}
    /// Pushes Recall, from the empty state.
    var recall: () -> Void = {}

    @ObservedObject private var store = PracticeStore.shared
    @State private var blocks: [String] = QiulingFonts.shared.blocks
    @State private var detail: String?
    @State private var confirmReset = false
    @ScaledMetric(relativeTo: .title) private var rowGlyph: CGFloat = 30

    private struct Mark: Identifiable { let text: String; var id: String { text } }

    var body: some View {
        let sessions = store.typedSessions
        let readings = store.readSessions
        let hasRecall = !store.book.recall.isEmpty
        Group {
            if sessions.isEmpty, readings.isEmpty, !hasRecall {
                empty.transition(.opacity)
            } else {
                SignalList {
                    if readings.isEmpty {
                        SignalSection {
                            EmptyView()
                        } footer: {
                            Text("No readings yet. Read a passage aloud and your speed shows up here.")
                        }
                    } else {
                        reading(readings)
                    }
                    if !readings.isEmpty || !sessions.isEmpty {
                        curve(readings: readings, typed: sessions)
                        breaks(readings: readings, typed: sessions)
                    }
                    if !sessions.isEmpty {
                        typing(sessions)
                        recent(sessions)
                        misread
                    }

                    RecallProgressSections(book: store.book, blocks: blocks, detail: $detail)

                    SignalSection {
                        Button(role: .destructive) { confirmReset = true } label: {
                            Text("Reset progress").font(.body).foregroundStyle(Color.Signal.red).frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("Removes every race and recall record for this alphabet.")
                    }
                }
                .confirmationDialog("Reset all progress?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset progress", role: .destructive) { withAnimation { store.reset() } }
                } message: {
                    Text("Every race and recall record for this alphabet will be removed. This can't be undone.")
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: sessions.isEmpty && readings.isEmpty && !hasRecall)
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

    // MARK: Reading

    /// Reading aloud: the last and best, the spoken share of English when both
    /// tests have been taken, and the readings themselves.
    private func reading(_ readings: [PracticeStore.Session]) -> some View {
        let goal = store.readingGoal
        let recent = Array(readings.suffix(60))
        return SignalSection {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { readingTiles(last: readings.last!.wpm, goal: goal) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) { readingTiles(last: readings.last!.wpm, goal: goal) }
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

            if recent.count >= 2 {
                Chart {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { i, s in
                        PointMark(x: .value("Reading", i), y: .value("Words per minute", s.wpm))
                            .foregroundStyle(s.mode == "read-test" ? PracticeTheme.accent : Color.Signal.tertiaryLabel)
                            .symbolSize(28)
                        if recent.count >= 3 {
                            LineMark(x: .value("Reading", i), y: .value("Words per minute", trend(recent, at: i)))
                                .foregroundStyle(Color.Signal.label)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.monotone)
                        }
                    }
                    if let e = goal.english {
                        RuleMark(y: .value("English", e))
                            .foregroundStyle(Color.Signal.secondaryLabel)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("English, aloud").font(.caption2).foregroundStyle(.secondary)
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
                .accessibilityLabel("Words per minute across your last \(recent.count) readings, best \(store.bestReading)")
            }

            ForEach(readings.suffix(5).reversed()) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.body)
                        Text("\(s.mode == "read-test" ? "Test" : "Sentences") · \(s.words ?? 0) words · \(s.seconds) s").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(s.wpm) wpm").font(.body.monospacedDigit())
                }
            }
        } header: {
            Text("Reading aloud")
        } footer: {
            Text(goal.percent != nil
                 ? "Red dots are tests; the dashed line is your English test speed, the line to reach. The share is your last three Qiuling tests against your last three English ones."
                 : "Red dots are tests. Take the test in Qiuling and in English and the share of your English speed appears here — the number that matters.")
        }
    }

    @ViewBuilder
    private func readingTiles(last: Int, goal: PracticeStore.ReadingGoal) -> some View {
        statTile("\(last) wpm", "Last reading", spoken: "Last reading, \(last) words per minute")
        statTile("\(store.bestReading) wpm", "Best", spoken: "Best, \(store.bestReading) words per minute")
        statTile(goal.percent.map { "\($0)%" } ?? "—", "Of your English, aloud",
                 spoken: goal.percent.map { "\($0) percent of your English speed, aloud" } ?? "No English baseline yet")
    }

    // MARK: Learning curve

    /// Which runs the curve and the break table are drawn from. Reading aloud
    /// is the eyes' speed and the phone's first mode, so it is the default when
    /// there are readings; typed speed is a different scale and gets its own fit.
    private enum CurveSource: String, CaseIterable, Identifiable {
        case reading, typing
        var id: String { rawValue }
        var label: String { self == .reading ? "Reading aloud" : "Typing" }
    }
    @State private var curveSource: CurveSource?

    /// The tests alone when there are enough to fit, since practice runs mix
    /// passage lengths and scatter the cloud; otherwise every run in the script.
    private func curveRuns(_ source: CurveSource, readings: [PracticeStore.Session], typed: [PracticeStore.Session]) -> [PracticeStore.Session] {
        switch source {
        case .reading:
            let tests = readings.filter { $0.mode == "read-test" }
            return tests.count >= 3 ? tests : readings
        case .typing:
            return typed
        }
    }

    /// Every run at its cumulative minutes of exposure, both axes logarithmic,
    /// the power-law fit through them, and the English speed as the line to
    /// reach. Kolers' result is that this is straight; the section shows
    /// whether yours is and where it meets English.
    private func curve(readings: [PracticeStore.Session], typed: [PracticeStore.Session]) -> some View {
        let source = curveSource ?? (readings.isEmpty ? .typing : .reading)
        let runs = curveRuns(source, readings: readings, typed: typed)
        let fit = LearningCurve.powerLaw(runs)
        let english: Int? = source == .reading ? store.readingGoal.english : nil
        return SignalSection {
            if !readings.isEmpty, !typed.isEmpty {
                Picker("Runs", selection: Binding(get: { source }, set: { curveSource = $0 })) {
                    ForEach(CurveSource.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
            }
            HStack(alignment: .top, spacing: 12) {
                statTile(store.exposureText, "Of exposure, all modes", spoken: "\(store.exposureText) of exposure in the script")
                if let f = fit {
                    statTile(String(format: "%.2f", f.k), "Learning exponent", spoken: String(format: "Learning exponent %.2f", f.k))
                    statTile(String(format: "%.2f", f.r2), "r², how straight", spoken: String(format: "r squared %.2f", f.r2))
                }
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

            if let f = fit {
                curveChart(f, english: english)
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                    .accessibilityLabel(curveVerdict(f, english: english))
            }
        } header: {
            Text("Learning curve")
        } footer: {
            Text(fit.map { curveVerdict($0, english: english) }
                 ?? "After three runs a line is fitted through your speed against cumulative practice, both on log scales. Kolers (1975) found that line is straight for a new typography, and that readers neared normal speed inside about 160 pages.")
        }
    }

    private func curveChart(_ f: LearningCurve.Fit, english: Int?) -> some View {
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
        let xTicks = ([1.0, 2, 5, 10, 20, 30] + [1.0, 2, 5, 10, 20, 50, 100, 200].map { $0 * 60 }).filter { $0 >= xLo && $0 <= xTop }
        return Chart {
            ForEach(f.points) { p in
                PointMark(x: .value("Minutes", p.minutes), y: .value("Words per minute", p.wpm))
                    .foregroundStyle(Color.Signal.tertiaryLabel)
                    .symbolSize(28)
            }
            ForEach(Array(samples.enumerated()), id: \.offset) { _, m in
                LineMark(x: .value("Minutes", m), y: .value("Fit", f.predict(m)), series: .value("Line", m <= xs.max()! * 1.0001 ? "fit" : "forecast"))
                    .foregroundStyle(Color.Signal.label)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: m <= xs.max()! * 1.0001 ? [] : [4, 4]))
            }
            if let e = english {
                RuleMark(y: .value("English", e))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("English \(e)").font(.caption2).foregroundStyle(.secondary)
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

    private func curveVerdict(_ f: LearningCurve.Fit, english: Int?) -> String {
        let total = LearningCurve.minutes(f.points.map(\.minutes).max()!)
        let tenfold = Int(((pow(10, f.k) - 1) * 100).rounded())
        let loose = f.r2 < 0.3 ? "The points barely fit a line yet (r² under 0.3), so read this loosely. " : ""
        if f.k <= 0.01 {
            return loose + "The line is flat: over \(total) of exposure these runs are not getting faster. Change what you practise before adding more of it."
        }
        guard let e = english else {
            return loose + String(format: "Speed is rising as the %.2f power of practice — tenfold the practice, %d%% more speed. Take the English test and this will say when the line meets it.", f.k, tenfold)
        }
        guard let reach = f.minutesTo(e), reach > f.points.map(\.minutes).max()! else {
            return loose + "The fitted line is already at or past your English speed of \(e) wpm."
        }
        return loose + String(format: "Speed is rising as the %.2f power of practice: tenfold the practice, %d%% more speed. Extended, the line meets your English speed of %d wpm at about %@ of exposure — %@ from here. Kolers' students, reading upside-down text, neared normal speed within about 160 pages.",
                              f.k, tenfold, e, LearningCurve.minutes(reach), LearningCurve.minutes(reach - f.points.map(\.minutes).max()!))
    }

    // MARK: Breaks

    /// What each break of two days or more cost: the first run back and the
    /// three after it, against the three before.
    private func breaks(readings: [PracticeStore.Session], typed: [PracticeStore.Session]) -> some View {
        let source = curveSource ?? (readings.isEmpty ? .typing : .reading)
        let runs = curveRuns(source, readings: readings, typed: typed)
        let rows = LearningCurve.breaks(runs)
        let since = runs.last.map { Int(Date().timeIntervalSince($0.date) / 86400) } ?? 0
        return SignalSection {
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
                            Text("\(b.days) days away · \(b.before) wpm before").font(.footnote).foregroundStyle(.secondary)
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
                Text("Kolers' readers kept their skill across a year away; Potter could not read her own cipher after decades. Every gap of two days or more will show here as the first run back against the three before it.")
            } else {
                let avg = rows.map(\.firstPercent).reduce(0, +) / rows.count
                let longest = rows.max { $0.days < $1.days }!
                Text("Over \(rows.count) break\(rows.count == 1 ? "" : "s") of two days or more, the first run back averaged \(avg)% of the speed before it; the longest, \(longest.days) days, came back at \(longest.firstPercent)%. Near 100% on the first run means the marks are in long-term memory, not this week's warm-up." + (since >= 2 ? " You are \(since) days into a break now." : ""))
            }
        }
    }

    // MARK: Typing

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
                        .foregroundStyle(s.wpm >= store.best ? PracticeTheme.good : Color.Signal.tertiaryLabel)
                        .symbolSize(28)
                    if recent.count >= 3 {
                        LineMark(x: .value("Race", i), y: .value("Words per minute", trend(recent, at: i)))
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
        statTile("\(last) wpm", "Last race", spoken: "Last race, \(last) words per minute")
        statTile("\(store.best) wpm", "Best", spoken: "Best, \(store.best) words per minute")
        statTile("\(accuracy)%", "Accuracy", spoken: "Accuracy, \(accuracy) percent")
    }

    private func statTile(_ value: String, _ caption: String, spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// A centred nine-race average, so the line says where you are going
    /// rather than how the last race went.
    private func trend(_ s: [PracticeStore.Session], at i: Int) -> Double {
        let lo = max(0, i - 4), hi = min(s.count - 1, i + 4)
        let w = s[lo...hi].map(\.wpm); return Double(w.reduce(0, +)) / Double(w.count)
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
            Text("Recent races")
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
                    .accessibilityLabel("\(PracticeFormat.spelled(m.text)), misread \(m.record.wrong) of \(m.record.seen) times")
                }
            } header: {
                Text("Often misread")
            }
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
