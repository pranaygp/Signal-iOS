//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SwiftUI
import UIKit

// MARK: - Custom Colors -

extension UIColor {
    fileprivate static func byUserInterfaceLevel(
        base: UIColor,
        elevated: UIColor,
    ) -> UIColor {
        UIColor { traitCollection in
            if traitCollection.userInterfaceLevel == .elevated {
                elevated
            } else {
                base
            }
        }
    }

    public static func byRGBHex(
        light: UInt32,
        lightHighContrast: UInt32? = nil,
        dark: UInt32,
        darkHighContrast: UInt32? = nil,
    ) -> UIColor {
        UIColor(
            light: UIColor(rgbHex: light),
            lightHighContrast: lightHighContrast != nil ? UIColor(rgbHex: lightHighContrast!) : nil,
            dark: UIColor(rgbHex: dark),
            darkHighContrast: darkHighContrast != nil ? UIColor(rgbHex: darkHighContrast!) : nil,
        )
    }

    public convenience init(
        light: UIColor,
        lightHighContrast: UIColor? = nil,
        dark: UIColor,
        darkHighContrast: UIColor? = nil,
    ) {
        self.init { traitCollection in
            switch (traitCollection.userInterfaceStyle, traitCollection.accessibilityContrast) {
            case (.dark, .high) where darkHighContrast != nil:
                darkHighContrast!
            case (.dark, _):
                dark
            case (_, .high) where lightHighContrast != nil:
                lightHighContrast!
            case (_, _):
                light
            }
        }
    }
}

// MARK: - UIKit

extension UIColor {
    public enum Signal {}
}

extension UIColor.Signal {

    // MARK: Accent

    /// Historically Signal blue; in Qiuling this is the brand's Action red
    /// (light) and Dark accent (dark). The name is kept so the hundreds of
    /// call sites keep compiling.
    public static var ultramarine: UIColor {
        UIColor.byRGBHex(
            light: 0xB93220,
            lightHighContrast: 0x942819,
            dark: 0xFF957B,
            darkHighContrast: 0xFFB09B,
        )
    }

    public static var red: UIColor {
        UIColor.byRGBHex(
            light: 0xFF3B30,
            lightHighContrast: 0xD70015,
            dark: 0xFF453A,
            darkHighContrast: 0xFF6961,
        )
    }

    public static var orange: UIColor {
        UIColor.byRGBHex(
            light: 0xFF9500,
            lightHighContrast: 0xC93400,
            dark: 0xFF9F0A,
            darkHighContrast: 0xFFB340,
        )
    }

    public static var yellow: UIColor {
        UIColor.byRGBHex(
            light: 0xFFCC00,
            lightHighContrast: 0xB25000,
            dark: 0xFFD60A,
            darkHighContrast: 0xFFD426,
        )
    }

    public static var green: UIColor {
        UIColor.byRGBHex(
            light: 0x34C759,
            lightHighContrast: 0x248A3D,
            dark: 0x30D158,
            darkHighContrast: 0x30DB5B,
        )
    }

    public static var indigo: UIColor {
        UIColor.byRGBHex(
            light: 0x5856D6,
            lightHighContrast: 0x3634A3,
            dark: 0x5E5CE6,
            darkHighContrast: 0x7D7AFF,
        )
    }

    public static var accent: UIColor { ultramarine }

    public static var link: UIColor { ultramarine }

    // MARK: Label

    public static var label: UIColor {
        UIColor(
            light: Brand.espresso,
            dark: Brand.darkText,
        )
    }

    public static var secondaryLabel: UIColor {
        UIColor(
            light: Brand.muted,
            lightHighContrast: UIColor(rgbHex: 0x5A4E46),
            dark: Brand.darkMuted,
            darkHighContrast: UIColor(rgbHex: 0xD6CBC0),
        )
    }

