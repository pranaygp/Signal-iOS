//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// The keyboard's root view: a system-style input view that the host blurs
/// behind, and that opts into keyboard clicks.
final class QiulingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Owns every touch on the keys so a finger can land on one key and lift on
/// its neighbour, and two thumbs can type at once. Keys themselves only draw.
final class KeyAreaView: UIView {
    weak var controller: KeyboardViewController?
    var keyViews: [KeyView] = []

    /// The key whose rectangle is nearest the point: touch targets reach half
    /// a gap in every direction, and further at the edges.
    func key(at point: CGPoint) -> KeyView? {
        var best: KeyView?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for key in keyViews where !key.isHidden {
            let rect = key.keyFrame
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = key
            }
        }
        guard let best, bestDistance <= 20 * 20 else { return nil }
        return best
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.keyTouchesBegan(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.keyTouchesMoved(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.keyTouchesEnded(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.keyTouchesEnded(touches, cancelled: true)
    }
}

/// The Qiuling keyboard. Letters type as Latin letters but are shown as the
/// script's marks; the strip above reads back what was typed in Qiuling; and
/// private compose keeps a message inside the keyboard until it is inserted
/// as the script's own code points or copied as a picture.
final class KeyboardViewController: UIInputViewController {

    // MARK: Views

    private var container: QiulingInputView { view as! QiulingInputView }
    private var strip: PreviewStripView!
    private let keyArea = KeyAreaView()
    private let calloutLayer = UIView()
    private var callout: CalloutView!
    private var globeButton: UIButton?

    // MARK: State

    private var metrics: KeyboardMetrics?
    private var currentLayer: KeyboardLayer = .letters
    private var placedKeys: [PlacedKey] = []
    private var keyViews: [KeyView] = []
    private var palette = KeyboardPalette(isDark: false)
    private var fontAvailable = false
    private var fontNoticeDismissed = false
    private let composer = PrivateComposer()
    private let suggester = Suggester()
    /// An autocorrection just applied, offered in the bar until the next key.
    private var pendingCorrection: Suggester.Correction?
    private var stripRefreshScheduled = false
    private var lastSpaceTap: TimeInterval = 0
    /// The last character typed on the Numbers layer, for punctuation-then-Space.
    private var lastNumbersCharacter: String?
    private var didChooseInitialLayer = false

    private final class TouchState {
        var key: KeyView?
        let startKey: KeyView
        var longPress: Timer?
        var deleteRepeat: Timer?
        var deleteRepeats = 0
        var startedWithEmptyBuffer = false
        var isRow = false
        var layerHold = false
        var previousLayer: KeyboardLayer = .letters
        var consumed = false
        /// Where the finger landed, to tell a held space bar from a drag.
        var startLocation: CGPoint = .zero
        /// Set once a held space bar has become the caret seeker.
        var isSeeking = false
        var seekLastX: CGFloat = 0
        /// Horizontal distance not yet turned into a caret step.
        var seekCarry: CGFloat = 0

        init(startKey: KeyView) {
            self.startKey = startKey
            key = startKey
        }

        func invalidate() {
            longPress?.invalidate()
            deleteRepeat?.invalidate()
        }
    }
    private var touchStates: [UITouch: TouchState] = [:]
    private var heightConstraint: NSLayoutConstraint?
    /// True while a held space bar is moving the caret; the key labels fade.
    private var isSeeking = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        inputView = QiulingInputView(frame: .zero, inputViewStyle: .keyboard)
        QiulingFont.shared.register()
        fontAvailable = QiulingFont.shared.isAvailable

        container.backgroundColor = .clear
        container.clipsToBounds = false

        strip = PreviewStripView(palette: palette)
        strip.onInsert = { [weak self] in self?.insertBuffer() }
        strip.onPicture = { [weak self] in self?.copyPicture() }
        strip.onSuggestion = { [weak self] in self?.accept($0) }
        strip.onEditorChange = { [weak self] in self?.editorDidChange() }
        composer.attach(strip.editor)
        container.addSubview(strip)
        requestSupplementaryLexicon { [weak self] lexicon in
            DispatchQueue.main.async { self?.suggester.adopt(lexicon); self?.scheduleStripRefresh() }
        }

        keyArea.controller = self
        keyArea.isMultipleTouchEnabled = true
        keyArea.clipsToBounds = false
        keyArea.backgroundColor = .clear
        container.addSubview(keyArea)

        calloutLayer.isUserInteractionEnabled = false
        calloutLayer.clipsToBounds = false
        calloutLayer.isAccessibilityElement = false
        calloutLayer.accessibilityElementsHidden = true
        container.addSubview(calloutLayer)
        callout = CalloutView(appearance: keyAppearance(fittedSize: 20, unionBox: .zero))
        callout.isHidden = true
        calloutLayer.addSubview(callout)

        if composer.isPrivate, fontAvailable {
            QiulingEncoder.shared.prepare { [weak self] in self?.refreshStrip() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !didChooseInitialLayer {
            didChooseInitialLayer = true
            switch textDocumentProxy.keyboardType {
            case .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad:
                currentLayer = .numbers
            default:
                currentLayer = .letters
            }
        }
        resolveAppearance()
        refreshStrip()
        view.setNeedsUpdateConstraints()
    }

    /// The editor can only take the caret once the view is in a window.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshStrip()
    }

    /// The height the keyboard asks for: the natural layout plus whatever the
    /// host reserves at the bottom of our view for its own dock (the globe and
    /// microphone iOS 26 draws under third-party keyboards on the phone), which
    /// arrives as the bottom safe-area inset. It is installed here, not in
    /// `viewDidLoad`, because the host only reads a keyboard extension's height
    /// constraint once the view is in its hierarchy; a host that ignores it and
    /// hands us something taller gets the natural layout anchored to the bottom
    /// of the safe area (see `updateMetricsIfNeeded`) rather than rows spread
    /// across the gap.
    override func updateViewConstraints() {
        super.updateViewConstraints()
        let natural = metrics?.totalHeight ?? naturalMetrics()?.totalHeight ?? 260
        let wanted = natural + view.safeAreaInsets.bottom
        if let heightConstraint {
            if heightConstraint.constant != wanted { heightConstraint.constant = wanted }
        } else {
            let constraint = view.heightAnchor.constraint(equalToConstant: wanted)
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateMetricsIfNeeded()
    }

    /// The dock inset is not known until the host places the view, and it
    /// changes with rotation; the height asked for and the rows follow it.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsUpdateConstraints()
        updateMetricsIfNeeded()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in self.updateMetricsIfNeeded() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        resolveAppearance()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        resolveAppearance()
        refreshStrip()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        refreshStrip()
    }

    // MARK: Metrics and layout

    private var isLandscape: Bool {
        if traitCollection.userInterfaceIdiom == .pad {
            let screen = (view.window?.screen ?? UIScreen.main).bounds
            return screen.width > screen.height
        }
        return view.bounds.width > 500
    }

    /// The metrics for the view's current width, or nil before it has one.
    private func naturalMetrics() -> KeyboardMetrics? {
        let width = view.bounds.width
        guard width > 0 else { return nil }
        return KeyboardMetrics(
            width: width,
            isLandscape: isLandscape,
            isPad: traitCollection.userInterfaceIdiom == .pad,
            safeLeft: view.safeAreaInsets.left,
            safeRight: view.safeAreaInsets.right
        )
    }

    private func updateMetricsIfNeeded() {
        guard let new = naturalMetrics() else { return }
        let width = new.width
        // The layout keeps its natural size whatever height the host gives.
        // Anchored to the bottom of the safe area — above the host's dock when
        // there is one — an over-tall view leaves a blank band of backdrop
        // above the strip, where the eye expects nothing, instead of keys
        // drifting up the screen or rows spread apart.
        let top = max(0, view.bounds.height - view.safeAreaInsets.bottom - new.totalHeight)
        let stripFrame = CGRect(x: 0, y: top, width: width, height: new.stripHeight)
        let keyAreaFrame = CGRect(x: 0, y: top + new.stripHeight, width: width, height: new.keyAreaHeight)
        if strip.frame != stripFrame { strip.frame = stripFrame }
        if keyArea.frame != keyAreaFrame { keyArea.frame = keyAreaFrame }
        if calloutLayer.frame != view.bounds { calloutLayer.frame = view.bounds }

        let globe = needsInputModeSwitchKey
        if let metrics, metrics.width == new.width, metrics.isLandscape == new.isLandscape,
           metrics.safeLeft == new.safeLeft, metrics.safeRight == new.safeRight, (globeButton != nil) == globe {
            return
        }
        let heightChanged = metrics?.totalHeight != new.totalHeight
        metrics = new
        if heightChanged {
            view.setNeedsUpdateConstraints()
        }
        strip.fontSize = new.stripFontSize
        rebuildKeys()
    }

    private func keyAppearance(fittedSize: CGFloat, unionBox: CGRect) -> KeyAppearance {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let hasText = !context.isEmpty || (isPrivateActive && composer.hasWaitingMessage)
        let returnType = textDocumentProxy.returnKeyType ?? .default
        let emphasisTypes: Set<UIReturnKeyType> = [.send, .go, .search, .google, .yahoo, .done, .join, .route, .continue, .next]
        var appearance = KeyAppearance(palette: palette, fittedSize: fittedSize, unionBox: unionBox, fontAvailable: fontAvailable)
        appearance.returnKeyType = returnType
        appearance.returnEmphasised = emphasisTypes.contains(returnType) && hasText
        appearance.returnDimmed = (textDocumentProxy.enablesReturnKeyAutomatically ?? false) && !hasText
        appearance.privateState = privateKeyState
        if let metrics {
            appearance.cornerRadius = metrics.cornerRadius
            appearance.characterLabelSize = metrics.systemLabelSize
            appearance.specialLabelSize = metrics.specialLabelSize
        }
        appearance.labelAlpha = isSeeking ? 0.3 : 1
        return appearance
    }

    private var currentKeyAppearance: KeyAppearance {
        let fitted = metrics.map(markSize) ?? 24
        let union = fontAvailable ? QiulingFont.shared.unionBox(size: fitted) : .zero
        return keyAppearance(fittedSize: fitted, unionBox: union)
    }

    /// The point size that makes a mark read as large as the system keyboard's
    /// letters. Every mark's ink stands 0.6em tall, a capital's about 0.7em, so
    /// the marks are scaled to the system font's cap height at the label size
    /// rather than set at that size, which would leave them small; the key's
    /// own room is the ceiling.
    private func markSize(for metrics: KeyboardMetrics) -> CGFloat {
        guard fontAvailable else { return metrics.systemLabelSize }
        let capHeight = UIFont.systemFont(ofSize: metrics.systemLabelSize).capHeight
        let inkPerPoint = QiulingFont.shared.unionBox(size: 100).height / 100
        guard inkPerPoint > 0 else { return metrics.systemLabelSize }
        return min(capHeight / inkPerPoint, QiulingFont.shared.fittedSize(in: metrics.markBox))
    }

    /// Lays out the keys of the current layer from scratch. Layer switches
    /// are instant, so there is nothing to animate here.
    private func rebuildKeys() {
        guard let metrics else { return }
        for touch in touchStates.values { touch.invalidate() }
        touchStates.removeAll()
        isSeeking = false
        hideCallout()
        keyViews.forEach { $0.removeFromSuperview() }
        globeButton?.removeFromSuperview()
        globeButton = nil

        let appearance = currentKeyAppearance
        placedKeys = KeyboardLayout.keys(layer: currentLayer, metrics: metrics, needsGlobe: needsInputModeSwitchKey)
        keyViews = placedKeys.map { placed in
            let key = KeyView(spec: placed.spec, appearance: appearance)
            key.keyFrame = placed.frame
            key.onActivate = { [weak self, weak key] in
                guard let self, let key else { return }
                self.activate(key)
            }
            keyArea.addSubview(key)
            return key
        }
        keyArea.keyViews = keyViews
        callout.update(appearance: appearance)

        if let globeKey = keyViews.first(where: { $0.spec.kind == .globe }) {
            // The system's own handler switches on a tap and lists keyboards on
            // a hold, given every touch event of a control over the key.
            let button = UIButton(type: .custom)
            button.frame = globeKey.frame
            button.isAccessibilityElement = false
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            button.addTarget(self, action: #selector(globeDown), for: .touchDown)
            button.addTarget(self, action: #selector(globeUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            keyArea.addSubview(button)
            globeButton = button
        }
    }

    private func refreshKeyAppearances() {
        let appearance = currentKeyAppearance
        keyViews.forEach { $0.appearance = appearance }
        callout.update(appearance: appearance)
    }

    private func setLayer(_ layer: KeyboardLayer) {
        guard layer != currentLayer else { return }
        currentLayer = layer
        lastNumbersCharacter = nil
        rebuildKeys()
    }

    @objc
    private func globeDown() {
        keyViews.first(where: { $0.spec.kind == .globe })?.setPressed(true)
    }

    @objc
    private func globeUp() {
        keyViews.first(where: { $0.spec.kind == .globe })?.setPressed(false)
        click()
    }

    // MARK: Appearance

    private func resolveAppearance() {
        let isDark: Bool
        switch textDocumentProxy.keyboardAppearance ?? .default {
        case .dark: isDark = true
        case .light: isDark = false
        default: isDark = traitCollection.userInterfaceStyle == .dark
        }
        palette = KeyboardPalette(isDark: isDark)
        strip.palette = palette
        refreshKeyAppearances()
    }

    // MARK: Private compose

    private var isSecure: Bool { textDocumentProxy.isSecureTextEntry ?? false }

    /// Whether private compose applies to this field: the persisted switch,
    /// overridden to off in secure fields and when there is no font.
    private var isPrivateActive: Bool { composer.isPrivate && !isSecure && fontAvailable }

    private var privateKeyState: PrivateKeyState {
        if isSecure || !fontAvailable { return .unavailable }
        if composer.isPrivate { return .on }
        return composer.hasWaitingMessage ? .offWaiting : .off
    }

    private func togglePrivate() {
        guard !isSecure, fontAvailable else { return }
        let turningOn = !composer.isPrivate
        composer.setPrivate(turningOn)
        if turningOn {
            QiulingEncoder.shared.prepare { [weak self] in self?.refreshStrip() }
        }
        click()
        strip.setMode(turningOn ? .privateCompose : .normal, animated: true)
        refreshStrip()
        refreshKeyAppearances()
        UIAccessibility.post(notification: .announcement, argument: turningOn ? Strings.privateOn : Strings.privateOff)
    }

    /// Moves the editor's caret by `offset` characters while the space bar is
    /// held to seek.
    func onSeek(offset: Int) {
        composer.moveCaret(by: offset)
    }

    /// The editor's text or caret moved, by a key or by the person's finger.
    private func editorDidChange() {
        guard isPrivateActive else { return }
        strip.updateComposer(hasText: composer.hasWaitingMessage, insertEnabled: QiulingEncoder.shared.isReady)
        refreshKeyAppearances()
    }

    /// Runs `action` against the host field's proxy. The proxy has been seen
    /// to stay on the host while the editor holds the caret (iOS 26), but a
    /// text view inside a keyboard can become the proxy's target, so the
    /// editor lets go for the duration and takes the caret back afterwards.
    private func onHost(_ action: () -> Void) {
        let editor = strip.editor
        let wasEditing = editor.isFirstResponder
        if wasEditing { editor.resignFirstResponder() }
        action()
        if wasEditing { editor.becomeFirstResponder() }
    }

    private func insertIntoHost(_ text: String) {
        onHost { textDocumentProxy.insertText(text) }
    }

    private func clearBuffer() {
        guard isPrivateActive else { return }
        composer.clear()
        refreshStrip()
        strip.showNotice(Strings.cleared, duration: 1.5)
        refreshKeyAppearances()
    }

    private func insertBuffer() {
        guard isPrivateActive, composer.hasWaitingMessage, QiulingEncoder.shared.isReady else { return }
        let encoded = QiulingEncoder.shared.encode(composer.normalisedBuffer)
        insertIntoHost(encoded)
        composer.clear()
        click()
        refreshKeyAppearances()
        UIAccessibility.post(notification: .announcement, argument: Strings.inserted)
        scheduleStripRefresh()
    }

    private func copyPicture() {
        guard isPrivateActive, composer.hasWaitingMessage else { return }
        guard hasFullAccess else {
            strip.showNotice(Strings.fullAccessNotice, duration: 4)
            return
        }
        guard let png = PictureRenderer.render(composer.normalisedBuffer) else {
            strip.showNotice(Strings.pictureFailedNotice, duration: 2)
            return
        }
        PictureRenderer.copy(png)
        click()
        strip.showCopied()
    }

    // MARK: Strip

    private func refreshStrip() {
        stripRefreshScheduled = false
        let wantsPrivate = isPrivateActive
        if (strip.mode == .privateCompose) != wantsPrivate {
            strip.setMode(wantsPrivate ? .privateCompose : .normal, animated: false)
        }
        strip.fontAvailable = fontAvailable
        let editor = strip.editor
        if wantsPrivate {
            strip.updateComposer(hasText: composer.hasWaitingMessage, insertEnabled: QiulingEncoder.shared.isReady)
            if !editor.isFirstResponder, view.window != nil {
                // Taken from the host before the editor can stand in for it.
                editor.adoptHostTraits(
                    returnKeyType: textDocumentProxy.returnKeyType ?? .default,
                    appearance: textDocumentProxy.keyboardAppearance ?? .default
                )
                editor.becomeFirstResponder()
            }
        } else {
            if editor.isFirstResponder { editor.resignFirstResponder() }
            if !fontAvailable, !fontNoticeDismissed {
                strip.showFontUnavailable()
            } else {
                strip.showSuggestions(currentSuggestions())
            }
        }
        refreshKeyAppearances()
    }

    /// The host's context is stale until the run loop turns after an insertion.
    private func scheduleStripRefresh() {
        guard !stripRefreshScheduled else { return }
        stripRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stripRefreshScheduled else { return }
            self.refreshStrip()
        }
    }

    // MARK: Suggestions

    /// Whether the host wants words corrected: not in secure fields, not
    /// where it asked for no correction, and not for addresses.
    private var suggestsWords: Bool {
        guard !isSecure, !isPrivateActive else { return false }
        switch textDocumentProxy.keyboardType ?? .default {
        case .URL, .emailAddress, .webSearch, .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad, .namePhonePad:
            return false
        default:
            return true
        }
    }

    private var correctsWords: Bool {
        suggestsWords && (textDocumentProxy.autocorrectionType ?? .default) != .no
    }

    private var currentWord: String {
        Suggester.currentWord(
            before: textDocumentProxy.documentContextBeforeInput ?? "",
            after: textDocumentProxy.documentContextAfterInput ?? ""
        )
    }

    /// What the bar shows: the word as it was typed after a correction, so a
    /// tap can bring it back; otherwise the checker's offers for the word
    /// under the caret.
    private func currentSuggestions() -> [Suggestion] {
        guard suggestsWords else { return [] }
        if let pending = pendingCorrection {
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            if context.hasSuffix(pending.replacement + pending.separator) {
                return [Suggestion(text: pending.original, quoted: true)]
            }
            pendingCorrection = nil
        }
        let word = currentWord
        guard !word.isEmpty else { return [] }
        return suggester.result(for: word, correcting: correctsWords).suggestions
    }

    /// A tapped cell: the word as typed brings a correction back; any other
    /// replaces the word under the caret and moves on with a space.
    private func accept(_ suggestion: Suggestion) {
        noteKeyTapped()
        if let pending = pendingCorrection {
            revert(pending, keepingSeparator: true)
        } else {
            let word = currentWord
            for _ in 0..<word.count { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(suggestion.text + " ")
        }
        click()
        refreshStrip()
        scheduleStripRefresh()
    }

    /// Before `separator` is typed: a word the checker is sure was a slip is
    /// replaced, as the system keyboard does, and remembered so the next tap
    /// on the bar or on Delete can undo it. True when a correction was made
    /// and the separator typed with it.
    private func autocorrect(before separator: String) -> Bool {
        pendingCorrection = nil
        guard correctsWords else { return false }
        let word = currentWord
        guard !word.isEmpty, let replacement = suggester.result(for: word, correcting: true).correction else { return false }
        for _ in 0..<word.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(replacement + separator)
        pendingCorrection = Suggester.Correction(original: word, replacement: replacement, separator: separator)
        return true
    }

    /// Puts the word back as it was typed, with or without the separator that
    /// followed it, and stops correcting that word while the keyboard is up.
    /// False when the correction is no longer where it was made.
    @discardableResult
    private func revert(_ pending: Suggester.Correction, keepingSeparator: Bool) -> Bool {
        pendingCorrection = nil
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let typed = pending.replacement + pending.separator
        guard context.hasSuffix(typed) else { return false }
        for _ in 0..<typed.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(keepingSeparator ? pending.original + pending.separator : pending.original)
        suggester.ignore(pending.original)
        return true
    }

    /// Punctuation that ends a word, and so is when a slip gets corrected.
    private static func closesWord(_ text: String) -> Bool {
        [".", ",", "?", "!", ";", ":"].contains(text)
    }

    // MARK: Typing

    private func click() {
        UIDevice.current.playInputClick()
    }

    private func noteKeyTapped() {
        if !fontNoticeDismissed {
            fontNoticeDismissed = true
        }
        strip.dismissNotice()
    }

    /// Types `text` where it belongs: the buffer in private compose, else the host.
    private func type(_ text: String) {
        noteKeyTapped()
        if isPrivateActive {
            composer.append(text)
        } else if Self.closesWord(text), autocorrect(before: text) {
            // The word was corrected and the punctuation typed with it.
        } else {
            pendingCorrection = nil
            textDocumentProxy.insertText(text)
        }
        if currentLayer != .letters, text.count == 1 {
            lastNumbersCharacter = text
        }
        click()
        refreshStrip()
        scheduleStripRefresh()
    }

    private func typeSpace() {
        noteKeyTapped()
        let now = ProcessInfo.processInfo.systemUptime
        let isDouble = now - lastSpaceTap < 0.4
        lastSpaceTap = isDouble ? 0 : now

        if isDouble, applyDoubleSpacePeriod() {
            // The trailing space became ". ": nothing more to type.
        } else if isPrivateActive {
            composer.append(" ")
        } else if !autocorrect(before: " ") {
            textDocumentProxy.insertText(" ")
        }
        click()
        if currentLayer != .letters, let last = lastNumbersCharacter, [".", ",", "?", "!", "'"].contains(last) {
            setLayer(.letters)
        }
        lastNumbersCharacter = nil
        refreshStrip()
        scheduleStripRefresh()
    }

    private func applyDoubleSpacePeriod() -> Bool {
        if isPrivateActive {
            return composer.applyDoubleSpacePeriod()
        }
        guard let context = textDocumentProxy.documentContextBeforeInput, context.hasSuffix(" ") else { return false }
        let before = context.dropLast()
        guard let last = before.unicodeScalars.last, PrivateComposer.isLetterOrMark(last) else { return false }
        textDocumentProxy.deleteBackward()
        textDocumentProxy.insertText(". ")
        return true
    }

    private func typeReturn() {
        noteKeyTapped()
        if isPrivateActive, composer.hasWaitingMessage, QiulingEncoder.shared.isReady {
            let encoded = QiulingEncoder.shared.encode(composer.normalisedBuffer)
            insertIntoHost(encoded + "\n")
            composer.clear()
            UIAccessibility.post(notification: .announcement, argument: Strings.inserted)
        } else if isPrivateActive {
            insertIntoHost("\n")
        } else if !autocorrect(before: "\n") {
            textDocumentProxy.insertText("\n")
        }
        click()
        refreshStrip()
        scheduleStripRefresh()
    }

    /// One Delete fire. In private compose the buffer goes first; the host is
    /// only touched by a press that started with the buffer already empty, so
    /// a held key never runs out of buffer and into the field.
    private func performDelete(state: TouchState, byWord: Bool) -> Bool {
        noteKeyTapped()
        if isPrivateActive {
            if composer.hasWaitingMessage {
                if byWord { composer.deleteWord() } else { composer.deleteLast() }
                click()
                refreshStrip()
                return composer.hasWaitingMessage
            }
            guard state.startedWithEmptyBuffer else { return false }
        }
        if let pending = pendingCorrection, revert(pending, keepingSeparator: false) {
            // Delete right after a correction undoes it, as the system's does,
            // leaving the caret on the word as it was typed.
            click()
            scheduleStripRefresh()
            return true
        }
        onHost {
            if byWord {
                let context = textDocumentProxy.documentContextBeforeInput ?? ""
                let count = context.isEmpty ? 1 : PrivateComposer.wordDeletionCount(before: context)
                for _ in 0..<count { textDocumentProxy.deleteBackward() }
            } else {
                textDocumentProxy.deleteBackward()
            }
        }
        click()
        scheduleStripRefresh()
        return true
    }

    /// The touch-up action of a key, also what VoiceOver activation performs.
    private func activate(_ key: KeyView) {
        switch key.spec.kind {
        case .character(let text): type(text)
        case .space: typeSpace()
        case .returnKey: typeReturn()
        case .delete:
            let state = TouchState(startKey: key)
            state.startedWithEmptyBuffer = !composer.hasWaitingMessage
            _ = performDelete(state: state, byWord: false)
        case .privateCompose: togglePrivate()
        case .layer(let target): click(); setLayer(target)
        case .page(let target): click(); setLayer(target)
        case .globe: advanceToNextInputMode()
        }
    }

    // MARK: Touches

    private func showCallout(for key: KeyView) {
        guard key.spec.kind.isCharacter, let metrics else { return }
        guard let placed = placedKeys.first(where: { $0.frame == key.keyFrame }) else { return }
        let rect = keyArea.convert(key.keyFrame, to: calloutLayer)
        callout.show(key: placed, keyRect: rect, keyWidth: metrics.keyWidth, within: calloutLayer.bounds)
        callout.isHidden = false
    }

    private func showRow(for key: KeyView, items: [CalloutItem]) {
        guard let metrics else { return }
        let rect = keyArea.convert(key.keyFrame, to: calloutLayer)
        callout.showRow(items: items, keyRect: rect, keyWidth: metrics.keyWidth, within: calloutLayer.bounds)
        callout.isHidden = false
    }

    private func hideCallout() {
        callout.isHidden = true
    }

    private func rowItems(for key: KeyView) -> [CalloutItem] {
        if key.spec.isLetter, fontAvailable, case .character(let letter) = key.spec.kind {
            return GroupMappings.shared.groups(startingWith: letter).prefix(8).map { CalloutItem(text: $0, isMark: true) }
        }
        return key.spec.alternates.map { CalloutItem(text: $0, isMark: false) }
    }

    private func scheduleLongPress(_ state: TouchState, for key: KeyView, touch: UITouch) {
        state.longPress?.invalidate()
        state.longPress = nil
        let action: (() -> Void)?
        switch key.spec.kind {
        case .character:
            let items = rowItems(for: key)
            guard !items.isEmpty else { return }
            action = { [weak self, weak key] in
                guard let self, let key else { return }
                state.isRow = true
                self.showRow(for: key, items: items)
                self.callout.highlight(self.callout.item(at: touch.location(in: self.calloutLayer)))
            }
        case .privateCompose:
            action = { [weak self] in
                guard let self, self.isPrivateActive else { return }
                state.consumed = true
                self.clearBuffer()
            }
        case .returnKey:
            action = { [weak self] in
                guard let self, self.isPrivateActive else { return }
                state.consumed = true
                self.composer.append("\n")
                self.click()
                self.refreshStrip()
            }
        case .space:
            action = { [weak self] in
                guard let self else { return }
                self.beginSeeking(state, touch: touch)
            }
        default:
            action = nil
        }
        guard let action else { return }
        let delay: TimeInterval = key.spec.kind == .space ? 0.4 : 0.5
        state.longPress = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in action() }
    }

    // MARK: Seeking

    /// A held space bar becomes the caret seeker, as on the system keyboard:
    /// the labels fade, and sideways movement walks the caret one character
    /// per half a key of travel. Lifting types nothing.
    private func beginSeeking(_ state: TouchState, touch: UITouch) {
        state.isSeeking = true
        state.consumed = true
        state.seekLastX = touch.location(in: keyArea).x
        state.seekCarry = 0
        setSeeking(true)
    }

    private func seekMoved(_ state: TouchState, to point: CGPoint) {
        guard let metrics else { return }
        state.seekCarry += point.x - state.seekLastX
        state.seekLastX = point.x
        let step = metrics.keyWidth / 2
        let characters = Int((state.seekCarry / step).rounded(.towardZero))
        guard characters != 0 else { return }
        state.seekCarry -= CGFloat(characters) * step
        if isPrivateActive {
            onSeek(offset: characters)
        } else {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: characters)
        }
        scheduleStripRefresh()
    }

    private func setSeeking(_ seeking: Bool) {
        guard seeking != isSeeking else { return }
        isSeeking = seeking
        refreshKeyAppearances()
    }

    func keyTouchesBegan(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let key = keyArea.key(at: touch.location(in: keyArea)) else { continue }
            let state = TouchState(startKey: key)
            state.startLocation = touch.location(in: keyArea)
            touchStates[touch] = state
            key.setPressed(true)

            switch key.spec.kind {
            case .character:
                showCallout(for: key)
                scheduleLongPress(state, for: key, touch: touch)
            case .delete:
                state.startedWithEmptyBuffer = !composer.hasWaitingMessage
                state.consumed = true
                guard performDelete(state: state, byWord: false) else { break }
                let started = ProcessInfo.processInfo.systemUptime
                state.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    state.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                        guard let self else { timer.invalidate(); return }
                        let byWord = ProcessInfo.processInfo.systemUptime - started > 2.5
                        if !self.performDelete(state: state, byWord: byWord) { timer.invalidate() }
                    }
                }
            case .layer(let target), .page(let target):
                state.layerHold = true
                state.previousLayer = currentLayer
                state.consumed = true
                click()
                // Rebuilding the keys drops every touch state; keep this one so a
                // slide to a key on the new layer can type it and snap back.
                setLayer(target)
                touchStates[touch] = state
                state.key = nil
            case .privateCompose, .returnKey, .space:
                scheduleLongPress(state, for: key, touch: touch)
            case .globe:
                break
            }
        }
    }

    func keyTouchesMoved(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let state = touchStates[touch] else { continue }
            let point = touch.location(in: keyArea)
            if state.isRow {
                callout.highlight(callout.item(at: touch.location(in: calloutLayer)))
                continue
            }
            if state.isSeeking {
                seekMoved(state, to: point)
                continue
            }
            if state.consumed, !state.layerHold { continue }
            // A finger that wanders on the space bar is typing a space, not
            // waiting to seek; only a still one starts the seeker.
            if state.key?.spec.kind == .space, hypot(point.x - state.startLocation.x, point.y - state.startLocation.y) > 8 {
                state.longPress?.invalidate()
                state.longPress = nil
            }
            let target = keyArea.key(at: point)
            if state.layerHold {
                // Only character keys take part in hold-and-slide.
                let candidate = target?.spec.kind.isCharacter == true ? target : nil
                if candidate !== state.key {
                    state.key?.setPressed(false)
                    hideCallout()
                    state.key = candidate
                    if let candidate {
                        candidate.setPressed(true)
                        showCallout(for: candidate)
                    }
                }
                continue
            }
            guard target !== state.key else { continue }
            state.key?.setPressed(false)
            state.longPress?.invalidate()
            state.longPress = nil
            hideCallout()
            state.key = target
            if let target {
                target.setPressed(true)
                if target.spec.kind.isCharacter {
                    showCallout(for: target)
                    scheduleLongPress(state, for: target, touch: touch)
                }
            }
        }
    }

    func keyTouchesEnded(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            guard let state = touchStates.removeValue(forKey: touch) else { continue }
            state.invalidate()
            state.key?.setPressed(false)
            let rowSelection = state.isRow ? callout.selectedItem() : nil
            hideCallout()
            if state.isSeeking { setSeeking(false) }
            guard !cancelled else { continue }

            if state.isRow {
                if let item = rowSelection { type(item.text) }
                continue
            }
            if state.layerHold {
                if let key = state.key, case .character(let text) = key.spec.kind {
                    type(text)
                    setLayer(state.previousLayer)
                }
                continue
            }
            guard !state.consumed, let key = state.key else { continue }
            switch key.spec.kind {
            case .character(let text): type(text)
            case .space: typeSpace()
            case .returnKey: typeReturn()
            case .privateCompose: togglePrivate()
            case .delete, .layer, .page, .globe: break
            }
        }
    }
}
