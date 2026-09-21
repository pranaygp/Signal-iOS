//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// The keyboard's colours, one set per appearance, sampled from the iOS 26
/// system keyboard. These are literals on purpose: the extension does not
/// link SignalUI, and the keyboard is meant to look like the system keyboard
/// rather than like the app, so the only brand colour here is the
/// private-mode indicator.
struct KeyboardPalette: Equatable {
    let isDark: Bool

    /// What the keys sit on when the host draws no blur of its own.
    var backdropFallback: UIColor { isDark ? rgb(0x2A2A2A) : rgb(0xD1D3D9) }
    /// Letter, digit and punctuation key faces.
    var keyFace: UIColor { isDark ? rgb(0x6B6B6E) : .white }
    var specialFace: UIColor { isDark ? rgb(0x46464A) : rgb(0xADB3BC) }
    /// A held special key takes the letter-key face, as the system's do.
    var pressedSpecialFace: UIColor { isDark ? rgb(0x6B6B6E) : .white }
    /// The one-point band under every key; the dark keyboard draws none.
    var keyShadow: UIColor { isDark ? .clear : rgb(0x898A8D) }
    var label: UIColor { isDark ? .white : .black }
    var secondaryLabel: UIColor { isDark ? UIColor.white.withAlphaComponent(0.40) : UIColor.black.withAlphaComponent(0.40) }
    var calloutFace: UIColor { isDark ? rgb(0x6B6B6E) : .white }
    var hairline: UIColor { isDark ? UIColor.white.withAlphaComponent(0.20) : UIColor.black.withAlphaComponent(0.20) }
    var emphasisedReturnFace: UIColor { isDark ? rgb(0x0A84FF) : rgb(0x007AFF) }
    var emphasisedReturnLabel: UIColor { .white }
    /// The only brand colour on the keyboard: the lock when private compose is
    /// on, the waiting dot, and the strip's lock.
    var indicator: UIColor { isDark ? rgb(0xFF957B) : rgb(0xB93220) }
    var privateOnFace: UIColor { isDark ? rgb(0x8E8E93) : .white }
    /// The compose box's red for a misspelled word's dotted underline.
    var misspelling: UIColor { isDark ? rgb(0xE4472D) : rgb(0xA62232) }

    private func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
