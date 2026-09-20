//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// The keyboard's colours, one set per appearance. These are literals on
/// purpose: the extension does not link SignalUI, and the keyboard is meant to
/// look like the system keyboard rather than like the app, so the only brand
/// colour here is the private-mode indicator.
struct KeyboardPalette: Equatable {
    let isDark: Bool

    /// What the keys sit on when the host draws no blur of its own.
    var backdropFallback: UIColor { isDark ? rgb(0x2A2A2A) : rgb(0xD1D3D9) }
    /// Letter, digit and punctuation key faces. In the dark they are white at
    /// an alpha so the system blur shows through them.
    var keyFace: UIColor { isDark ? UIColor.white.withAlphaComponent(0.30) : .white }
    var specialFace: UIColor { isDark ? UIColor.white.withAlphaComponent(0.12) : rgb(0xADB3BC) }
    var pressedSpecialFace: UIColor { isDark ? UIColor.white.withAlphaComponent(0.30) : .white }
    var keyShadow: UIColor { isDark ? UIColor.black.withAlphaComponent(0.50) : rgb(0x898A8D) }
    var label: UIColor { isDark ? .white : .black }
    var secondaryLabel: UIColor { isDark ? UIColor.white.withAlphaComponent(0.40) : UIColor.black.withAlphaComponent(0.40) }
    var calloutFace: UIColor { isDark ? rgb(0x6B6B6B) : .white }
    var hairline: UIColor { isDark ? UIColor.white.withAlphaComponent(0.20) : UIColor.black.withAlphaComponent(0.20) }
    var emphasisedReturnFace: UIColor { isDark ? rgb(0x0A84FF) : rgb(0x007AFF) }
    var emphasisedReturnLabel: UIColor { .white }
    /// The only brand colour on the keyboard: the lock when private compose is
    /// on, the waiting dot, and the strip's lock.
    var indicator: UIColor { isDark ? rgb(0xFF957B) : rgb(0xB93220) }
    var privateOnFace: UIColor { isDark ? rgb(0x8E8E93) : .white }
    var pictureInk: UIColor { isDark ? rgb(0xF7EFE3) : rgb(0x251F1B) }
    var pictureBackground: UIColor { isDark ? rgb(0x1C1917) : rgb(0xF6F1E8) }

    private func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
