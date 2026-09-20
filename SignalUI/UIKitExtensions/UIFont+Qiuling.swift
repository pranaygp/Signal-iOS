//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import UIKit

/// Message text in Qiuling, a private script whose font maps a–z onto its
/// marks and joins common letter groups as ligatures. Only what a message
/// *says* is set in it — bubbles, the compose box, chat-list previews — so
/// the rest of the app stays legible while the screen is not.
///
/// The bundled file lives in `SignalUI/Fonts` and comes from the qiuling
/// repo's `node tools/build_font.js --alphabet morph`; `QiulingFonts` swaps in
/// a newer copy fetched from the trainer when there is one.
public extension UIFont {

    static let qiulingFontName = QiulingFonts.family

    /// Qiuling marks are dense and sit low in the em, so the script reads
    /// comfortably at roughly twice the point size Latin does.
    static let qiulingScale: CGFloat = 1.8

    static var isQiulingAvailable: Bool {
        UIFont(name: qiulingFontName, size: 17) != nil
    }

    /// Qiuling at the given Dynamic Type style: the style's default point size
    /// times `qiulingScale`, then scaled for the user's content size setting
    /// like `UIFont.preferredFont(forTextStyle:)`. Falls back to the system
    /// font if the file is missing, so a bad build degrades to ordinary Signal.
    class func qiuling(forTextStyle style: UIFont.TextStyle, maximumPointSize: CGFloat? = nil) -> UIFont {
        let standard = UITraitCollection(preferredContentSizeCategory: .large)
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: standard)
        guard let face = UIFont(name: qiulingFontName, size: base.pointSize * qiulingScale) else {
            return UIFont.preferredFont(forTextStyle: style, compatibleWith: .current)
        }
        // CoreText applies standard ligatures by default, but the whole script
        // depends on them, so ask for them explicitly rather than trust the default.
        let descriptor = face.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.featureIdentifier: kLigaturesType,
                UIFontDescriptor.FeatureKey.typeIdentifier: kCommonLigaturesOnSelector,
            ]],
        ])
        let ligated = UIFont(descriptor: descriptor, size: 0)
        let metrics = UIFontMetrics(forTextStyle: style)
        if let maximumPointSize {
            return metrics.scaledFont(for: ligated, maximumPointSize: maximumPointSize * qiulingScale, compatibleWith: .current)
        }
        return metrics.scaledFont(for: ligated, compatibleWith: .current)
    }

    /// What `dynamicTypeBody` is for message text.
    class var qiulingBody: UIFont { qiuling(forTextStyle: .body) }

    /// What `dynamicTypeSubheadlineClamped` is for the chat-list snippet.
    class var qiulingSubheadlineClamped: UIFont { qiuling(forTextStyle: .subheadline, maximumPointSize: 21) }
}
