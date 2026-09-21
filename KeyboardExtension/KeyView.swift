//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import UIKit

enum PrivateKeyState {
    case off
    case offWaiting
    case on
    /// Secure field or no font: drawn faint, does nothing.
    case unavailable
}

/// Everything that decides how a key looks apart from its own kind.
struct KeyAppearance: Equatable {
    var palette: KeyboardPalette
    var fittedSize: CGFloat
    /// The a–z union box at `fittedSize`, y up, relative to the baseline origin.
    var unionBox: CGRect
    var fontAvailable: Bool
    var returnKeyType: UIReturnKeyType = .default
    var returnEmphasised = false
    var returnDimmed = false
    var privateState: PrivateKeyState = .off
    var cornerRadius: CGFloat = 8
    /// Digits and punctuation, drawn in the system font like the system's letters.
    var characterLabelSize: CGFloat = 24
    /// Return, 123, space and the like.
    var specialLabelSize: CGFloat = 18
    /// Labels fade while the space bar is held to seek the caret.
    var labelAlpha: CGFloat = 1
}

/// One key: face, shadow band, label. Touches are tracked by the key area,
/// not here, so a finger can slide between keys; this view only draws and
/// speaks for VoiceOver.
final class KeyView: UIView {
    let spec: KeySpec
    var appearance: KeyAppearance {
        didSet {
            guard appearance != oldValue else { return }
            highlight.backgroundColor = appearance.palette.pressedSpecialFace
            setNeedsDisplay()
            refreshAccessibility()
        }
    }
    /// Performs the key's touch-up action, for VoiceOver activation.
    var onActivate: (() -> Void)?

    /// The key's rectangle in the key area; the view is one point taller to
    /// hold the shadow band beneath the face.
    var keyFrame: CGRect = .zero {
        didSet { frame = CGRect(x: keyFrame.minX, y: keyFrame.minY, width: keyFrame.width, height: keyFrame.height + 1) }
    }
    private(set) var isPressed = false
    private let highlight = UIView()

    init(spec: KeySpec, appearance: KeyAppearance) {
        self.spec = spec
        self.appearance = appearance
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        highlight.isUserInteractionEnabled = false
        highlight.alpha = 0
        highlight.layer.cornerRadius = appearance.cornerRadius
        highlight.layer.cornerCurve = .continuous
        addSubview(highlight)
        isAccessibilityElement = true
        accessibilityTraits = [.keyboardKey]
        refreshAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = faceRect
        highlight.backgroundColor = appearance.palette.pressedSpecialFace
    }

