//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// One cell of the suggestions bar: what tapping it types, and how it reads.
struct Suggestion: Equatable {
    let text: String
    /// The word as typed, shown in quotes: tapping keeps it as it was.
    var quoted = false
    /// The correction Space would apply, drawn heavier than its neighbours.
    var emphasised = false
}

/// The band above the keys. While typing into the host it is the suggestions
/// bar — the word under the caret with the checker's completions and
/// corrections, set in Qiuling; in private compose it becomes the composer:
/// the lock, an editor holding the message, Insert and Picture.
final class PreviewStripView: UIView {
    enum Mode: Equatable {
        case normal
        case privateCompose
    }

    var palette: KeyboardPalette {
        didSet { applyPalette() }
    }
    /// The layout's strip text size; the bar and the editor set a little under it.
    var fontSize: CGFloat = 24 {
        didSet { bar.fontSize = fontSize - 2 }
    }
    var fontAvailable = true {
        didSet { bar.fontAvailable = fontAvailable; editor.fontAvailable = fontAvailable }
    }
    private(set) var mode: Mode = .normal

    var onInsert: (() -> Void)?
    var onPicture: (() -> Void)?
    var onSuggestion: ((Suggestion) -> Void)?
    /// The editor's text or caret changed, by a key or by the person's finger.
    var onEditorChange: (() -> Void)?

    /// The private message, edited in place; the composer types into it.
    let editor = PrivateEditorView()
    private let bar = SuggestionsBar()
    private let lock = UIImageView()
    private let insertButton = StripButton()
    private let pictureButton = StripButton()
    private let notice = UILabel()
    private var noticeTimer: Timer?
    /// Layout numbers for reading off a device screenshot; nil hides the line.
    var diagnostics: String? {
        didSet { diagnosticsLabel.text = diagnostics; diagnosticsLabel.isHidden = diagnostics == nil; setNeedsLayout() }
    }
    private let diagnosticsLabel = UILabel()
    private var copiedTimer: Timer?

    private static let edge: CGFloat = 12
    private static let gap: CGFloat = 8

