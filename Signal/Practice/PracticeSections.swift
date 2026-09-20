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
        let sessions = store.book.sessions
        let hasRecall = !store.book.recall.isEmpty
        Group {
            if sessions.isEmpty, !hasRecall {
                empty.transition(.opacity)
            } else {
                SignalList {
                    if sessions.isEmpty {
                        SignalSection {
                            EmptyView()
                        } footer: {
                            Text("No races yet. Finish a race and your speed shows up here.")
                        }
                    } else {
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
        .animation(.default, value: sessions.isEmpty && !hasRecall)
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
                ContentUnavailableView("No progress yet", systemImage: "chart.line.uptrend.xyaxis", description: Text("Finish a race or answer a few recall cards and your numbers show up here."))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No progress yet").font(.title3.weight(.semibold))
                    Text("Finish a race or answer a few recall cards and your numbers show up here.").font(.body).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            }
            HStack(spacing: 12) {
                Button("Race") { race() }.practicePrimaryButton()
                Button("Recall") { recall() }.practiceSecondaryButton()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
