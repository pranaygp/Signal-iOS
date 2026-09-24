//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import SignalUI
import Speech
import SwiftUI

// MARK: - Model

/// Reading aloud: one passage, timed from the tap that reveals it to the tap
/// that says it is read. Typing caps out far below reading speed, so the
/// typed race can never show more than the hands allow; reading aloud is how
/// reading research measures fluency — words correct per minute — and runs
/// at 150–200 wpm, close to the eyes. The reader holds the clock, so the time
/// is honest to the tenth of a second with or without a recogniser; the
/// microphone, when it is on, only scores.
///
/// The test is always about sixty words of one excerpt, in the script or, for
/// the baseline, in English; the goal is the ratio between the two.
@available(iOS 16, *)
@MainActor
final class ReadModel: ObservableObject {
    enum Source: String, CaseIterable { case sentences, test
        var label: String { switch self { case .sentences: "Sentences"; case .test: "Test" } }
    }
    enum Script: String, CaseIterable { case qiuling, english
        var label: String { switch self { case .qiuling: "Qiuling"; case .english: "English" } }
    }

    static let lengths = [15, 30, 60, 120]
    static let testWords = 60

    @AppStorage("Read.source") var sourceRaw = Source.sentences.rawValue
    @AppStorage("Read.script") var scriptRaw = Script.qiuling.rawValue
    @AppStorage("Read.words") var words = 30
    @AppStorage("Read.microphone") var microphone = false

    var source: Source { get { Source(rawValue: sourceRaw) ?? .sentences } set { sourceRaw = newValue.rawValue } }
    var script: Script { get { Script(rawValue: scriptRaw) ?? .qiuling } set { scriptRaw = newValue.rawValue } }
    var isTest: Bool { source == .test }
    var inEnglish: Bool { isTest && script == .english }
    var passageWords: Int { isTest ? Self.testWords : words }

    /// What the store files the run under: `read`, `read-test` or `read-english`.
    var mode: String { isTest ? (inEnglish ? "read-english" : "read-test") : "read" }

    @Published private(set) var excerpt: PracticePassages.Excerpt?
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var scoring = false      // the recogniser's last words are on their way
    @Published private(set) var ready = false
    @Published private(set) var result: ReadResult?
    @Published private(set) var heard = SpeechScorer.Heard()
    @Published private(set) var microphoneNote: String?

    private var ticker: Timer?
    private var scorer: SpeechScorer?

    var isRunning: Bool { startedAt != nil && endedAt == nil }
    var isFinished: Bool { result != nil }

    init() {
        Task {
            await PracticePassages.shared.loadIfNeeded()
            await PracticeCorpus.shared.loadIfNeeded()
            ready = true
            if excerpt == nil { start() }
        }
        NotificationCenter.default.addObserver(forName: QiulingFonts.fontDidChange, object: nil, queue: .main) { [weak self] _ in
            QiulingSegmenter.clearCache()
            Task { @MainActor in self?.start() }
        }
    }

    /// A fresh passage, hidden until the reader taps it.
    func start() {
        ticker?.invalidate(); ticker = nil
        scorer?.cancel(); scorer = nil
        startedAt = nil; endedAt = nil; elapsed = 0
        scoring = false; result = nil
        heard = SpeechScorer.Heard()
        microphoneNote = nil
        excerpt = PracticePassages.shared.excerpt(words: passageWords) ?? Self.fallback(words: passageWords)
    }

    /// Without the excerpt file: the corpus's sentences, run to the target.
    private static func fallback(words n: Int) -> PracticePassages.Excerpt {
        var sentences = [String](); var got = 0
        while got < n { let s = PracticeCorpus.shared.nextSentence(); sentences.append(s); got += s.split(separator: " ").count }
        return PracticePassages.Excerpt(sentences: sentences, book: 0, title: "", author: "")
    }