    init(palette: KeyboardPalette) {
        self.palette = palette
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false

        lock.image = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        lock.contentMode = .center
        lock.isAccessibilityElement = false

        notice.font = .systemFont(ofSize: 13)
        notice.numberOfLines = 2
        notice.adjustsFontSizeToFitWidth = true
        notice.minimumScaleFactor = 0.85
        notice.isHidden = true

        insertButton.addTarget(self, action: #selector(insertTapped), for: .touchUpInside)
        pictureButton.addTarget(self, action: #selector(pictureTapped), for: .touchUpInside)
        insertButton.accessibilityHint = Strings.insertHint
        pictureButton.accessibilityHint = Strings.pictureHint

        bar.onTap = { [weak self] in self?.onSuggestion?($0) }
        editor.onChange = { [weak self] in
            guard let self else { return }
            self.setNeedsLayout()
            self.onEditorChange?()
        }
        editor.accessibilityLabel = Strings.stripPrivateLabel

        [bar, lock, editor, insertButton, pictureButton, notice].forEach(addSubview)
        applyPalette()
        setMode(.normal, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyPalette() {
        // The buttons' dynamic colours must follow the host's keyboard
        // appearance, which need not match the app the strip is drawn in.
        overrideUserInterfaceStyle = palette.isDark ? .dark : .light
        bar.palette = palette
        editor.palette = palette
        lock.tintColor = palette.indicator
        notice.textColor = palette.secondaryLabel
        insertButton.configuration = Self.buttonConfiguration(title: insertButton.configuration?.title ?? Strings.insert, filled: true, palette: palette)
        pictureButton.configuration = Self.buttonConfiguration(title: pictureButton.configuration?.title ?? Strings.picture, filled: false, palette: palette)
    }

    /// Insert is a filled capsule on the special-key grey with that key's
    /// label colour; Picture the quieter grey style. Both read at 15pt.
    private static func buttonConfiguration(title: String, filled: Bool, palette: KeyboardPalette) -> UIButton.Configuration {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = title
        config.buttonSize = .small
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            return outgoing
        }
        if filled {
            config.baseBackgroundColor = palette.specialFace
            config.baseForegroundColor = palette.isDark ? .white : .black
        } else {
            config.baseForegroundColor = palette.label
        }
        return config
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let edge = Self.edge
        let gap = Self.gap
        if diagnosticsLabel.superview == nil {
            diagnosticsLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            diagnosticsLabel.textColor = .systemRed
            diagnosticsLabel.isHidden = diagnostics == nil
            addSubview(diagnosticsLabel)
        }
        diagnosticsLabel.frame = CGRect(x: edge, y: 0, width: bounds.width - 2 * edge, height: 11)
        bringSubviewToFront(diagnosticsLabel)
        switch mode {
        case .normal:
            bar.frame = bounds
            notice.frame = bounds.insetBy(dx: edge, dy: 0)
        case .privateCompose:
            let pictureSize = pictureButton.intrinsicContentSize
            let insertSize = insertButton.intrinsicContentSize
            pictureButton.frame = CGRect(
                x: bounds.width - edge - pictureSize.width, y: (h - pictureSize.height) / 2,
                width: pictureSize.width, height: pictureSize.height
            )
            insertButton.frame = CGRect(
                x: pictureButton.frame.minX - gap - insertSize.width, y: (h - insertSize.height) / 2,
                width: insertSize.width, height: insertSize.height
            )
            insertButton.hitHeight = h
            pictureButton.hitHeight = h

            let lockWidth: CGFloat = 12
            let editorX = edge + lockWidth + gap
            editor.frame = CGRect(x: editorX, y: 0, width: insertButton.frame.minX - gap - editorX, height: h)
            editor.layoutIfNeeded()
            notice.frame = editor.frame

            // The lock sits on the first line's baseline, as a glyph would.
            let baseline = editor.firstBaseline
            let cap = UIFont.systemFont(ofSize: 12).capHeight
            lock.frame = CGRect(x: edge, y: baseline - cap / 2 - 8, width: lockWidth, height: 16)
        }
    }

    // MARK: Mode

    func setMode(_ newMode: Mode, animated: Bool) {
        let apply = {
            self.mode = newMode
            let isPrivate = newMode == .privateCompose
            [self.lock, self.editor, self.insertButton, self.pictureButton].forEach { $0.isHidden = !isPrivate }
            self.bar.isHidden = isPrivate
            if self.isShowingNotice { self.endNotice() }
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve], animations: apply)
        } else {
            apply()
        }
    }

    // MARK: Normal mode

    /// Up to three cells; an empty list clears the bar.
    func showSuggestions(_ suggestions: [Suggestion]) {
        guard !isShowingNotice else { return }
        bar.show(suggestions)
    }

    /// The fallback when the font could not be loaded: a notice until any key is tapped.
    func showFontUnavailable() {
        showNotice(Strings.fontUnavailableNotice, duration: .infinity)
    }

    // MARK: Private mode

    /// The controls follow the editor: nothing to insert or picture while it
    /// is empty, and nothing to insert before the encoder's table is built.
    func updateComposer(hasText: Bool, insertEnabled: Bool) {
        insertButton.isEnabled = hasText && insertEnabled
        pictureButton.isEnabled = hasText
    }

    // MARK: Notices

    /// A short message in place of the text; the lock and buttons stay.
    func showNotice(_ text: String, duration: TimeInterval) {
        noticeTimer?.invalidate()
        noticeTimer = nil
        notice.text = text
        notice.isHidden = false
        bar.alpha = 0
        editor.alpha = 0
        UIAccessibility.post(notification: .announcement, argument: text)
        if duration.isFinite {
            noticeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.endNotice()
            }
        }
    }

    /// Ends a notice early, when a key is tapped.
    func dismissNotice() {
        guard isShowingNotice else { return }
        endNotice()
    }

    private func endNotice() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        notice.isHidden = true
        bar.alpha = 1
        editor.alpha = 1
    }

    var isShowingNotice: Bool { !notice.isHidden }

    /// After copying: how to get the picture into the field, since a keyboard
    /// can only type; the Picture button reads Copied for as long.
    func showCopied() {
        showNotice(Strings.copiedPasteHint, duration: 2.5)
        copiedTimer?.invalidate()
        setPictureTitle(Strings.copied)
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.setPictureTitle(Strings.picture)
        }
    }

    private func setPictureTitle(_ title: String) {
        pictureButton.configuration?.title = title
        pictureButton.accessibilityLabel = title
        setNeedsLayout()
    }

    // MARK: Actions

    @objc
    private func insertTapped() {
        onInsert?()
    }

    @objc
    private func pictureTapped() {
        onPicture?()
    }
}

