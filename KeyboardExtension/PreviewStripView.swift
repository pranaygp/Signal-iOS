//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import UIKit

/// The band above the keys. Normally it shows what has been typed into the
/// host, set in Qiuling, so the marks can be read back; in private compose it
/// becomes the composer — lock, the message with a caret, Insert and Picture.
final class PreviewStripView: UIView {
    enum Mode: Equatable {
        case normal
        case privateCompose
    }

    var palette: KeyboardPalette {
        didSet { applyPalette() }
    }
    var fontSize: CGFloat = 24 {
        didSet { message.fontSize = fontSize }
    }
    var fontAvailable = true {
        didSet { message.fontAvailable = fontAvailable }
    }
    var cellWidth: CGFloat = 64 {
        didSet { setNeedsLayout() }
    }
    private(set) var mode: Mode = .normal

    var onInsert: (() -> Void)?
    var onPicture: (() -> Void)?

    private let message = MessageAreaView()
    private let lock = UIImageView()
    private let insertCell = StripCell(title: Strings.insert)
    private let pictureCell = StripCell(title: Strings.picture)
    private let hairlineA = UIView()
    private let hairlineB = UIView()
    private let peek = UILongPressGestureRecognizer()
    private var noticeTimer: Timer?
    private var copiedTimer: Timer?
    private var latinForPeek = ""

    init(palette: KeyboardPalette) {
        self.palette = palette
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        lock.image = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        lock.contentMode = .center
        lock.isAccessibilityElement = false
        [message, lock, hairlineA, insertCell, hairlineB, pictureCell].forEach(addSubview)
        insertCell.addTarget(self, action: #selector(insertTapped), for: .touchUpInside)
        pictureCell.addTarget(self, action: #selector(pictureTapped), for: .touchUpInside)
        insertCell.accessibilityHint = Strings.insertHint
        pictureCell.accessibilityHint = Strings.pictureHint
        peek.minimumPressDuration = 0.4
        peek.addTarget(self, action: #selector(peekChanged))
        message.addGestureRecognizer(peek)
        message.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: Strings.showLettersAction, target: self, selector: #selector(showLettersAction)),
        ]
        applyPalette()
        setMode(.normal, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyPalette() {
        message.palette = palette
        lock.tintColor = palette.indicator
        hairlineA.backgroundColor = palette.hairline
        hairlineB.backgroundColor = palette.hairline
        insertCell.palette = palette
        pictureCell.palette = palette
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        switch mode {
        case .normal:
            message.frame = bounds
        case .privateCompose:
            lock.frame = CGRect(x: 10, y: 0, width: 13, height: h)
            let cellsStart = bounds.width - 2 * cellWidth - 2
            message.frame = CGRect(x: 10 + 13 + 8, y: 0, width: cellsStart - (10 + 13 + 8), height: h)
            hairlineA.frame = CGRect(x: cellsStart, y: (h - 28) / 2, width: 1, height: 28)
            insertCell.frame = CGRect(x: cellsStart + 1, y: 0, width: cellWidth, height: h)
            hairlineB.frame = CGRect(x: cellsStart + 1 + cellWidth, y: (h - 28) / 2, width: 1, height: 28)
            pictureCell.frame = CGRect(x: cellsStart + 2 + cellWidth, y: 0, width: cellWidth, height: h)
        }
    }

    // MARK: Mode

    func setMode(_ newMode: Mode, animated: Bool) {
        let apply = {
            self.mode = newMode
            let isPrivate = newMode == .privateCompose
            [self.lock, self.hairlineA, self.hairlineB, self.insertCell, self.pictureCell].forEach { $0.isHidden = !isPrivate }
            self.message.isPrivate = isPrivate
            self.peek.isEnabled = isPrivate
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve], animations: apply)
        } else {
            apply()
        }
    }

    /// Normal mode: the host's text before the caret, normalised for display.
    func showContext(_ latin: String) {
        if isShowingNotice {
            message.rememberContext(latin)
        } else {
            message.content = .normal(latin)
        }
        message.accessibilityLabel = Strings.stripNormalLabel
        message.accessibilityValue = latin
        message.accessibilityHint = nil
        message.accessibilityTraits = [.staticText]
        message.accessibilityCustomActions = []
    }

    /// The fallback strip when the font could not be loaded: a notice until any key is tapped.
    func showFontUnavailable() {
        message.content = .notice(Strings.fontUnavailableNotice, symbol: nil)
        message.accessibilityLabel = Strings.fontUnavailableNotice
        message.accessibilityValue = nil
    }

    /// Private mode: the buffer, with Insert live once the table is ready.
    func showBuffer(_ normalised: String, insertEnabled: Bool, animated: Bool = false) {
        latinForPeek = normalised
        let apply = { self.message.content = .buffer(normalised) }
        if isShowingNotice {
            // The notice keeps the area until its time is up; it restores this text.
        } else if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: message, duration: 0.15, options: [.transitionCrossDissolve], animations: apply)
        } else {
            apply()
        }
        insertCell.isEnabled = insertEnabled && !normalised.isEmpty
        pictureCell.isEnabled = !normalised.isEmpty
        peek.isEnabled = !normalised.isEmpty
        message.accessibilityLabel = Strings.stripPrivateLabel
        message.accessibilityValue = normalised.isEmpty ? Strings.stripEmptyValue : normalised
        message.accessibilityHint = Strings.stripPrivateHint
        message.accessibilityTraits = [.staticText]
        message.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: Strings.showLettersAction, target: self, selector: #selector(showLettersAction)),
        ]
    }

    /// A short message in place of the text; the lock and cells stay.
    func showNotice(_ text: String, symbol: String? = nil, duration: TimeInterval) {
        noticeTimer?.invalidate()
        message.content = .notice(text, symbol: symbol)
        UIAccessibility.post(notification: .announcement, argument: text)
        noticeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.restoreAfterNotice()
        }
    }

    /// Ends a notice early, when a key is tapped.
    func dismissNotice() {
        guard noticeTimer != nil else { return }
        noticeTimer?.invalidate()
        restoreAfterNotice()
    }

    private func restoreAfterNotice() {
        noticeTimer = nil
        if mode == .privateCompose {
            message.content = .buffer(latinForPeek)
        } else {
            message.content = .normal(message.lastContextText)
        }
    }

    /// "Copied": the notice, and the Picture cell reads Copied for as long.
    func showCopied() {
        showNotice(Strings.copied, symbol: "checkmark", duration: 2)
        copiedTimer?.invalidate()
        pictureCell.setTitle(Strings.copied, animated: true)
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.pictureCell.setTitle(Strings.picture, animated: true)
        }
    }

    var isShowingNotice: Bool { noticeTimer != nil }

    // MARK: Actions

    @objc
    private func insertTapped() {
        guard insertCell.isEnabled else { return }
        onInsert?()
    }

    @objc
    private func pictureTapped() {
        guard pictureCell.isEnabled else { return }
        onPicture?()
    }

    @objc
    private func peekChanged(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            message.content = .peek(latinForPeek)
        case .changed:
            if !message.bounds.contains(recognizer.location(in: message)) {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        case .ended, .cancelled, .failed:
            if !isShowingNotice { message.content = .buffer(latinForPeek) }
        default:
            break
        }
    }

    @objc
    private func showLettersAction() -> Bool {
        let latin = latinForPeek.isEmpty ? Strings.stripEmptyValue : latinForPeek
        UIAccessibility.post(notification: .announcement, argument: latin)
        return true
    }
}

