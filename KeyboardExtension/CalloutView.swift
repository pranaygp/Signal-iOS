//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import UIKit

/// One entry in the long-press row: a letter group or a punctuation alternate.
struct CalloutItem: Equatable {
    /// What lifting on the item types.
    let text: String
    /// Drawn as a Qiuling mark (letter groups) or as the character itself.
    let isMark: Bool
}

/// The pop-up over a pressed character key: the key's own rounded rect joined
/// by concave necks to a larger rect above showing the mark magnified with its
/// letter beneath, 11pt wider than the key each side as the system's is. After
/// a long press it widens into a row of alternates. It lives in an overlay
/// above the strip so nothing clips it, and never rises past the input view's
/// top, where the host would clip it.
final class CalloutView: UIView {
    static let upperHeight: CGFloat = 54
    static let upperRise: CGFloat = 8
    static let neck: CGFloat = 6
    static let flare: CGFloat = 11

    private var appearance: KeyAppearance
    private var keyRect: CGRect = .zero
    private var upperRect: CGRect = .zero
    private var spec: KeySpec?
    private var items: [CalloutItem] = []
    private(set) var highlightedIndex: Int?
    private var itemWidth: CGFloat = 44

    init(appearance: KeyAppearance) {
        self.appearance = appearance
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(appearance: KeyAppearance) {
        self.appearance = appearance
        setNeedsDisplay()
    }

    /// Shows the single-key callout for `key`; `keyRect` and `bounds` are in the
    /// overlay's coordinates.
    func show(key: PlacedKey, keyRect: CGRect, keyWidth: CGFloat, within bounds: CGRect) {
        spec = key.spec
        items = []
        highlightedIndex = nil
        self.keyRect = keyRect
        var width = keyWidth + 2 * Self.flare
        var x = keyRect.midX - width / 2
        if key.isFirstInRow && key.row < 3 { x = keyRect.minX }
        if key.isLastInRow && key.row < 3 { x = keyRect.maxX - width }
        width = max(width, keyRect.width)
        upperRect = Self.upperRect(x: x, width: width, above: keyRect, within: bounds)
        relayout()
    }

    /// The magnified rect above the key, held inside the overlay: the host
    /// clips a keyboard at its own top edge, so on the first row the rise
    /// gives way first and then the rect shrinks, rather than run off the top.
    private static func upperRect(x: CGFloat, width: CGFloat, above keyRect: CGRect, within bounds: CGRect) -> CGRect {
        let overflow = max(0, bounds.minY - (keyRect.minY - upperRise - upperHeight))
        let rise = max(0, upperRise - overflow)
        let bottom = keyRect.minY - rise
        let y = max(bounds.minY, bottom - upperHeight)
        return CGRect(x: x, y: y, width: width, height: max(1, bottom - y))
    }

    /// Widens into a row of `items` above the key, kept inside `bounds`.
    func showRow(items: [CalloutItem], keyRect: CGRect, keyWidth: CGFloat, within bounds: CGRect) {
        self.items = items
        self.keyRect = keyRect
        highlightedIndex = nil
        itemWidth = max(keyWidth, 44)
        let width = CGFloat(items.count) * itemWidth + 12
        var x = keyRect.midX - width / 2
        x = min(max(x, bounds.minX + 3), bounds.maxX - 3 - width)
        upperRect = Self.upperRect(x: x, width: width, above: keyRect, within: bounds)
        relayout()
    }

    var isShowingRow: Bool { !items.isEmpty }

    /// The item under a point given in the overlay's coordinates, or nil.
    func item(at point: CGPoint) -> Int? {
        guard isShowingRow, upperRect.insetBy(dx: 0, dy: -12).contains(point) else { return nil }
        let index = Int((point.x - upperRect.minX - 6) / itemWidth)
        return (0..<items.count).contains(index) ? index : nil
    }

    func highlight(_ index: Int?) {
        guard index != highlightedIndex else { return }
        highlightedIndex = index
        setNeedsDisplay()
    }

    func selectedItem() -> CalloutItem? {
        guard let highlightedIndex, highlightedIndex < items.count else { return nil }
        return items[highlightedIndex]
    }

    private func relayout() {
        let union = upperRect.union(keyRect)
        frame = union.insetBy(dx: -8, dy: -8)
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let origin = frame.origin
        let key = keyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let upper = upperRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let palette = appearance.palette

        palette.calloutFace.setFill()
        shapePath(key: key, upper: upper).fill()

        if items.isEmpty {
            drawSingle(in: upper, context: context)
        } else {
            drawRow(in: upper, context: context)
        }
    }

    /// Clockwise from the upper-left: the upper rect, a neck down to the key's
    /// right edge, around the key, and a neck back up. A side whose upper edge
    /// is flush with the key's gets a straight line instead of a neck. The
    /// upper rect is rounder than the key, as the system's magnified pop-up is.
    private func shapePath(key: CGRect, upper: CGRect) -> UIBezierPath {
        let r = appearance.cornerRadius
        let ru = min(r + 5, upper.height / 2)
        let neck = Self.neck
        let path = UIBezierPath()
        path.move(to: CGPoint(x: upper.minX, y: upper.minY + ru))
        path.addArc(withCenter: CGPoint(x: upper.minX + ru, y: upper.minY + ru), radius: ru, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: upper.maxX - ru, y: upper.minY))
        path.addArc(withCenter: CGPoint(x: upper.maxX - ru, y: upper.minY + ru), radius: ru, startAngle: 1.5 * .pi, endAngle: 0, clockwise: true)
        if abs(upper.maxX - key.maxX) < 0.5 {
            path.addLine(to: CGPoint(x: key.maxX, y: key.maxY - r))
        } else {
            path.addLine(to: CGPoint(x: upper.maxX, y: upper.maxY - ru))
            path.addArc(withCenter: CGPoint(x: upper.maxX - ru, y: upper.maxY - ru), radius: ru, startAngle: 0, endAngle: 0.5 * .pi, clockwise: true)
            path.addCurve(
                to: CGPoint(x: key.maxX, y: key.minY),
                controlPoint1: CGPoint(x: key.maxX + neck, y: upper.maxY),
                controlPoint2: CGPoint(x: key.maxX, y: key.minY - neck)
            )
            path.addLine(to: CGPoint(x: key.maxX, y: key.maxY - r))
        }
        path.addArc(withCenter: CGPoint(x: key.maxX - r, y: key.maxY - r), radius: r, startAngle: 0, endAngle: 0.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: key.minX + r, y: key.maxY))
        path.addArc(withCenter: CGPoint(x: key.minX + r, y: key.maxY - r), radius: r, startAngle: 0.5 * .pi, endAngle: .pi, clockwise: true)
        if abs(upper.minX - key.minX) < 0.5 {
            path.addLine(to: CGPoint(x: upper.minX, y: upper.minY + ru))
        } else {
            path.addLine(to: CGPoint(x: key.minX, y: key.minY))
            path.addCurve(
                to: CGPoint(x: upper.minX + ru, y: upper.maxY),
                controlPoint1: CGPoint(x: key.minX, y: key.minY - neck),
                controlPoint2: CGPoint(x: key.minX - neck, y: upper.maxY)
            )
            path.addArc(withCenter: CGPoint(x: upper.minX + ru, y: upper.maxY - ru), radius: ru, startAngle: 0.5 * .pi, endAngle: .pi, clockwise: true)
            path.addLine(to: CGPoint(x: upper.minX, y: upper.minY + ru))
        }
        path.close()
        return path
    }

    private func drawSingle(in upper: CGRect, context: CGContext) {
        guard let spec, case .character(let text) = spec.kind else { return }
        let palette = appearance.palette
        if spec.isMark, appearance.fontAvailable {
            let size = appearance.fittedSize * 1.6
            guard let (glyph, font) = QiulingFont.shared.glyph(for: text, size: size) else { return }
            let union = QiulingFont.shared.unionBox(size: size)
            let latin = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: palette.secondaryLabel,
            ])
            let latinSize = latin.size()
            let blockHeight = union.height + 4 + latinSize.height
            let blockTop = upper.midY - blockHeight / 2
            let markCentre = CGPoint(x: upper.midX, y: blockTop + union.height / 2)
            KeyView.drawMark(glyph: glyph, font: font, unionBox: union, centre: markCentre, color: palette.label, in: context, viewHeight: bounds.height)
            latin.draw(at: CGPoint(x: upper.midX - latinSize.width / 2, y: blockTop + union.height + 4))
        } else {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 36), .foregroundColor: palette.label,
            ])
            let size = attributed.size()
            attributed.draw(at: CGPoint(x: upper.midX - size.width / 2, y: upper.midY - size.height / 2))
        }
    }

    private func drawRow(in upper: CGRect, context: CGContext) {
        let palette = appearance.palette
        for (index, item) in items.enumerated() {
            let cell = CGRect(x: upper.minX + 6 + CGFloat(index) * itemWidth, y: upper.minY + 4, width: itemWidth, height: upper.height - 8)
            if index == highlightedIndex {
                palette.pressedSpecialFace.setFill()
                UIBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 0), cornerRadius: appearance.cornerRadius).fill()
            }
            if item.isMark, appearance.fontAvailable {
                let letters = NSAttributedString(string: item.text, attributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: palette.secondaryLabel,
                ])
                let lettersSize = letters.size()
                let union = appearance.unionBox
                let blockHeight = union.height + 2 + lettersSize.height
                let blockTop = cell.midY - blockHeight / 2
                if let font = QiulingFont.shared.ctFont(size: appearance.fittedSize) {
                    // The group is one ligature; CoreText shapes it as the screen would.
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: [
                        kCTFontAttributeName as NSAttributedString.Key: font,
                        kCTForegroundColorAttributeName as NSAttributedString.Key: palette.label.cgColor,
                    ]))
                    let inkWidth = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width
                    context.saveGState()
                    context.translateBy(x: 0, y: bounds.height)
                    context.scaleBy(x: 1, y: -1)
                    context.textMatrix = .identity
                    context.textPosition = CGPoint(x: cell.midX - inkWidth / 2, y: bounds.height - (blockTop + union.height / 2 + union.midY))
                    CTLineDraw(line, context)
                    context.restoreGState()
                }
                letters.draw(at: CGPoint(x: cell.midX - lettersSize.width / 2, y: blockTop + union.height + 2))
            } else {
                let attributed = NSAttributedString(string: item.text, attributes: [
                    .font: UIFont.systemFont(ofSize: appearance.characterLabelSize), .foregroundColor: palette.label,
                ])
                let size = attributed.size()
                attributed.draw(at: CGPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
            }
        }
    }
}