// MARK: - Buttons

/// A configured button whose touch target is the strip's full height, so a
/// thumb aimed at a 28pt capsule cannot miss it.
final class StripButton: UIButton {
    var hitHeight: CGFloat = 44

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let extra = max(0, hitHeight - bounds.height) / 2
        return bounds.insetBy(dx: -4, dy: -extra).contains(point)
    }
}

// MARK: - Suggestions bar

/// Three cells parted by hairlines, as the system keyboard's. The labels are
/// made once and only their text changes, cross-fading briefly, so the bar
/// keeps up with the fastest typing.
final class SuggestionsBar: UIView {
    var palette = KeyboardPalette(isDark: false) {
        didSet { applyPalette() }
    }
    var fontSize: CGFloat = 22 {
        didSet { cells.forEach { $0.fontSize = fontSize } }
    }
    var fontAvailable = true {
        didSet { cells.forEach { $0.fontAvailable = fontAvailable } }
    }
    var onTap: ((Suggestion) -> Void)?

    private let cells = (0..<3).map { _ in SuggestionCell() }
    private let hairlines = [UIView(), UIView()]
    private var current: [Suggestion] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        cells.forEach { cell in
            addSubview(cell)
            cell.addTarget(self, action: #selector(cellTapped(_:)), for: .touchUpInside)
        }
        hairlines.forEach { line in
            line.isHidden = true
            addSubview(line)
        }
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyPalette() {
        cells.forEach { $0.palette = palette }
        hairlines.forEach { $0.backgroundColor = palette.hairline }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width / 3
        for (i, cell) in cells.enumerated() {
            cell.frame = CGRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height)
        }
        for (i, line) in hairlines.enumerated() {
            line.frame = CGRect(x: CGFloat(i + 1) * width - 0.5, y: bounds.height * 0.25, width: 1, height: bounds.height * 0.5)
        }
    }

    func show(_ suggestions: [Suggestion]) {
        guard suggestions != current else { return }
        current = suggestions
        for (i, cell) in cells.enumerated() {
            cell.suggestion = i < suggestions.count ? suggestions[i] : nil
        }
        // Hairlines only part cells that have something in them.
        hairlines[0].isHidden = suggestions.count < 2
        hairlines[1].isHidden = suggestions.count < 3
    }

    @objc
    private func cellTapped(_ cell: SuggestionCell) {
        guard let suggestion = cell.suggestion else { return }
        onTap?(suggestion)
    }
}

/// One suggestion: the word in Qiuling, a pressed fill, nothing when empty.
final class SuggestionCell: UIControl {
    private let label = UILabel()
    private let fill = UIView()
    var palette = KeyboardPalette(isDark: false) {
        didSet { refresh() }
    }
    var fontSize: CGFloat = 22 {
        didSet { refresh() }
    }
    var fontAvailable = true {
        didSet { refresh() }
    }
    var suggestion: Suggestion? {
        didSet {
            guard suggestion != oldValue else { return }
            let apply = { self.refresh() }
            if !UIAccessibility.isReduceMotionEnabled, window != nil {
                UIView.transition(with: label, duration: 0.08, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: apply)
            } else {
                apply()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.isUserInteractionEnabled = false
        fill.layer.cornerRadius = 6
        fill.layer.cornerCurve = .continuous
        fill.alpha = 0
        addSubview(fill)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 6, dy: 0)
        fill.frame = bounds.insetBy(dx: 3, dy: 5)
    }

    override var isHighlighted: Bool {
        didSet { fill.alpha = isHighlighted && suggestion != nil ? 1 : 0 }
    }

    private var font: UIFont {
        (fontAvailable ? QiulingFont.shared.uiFont(size: fontSize) : nil) ?? .systemFont(ofSize: fontSize)
    }

    private func refresh() {
        fill.backgroundColor = palette.pressedSpecialFace
        guard let suggestion else {
            label.attributedText = nil
            isEnabled = false
            accessibilityLabel = nil
            isAccessibilityElement = false
            return
        }
        isEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = suggestion.text
        // Shown as the script draws it; the quotes and anything the alphabet
        // lacks fall through to the system font.
        let shown = QiulingEncoder.normalise(suggestion.text)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.label]
        if suggestion.emphasised {
            // The face has one weight; a stroke around the ink stands in for bold.
            attributes[.strokeWidth] = -2.5
            attributes[.strokeColor] = palette.label
        }
        label.attributedText = NSAttributedString(string: suggestion.quoted ? "\u{201C}\(shown)\u{201D}" : shown, attributes: attributes)
    }
}

