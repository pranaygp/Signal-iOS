//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import UniformTypeIdentifiers

/// The message as a PNG, set the way the app's Write screen sets it: the
/// script at 56pt, wrapped to a chat's width, on the appearance's paper.
enum PictureRenderer {
    static let canvasWidth: CGFloat = 900
    static let margin: CGFloat = 40

    static func render(_ text: String, palette: KeyboardPalette) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let font = QiulingFont.shared.uiFont(size: 56) else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 10
        paragraph.alignment = .left
        let attributed = NSAttributedString(string: trimmed, attributes: [
            .font: font,
            .foregroundColor: palette.pictureInk,
            .paragraphStyle: paragraph,
        ])
        let textWidth = canvasWidth - 2 * margin
        let bounds = attributed.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let size = CGSize(width: canvasWidth, height: ceil(bounds.height) + 2 * margin)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            palette.pictureBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            attributed.draw(with: CGRect(x: margin, y: margin, width: textWidth, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        return image.pngData()
    }

    /// Puts the picture on the pasteboard for this device only, for five
    /// minutes: long enough to paste into a chat, not long enough to linger.
    static func copy(_ png: Data) {
        UIPasteboard.general.setItems(
            [[UTType.png.identifier: png]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]
        )
    }
}