    public static var tertiaryLabel: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x251F1B, alpha: 0.35),
            lightHighContrast: UIColor(rgbHex: 0x251F1B, alpha: 0.55),
            dark: UIColor(rgbHex: 0xF7EFE3, alpha: 0.35),
            darkHighContrast: UIColor(rgbHex: 0xF7EFE3, alpha: 0.5),
        )
    }

    public static var quaternaryLabel: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x251F1B, alpha: 0.2),
            lightHighContrast: UIColor(rgbHex: 0x251F1B, alpha: 0.42),
            dark: UIColor(rgbHex: 0xF7EFE3, alpha: 0.18),
            darkHighContrast: UIColor(rgbHex: 0xF7EFE3, alpha: 0.28),
        )
    }

    public static var emphasisLabel: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0xE81F28),
            lightHighContrast: UIColor(rgbHex: 0xE30B14),
            dark: UIColor(rgbHex: 0xFC3040),
            darkHighContrast: UIColor(rgbHex: 0xFF515E),
        )
    }

    public static var warningLabel: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0xB44828),
            dark: UIColor(rgbHex: 0xEB977D),
        )
    }

    public static var officialLabel: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x2934FD),
            dark: UIColor(rgbHex: 0xC5C7F5),
        )
    }

    public static var officialLabelBackground: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x2934FD).withAlphaComponent(0.12),
            dark: UIColor(rgbHex: 0x424585),
        )
    }

    // MARK: Background

    public static var background: UIColor {
        UIColor.byUserInterfaceLevel(
            base: UIColor.byRGBHex(
                light: 0xF6F1E8,
                dark: 0x1C1917,
            ),
            elevated: UIColor.byRGBHex(
                light: 0xF6F1E8,
                dark: 0x292320,
                darkHighContrast: 0x352D29,
            ),
        )
    }

    /// Background for all media content. Black in dark mode and white in light mode.
    /// Unlike `background` this color does not have "elevated" colors.
    public static var mediaBackground: UIColor {
        return UIColor(light: .white, dark: .black)
    }

    public static var secondaryBackground: UIColor {
        guard #available(iOS 16.0, *) else {
            return .secondarySystemBackground
        }
        return UIColor.byUserInterfaceLevel(
            base: UIColor.byRGBHex(
                light: 0xFFFCF7,
                lightHighContrast: 0xFFFFFF,
                dark: 0x292320,
                darkHighContrast: 0x352D29,
            ),
            elevated: UIColor.byRGBHex(
                light: 0xFFFCF7,
                lightHighContrast: 0xFFFFFF,
                dark: 0x352D29,
                darkHighContrast: 0x443A35,
            ),
        )
    }

    public static var tertiaryBackground: UIColor {
        UIColor.byUserInterfaceLevel(
            base: UIColor.byRGBHex(
                light: 0xFFFCF7,
                dark: 0x352D29,
                darkHighContrast: 0x443A35,
            ),
            elevated: UIColor.byRGBHex(
                light: 0xFFFCF7,
                dark: 0x443A35,
                darkHighContrast: 0x554A44,
            ),
        )
    }

    public static var secondaryUltramarineBackground: UIColor {
        Brand.selection
    }

    public static var backdrop: UIColor {
        UIColor(
            light: UIColor(white: 0, alpha: 0.2),
            dark: UIColor(white: 0, alpha: 0.48),
        )
    }

    // MARK: Grouped Background

    public static var groupedBackground: UIColor {
        guard #available(iOS 16.0, *) else {
            return .systemGroupedBackground
        }
        return UIColor.byUserInterfaceLevel(
            base: UIColor.byRGBHex(
                light: 0xF6F1E8,
                lightHighContrast: 0xEFE8DD,
                dark: 0x1C1917,
            ),
            elevated: UIColor.byRGBHex(
                light: 0xF6F1E8,
                lightHighContrast: 0xEFE8DD,
                dark: 0x292320,
                darkHighContrast: 0x352D29,
            ),
        )
    }

    public static var secondaryGroupedBackground: UIColor {
        UIColor.byUserInterfaceLevel(
            base: UIColor.byRGBHex(
                light: 0xFFFCF7,
                dark: 0x292320,
                darkHighContrast: 0x352D29,
            ),
            elevated: UIColor.byRGBHex(
                light: 0xFFFCF7,
                dark: 0x352D29,
                darkHighContrast: 0x443A35,
            ),
        )
    }

    public static var tertiaryGroupedBackground: UIColor {
        guard #available(iOS 16.0, *) else {
            return .tertiarySystemGroupedBackground
        }
        return UIColor.byUserInterfaceLevel(
            base: UIColor.byRGBHex(
                light: 0xEFE8DD,
                lightHighContrast: 0xE6DDD0,
                dark: 0x352D29,
                darkHighContrast: 0x443A35,
            ),
            elevated: UIColor.byRGBHex(
                light: 0xEFE8DD,
                lightHighContrast: 0xE6DDD0,
                dark: 0x443A35,
                darkHighContrast: 0x554A44,
            ),
        )
    }

    // MARK: Fill

    public static var primaryFill: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x787880, alpha: 0.2),
            lightHighContrast: UIColor(rgbHex: 0x787880, alpha: 0.3),
            dark: UIColor(rgbHex: 0x787880, alpha: 0.36),
            darkHighContrast: UIColor(rgbHex: 0x787880, alpha: 0.46),
        )
    }

    public static var secondaryFill: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x787880, alpha: 0.16),
            lightHighContrast: UIColor(rgbHex: 0x787880, alpha: 0.26),
            dark: UIColor(rgbHex: 0x787880, alpha: 0.32),
            darkHighContrast: UIColor(rgbHex: 0x787880, alpha: 0.42),
        )
    }

    public static var tertiaryFill: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x767680, alpha: 0.12),
            lightHighContrast: UIColor(rgbHex: 0x767680, alpha: 0.22),
            dark: UIColor(rgbHex: 0x767680, alpha: 0.24),
            darkHighContrast: UIColor(rgbHex: 0x767680, alpha: 0.34),
        )
    }

    public static var quaternaryFill: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x747480, alpha: 0.08),
            lightHighContrast: UIColor(rgbHex: 0x747480, alpha: 0.18),
            dark: UIColor(rgbHex: 0x747480, alpha: 0.18),
            darkHighContrast: UIColor(rgbHex: 0x747480, alpha: 0.28),
        )
    }

    // MARK: Material

    /// Designed to be used on top of material (blur / glass) backgrounds.
    public enum MaterialBase {

        public static var fillPrimary: UIColor {
            UIColor(
                light: UIColor(white: 0, alpha: 0.24),
                dark: UIColor(white: 1, alpha: 0.48),
            )
        }

        public static var fillSecondary: UIColor {
            UIColor(
                light: UIColor(white: 0, alpha: 0.16),
                dark: UIColor(white: 1, alpha: 0.24),
            )
        }

        public static var fillTertiary: UIColor {
            UIColor(
                light: UIColor(white: 0, alpha: 0.1),
                dark: UIColor(white: 1, alpha: 0.16),
            )
        }

        public static var button: UIColor {
            UIColor(
                light: UIColor(white: 0, alpha: 0.12),
                dark: UIColor(white: 1, alpha: 0.2),
            )
        }
    }

    // MARK: Light

    /// To be used on top of neutral backgrounds
    /// (eg incoming message bubbles when no wallpaper).
    public enum LightBase {

        public static var fillPrimary: UIColor {
            UIColor(
                light: UIColor(white: 1, alpha: 1),
                dark: UIColor(white: 1, alpha: 0.48),
            )
        }

        public static var fillSecondary: UIColor {
            UIColor(
                light: UIColor(white: 1, alpha: 0.8),
                dark: UIColor(white: 1, alpha: 0.24),
            )
        }

        public static var fillTertiary: UIColor {
            UIColor(
                light: UIColor(white: 1, alpha: 0.6),
                dark: UIColor(white: 1, alpha: 0.16),
            )
        }

        public static var button: UIColor {
            UIColor(
                light: UIColor(white: 1, alpha: 0.8),
                dark: UIColor(white: 1, alpha: 0.2),
            )
        }
    }

    // MARK: Color

    /// To be used on top of any arbitrary color. Fixed across light/dark theme.
    public enum ColorBase {

        public static var labelPrimary: UIColor {
            UIColor(white: 1, alpha: 1)
        }

        public static var labelSecondary: UIColor {
            UIColor(white: 1, alpha: 0.8)
        }

        public static var labelTertiary: UIColor {
            UIColor(white: 1, alpha: 0.4)
        }

        public static var labelInverted: UIColor {
            UIColor(white: 0, alpha: 1)
        }

        public static var labelInvertedSecondary: UIColor {
            UIColor(white: 0, alpha: 0.7)
        }

        public static var fillPrimary: UIColor {
            UIColor(white: 1, alpha: 0.8)
        }

        public static var fillSecondary: UIColor {
            UIColor(white: 1, alpha: 0.7)
        }

        public static var fillTertiary: UIColor {
            UIColor(
                light: UIColor(white: 1, alpha: 0.6),
                dark: UIColor(white: 1, alpha: 0.48),
            )
        }

        public static var button: UIColor {
            UIColor(white: 1, alpha: 0.2)
        }
    }

    @available(iOS 26, *)
    public static var glassBackgroundTint: UIColor {
        UIColor(
            light: UIColor(white: 1, alpha: 0.12),
            dark: UIColor(white: 0, alpha: 0.2),
        )
    }

    // MARK: Separator

    public static var opaqueSeparator: UIColor {
        UIColor.byRGBHex(
            light: 0xC6C6C8,
            lightHighContrast: 0xAEAEB2,
            dark: 0x38383A,
            darkHighContrast: 0x515154,
        )
    }

    public static var transparentSeparator: UIColor {
        UIColor(
            light: UIColor(rgbHex: 0x3C3C43, alpha: 0.36),
            lightHighContrast: UIColor(rgbHex: 0x3C3C43, alpha: 0.46),
            dark: UIColor(rgbHex: 0x545458, alpha: 0.65),
            darkHighContrast: UIColor(rgbHex: 0x545458, alpha: 0.75),
        )
    }
}