// MARK: - Suggester

/// Finds what to offer for the word under the caret: the system checker's
/// completions and, for a word it does not know, its corrections; the person's
/// own names from the host's lexicon come first. Results are kept for the
/// last word asked about, since the bar asks twice per keystroke.
final class Suggester {
    struct Result {
        var suggestions: [Suggestion] = []
        /// What Space or punctuation would replace the word with, if anything.
        var correction: String?
    }

    /// An autocorrection that was applied, kept until the next keystroke so
    /// the bar can offer the word as it was typed.
    struct Correction: Equatable {
        let original: String
        let replacement: String
        let separator: String
    }

    static let language = "en_US"
    private let checker = UITextChecker()
    private var lexicon: [UILexiconEntry] = []
    private var cache: (word: String, correcting: Bool, result: Result)?

    func adopt(_ lexicon: UILexicon) {
        self.lexicon = lexicon.entries
        cache = nil
    }

    /// The word being typed: the run of letters (and apostrophes) that ends
    /// at the caret, or nothing when the caret is not at the end of a word.
    static func currentWord(before context: String, after: String) -> String {
        if let next = after.unicodeScalars.first, isWordScalar(next) { return "" }
        var scalars: [Unicode.Scalar] = []
        for scalar in context.unicodeScalars.reversed() {
            guard isWordScalar(scalar) else { break }
            scalars.append(scalar)
        }
        var word = String(String.UnicodeScalarView(scalars.reversed()))
        while let first = word.first, first == "'" || first == "’" { word.removeFirst() }
        return word
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic && scalar.value < 0xF0000 || scalar == "'" || scalar == "’"
    }

    /// Reverted corrections are words the person meant; they are not
    /// corrected again while the keyboard is up.
    func ignore(_ word: String) {
        checker.ignoreWord(word)
        cache = nil
    }

    /// `correcting` is whether the host lets a separator replace the word:
    /// where it does not, the checker's guesses are offers like any other.
    func result(for word: String, correcting: Bool) -> Result {
        if let cache, cache.word == word, cache.correcting == correcting { return cache.result }
        let result = compute(word, correcting: correcting)
        cache = (word, correcting, result)
        return result
    }

    private func compute(_ word: String, correcting: Bool) -> Result {
        guard !word.isEmpty else { return Result() }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let known = lexicon.filter { $0.userInput.lowercased().hasPrefix(word.lowercased()) }.map(\.documentText)
        let isName = lexicon.contains { $0.userInput.caseInsensitiveCompare(word) == .orderedSame }
        let misspelled = !isName
            && checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: Self.language).location != NSNotFound
        let guesses = misspelled ? (checker.guesses(forWordRange: range, in: word, language: Self.language) ?? []) : []
        let completions = checker.completions(forPartialWordRange: range, in: word, language: Self.language) ?? []

        var candidates: [String] = []
        func add(_ candidate: String) {
            guard candidate.caseInsensitiveCompare(word) != .orderedSame,
                  !candidates.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else { return }
            candidates.append(candidate)
        }
        known.forEach(add)
        guesses.forEach(add)
        completions.forEach(add)