    private var faceRect: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 1) }

    /// Special keys light up on touch-down at once and fade out on release; the
    /// callout is the feedback for character keys, whose faces stay put.
    func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        if spec.kind.isSpecial {
            if pressed {
                highlight.layer.removeAllAnimations()
                highlight.alpha = 1
            } else {
                UIView.animate(withDuration: 0.1) { self.highlight.alpha = 0 }
            }
        }
        if spec.kind == .delete { setNeedsDisplay() }
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let palette = appearance.palette
        let face = faceRect
        let radius = appearance.cornerRadius

        let shadowPath = UIBezierPath(roundedRect: face.offsetBy(dx: 0, dy: 1), cornerRadius: radius)
        palette.keyShadow.setFill()
        shadowPath.fill()

        let facePath = UIBezierPath(roundedRect: face, cornerRadius: radius)
        faceColor.setFill()
        facePath.fill()

        context.setAlpha(appearance.labelAlpha)
        var labelColor = palette.label
        var labelAlpha: CGFloat = 1
        let size = appearance.specialLabelSize
        switch spec.kind {
        case .character(let text):
            drawCharacterLabel(text, in: face, context: context, color: labelColor)
        case .space:
            drawText(Strings.spaceKey, size: size, color: palette.secondaryLabel, in: face)
        case .layer(let target):
            drawText(target == .numbers ? Strings.numbersKey : Strings.lettersKey, size: size, color: labelColor, in: face)
        case .page(let target):
            drawText(target == .symbols ? Strings.symbolsKey : Strings.numbersKey, size: size, color: labelColor, in: face)
        case .delete:
            drawSymbol(isPressed ? "delete.left.fill" : "delete.left", color: labelColor, in: face)
        case .globe:
            drawSymbol("globe", color: labelColor, in: face)
        case .returnKey:
            if appearance.returnEmphasised { labelColor = palette.emphasisedReturnLabel }
            if appearance.returnDimmed { labelAlpha = 0.4 }
            drawText(Strings.returnLabel(for: appearance.returnKeyType), size: size, color: labelColor.withAlphaComponent(labelAlpha), in: face)
        case .privateCompose:
            switch appearance.privateState {
            case .on:
                drawSymbol("lock.fill", color: palette.indicator, in: face)
            case .unavailable:
                drawSymbol("lock", color: labelColor.withAlphaComponent(0.4), in: face)
            case .off, .offWaiting:
                drawSymbol("lock", color: labelColor, in: face)
                if appearance.privateState == .offWaiting {
                    palette.indicator.setFill()
                    UIBezierPath(ovalIn: CGRect(x: face.maxX - 5 - 6, y: face.minY + 5, width: 6, height: 6)).fill()
                }
            }
        }
    }

    private var faceColor: UIColor {
        let palette = appearance.palette
        switch spec.kind {
        case .character, .space:
            return palette.keyFace
        case .returnKey:
            return appearance.returnEmphasised ? palette.emphasisedReturnFace : palette.specialFace
        case .privateCompose:
            return appearance.privateState == .on ? palette.privateOnFace : palette.specialFace
        default:
            return palette.specialFace
        }
    }

    private func drawCharacterLabel(_ text: String, in face: CGRect, context: CGContext, color: UIColor) {
        if spec.isMark, appearance.fontAvailable,
           let (glyph, font) = QiulingFont.shared.glyph(for: text, size: appearance.fittedSize) {
            KeyView.drawMark(glyph: glyph, font: font, unionBox: appearance.unionBox, centre: CGPoint(x: face.midX, y: face.midY), color: color, in: context, viewHeight: bounds.height)
        } else {
            drawText(text, size: appearance.characterLabelSize, color: color, in: face)
        }
    }

    /// Draws a mark with the alphabet's union box centred vertically on
    /// `centre` and its own ink centred horizontally, so every letter sits on
    /// the same baseline and none looks shoved to one side.
    static func drawMark(glyph: CGGlyph, font: CTFont, unionBox: CGRect, centre: CGPoint, color: UIColor, in context: CGContext, viewHeight: CGFloat) {
        var glyphs = [glyph]
        let ink = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1)
        let originX = centre.x - ink.midX
        let baselineY = centre.y + unionBox.midY
        context.saveGState()
        context.translateBy(x: 0, y: viewHeight)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.setFillColor(color.cgColor)
        var position = CGPoint(x: originX, y: viewHeight - baselineY)
        CTFontDrawGlyphs(font, &glyphs, &position, 1, context)
        context.restoreGState()
    }

    private func drawText(_ text: String, size: CGFloat, color: UIColor, in face: CGRect) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ])
        let textSize = attributed.size()
        attributed.draw(at: CGPoint(x: face.midX - textSize.width / 2, y: face.midY - textSize.height / 2))
    }

    private func drawSymbol(_ name: String, color: UIColor, in face: CGRect) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular, scale: .medium)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let size = image.size
        // UIImage drawing sets its own alpha, so the context's fade is passed along.
        image.draw(in: CGRect(x: face.midX - size.width / 2, y: face.midY - size.height / 2, width: size.width, height: size.height), blendMode: .normal, alpha: appearance.labelAlpha)
    }

    // MARK: Accessibility

    private func refreshAccessibility() {
        accessibilityValue = nil
        accessibilityHint = nil
        var traits: UIAccessibilityTraits = [.keyboardKey]
        switch spec.kind {
        case .character(let text):
            accessibilityLabel = Strings.accessibilityName(for: text)
        case .space:
            accessibilityLabel = Strings.spaceLabel
        case .delete:
            accessibilityLabel = Strings.deleteLabel
            accessibilityHint = Strings.deleteHint
        case .layer(let target):
            accessibilityLabel = target == .numbers ? Strings.numbersLabel : Strings.lettersLabel
        case .page(let target):
            accessibilityLabel = target == .symbols ? Strings.symbolsLabel : Strings.numbersLabel
        case .globe:
            accessibilityLabel = Strings.globeLabel
            accessibilityHint = Strings.globeHint
        case .returnKey:
            accessibilityLabel = Strings.returnAccessibilityLabel(for: appearance.returnKeyType)
        case .privateCompose:
            accessibilityLabel = Strings.privateLabel
            accessibilityHint = Strings.privateHint
            switch appearance.privateState {
            case .on: accessibilityValue = Strings.privateValueOn
            case .off: accessibilityValue = Strings.privateValueOff
            case .offWaiting: accessibilityValue = Strings.privateValueWaiting
            case .unavailable:
                accessibilityValue = Strings.privateValueOff
                traits.insert(.notEnabled)
            }
        }
        accessibilityTraits = traits
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}