    /// The reveal: the clock starts, and so does the recogniser if it is on.
    func begin() {
        guard let excerpt, startedAt == nil else { return }
        let now = Date()
        startedAt = now
        if microphone && PracticeFeatures.microphone {
            let scorer = SpeechScorer(target: excerpt.words, startedAt: now)
            self.scorer = scorer
            scorer.onChange = { [weak self] heard in self?.heard = heard }
            scorer.onUnavailable = { [weak self] why in self?.microphoneNote = why }
            scorer.start()
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt, self.endedAt == nil else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Read. The recogniser is still holding a word or two; it gets a moment
    /// to hand them over before the run is scored.
    func done() {
        guard let startedAt, endedAt == nil else { return }
        let now = Date()
        endedAt = now
        elapsed = now.timeIntervalSince(startedAt)
        ticker?.invalidate(); ticker = nil
        if let scorer {
            scoring = true
            scorer.finish { [weak self] heard in
                guard let self else { return }
                self.heard = heard
                self.scoring = false
                self.score()
            }
        } else {
            score()
        }
    }

    private func score() {
        guard let excerpt, let startedAt, let endedAt else { return }
        let r = ReadResult(excerpt: excerpt, seconds: endedAt.timeIntervalSince(startedAt), heard: scorer == nil ? nil : heard)
        result = r
        scorer = nil
        PracticeStore.shared.record(reading: r, mode: mode)
    }
}

/// One finished reading, scored.
struct ReadResult {
    let excerpt: PracticePassages.Excerpt
    let seconds: TimeInterval
    /// What the recogniser made of it, or nil when it was not listening.
    let heard: SpeechScorer.Heard?

    var words: Int { excerpt.words.count }
    var listened: Bool { heard != nil }

    /// Per passage word: how it was read. Words past the recogniser's
    /// frontier at the stop tap were read but not caught: counted as read and
    /// reported, since a recogniser trailing by two words on every run would
    /// otherwise file two skips a run.
    enum Verdict { case ok, sub(String), skip, unheard }
    var verdicts: [Verdict] {
        guard let heard else { return excerpt.words.map { _ in .ok } }
        var out = [Verdict](repeating: .unheard, count: words)
        for op in heard.ops {
            switch op {
            case .ok(let t, _): out[t] = .ok
            case .sub(let t, let h): out[t] = .sub(heard.words[h])
            case .skip(let t): out[t] = .skip
            case .extra: break
            }
        }
        return out
    }

    var correct: Int { verdicts.filter { if case .sub = $0 { return false }; if case .skip = $0 { return false }; return true }.count }
    var extras: Int { heard?.ops.filter { if case .extra = $0 { return true }; return false }.count ?? 0 }
    var errors: Int { words - correct + extras }
    var unheard: Int { verdicts.filter { if case .unheard = $0 { return true }; return false }.count }
    var accuracy: Int { Int((Double(correct) / Double(max(1, words + extras)) * 100).rounded()) }
    /// Words per minute — words correct, where a recogniser listened.
    var wpm: Int { Int((Double(correct) / max(seconds, 0.001) * 60).rounded()) }
    var secondsPerWord: Double { seconds / Double(max(1, words)) }

    struct Misreading: Identifiable { let text: String; let said: String?; var id: String { text + "→" + (said ?? "") } }
    var misreadings: [Misreading] {
        zip(excerpt.words, verdicts).compactMap { w, v in
            switch v { case .sub(let s): Misreading(text: w, said: s); case .skip: Misreading(text: w, said: nil); default: nil }
        }
    }

    struct Hesitation: Identifiable { let text: String; let ms: Int; let typicalMs: Int; var id: String { text + "\(ms)" } }
    /// Words whose onset came two and a half times the run's typical gap after
    /// the word before — the ones you stopped on. Only words read right.
    var hesitations: [Hesitation] {
        guard let heard else { return [] }
        var gaps = [(String, Double)](); var prev = 0.0
        for op in heard.ops {
            guard case .ok(let t, let h) = op, h < heard.at.count else { continue }
            gaps.append((excerpt.words[t], heard.at[h] - prev)); prev = heard.at[h]
        }
        let sorted = gaps.map(\.1).sorted()
        guard !sorted.isEmpty else { return [] }
        let median = sorted[sorted.count / 2]
        return gaps.filter { median > 0 && $0.1 > median * 2.5 }.sorted { $0.1 > $1.1 }
            .map { Hesitation(text: $0.0, ms: Int($0.1 * 1000), typicalMs: Int(median * 1000)) }
    }
}

// MARK: - Speech

/// The recogniser, on device where iOS allows it. It is asked for partial
/// results so a word's arrival is roughly its onset; the transcript is aligned
/// to the passage after each one. It emits what it heard rather than a cleaned
/// up guess at what was meant, so a misreading survives — the property a
/// dictation app does not have.
final class SpeechScorer {
    struct Heard {
        var words: [String] = []
        var at: [TimeInterval] = []            // onset, seconds since the reveal
        var ops: [SpeechAlignment.Op] = []
        var frontier = 0
    }

    private let target: [String]
    private let startedAt: Date
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = Heard()
    private var finished = false
    private var onFinish: ((Heard) -> Void)?

    var onChange: ((Heard) -> Void)?
    var onUnavailable: ((String) -> Void)?

    init(target: [String], startedAt: Date) {
        self.target = target
        self.startedAt = startedAt
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else { unavailable("Speech recognition isn't available on this device."); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else { self.unavailable("Speech recognition is off for Qiuling. Allow it in Settings to score your reading."); return }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else { self.unavailable("The microphone is off for Qiuling. Allow it in Settings to score your reading."); return }
                        self.listen()
                    }
                }
            }
        }
    }

    private func unavailable(_ why: String) {
        onUnavailable?(why)
        finished = true
        onFinish?(heard)
    }

    private func listen() {
        guard !finished, let recognizer else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            unavailable("The microphone couldn't be started."); return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.taskHint = .dictation
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { unavailable("The microphone couldn't be started."); return }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result { self.take(result) }
                if error != nil || result?.isFinal == true { self.wrapUp() }
            }
        }
    }

    /// A transcript so far. The recogniser gives each segment its own onset
    /// in the audio, which began at the reveal — better than the web's
    /// arrival-time guess.
    private func take(_ result: SFSpeechRecognitionResult) {
        var words = [String](); var at = [TimeInterval]()
        for seg in result.bestTranscription.segments {
            for w in PracticePassages.words(seg.substring) { words.append(w); at.append(seg.timestamp) }
        }
        heard.words = words; heard.at = at
        (heard.ops, heard.frontier) = SpeechAlignment.align(target: target, heard: words)
        onChange?(heard)
    }

    /// Stop taking audio; give the recogniser a moment for its last words.
    func finish(_ completion: @escaping (Heard) -> Void) {
        onFinish = completion
        if finished { completion(heard); return }
        request?.endAudio()
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.wrapUp() }
    }

    private func wrapUp() {
        guard !finished else { return }
        finished = true
        task?.cancel(); task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onFinish?(heard)
    }

    func cancel() {
        finished = true
        onFinish = nil
        task?.cancel(); task = nil
        request?.endAudio()
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Screen

@available(iOS 16, *)
struct ReadView: View {
    @ObservedObject var model: ReadModel
    @State private var showResults = false
    @AccessibilityFocusState private var passageFocused: Bool

    var body: some View {
        Group {
            if showResults, let result = model.result {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, OWSTableViewController2.defaultHOuterMargin)
                        .padding(.vertical, 12)
                    ReadResultsView(result: result, mode: model.mode) { model.start(); passageFocused = true }
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
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: showResults)
        .background(Color.Signal.groupedBackground)
        .onChange(of: model.isFinished) { finished in
            if finished {
                Task { try? await Task.sleep(nanoseconds: 300_000_000); if model.isFinished { showResults = true } }
            } else {
                showResults = false
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                if !showResults { clock }
                Spacer()
                optionsMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                if !showResults { clock }
                optionsMenu
            }
        }
    }

    /// Seconds, counting up: the reader's own time, to a tenth.
    private var clock: some View {
        Text(model.elapsed, format: .number.precision(.fractionLength(1)))
            .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
            .foregroundStyle(model.isRunning ? Color.Signal.accent : Color.Signal.secondaryLabel)
            .accessibilityLabel(String(format: "%.1f seconds", model.elapsed))
    }

    private var optionsLabel: String {
        if model.isTest { return "Test · \(model.script.label)" }
        return "\(model.source.label) · \(model.words) words"
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Passage", selection: Binding(get: { model.source }, set: { model.source = $0; model.start() })) {
                ForEach(ReadModel.Source.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            if model.isTest {
                Picker("Script", selection: Binding(get: { model.script }, set: { model.script = $0; model.start() })) {
                    ForEach(ReadModel.Script.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } else {
                Picker("Length", selection: Binding(get: { model.words }, set: { model.words = $0; model.start() })) {
                    ForEach(ReadModel.lengths, id: \.self) { Text("\($0) words").tag($0) }
                }
                .pickerStyle(.inline)
            }
            Divider()
            if PracticeFeatures.microphone {
                Toggle("Score with microphone", systemImage: "mic", isOn: Binding(get: { model.microphone }, set: { model.microphone = $0; model.start() }))
            }
            Button("New passage", systemImage: "arrow.clockwise") { model.start() }
        } label: {
            HStack(spacing: 4) {
                Text(optionsLabel)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.subheadline.weight(.medium))
        }
        .practiceSecondaryButton()
        .controlSize(.small)
        .disabled(model.excerpt == nil || model.isRunning)
        .accessibilityLabel("Reading options")
    }

    // MARK: Passage

    @ViewBuilder
    private var passageCard: some View {
        if let excerpt = model.excerpt {
            let hidden = model.startedAt == nil
            ReadPassageView(excerpt: excerpt, verdicts: model.isRunning && model.microphone && PracticeFeatures.microphone ? liveVerdicts : nil, frontier: model.isRunning && model.microphone && PracticeFeatures.microphone ? model.heard.frontier : nil, english: model.inEnglish)
                .blur(radius: hidden ? 7 : 0)
                .opacity(hidden ? 0.45 : 1)
                .contentShape(Rectangle())
                .onTapGesture { if hidden { model.begin() } }
                .overlay {
                    if hidden {
                        Text("Tap to start")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .practiceGlass()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: hidden)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hidden ? "Passage, hidden" : "Passage")
                .accessibilityHint(hidden ? "Double tap to reveal it and start the clock. Read it aloud, then tap Done." : "Read it aloud, then tap Done.")
                .accessibilityAddTraits(hidden ? .isButton : [])
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

    /// While the recogniser listens, how each word stands so far.
    private var liveVerdicts: [ReadResult.Verdict] {
        guard let excerpt = model.excerpt else { return [] }
        var out = [ReadResult.Verdict](repeating: .unheard, count: excerpt.words.count)
        for op in model.heard.ops {
            switch op {
            case .ok(let t, _): out[t] = .ok
            case .sub(let t, let h): out[t] = .sub(model.heard.words[h])
            case .skip(let t): out[t] = .skip
            case .extra: break
            }
        }
        return out
    }

    private var stateSlot: some View {
        VStack(spacing: 10) {
            if model.scoring {
                HStack(spacing: 8) { ProgressView(); Text("Scoring…").font(.footnote).foregroundStyle(.secondary) }
            } else if model.isRunning {
                HStack(spacing: 12) {
                    // A run interrupted is not a run: Discard keeps nothing
                    // and brings up a fresh passage, hidden, ready to tap.
                    Button("Discard", systemImage: "xmark") { model.start() }
                        .practiceSecondaryButton()
                        .controlSize(.large)
                        .accessibilityHint("Throws this run away without saving it and brings up a new passage.")
                    Button("Done", systemImage: "checkmark") { model.done() }
                        .practicePrimaryButton()
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                if let note = model.microphoneNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                }
            } else if model.excerpt != nil {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var hint: String {
        let what = model.isTest
            ? "The test: about \(ReadModel.testWords) words of one excerpt, in \(model.script.label). Take it in both scripts to compare."
            : "About \(model.words) words of one excerpt."
        return what + " Tap the passage to reveal it and start the clock; read it aloud; tap Done. Interrupted? Discard keeps nothing." +
            (model.microphone && PracticeFeatures.microphone ? " The microphone marks the words you misread." : "")
    }
}

// MARK: - Passage

/// The passage whole. In the script, each a–z word is its own run so a colour
/// change never splits a glyph. For the English baseline it is the excerpt as
/// printed, capitals and punctuation and all, in the book face at a reading
/// size: the baseline is English as it is normally read, or the ratio means
/// nothing.
@available(iOS 16, *)
struct ReadPassageView: View {
    let excerpt: PracticePassages.Excerpt
    /// How each word has been read so far, or nil when nothing is listening.
    let verdicts: [ReadResult.Verdict]?
    let frontier: Int?
    let english: Bool
    @ScaledMetric(relativeTo: .title) private var scriptSize: CGFloat = 40
    @ScaledMetric(relativeTo: .title2) private var latinSize: CGFloat = 23

    var body: some View {
        Group {
            if english {
                ExcerptView(excerpt: excerpt, verdicts: verdicts, size: latinSize, cite: false)
            } else {
                Text(attributed)
                    .lineSpacing(10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCardBackground()
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (i, w) in excerpt.words.enumerated() {
            var run = AttributedString(w)
            run.font = PracticeTheme.script(scriptSize)
            run.foregroundColor = Color.Signal.label
            if let verdicts, i < verdicts.count {
                switch verdicts[i] {
                case .ok: run.foregroundColor = Color.Signal.secondaryLabel
                case .sub: run.foregroundColor = PracticeTheme.wrong; run.backgroundColor = PracticeTheme.wrongBackground
                case .skip: run.foregroundColor = Color.Signal.tertiaryLabel
                case .unheard: break
                }
            }
            if let frontier, i == frontier { run.backgroundColor = PracticeTheme.tint }
            out += run
            // The space in the script's own font: the drawn word gap, not the
            // system face's, which is a sliver beside 40-point marks.
            var gap = AttributedString(" ")
            gap.font = PracticeTheme.script(scriptSize)
            out += gap
        }
        return out
    }
}

// MARK: - The English

/// The excerpt as printed, in a book face at reading size — the one place in
/// Practice that is for reading English — with the words the recogniser
/// scored wrong marked in place, and where it came from.
@available(iOS 16, *)
struct ExcerptView: View {
    let excerpt: PracticePassages.Excerpt
    var verdicts: [ReadResult.Verdict]? = nil
    /// Point size; the default is body reading size.
    var size: CGFloat? = nil
    var cite = true
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17

    var body: some View {
        let size = size ?? bodySize
        VStack(alignment: .leading, spacing: 10) {
            Text(attributed)
                .font(.system(size: size, design: .serif))
                .lineSpacing(size * 0.3)
                .fixedSize(horizontal: false, vertical: true)
            if cite, !excerpt.title.isEmpty {
                Link(destination: excerpt.url) {
                    (Text("— \(excerpt.citation) ") + Text(Image(systemName: "arrow.up.right")).font(.caption2))
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                }
                .tint(Color.Signal.accent)
                .accessibilityLabel("Source: \(excerpt.citation). Opens Project Gutenberg.")
            }
        }
    }

    /// A printed token carries the reading of the a–z words it became (a dash
    /// can make one token two).
    private var attributed: AttributedString {
        var out = AttributedString()
        var k = 0
        let tokens = excerpt.sentences.joined(separator: " ").split(separator: " ").map(String.init)
        for (n, tok) in tokens.enumerated() {
            var run = AttributedString(tok)
            let count = PracticePassages.words(tok).count
            if let verdicts {
                let mine = (k..<min(k + count, verdicts.count)).map { verdicts[$0] }
                if mine.contains(where: { if case .sub = $0 { return true }; return false }) {
                    run.foregroundColor = PracticeTheme.wrong
                    run.underlineStyle = .single
                } else if mine.contains(where: { if case .skip = $0 { return true }; return false }) {
                    run.foregroundColor = Color.Signal.secondaryLabel
                    run.underlineStyle = .patternDot
                }
            }
            k += count
            out += run
            if n < tokens.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}

// MARK: - Results

@available(iOS 16, *)
struct ReadResultsView: View {
    let result: ReadResult
    let mode: String
    let again: () -> Void
    @ObservedObject private var store = PracticeStore.shared
    @State private var celebrate = false
    @ScaledMetric(relativeTo: .title) private var glyphSize: CGFloat = 30

    private var isTest: Bool { mode == "read-test" }
    private var isEnglish: Bool { mode == "read-english" }

    var body: some View {
        let goal = store.readingGoal
        SignalList {
            SignalSection {
                hero.listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } footer: {
                if result.seconds < 3 { Text("Readings shorter than 3 seconds aren't saved to Progress.") }
                else if let line = comparison(goal) { Text(line) }
            }

            SignalSection {
                ExcerptView(excerpt: result.excerpt, verdicts: result.listened ? result.verdicts : nil)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            } header: {
                Text("The passage")
            } footer: {
                if result.listened {
                    Text(result.unheard > 0
                         ? "Words you misread are underlined; skipped ones are dotted. \(result.unheard) word\(result.unheard == 1 ? "" : "s") at the end weren't caught by the recogniser and count as read."
                         : "Words you misread are underlined; skipped ones are dotted.")
                } else {
                    Text(PracticeFeatures.microphone
                         ? "Check it against what you took in. Turn on the microphone in the options to have the words you misread marked."
                         : "Check it against what you took in.")
                }
            }

            if result.listened, !result.misreadings.isEmpty {
                SignalSection {
                    ForEach(result.misreadings.prefix(8)) { m in
                        HStack(spacing: 12) {
                            if !isEnglish { Text(m.text).font(PracticeTheme.script(glyphSize)).frame(width: 72, alignment: .leading) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.text).font(.system(.body, design: .monospaced))
                                Text(saidLine(m.said)).font(.footnote)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(m.text), \(m.said.map { "you said \($0)" } ?? "skipped")")
                    }
                } header: {
                    Text(isEnglish ? "Heard differently" : "What you misread")
                }
            }

            if result.listened, !result.hesitations.isEmpty {
                SignalSection {
                    ForEach(result.hesitations.prefix(6)) { h in
                        HStack(spacing: 12) {
                            if !isEnglish { Text(h.text).font(PracticeTheme.script(glyphSize)).frame(width: 72, alignment: .leading) }
                            Text(h.text).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(PracticeFormat.seconds(ms: h.ms)).font(.body.monospacedDigit())
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(h.text), a pause of \(PracticeFormat.secondsSpoken(ms: h.ms))")
                    }
                } header: {
                    Text("Where you hesitated")
                } footer: {
                    Text("A pause before the word of more than two and a half times your typical gap (\(PracticeFormat.seconds(ms: result.hesitations.first?.typicalMs ?? 0))).")
                }
            }

            Color.clear.frame(height: 88).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        .safeAreaInset(edge: .bottom) {
            Button("Read again", systemImage: "arrow.counterclockwise") { again() }
                .practicePrimaryButton()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        }
        .onAppear { celebrate = isBest }
        .practiceSuccessHaptic(trigger: celebrate)
    }

    /// Ties or beats the best saved reading of this kind, once there is more
    /// than one to compare against.
    private var isBest: Bool {
        let peers = store.book.sessions.filter { $0.mode == mode }
        return result.seconds >= 3 && peers.count > 1 && result.wpm >= (peers.map(\.wpm).max() ?? 0)
    }

    private func comparison(_ g: PracticeStore.ReadingGoal) -> String? {
        if isTest {
            if let pct = g.percent { return "Aloud you read Qiuling at \(pct)% of your English speed (\(g.qiuling ?? 0) vs \(g.english ?? 0) words a minute, last \(g.baselineN) English reading\(g.baselineN == 1 ? "" : "s"), 3-test average)." }
            return "Take the test in English once, and this becomes your share of your English reading speed."
        }
        if isEnglish {
            if let pct = g.percent { return "Your English baseline. Your Qiuling test is at \(pct)% of it." }
            return "Your English baseline. Now take the test in Qiuling."
        }
        return nil
    }

    private func saidLine(_ said: String?) -> AttributedString {
        guard let said else { var s = AttributedString("Skipped"); s.foregroundColor = Color.Signal.secondaryLabel; return s }
        var out = AttributedString("You said ")
        var w = AttributedString(said); w.foregroundColor = PracticeTheme.wrong
        out += w
        return out
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(result.wpm)")
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
                Text(result.listened ? "Words correct per minute" : "Words per minute").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(result.wpm) words per minute\(celebrate ? ", new personal best" : "")")

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { tiles }
                VStack(alignment: .leading, spacing: 12) { tiles }
            }
        }
        .animation(.snappy, value: celebrate)
    }

    @ViewBuilder
    private var tiles: some View {
        tile(String(format: "%.1f s", result.seconds), "Time", spoken: String(format: "%.1f seconds", result.seconds))
        tile("\(result.words)", "Words", spoken: "\(result.words) words")
        if result.listened {
            tile("\(result.accuracy)%", "Accuracy", spoken: "\(result.accuracy) percent accuracy")
            tile("\(result.errors)", "Errors", spoken: "\(result.errors) errors")
        } else {
            tile(String(format: "%.2f s", result.secondsPerWord), "Per word", spoken: String(format: "%.2f seconds a word", result.secondsPerWord))
        }
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
}
