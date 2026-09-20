//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import SwiftUI

/// The practice screens' vocabulary: the app's palette as SwiftUI colours and
/// the script's font at the sizes the trainer uses. Controls are the system's
/// — segmented pickers, bordered and glass buttons, menus — tinted with the
/// brand's Action red; only the content surfaces are drawn here.
@available(iOS 16, *)
enum PracticeTheme {
    static let paper = Color(uiColor: Brand.background)
    static let surface = Color(uiColor: Brand.surfaceColor)
    static let ink = Color(uiColor: Brand.text)
    static let muted = Color(uiColor: Brand.textSecondary)
    static let faint = Color(uiColor: UIColor(light: UIColor(rgbHex: 0xC9BDB0), dark: UIColor(rgbHex: 0x74675E)))
    static let accent = Color(uiColor: Brand.actionColor)
    static let good = Color(uiColor: UIColor(light: Brand.success, dark: UIColor(rgbHex: 0x86B789)))
    static let tint = Color(uiColor: Brand.selection)
    static let line = Color(uiColor: Brand.separator)
    static let wrongBackground = Color(uiColor: UIColor(light: UIColor(rgbHex: 0xF6D9D3), dark: UIColor(rgbHex: 0x4A2A25)))

    /// The script. `Font.custom` resolves registered process fonts, including
    /// a copy `QiulingFonts` swapped in over the air.
    static func script(_ size: CGFloat) -> Font { .custom(QiulingFonts.family, size: size) }
    static let mono = Font.system(.footnote, design: .monospaced)
    static let numeral = Font.system(size: 44, weight: .semibold, design: .monospaced).monospacedDigit()
}

@available(iOS 16, *)
extension View {
    /// A floating label over content: Liquid Glass on iOS 26, a material below.
    @ViewBuilder
    func practiceGlass() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// A card on the paper: the brand's Surface with a hairline border. The
    /// border is decoration only; touches fall through to the content.
    func practiceCard() -> some View {
        self
            .background(PracticeTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(PracticeTheme.line, lineWidth: 1).allowsHitTesting(false))
    }

    /// Section caption in the trainer's voice.
    func practiceLabel() -> some View {
        self.font(.system(size: 11, weight: .semibold, design: .monospaced)).textCase(.uppercase).kerning(1.2).foregroundStyle(PracticeTheme.muted)
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
            self.buttonStyle(.glass).tint(PracticeTheme.ink)
        } else {
            self.buttonStyle(.bordered).tint(PracticeTheme.ink)
        }
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
