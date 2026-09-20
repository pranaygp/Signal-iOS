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
        container.addSubview(strip)

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

    /// The height the keyboard asks for. It is installed here, not in
    /// `viewDidLoad`, because the host only reads a keyboard extension's height
    /// constraint once the view is in its hierarchy; a host that ignores it and
    /// hands us something taller gets the natural layout anchored to its bottom
    /// (see `updateMetricsIfNeeded`) rather than rows spread across the gap.
    override func updateViewConstraints() {
        super.updateViewConstraints()
        let wanted = metrics?.totalHeight ?? naturalMetrics()?.totalHeight ?? 260
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
        // Anchored to the bottom, an over-tall view leaves a blank band of
        // backdrop above the strip, where the eye expects nothing, instead of
        // keys drifting up the screen or rows spread apart.
        let top = max(0, view.bounds.height - new.totalHeight)
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
        strip.cellWidth = new.stripCellWidth
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
        appearance.cornerRadius = metrics?.cornerRadius ?? 5
        return appearance
    }

    private var currentKeyAppearance: KeyAppearance {
        let box = metrics?.markBox ?? CGSize(width: 22, height: 26)
        let fitted = fontAvailable ? QiulingFont.shared.fittedSize(in: box) : 22.5
        let union = fontAvailable ? QiulingFont.shared.unionBox(size: fitted) : .zero
        return keyAppearance(fittedSize: fitted, unionBox: union)
    }

    /// Lays out the keys of the current layer from scratch. Layer switches
    /// are instant, so there is nothing to animate here.
    private func rebuildKeys() {
        guard let metrics else { return }
        for touch in touchStates.values { touch.invalidate() }
        touchStates.removeAll()
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
        textDocumentProxy.insertText(encoded)
        composer.clear()
        click()
        strip.showBuffer("", insertEnabled: true, animated: true)
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
        guard let png = PictureRenderer.render(composer.normalisedBuffer, palette: palette) else {
            strip.showNotice(Strings.pictureFailedNotice, duration: 2)
            return
        }
        PictureRenderer.copy(png)
        click()
        strip.showCopied()
    }

    // MARK: Strip

    private func refreshStrip() {
        let wantsPrivate = isPrivateActive
        if (strip.mode == .privateCompose) != wantsPrivate {
            strip.setMode(wantsPrivate ? .privateCompose : .normal, animated: false)
        }
        strip.fontAvailable = fontAvailable
        if wantsPrivate {
            strip.showBuffer(composer.normalisedBuffer, insertEnabled: QiulingEncoder.shared.isReady)
        } else if !fontAvailable, !fontNoticeDismissed {
            strip.showFontUnavailable()
        } else if isSecure {
            strip.showContext("")
        } else {
            strip.showContext(QiulingEncoder.normalise(textDocumentProxy.documentContextBeforeInput ?? ""))
        }
        refreshKeyAppearances()
    }

    /// The host's context is stale until the run loop turns after an insertion.
    private func scheduleStripRefresh() {
        DispatchQueue.main.async { [weak self] in self?.refreshStrip() }
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
        } else {
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
        } else {
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
            textDocumentProxy.insertText(encoded + "\n")
            composer.clear()
            strip.showBuffer("", insertEnabled: true, animated: true)
            UIAccessibility.post(notification: .announcement, argument: Strings.inserted)
        } else {
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
        if byWord {
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            let count = context.isEmpty ? 1 : PrivateComposer.wordDeletionCount(before: context)
            for _ in 0..<count { textDocumentProxy.deleteBackward() }
        } else {
            textDocumentProxy.deleteBackward()
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
        default:
            action = nil
        }
        guard let action else { return }
        state.longPress = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in action() }
    }

    func keyTouchesBegan(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let key = keyArea.key(at: touch.location(in: keyArea)) else { continue }
            let state = TouchState(startKey: key)
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
            case .privateCompose, .returnKey:
                scheduleLongPress(state, for: key, touch: touch)
            case .space, .globe:
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
            if state.consumed, !state.layerHold { continue }
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