// MARK: - SwiftUI

extension Color {
    public enum Signal {}
}

extension Color.Signal {

    // MARK: Accent

    public static var ultramarine: Color {
        Color(UIColor.Signal.ultramarine)
    }

    public static var red: Color {
        Color(UIColor.Signal.red)
    }

    public static var orange: Color {
        Color(UIColor.Signal.orange)
    }

    public static var yellow: Color {
        Color(UIColor.Signal.yellow)
    }

    public static var green: Color {
        Color(UIColor.Signal.green)
    }

    public static var indigo: Color {
        Color(UIColor.Signal.indigo)
    }

    public static var accent: Color { ultramarine }

    public static var link: Color { ultramarine }

    // MARK: Label

    public static var label: Color {
        Color(UIColor.Signal.label)
    }

    public static var secondaryLabel: Color {
        Color(UIColor.Signal.secondaryLabel)
    }

    public static var tertiaryLabel: Color {
        Color(UIColor.Signal.tertiaryLabel)
    }

    public static var quaternaryLabel: Color {
        Color(UIColor.Signal.quaternaryLabel)
    }

    public static var emphasisLabel: Color {
        Color(UIColor.Signal.emphasisLabel)
    }

    public static var warningLabel: Color {
        Color(UIColor.Signal.warningLabel)
    }

