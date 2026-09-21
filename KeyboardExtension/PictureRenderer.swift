//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import UniformTypeIdentifiers

/// The message as a PNG: the script at 64pt, white on black whatever the
/// appearance, wrapped only once a line would pass the width a chat can show,
/// and no wider than its text — so a short message is a small picture.
enum PictureRenderer {
    static let fontSize: CGFloat = 64
    static let maxTextWidth: CGFloat = 1000
    static let padding: CGFloat = 28

    static func render(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let font = QiulingFont.shared.uiFont(size: fontSize) else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        let attributed = NSAttributedString(string: trimmed, attributes: [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ])
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: options,
            context: nil
        )
        let textSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        let size = CGSize(width: textSize.width + 2 * padding, height: textSize.height + 2 * padding)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // Drawn into the width it was measured at, so the lines break
            // where they were counted; the canvas is only as wide as the ink.
            attributed.draw(
                with: CGRect(x: padding, y: padding, width: maxTextWidth, height: textSize.height),
                options: options,
                context: nil
            )
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
