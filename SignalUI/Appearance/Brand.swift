//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// The Qiuling palette ("Vermilion"): paper surfaces, espresso text, measured
/// red accents. Values are the kit's `tokens/palette.json`; nothing in the
/// app should reach for a hex outside this file.
///
/// The interface accent is the darker Action red (5.5:1 on ivory labels), not
/// the brand vermilion, which is reserved for the icon and large marks where
/// its 3.7:1 against ivory is acceptable.
public enum Brand {
    // Fixed values
    public static let vermilion = UIColor(rgbHex: 0xE4472D)
    public static let ivory = UIColor(rgbHex: 0xFFF6E5)
    public static let paper = UIColor(rgbHex: 0xF6F1E8)
    public static let surface = UIColor(rgbHex: 0xFFFCF7)
    public static let espresso = UIColor(rgbHex: 0x251F1B)
    public static let muted = UIColor(rgbHex: 0x74675E)
    public static let border = UIColor(rgbHex: 0xDED4C8)
    public static let action = UIColor(rgbHex: 0xB93220)
    public static let actionPressed = UIColor(rgbHex: 0x942819)
    public static let tint = UIColor(rgbHex: 0xFCE2D8)
    public static let success = UIColor(rgbHex: 0x29664D)
    public static let error = UIColor(rgbHex: 0xA62232)

    public static let darkBackground = UIColor(rgbHex: 0x1C1917)
    public static let darkSurface = UIColor(rgbHex: 0x292320)
    public static let darkText = UIColor(rgbHex: 0xF7EFE3)
    public static let darkMuted = UIColor(rgbHex: 0xBCAFA3)
    public static let darkAccent = UIColor(rgbHex: 0xFF957B)
    public static let darkBorder = UIColor(rgbHex: 0x4B4038)
    public static let darkTint = UIColor(rgbHex: 0x49302A)

    /// A step above the dark surface, for sheets presented over it.
    public static let darkElevated = UIColor(rgbHex: 0x352D29)

    // Semantic, switching with the appearance
    public static var background: UIColor { UIColor(light: paper, dark: darkBackground) }
    public static var surfaceColor: UIColor { UIColor(light: surface, dark: darkSurface) }
    public static var text: UIColor { UIColor(light: espresso, dark: darkText) }
    public static var textSecondary: UIColor { UIColor(light: muted, dark: darkMuted) }
    public static var actionColor: UIColor { UIColor(light: action, dark: darkAccent) }
    public static var onAction: UIColor { UIColor(light: ivory, dark: espresso) }
    public static var selection: UIColor { UIColor(light: tint, dark: darkTint) }
    public static var separator: UIColor { UIColor(light: border, dark: darkBorder) }

    /// Outgoing-bubble tint for a given theme, when the chat has no color of its own.
    public static func bubbleTint(isDarkThemeEnabled: Bool) -> UIColor { isDarkThemeEnabled ? darkTint : tint }
    /// Incoming-bubble surface for a given theme.
    public static func bubbleSurface(isDarkThemeEnabled: Bool) -> UIColor { isDarkThemeEnabled ? darkSurface : surface }
}