        var result = Result()
        if correcting, misspelled, let first = guesses.first, Self.isConfident(first, for: word) {
            result.correction = first
        }
        var cells: [Suggestion] = []
        if let correction = result.correction {
            cells.append(Suggestion(text: word, quoted: true))
            cells.append(Suggestion(text: correction, emphasised: true))
            if let next = candidates.first(where: { $0 != correction }) { cells.append(Suggestion(text: next)) }
        } else {
            cells.append(Suggestion(text: word))
            cells.append(contentsOf: candidates.prefix(2).map { Suggestion(text: $0) })
        }
        result.suggestions = cells
        return result
    }

    /// Whether the checker's first guess is close enough to have been meant:
    /// a slip of a letter or two, not a different word.
    private static func isConfident(_ guess: String, for word: String) -> Bool {
        guard word.count >= 2, guess.count <= word.count + 2 else { return false }
        guard word.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        return editDistance(word.lowercased(), guess.lowercased()) <= 2
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Private editor

/// The message being composed, in a real text view: a caret that a tap or
/// the held space bar moves, selection, and the script's marks at a size that
/// fits two lines in the strip. One line sits centred; two fill the height;
/// more scroll. Words the checker does not know get the compose box's red
/// dotted underline, since a typo is easy to miss in marks.
final class PrivateEditorView: UITextView, UITextViewDelegate, NSLayoutManagerDelegate {
    var palette = KeyboardPalette(isDark: false) {
        didSet { applyPalette() }
    }
    var fontAvailable = true {
        didSet { applyFont() }
    }
    var onChange: (() -> Void)?

    private let misspellings = MisspellingLayoutManager()
    private let checker = UITextChecker()
    private var spellCheckTimer: Timer?
    private var lineHeight: CGFloat = 22

    init() {
        let storage = NSTextStorage()
        storage.addLayoutManager(misspellings)
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        misspellings.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        misspellings.delegate = self
        delegate = self

        backgroundColor = .clear
        isScrollEnabled = true
        alwaysBounceVertical = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        enablesReturnKeyAutomatically = false
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        // Should the host ever hand this view a keyboard of its own, an
        // empty one keeps the system keyboard from covering ours.
        inputView = UIView()
        applyFont()
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        spellCheckTimer?.invalidate()
    }

    private func applyFont() {
        let size = lineHeight
        font = (fontAvailable ? QiulingFont.shared.uiFont(size: size) : nil) ?? .systemFont(ofSize: size)
        misspellings.markSize = size
        fitLines()
    }

    private func applyPalette() {
        textColor = palette.label
        misspellings.color = palette.misspelling
        if !text.isEmpty {
            // Text already typed keeps the colour it was typed in unless told.
            textStorage.addAttribute(.foregroundColor, value: palette.label, range: NSRange(location: 0, length: textStorage.length))
        }
    }

    /// While the editor is the target of the keys, the host's traits are
    /// read from it, so it carries the ones the keys show: the Return face
    /// and the dark or light appearance.
    func adoptHostTraits(returnKeyType hostReturn: UIReturnKeyType, appearance: UIKeyboardAppearance) {
        returnKeyType = hostReturn
        keyboardAppearance = appearance
    }

    // MARK: Lines

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.height / 2
        if size > 0, size != lineHeight {
            lineHeight = size
            applyFont()
        }
        fitLines()
    }

    /// One line is centred; from two on the lines fill the strip exactly,
    /// since each is half its height.
    private func fitLines() {
        guard bounds.height > 0 else { return }
        misspellings.ensureLayout(for: textContainer)
        let used = misspellings.usedRect(for: textContainer).height
        let lines = max(1, Int((used / lineHeight).rounded()))
        let inset = lines >= 2 ? 0 : (bounds.height - lineHeight) / 2
        let insets = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        if textContainerInset != insets { textContainerInset = insets }
    }

    /// Where the first line's letters stand, in the editor's coordinates.
    /// `UITextView.font` can drop to nil after the text is reset; the layout
    /// path must never trust it.
    private var currentFont: UIFont {
        font ?? QiulingFont.shared.uiFont(size: lineHeight) ?? .systemFont(ofSize: lineHeight)
    }

    var firstBaseline: CGFloat {
        textContainerInset.top + currentFont.ascender
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        // A digit or a quote from the fallback font must not make its line
        // taller, or two lines would no longer fit the strip.
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee = currentFont.ascender
        return true
    }

    // MARK: Editing

    var textBeforeCaret: String {
        (text as NSString).substring(to: min(selectedRange.location, (text as NSString).length))
    }

    /// Replaces `count` characters before the caret (fewer when the text is
    /// shorter) with `replacement`, leaving the caret after it.
    func replaceBeforeCaret(count: Int, with replacement: String) {
        let caret = selectedRange.location
        let length = min(count, caret)
        let range = NSRange(location: caret - length, length: length + selectedRange.length)
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
        selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        changed()
    }

    /// Deletes the selection, or the character before the caret.
    func deleteBackwardOrSelection() {
        if selectedRange.length > 0 {
            replaceBeforeCaret(count: 0, with: "")
        } else {
            deleteBackward()
        }
    }

    func moveCaret(by offset: Int) {
        let length = (text as NSString).length
        let target = max(0, min(length, selectedRange.location + selectedRange.length + offset))
        selectedRange = NSRange(location: target, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    func clear() {
        text = ""
        changed()
    }

    private func changed() {
        typingAttributes = [.font: currentFont, .foregroundColor: palette.label]
        fitLines()
        scrollRangeToVisible(selectedRange)
        scheduleSpellCheck()
        onChange?()
    }

    func textViewDidChange(_ textView: UITextView) {
        changed()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // Leaving a word finishes it, so the caret moving is a reason to look again.
        scheduleSpellCheck()
        onChange?()
    }

    // MARK: Misspellings

    private func scheduleSpellCheck() {
        spellCheckTimer?.invalidate()
        spellCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.checkSpelling()
        }
    }

    private func checkSpelling() {
        spellCheckTimer = nil
        let text = self.text ?? ""
        let length = (text as NSString).length
        let caret: Int? = selectedRange.length == 0 ? selectedRange.location : nil
        var misspelled: [NSRange] = []
        var start = 0
        while start < length {
            let range = checker.rangeOfMisspelledWord(
                in: text, range: NSRange(location: start, length: length - start),
                startingAt: start, wrap: false, language: Suggester.language
            )
            guard range.location != NSNotFound, range.length > 0 else { break }
            start = range.upperBound
            // A word still being typed is not wrong yet.
            if let caret, range.location <= caret, caret <= range.upperBound { continue }
            misspelled.append(range)
        }
        guard misspelled != misspellings.misspelledRanges else { return }
        misspellings.misspelledRanges = misspelled
        setNeedsDisplay()
    }
}

/// Draws a red dotted line under misspelled words without touching the
/// text's attributes — the face has no underline metrics, so the line is
/// placed by its size — and keeps the ranges in step with edits until the
/// next check.
final class MisspellingLayoutManager: NSLayoutManager {
    var color = UIColor.systemRed
    var markSize: CGFloat = 22
    private var stored: [NSRange] = []

    var misspelledRanges: [NSRange] {
        get { stored }
        set {
            let stale = stored
            stored = newValue
            guard let textStorage else { return }
            let whole = NSRange(location: 0, length: textStorage.length)
            for range in stale + newValue {
                guard let clamped = range.intersection(whole), clamped.length > 0 else { continue }
                invalidateDisplay(forCharacterRange: clamped)
            }
        }
    }

    override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorage.EditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
        guard editMask.contains(.editedCharacters), !stored.isEmpty else { return }
        let replaced = NSRange(location: newCharRange.location, length: max(0, newCharRange.length - delta))
        stored = stored.compactMap { range in
            if range.upperBound < replaced.location { return range }
            if range.location > replaced.upperBound { return NSRange(location: range.location + delta, length: range.length) }
            // Touched by the edit: its verdict no longer applies.
            return nil
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !stored.isEmpty, let textStorage, let context = UIGraphicsGetCurrentContext() else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let scale = max(1, UIScreen.main.scale)
        let thickness = max(1, (markSize / 20).rounded())
        // The marks reach a twentieth of the size below the baseline; the
        // line sits a tenth down to clear them.
        let drop = markSize / 10

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(thickness)
        context.setLineDash(phase: 0, lengths: [thickness, thickness])
        for range in stored {
            guard let visible = range.intersection(shown), visible.length > 0, visible.upperBound <= textStorage.length else { continue }
            let glyphRange = self.glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
            guard glyphRange.length > 0, let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else { continue }
            enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
                guard let inLine = glyphRange.intersection(lineGlyphRange), inLine.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: inLine, in: container)
                let baseline = lineRect.minY + self.location(forGlyphAt: inLine.location).y
                let top = min(baseline + drop, lineRect.maxY - thickness) + origin.y
                let y = (top * scale).rounded() / scale + thickness / 2
                context.move(to: CGPoint(x: bounds.minX + origin.x, y: y))
                context.addLine(to: CGPoint(x: bounds.maxX + origin.x, y: y))
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}