    // MARK: Background

    public static var background: Color {
        Color(UIColor.Signal.background)
    }

    public static var secondaryBackground: Color {
        Color(UIColor.Signal.secondaryBackground)
    }

    public static var tertiaryBackground: Color {
        Color(UIColor.Signal.tertiaryBackground)
    }

    // MARK: Grouped Background

    public static var groupedBackground: Color {
        Color(UIColor.Signal.groupedBackground)
    }

    public static var secondaryGroupedBackground: Color {
        Color(UIColor.Signal.secondaryGroupedBackground)
    }

    public static var tertiaryGroupedBackground: Color {
        Color(UIColor.Signal.tertiaryGroupedBackground)
    }

    // MARK: Fill

    public static var primaryFill: Color {
        Color(UIColor.Signal.primaryFill)
    }

    public static var secondaryFill: Color {
        Color(UIColor.Signal.secondaryFill)
    }

    public static var tertiaryFill: Color {
        Color(UIColor.Signal.tertiaryFill)
    }

    public static var quaternaryFill: Color {
        Color(UIColor.Signal.quaternaryFill)
    }

    // MARK: Separator

    public static var opaqueSeparator: Color {
        Color(UIColor.Signal.opaqueSeparator)
    }

    public static var transparentSeparator: Color {
        Color(UIColor.Signal.transparentSeparator)
    }

}