// MARK: - Message area

/// The text part of the strip, drawn with CoreText: Qiuling for the marks,
/// the system font for anything the alphabet lacks, and a caret when composing.
final class MessageAreaView: UIView {
    enum Content: Equatable {
        case normal(String)
        case buffer(String)
        case peek(String)
        case notice(String, symbol: String?)
    }

    var content: Content = .normal("") {
        didSet {
            if case .normal(let text) = content { lastContextText = text }
            updateCaretTimer()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
    private(set) var lastContextText = ""

    /// Keeps the host text current while a notice occupies the area.
    func rememberContext(_ text: String) {
        lastContextText = text
    }
    var palette = KeyboardPalette(isDark: false) {
        didSet { setNeedsDisplay() }
    }
    var fontSize: CGFloat = 24 {
        didSet { setNeedsLayout(); setNeedsDisplay() }
    }
    var fontAvailable = true
    var isPrivate = false {
        didSet { updateCaretTimer() }
    }

    private static let fadeWidth: CGFloat = 24
    private static let trailingInset: CGFloat = 12
    private let fade = CAGradientLayer()
    private var caretTimer: Timer?
    private var caretOn = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = [.staticText]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var font: UIFont {
        (fontAvailable ? QiulingFont.shared.uiFont(size: fontSize) : nil) ?? UIFont.systemFont(ofSize: fontSize)
    }

    /// Ascent and descent of the script font, so the baseline holds still when
    /// a digit from the fallback font joins the line.
    private var ascent: CGFloat { font.ascender }
    private var descent: CGFloat { -font.descender }

    // MARK: Layout

    private struct Segment {
        let line: CTLine
        let width: CGFloat
    }

    private struct Layout {
        var segments: [Segment] = []
        var totalWidth: CGFloat = 0
        var startX: CGFloat = 0
        var clipped = false
    }

    private func makeLine(_ text: String, font: UIFont, color: UIColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor,
        ]))
    }

    private func layoutText() -> Layout {
        var layout = Layout()
        let available = bounds.width
        switch content {
        case .normal(let text):
            let line = makeLine(text, font: font, color: palette.label)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            layout.segments = [Segment(line: line, width: width)]
            layout.totalWidth = width
            layout.startX = available - Self.trailingInset - width
            layout.clipped = layout.startX < 0
        case .buffer(let text):
            var x: CGFloat = 0
            let parts = text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 { x += 4 + 1 + 4 }
                let line = makeLine(part, font: font, color: palette.label)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                layout.segments.append(Segment(line: line, width: width))
                x += width
            }
            layout.totalWidth = x + 2
            layout.startX = layout.totalWidth > available ? available - layout.totalWidth : 0
            layout.clipped = layout.startX < 0
        case .peek(let text):
            let line = makeLine(text, font: .systemFont(ofSize: 17), color: palette.label)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            layout.segments = [Segment(line: line, width: width)]
            layout.totalWidth = width
            layout.startX = available - width
            layout.clipped = layout.startX < 0
        case .notice:
            break
        }
        return layout
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = layoutText()
        if layout.clipped, bounds.width > 0 {
            fade.frame = bounds
            let stop = NSNumber(value: Double(Self.fadeWidth / bounds.width))
            fade.locations = [0, stop, 1]
            layer.mask = fade
        } else {
            layer.mask = nil
        }
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let layout = layoutText()
        let midY = bounds.midY

        switch content {
        case .notice(let text, let symbol):
            drawNotice(text, symbol: symbol)
            return
        case .peek:
            drawCaption(Strings.lettersCaption)
            let baseline = midY + (UIFont.systemFont(ofSize: 17).ascender + UIFont.systemFont(ofSize: 17).descender) / 2
            drawSegments(layout, baselineY: baseline, context: context, rules: false)
        case .normal, .buffer:
            let baseline = midY + (ascent - descent) / 2
            drawSegments(layout, baselineY: baseline, context: context, rules: true)
            if case .buffer = content {
                let caretX = layout.startX + layout.totalWidth - 2
                if caretOn {
                    palette.label.setFill()
                    UIBezierPath(rect: CGRect(x: caretX, y: midY - (ascent + descent) / 2, width: 2, height: ascent + descent)).fill()
                }
            }
        }
    }

    private func drawSegments(_ layout: Layout, baselineY: CGFloat, context: CGContext, rules: Bool) {
        var x = layout.startX
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        for (i, segment) in layout.segments.enumerated() {
            if i > 0, rules {
                x += 4
                context.setFillColor(palette.secondaryLabel.cgColor)
                context.fill(CGRect(x: x, y: bounds.height - bounds.midY - 10, width: 1, height: 20))
                x += 1 + 4
            }
            context.textPosition = CGPoint(x: x, y: bounds.height - baselineY)
            CTLineDraw(segment.line, context)
            x += segment.width
        }
        context.restoreGState()
    }

    private func drawCaption(_ text: String) {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 11), .foregroundColor: palette.secondaryLabel,
        ]).draw(at: CGPoint(x: 2, y: 2))
    }

    private func drawNotice(_ text: String, symbol: String?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 13), .foregroundColor: palette.secondaryLabel, .paragraphStyle: paragraph,
        ])
        var x: CGFloat = 0
        if let symbol, let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))?.withTintColor(palette.secondaryLabel, renderingMode: .alwaysOriginal) {
            image.draw(in: CGRect(x: 0, y: bounds.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
            x = image.size.width + 6
        }
        let box = CGRect(x: x, y: 0, width: bounds.width - x, height: bounds.height)
        let needed = attributed.boundingRect(with: CGSize(width: box.width, height: 2 * 16), options: [.usesLineFragmentOrigin], context: nil)
        let height = min(needed.height, 2 * 16)
        attributed.draw(with: CGRect(x: x, y: bounds.midY - height / 2, width: box.width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    // MARK: Caret

    private func updateCaretTimer() {
        var wantsBlink = false
        if isPrivate, case .buffer = content { wantsBlink = !UIAccessibility.isReduceMotionEnabled }
        if wantsBlink {
            guard caretTimer == nil else { return }
            caretOn = true
            caretTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.caretOn.toggle()
                self.setNeedsDisplay()
            }
        } else {
            caretTimer?.invalidate()
            caretTimer = nil
            caretOn = true
        }
    }
}

// MARK: - Cells

/// Insert and Picture: a word, a pressed fill, and a disabled state.
final class StripCell: UIControl {
    private let label = UILabel()
    private let fill = UIView()
    var palette = KeyboardPalette(isDark: false) {
        didSet { refresh() }
    }

    init(title: String) {
        super.init(frame: .zero)
        fill.isUserInteractionEnabled = false
        fill.layer.cornerRadius = 5
        fill.layer.cornerCurve = .continuous
        fill.alpha = 0
        addSubview(fill)
        label.font = .systemFont(ofSize: 16)
        label.textAlignment = .center
        label.text = title
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = [.button]
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        fill.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    override var isEnabled: Bool {
        didSet { refresh() }
    }

    override var isHighlighted: Bool {
        didSet { fill.alpha = isHighlighted && isEnabled ? 1 : 0 }
    }

    func setTitle(_ title: String, animated: Bool) {
        let apply = { self.label.text = title; self.accessibilityLabel = title }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: label, duration: 0.15, options: [.transitionCrossDissolve], animations: apply)
        } else {
            apply()
        }
    }

    private func refresh() {
        label.textColor = isEnabled ? palette.label : palette.label.withAlphaComponent(0.4)
        fill.backgroundColor = palette.pressedSpecialFace
        accessibilityTraits = isEnabled ? [.button] : [.button, .notEnabled]
    }
}
