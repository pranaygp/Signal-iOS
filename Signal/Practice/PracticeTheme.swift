//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import SwiftUI

/// The practice screens' vocabulary: the app's palette as SwiftUI colours,
/// the script's font at the sizes the trainer uses, and Liquid Glass for the
/// floating controls where the OS has it.
@available(iOS 16, *)
enum PracticeTheme {
    static let paper = Color(uiColor: Brand.background)
    static let surface = Color(uiColor: Brand.surfaceColor)
    static let ink = Color(uiColor: Brand.text)
    static let muted = Color(uiColor: Brand.textSecondary)
    static let faint = Color(uiColor: UIColor(light: UIColor(rgbHex: 0xC9BDB0), dark: UIColor(rgbHex: 0x74675E)))
    static let accent = Color(uiColor: Brand.actionColor)
    static let onAccent = Color(uiColor: Brand.onAction)
    static let good = Color(uiColor: UIColor(light: Brand.success, dark: UIColor(rgbHex: 0x86B789)))
    static let tint = Color(uiColor: Brand.selection)
    static let line = Color(uiColor: Brand.separator)
    static let wrongBackground = Color(uiColor: UIColor(light: UIColor(rgbHex: 0xF6D9D3), dark: UIColor(rgbHex: 0x4A2A25)))
    static let rightBackground = Color(uiColor: UIColor(light: UIColor(rgbHex: 0xE6EFE9), dark: UIColor(rgbHex: 0x243328)))

    /// The script. `Font.custom` resolves registered process fonts, including
    /// a copy `QiulingFonts` swapped in over the air.
    static func script(_ size: CGFloat) -> Font { .custom(QiulingFonts.family, size: size) }
    static let mono = Font.system(.footnote, design: .monospaced)
    static let monoLabel = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let numeral = Font.system(size: 44, weight: .semibold, design: .monospaced).monospacedDigit()
}

@available(iOS 16, *)
extension View {
    /// A floating control cluster: Liquid Glass on iOS 26, a material below.
    @ViewBuilder
    func practiceGlass(_ shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// A card on the paper: the brand's Surface with a hairline border.
    func practiceCard() -> some View {
        self
            .background(PracticeTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(PracticeTheme.line, lineWidth: 1).allowsHitTesting(false))
    }

    /// Small caps label in the trainer's voice.
    func practiceLabel() -> some View {
        self.font(PracticeTheme.monoLabel).textCase(.uppercase).kerning(1.2).foregroundStyle(PracticeTheme.muted)
    }
}

/// A row of options in a capsule, the trainer's segmented pickers.
@available(iOS 16, *)
struct PracticeSegment<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selection = value }
                } label: {
                    Text(label)
                        .font(.system(size: 13, weight: selection == value ? .semibold : .regular, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .foregroundStyle(selection == value ? PracticeTheme.onAccent : PracticeTheme.ink)
                        .background(selection == value ? PracticeTheme.accent : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .practiceGlass()
    }
}

/// The primary action, in the brand's Action red with ivory text.
@available(iOS 16, *)
struct PracticeButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .textCase(.uppercase).kerning(1)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(prominent ? PracticeTheme.onAccent : PracticeTheme.ink)
            .background(prominent ? PracticeTheme.accent : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? .clear : PracticeTheme.ink, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A multi-line field on a card. Focus is taken explicitly on tap: the
/// editor's own hit-testing is unreliable inside the section's scroll view.
@available(iOS 16, *)
struct PracticeEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 96
    @FocusState private var editing: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 15, design: .monospaced))
            .focused($editing)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(8)
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
            .practiceCard()
    }
}
