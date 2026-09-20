//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import SwiftUI

/// The practice screens' vocabulary. Surfaces and labels come from
/// `Color.Signal`; only the handful of meanings Signal has no word for —
/// right, wrong, the current mark — are named here, and this is the one place
/// in Practice where a hex value may appear.
@available(iOS 16, *)
enum PracticeTheme {
    static let accent = Color(uiColor: Brand.actionColor)
    static let good = Color(uiColor: UIColor(light: Brand.success, dark: UIColor(rgbHex: 0x86B789)))
    static let wrong = Color(uiColor: UIColor(light: Brand.error, dark: UIColor(rgbHex: 0xE0847E)))
    static let tint = Color(uiColor: Brand.selection)
    static let wrongBackground = Color(uiColor: UIColor(light: UIColor(rgbHex: 0xF6D9D3), dark: UIColor(rgbHex: 0x4A2A25)))

    /// The script. `Font.custom` resolves registered process fonts, including
    /// a copy `QiulingFonts` swapped in over the air.
    static func script(_ size: CGFloat) -> Font { .custom(QiulingFonts.family, size: size) }

    /// The tint behind a mark in the heat map, a chip or a status capsule.
    static func statusFill(_ label: Recall.Label) -> Color {
        switch label {
        case .new: Color.Signal.groupedBackground
        case .struggling: wrong.opacity(0.18)
        case .learning: Color.Signal.accent.opacity(0.12)
        case .mastered: good.opacity(0.22)
        }
    }

    /// The text colour that names a learning state.
    static func statusColor(_ label: Recall.Label) -> Color {
        switch label {
        case .new: Color.Signal.secondaryLabel
        case .struggling: wrong
        case .learning: Color.Signal.accent
        case .mastered: good
        }
    }
}

/// The numbers as the practice screens spell them.
enum PracticeFormat {
    /// `0.8 s` from a millisecond count.
    static func seconds(ms: Double) -> String { String(format: "%.1f s", ms / 1000) }
    static func seconds(ms: Int) -> String { seconds(ms: Double(ms)) }
    /// `0.8 seconds`, for VoiceOver.
    static func secondsSpoken(ms: Int) -> String { String(format: "%.1f seconds", Double(ms) / 1000) }

    /// `30 s`, `1 min`, `2 min` for a race's clock in a label or row.
    static func duration(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    /// `30 seconds`, `1 minute`, `2 minutes` for a menu.
    static func durationSpelled(_ seconds: Int) -> String {
        if seconds % 60 == 0 { let m = seconds / 60; return m == 1 ? "1 minute" : "\(m) minutes" }
        return "\(seconds) seconds"
    }

    /// A mark's spelling read letter by letter, for VoiceOver.
    static func spelled(_ mark: String) -> String { mark.map(String.init).joined(separator: " ") }
}

@available(iOS 16, *)
extension Recall.Label {
    var title: String {
        switch self { case .new: "New"; case .struggling: "Struggling"; case .learning: "Learning"; case .mastered: "Mastered" }
    }
}

@available(iOS 16, *)
extension View {
    /// A floating label over content: Liquid Glass on iOS 26, a material below.
    @ViewBuilder
    func practiceGlass() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// The system's primary button: glass on iOS 26, bordered-prominent below.
    @ViewBuilder
    func practicePrimaryButton() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glassProminent).tint(PracticeTheme.accent)
        } else {
            self.buttonStyle(.borderedProminent).tint(PracticeTheme.accent)
        }
    }

    /// The system's secondary button: glass on iOS 26, bordered below.
    @ViewBuilder
    func practiceSecondaryButton() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glass).tint(Color.Signal.label)
        } else {
            self.buttonStyle(.bordered).tint(Color.Signal.label)
        }
    }

    /// A card that is not a table row: the same surface and rounding as one.
    func practiceCardBackground() -> some View {
        self.background(Color.Signal.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: OWSTableViewController2.cellRounding, style: .continuous))
    }

    /// A tap of the haptic engine when `trigger` changes, where the system
    /// offers one (iOS 17). `verdict` says which kind, or nil for none.
    @ViewBuilder
    func practiceHaptic<T: Equatable>(trigger: T, verdict: @escaping (T, T) -> Bool?) -> some View {
        if #available(iOS 17, *) {
            self.sensoryFeedback(trigger: trigger) { old, new in
                switch verdict(old, new) { case true?: .success; case false?: .error; case nil: nil }
            }
        } else {
            self
        }
    }

    /// Swaps a label's symbol with the system's replace effect where it exists.
    @ViewBuilder
    func practiceSymbolReplace() -> some View {
        if #available(iOS 17, *) { self.contentTransition(.symbolEffect(.replace)) } else { self }
    }

    /// Success feedback whenever `trigger` becomes true.
    func practiceSuccessHaptic(trigger: Bool) -> some View {
        practiceHaptic(trigger: trigger) { _, new in new ? true : nil }
    }
}

/// A multi-line field in a table row. Focus is taken explicitly on tap: the
/// editor's own hit-testing is unreliable inside a list.
@available(iOS 16, *)
struct PracticeEditor: View {
    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 96
    @FocusState private var editing: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .focused($editing)
            .textInputAutocapitalization(.sentences)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(Color.Signal.tertiaryLabel)
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
    }
}
