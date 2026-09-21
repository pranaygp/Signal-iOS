//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import LibSignalClient
public import SignalServiceKit

public protocol BodyRangesTextViewDelegate: UITextViewDelegate {
    func textViewDidBeginTypingMention(_ textView: BodyRangesTextView)
    func textViewDidEndTypingMention(_ textView: BodyRangesTextView)

    func textViewMentionPickerParentView(_ textView: BodyRangesTextView) -> UIView?
    func textViewMentionPickerReferenceView(_ textView: BodyRangesTextView) -> UIView?
    // It doesn't matter what this key is; but when it changes cached mention names will be discarded.
    // Typically, we want this to change in new thread contexts and such.
    func textViewMentionCacheInvalidationKey(_ textView: BodyRangesTextView) -> String
    func textViewMentionPickerPossibleAcis(_ textView: BodyRangesTextView, tx: DBReadTransaction) -> [Aci]

    func textViewDisplayConfiguration(_ textView: BodyRangesTextView) -> HydratedMessageBody.DisplayConfiguration
    func mentionPickerStyle(_ textView: BodyRangesTextView) -> MentionPickerStyle

    func textViewDidInsertMemoji(_ memojiGlyph: OWSAdaptiveImageGlyph)
}

extension BodyRangesTextViewDelegate {
    public func textViewDidInsertMemoji(_ memojiGlyph: OWSAdaptiveImageGlyph) {}
}

// MARK: -

open class BodyRangesTextView: OWSTextView, EditableMessageBodyDelegate, UITextViewDelegate, UIEditMenuInteractionDelegate {

    public weak var bodyRangesDelegate: BodyRangesTextViewDelegate? {
        didSet { updateMentionState() }
    }

    override public var delegate: UITextViewDelegate? {
        didSet {
            if let delegate {
                owsAssertDebug(delegate === self)
            }
        }
    }

    private let customLayoutManager: MisspellingLayoutManager
    private var iOS15EditMenu: BodyRangesTextViewIOS15EditMenu?

    public init() {
        let editableBody = EditableMessageBodyTextStorage(db: DependenciesBridge.shared.db)
        self.editableBody = editableBody
        let container = NSTextContainer()
        let layoutManager = MisspellingLayoutManager()
        self.customLayoutManager = layoutManager
        layoutManager.textStorage = editableBody
        layoutManager.addTextContainer(container)
        container.replaceLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)
        updateTextContainerInset()
        delegate = self
        editableBody.editableBodyDelegate = self
        textAlignment = .natural
        enablesReturnKeyAutomatically = true

        if #available(iOS 16, *) {
            iOS15EditMenu = nil
        } else {
            iOS15EditMenu = BodyRangesTextViewIOS15EditMenu(
                textView: self,
                didSelectStyleBlock: { [unowned self] in didSelectStyle($0) },
            )
        }
    }

    override public var layoutManager: NSLayoutManager {
        return customLayoutManager
    }

    deinit {
        pickerView?.removeFromSuperview()
        spellCheckTimer?.invalidate()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: -

    /// Can we perform the ``paste(_:)`` action?
    ///
    /// False by default. Subclasses that can handle pasted contents should
    /// override this method.
    ///
    /// - SeeAlso ``canPerformAction(_:withSender:)``
    open func canPerformPasteAction() -> Bool {
        return false
    }

    override open func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if
            let iOS15EditMenu,
            let allowAction = iOS15EditMenu.allowAction(action)
        {
            return allowAction
        }

        // By default, canPerformAction returns false for the "paste" action. As
        // a result, we need to manually intercept and potentially allow it.
        if action == #selector(paste(_:)), canPerformPasteAction() {
            return true
        }

        return super.canPerformAction(action, withSender: sender)
    }

    override open func forwardingTarget(for aSelector: Selector!) -> Any? {
        if
            let iOS15EditMenu,
            iOS15EditMenu.selectorsHandledByThisType.contains(aSelector)
        {
            return iOS15EditMenu
        }

        return super.forwardingTarget(for: aSelector)
    }

    override open func resignFirstResponder() -> Bool {
        if let iOS15EditMenu {
            iOS15EditMenu.reset()
        }

        return super.resignFirstResponder()
    }

    // MARK: -

    public func insertTypedMention(address: SignalServiceAddress) {
        guard case .typingMention(let range) = state else {
            return owsFailDebug("Can't finish typing when no mention in progress")
        }

        replaceCharacters(
            in: NSRange(
                location: range.location - Mention.prefix.count,
                length: range.length + Mention.prefix.count,
            ),
            withMentionAddress: address,
        )
    }

    public func replaceCharacters(
        in range: NSRange,
        withMentionAddress mentionAddress: SignalServiceAddress,
    ) {
        guard let bodyRangesDelegate else {
            return owsFailDebug("Can't replace characters without delegate")
        }
        guard let mentionAci = mentionAddress.aci else {
            return owsFailDebug("Can't insert a mention without an ACI")
        }

        let body = MessageBody(
            text: "@",
            ranges: MessageBodyRanges(mentions: [NSRangedValue(mentionAci, range: NSRange(location: 0, length: 1))], styles: []),
        )
        let (hydrated, possibleAcis) = DependenciesBridge.shared.db.read { tx in
            return (
                body.hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx)),
                bodyRangesDelegate.textViewMentionPickerPossibleAcis(self, tx: tx),
            )
        }
        let hydratedPlaintext = hydrated.asPlaintext()

        if possibleAcis.contains(mentionAci) {
            editableBody.beginEditing()
            editableBody.replaceCharacters(in: range, withMentionAci: mentionAci, txProvider: DependenciesBridge.shared.db.readTxProvider)
            editableBody.endEditing()
        } else {
            // If we shouldn't resolve the mention, insert the plaintext representation.
            editableBody.beginEditing()
            editableBody.replaceCharacters(in: range, with: hydratedPlaintext, selectedRange: selectedRange)
            editableBody.endEditing()
        }
        textViewDidChange(self)
    }

    public var currentlyTypingMentionText: String? {
        guard case .typingMention(let range) = state else { return nil }
        guard (editableBody.hydratedPlaintext as NSString).length >= range.location + range.length else { return nil }
        guard range.length > 0 else { return "" }

        return (editableBody.hydratedPlaintext as NSString).substring(with: range)
    }

    public var defaultAttributes: [NSAttributedString.Key: Any] {
        var defaultAttributes = [NSAttributedString.Key: Any]()
        if let font { defaultAttributes[.font] = font }
        if let textColor { defaultAttributes[.foregroundColor] = textColor }
        return defaultAttributes
    }

    public var isEmpty: Bool {
        return editableBody.isEmpty
    }

    public var isWhitespaceOrEmpty: Bool {
        return editableBody.hydratedPlaintext.filterForDisplay.isEmpty
    }

    @available(*, unavailable)
    override public var text: String! {
        get {
            return textStorage.string
        }
        set {
            // Ignore setters; this is illegal
        }
    }

    @available(*, unavailable)
    override public var attributedText: NSAttributedString! {
        get {
            return textStorage.attributedString()
        }
        set {
            // Ignore setters; this is illegal
        }
    }

    override public var textColor: UIColor? {
        didSet {
            editableBody.didUpdateTheming()
        }
    }

    override open var font: UIFont? {
        didSet {
            editableBody.didUpdateTheming()
        }
    }

    fileprivate let editableBody: EditableMessageBodyTextStorage

    public var messageBodyForSending: MessageBody {
        return editableBody.messageBody.filterStringForDisplay()
    }

    open func setMessageBody(_ messageBody: MessageBody?, txProvider: EditableMessageBodyTextStorage.ReadTxProvider) {
        editableBody.beginEditing()
        if messageBody == nil {
            // "unmark" text so that pending marked ranges
            // are cleared on iOS 18.1 and don't result in a
            // crash when we later set selected range to empty.
            self.unmarkText()
        }
        editableBody.setMessageBody(messageBody, txProvider: txProvider)
        editableBody.endEditing()
        scheduleSpellCheck()
    }

    // MARK: - Misspellings

    /// Whether words the system spell checker does not know get a red dotted
    /// underline, the way the system marks them in fields it owns. Off by
    /// default; the compose box turns it on from the person's setting.
    ///
    /// The marks are drawn by the layout manager rather than stored as
    /// attributes: the text storage rebuilds its display string from the
    /// message body on every edit and refuses attributes set from outside, so
    /// an underline attribute would be wiped by the next keystroke. Drawing
    /// them beside the text, and moving them with the edits, keeps them out
    /// of the body-ranges styling altogether.
    public var marksMisspellings = false {
        didSet {
            guard marksMisspellings != oldValue else { return }
            if marksMisspellings {
                scheduleSpellCheck()
            } else {
                spellCheckTimer?.invalidate()
                spellCheckTimer = nil
                customLayoutManager.misspelledRanges = []
                setNeedsDisplay()
            }
        }
    }

    private static let spellCheckLanguage = "en_US"
    private static let spellCheckDelay: TimeInterval = 0.15
    private lazy var spellChecker = UITextChecker()
    private var spellCheckTimer: Timer?

    /// Checks shortly after the last change rather than on every keystroke:
    /// a fast typist would otherwise pay for a whole-text check per letter,
    /// and the word under the caret is skipped anyway until it is finished.
    private func scheduleSpellCheck() {
        guard marksMisspellings else { return }
        spellCheckTimer?.invalidate()
        spellCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.spellCheckDelay, repeats: false) { [weak self] _ in
            self?.checkSpelling()
        }
    }

    private func checkSpelling() {
        AssertIsOnMainThread()
        guard marksMisspellings else { return }
        let text = editableBody.hydratedPlaintext as NSString
        let mentionRanges = editableBody.mentionRanges
        let caret: Int? = selectedRange.length == 0 ? selectedRange.location : nil

        var misspelled = [NSRange]()
        var searchStart = 0
        while searchStart < text.length {
            let range = spellChecker.rangeOfMisspelledWord(
                in: text as String,
                range: NSRange(location: searchStart, length: text.length - searchStart),
                startingAt: searchStart,
                wrap: false,
                language: Self.spellCheckLanguage,
            )
            guard range.location != NSNotFound, range.length > 0 else { break }
            searchStart = range.upperBound
            // A word still being typed is not wrong yet.
            if let caret, range.location <= caret, caret <= range.upperBound { continue }
            if mentionRanges.contains(where: { ($0.intersection(range)?.length ?? 0) > 0 }) { continue }
            guard Self.isCheckable(range, in: text) else { continue }
            misspelled.append(range)
        }

        guard misspelled != customLayoutManager.misspelledRanges else { return }
        customLayoutManager.misspelledRanges = misspelled
        setNeedsDisplay()
    }

    /// Whether a word the checker flagged is one the person meant as English.
    /// Marks encoded as Qiuling private-use points are not words the checker
    /// can judge; digits, addresses and links are not spelt.
    private static func isCheckable(_ range: NSRange, in text: NSString) -> Bool {
        // Widen to the run between spaces so "example.com/nonsense" is judged
        // as the link it is rather than by its last piece.
        let separators = CharacterSet.whitespacesAndNewlines
        let before = text.rangeOfCharacter(from: separators, options: .backwards, range: NSRange(location: 0, length: range.location))
        let start = before.location == NSNotFound ? 0 : before.upperBound
        let after = text.rangeOfCharacter(from: separators, range: NSRange(location: range.upperBound, length: text.length - range.upperBound))
        let end = after.location == NSNotFound ? text.length : after.location
        let run = text.substring(with: NSRange(location: start, length: end - start))

        if run.unicodeScalars.contains(where: { $0.value >= 0xF0000 }) { return false }
        if run.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        if run.contains("/") || run.contains("@") { return false }
        if run.range(of: #"\.\p{L}"#, options: .regularExpression) != nil { return false }
        return true
    }

    public func scrollToBottom() {
        let length = (editableBody.attributedString.string as NSString).length
        if length == 0 {
            return
        }
        scrollRangeToVisible(NSRange(location: length - 1, length: 1))
    }

    public func stopTypingMention() {
        state = .notTypingMention
    }

    public func reloadMentionState() {
        stopTypingMention()
        updateMentionState()
    }

    // MARK: - Mention State

    private enum State: Equatable {
        case typingMention(range: NSRange)
        case notTypingMention
    }

    private var state: State = .notTypingMention {
        didSet {
            switch state {
            case .notTypingMention:
                if oldValue != .notTypingMention { didEndTypingMention() }
            case .typingMention:
                if oldValue == .notTypingMention {
                    didBeginTypingMention()
                } else {
                    guard let currentlyTypingMentionText else {
                        return owsFailDebug("unexpectedly missing mention text while typing a mention")
                    }

                    didUpdateMentionText(currentlyTypingMentionText)
                }
            }
        }
    }

    private weak var pickerView: MentionPicker?

    private func didBeginTypingMention() {
        guard let bodyRangesDelegate else { return }

        bodyRangesDelegate.textViewDidBeginTypingMention(self)

        if let pickerView {
            pickerView.removeFromSuperview()
            self.pickerView = nil
        }

        guard
            let pickerReferenceView = bodyRangesDelegate.textViewMentionPickerReferenceView(self),
            let pickerParentView = bodyRangesDelegate.textViewMentionPickerParentView(self) else { return }

        let mentionableAcis = SSKEnvironment.shared.databaseStorageRef.read { tx in
            return bodyRangesDelegate.textViewMentionPickerPossibleAcis(self, tx: tx)
        }
        guard !mentionableAcis.isEmpty else { return }

        let pickerView = MentionPicker(
            mentionableAcis: mentionableAcis,
            style: bodyRangesDelegate.mentionPickerStyle(self),
        ) { [weak self] selectedAddress in
            self?.insertTypedMention(address: selectedAddress)
        }

        // IS THIS EVEN POSSIBLE?
        guard let currentlyTypingMentionText, pickerView.mentionTextChanged(currentlyTypingMentionText) else {
            state = .notTypingMention
            return
        }

        self.pickerView = pickerView

        // Add to super view and set up constraints.
        pickerView.translatesAutoresizingMaskIntoConstraints = false
        pickerParentView.insertSubview(pickerView, belowSubview: pickerReferenceView)
        NSLayoutConstraint.activate([
            pickerView.topAnchor.constraint(greaterThanOrEqualTo: pickerParentView.safeAreaLayoutGuide.topAnchor),
            pickerView.leadingAnchor.constraint(equalTo: pickerParentView.safeAreaLayoutGuide.leadingAnchor),
            pickerView.trailingAnchor.constraint(equalTo: pickerParentView.safeAreaLayoutGuide.trailingAnchor),
            pickerView.bottomAnchor.constraint(equalTo: pickerReferenceView.topAnchor),
        ])

        // Do initial layout - make sure views are in their final position before being presented.
        UIView.performWithoutAnimation {
            pickerView.prepareToAnimateIn()
            pickerParentView.layoutIfNeeded()
            pickerView.updateHeightIfNeeded()
        }

        // Fade in.
        pickerView.animateIn()

        ImpactHapticFeedback.impactOccurred(style: .light)
    }

    private func didEndTypingMention() {
        bodyRangesDelegate?.textViewDidEndTypingMention(self)

        guard let pickerView else { return }

        pickerView.animateOut { _ in
            pickerView.removeFromSuperview()
        }
    }

    private func didUpdateMentionText(_ text: String) {
        if let pickerView, !pickerView.mentionTextChanged(text) {
            state = .notTypingMention
        }
    }

    private func shouldUpdateMentionText(in range: NSRange, changedText text: String) -> Bool {
        let mentionRanges = editableBody.mentionRanges

        if range.length > 0 {
            // Locate any mentions in the edited range.
            // TODO[TextFormatting]: update styles as needed
            for mentionRange in mentionRanges {
                // Mention ranges are ordered; once we are past the range
                // we are looking for no need to look more.
                if mentionRange.location > range.upperBound {
                    break
                }
            }
        } else if
            range.location > 0,
            mentionRanges.first(where: { mentionRange in
                mentionRange.upperBound == range.location
            }) != nil
        {
            // If there is a mention to the left, the typing attributes will
            // be the mention's attributes. We don't want that, so we need
            // to reset them here.
            typingAttributes = defaultAttributes
        }

        return true
    }

    private func updateMentionState() {
        // If we don't yet have a delegate, we can ignore any updates.
        // We'll check again when the delegate is assigned.
        guard bodyRangesDelegate != nil else { return }

        let bodyLength = (editableBody.hydratedPlaintext as NSString).length
        guard
            selectedRange.length == 0,
            selectedRange.location > 0,
            bodyLength > 0,
            selectedRange.upperBound <= bodyLength
        else {
            state = .notTypingMention
            return
        }

        var location = selectedRange.location

        while location > 0 {
            let possiblePrefix = editableBody.hydratedPlaintext.substring(
                withRange: NSRange(location: location - Mention.prefix.count, length: Mention.prefix.count),
            )

            let mentionRanges = editableBody.mentionRanges

            // If the previous character is part of a mention, we're not typing a mention
            if mentionRanges.first(where: { $0.contains(location) }) != nil {
                state = .notTypingMention
                return
            }

            // If we find whitespace before the selected range, we're not typing a mention.
            // Mention typing breaks on whitespace.
            if possiblePrefix.unicodeScalars.allSatisfy({ NSCharacterSet.whitespacesAndNewlines.contains($0) }) {
                state = .notTypingMention
                return
            }

            // If we find the mention prefix before the selected range, we may be typing a mention.
            if possiblePrefix == Mention.prefix {

                // If there's more text before the mention prefix, check if it's whitespace. Mentions
                // only start at the beginning of the string OR after a whitespace character.
                if location - Mention.prefix.count > 0 {
                    let characterPrecedingPrefix: Character = editableBody.hydratedPlaintext.substring(
                        withRange: NSRange(
                            location: location - Mention.prefix.count - 1,
                            length: 1,
                        ),
                    ).first!

                    // If it's alphanumeric, keep looking back. We don't want to
                    // insert a mention in the middle of typed text. Mention
                    // text can also itself contain an "@", for example when
                    // trying to match a profile name that contains "@".
                    if characterPrecedingPrefix.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                        location -= 1
                        continue
                    }
                }

                state = .typingMention(
                    range: NSRange(location: location, length: selectedRange.location - location),
                )
                return
            } else {
                location -= 1
            }
        }

        // We checked everything, so we're not typing
        state = .notTypingMention
    }

    // MARK: - Text Container Insets

    open var defaultTextContainerInset: UIEdgeInsets {
        UIEdgeInsets(hMargin: 7, vMargin: 7 - hairlineWidth)
    }

    public func updateTextContainerInset() {
        var newTextContainerInset = defaultTextContainerInset

        let currentFont = font ?? UIFont.dynamicTypeBody
        let systemDefaultFont = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: .init(preferredContentSizeCategory: .large),
        )
        guard systemDefaultFont.pointSize > currentFont.pointSize else {
            textContainerInset = newTextContainerInset
            return
        }

        // Increase top and bottom insets so that textView has the same one-line height
        // for any content size category smaller than the default (Large).
        // Simply fixing textView at a minimum height doesn't work well because
        // smaller text will be top-aligned (and we want center).
        let insetFontAdjustment = (systemDefaultFont.ascender - systemDefaultFont.descender) - (currentFont.ascender - currentFont.descender)
        newTextContainerInset.top += insetFontAdjustment * 0.5
        newTextContainerInset.bottom = newTextContainerInset.top - 1
        textContainerInset = newTextContainerInset
    }

    // MARK: - EditableMessageBodyDelegate

    public func editableMessageBodyDidRequestNewSelectedRange(_ newSelectedRange: NSRange) {
        self.selectedRange = newSelectedRange
    }

    public func editableMessageBodyHydrator(tx: DBReadTransaction) -> MentionHydrator {
        var possibleMentionAcis = Set<Aci>()
        bodyRangesDelegate?.textViewMentionPickerPossibleAcis(self, tx: tx).forEach {
            possibleMentionAcis.insert($0)
        }
        let hydrator = ContactsMentionHydrator.mentionHydrator(transaction: tx)
        return { aci in
            guard possibleMentionAcis.contains(aci) else {
                return .preserveMention
            }
            return hydrator(aci)
        }
    }

    public func editableMessageBodyDisplayConfig() -> HydratedMessageBody.DisplayConfiguration {
        return bodyRangesDelegate?.textViewDisplayConfiguration(self) ?? .composing(textViewColor: self.textColor)
    }

    public func isEditableMessageBodyDarkThemeEnabled() -> Bool {
        return Theme.isDarkThemeEnabled
    }

    public func editableMessageSelectedRange() -> NSRange {
        return selectedRange
    }

    public func mentionCacheInvalidationKey() -> String {
        return bodyRangesDelegate?.textViewMentionCacheInvalidationKey(self) ?? UUID().uuidString
    }

    public func didInsertMemoji(_ memojiGlyph: OWSAdaptiveImageGlyph) {
        bodyRangesDelegate?.textViewDidInsertMemoji(memojiGlyph)
    }

    // MARK: - Picker Keyboard Interaction

    override open var keyCommands: [UIKeyCommand]? {
        guard pickerView != nil else { return nil }

        return [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upArrowPressed(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downArrowPressed(_:))),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnPressed(_:))),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabPressed(_:))),
        ]
    }

    @objc
    func upArrowPressed(_ sender: UIKeyCommand) {
        guard let pickerView else { return }
        pickerView.didTapUpArrow()
    }

    @objc
    func downArrowPressed(_ sender: UIKeyCommand) {
        guard let pickerView else { return }
        pickerView.didTapDownArrow()
    }

    @objc
    func returnPressed(_ sender: UIKeyCommand) {
        guard let pickerView else { return }
        pickerView.didTapReturn()
    }

    @objc
    func tabPressed(_ sender: UIKeyCommand) {
        guard let pickerView else { return }
        pickerView.didTapTab()
    }

    // MARK: - Cut/Copy/Paste

    override open func cut(_ sender: Any?) {
        let selectedRange = self.selectedRange
        copy(sender)
        editableBody.beginEditing()
        editableBody.replaceCharacters(in: selectedRange, with: "", selectedRange: selectedRange)
        editableBody.endEditing()
        self.selectedRange = NSRange(location: selectedRange.location, length: 0)
        textViewDidChange(self)
    }

    public class func copyToPasteboard(_ text: CVTextValue) {
        let plaintext: String
        switch text {
        case .text(let text):
            plaintext = text
            UIPasteboard.general.setItems([], options: [:])
        case .attributedText(let text):
            plaintext = text.string
            UIPasteboard.general.setItems([], options: [:])
        case .messageBody(let messageBody):
            copyToPasteboard(messageBody.asMessageBodyForForwarding())
            return
        }

        let plaintextData = Data(plaintext.utf8)

        UIPasteboard.general.addItems([["public.utf8-plain-text": plaintextData]])
    }

    private class func copyToPasteboard(_ messageBody: MessageBody) {
        if messageBody.hasRanges, let encodedMessageBody = try? NSKeyedArchiver.archivedData(withRootObject: messageBody, requiringSecureCoding: true) {
            UIPasteboard.general.setItems([[Self.pasteboardType: encodedMessageBody]], options: [.localOnly: true])
        } else {
            UIPasteboard.general.setItems([], options: [:])
        }

        let plaintextData = Data(messageBody.text.utf8)

        UIPasteboard.general.addItems([["public.utf8-plain-text": plaintextData]])
    }

    // This can be more than just mentions (e.g. also text formatting styles)
    // but the name remains as-is for backwards compatibility.
    public static let pasteboardType = "private.archived-mention-text"

    override open func copy(_ sender: Any?) {
        let messageBody: MessageBody
        if selectedRange.length > 0 {
            messageBody = editableBody.messageBody(forHydratedTextSubrange: selectedRange)
        } else {
            messageBody = editableBody.messageBody
        }
        Self.copyToPasteboard(messageBody)
    }

    override open func paste(_ sender: Any?) {
        if
            let encodedMessageBody = UIPasteboard.general.data(forPasteboardType: Self.pasteboardType),
            var messageBody = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MessageBody.self, from: encodedMessageBody)
        {
            editableBody.beginEditing()
            DependenciesBridge.shared.db.read { tx in
                if let possibleAcis = bodyRangesDelegate?.textViewMentionPickerPossibleAcis(self, tx: tx) {
                    messageBody = messageBody.forPasting(intoContextWithPossibleAcis: possibleAcis, transaction: tx)
                }
                editableBody.replaceCharacters(in: selectedRange, withPastedMessageBody: messageBody, txProvider: { $0(tx) })
            }
            editableBody.endEditing()
        } else if let string = UIPasteboard.general.strings?.first {
            editableBody.beginEditing()
            editableBody.replaceCharacters(in: selectedRange, with: StringSanitizer.sanitize(string), selectedRange: selectedRange)
            editableBody.endEditing()
            // Put the selection at the end of the new range.
            self.selectedRange = NSRange(location: selectedRange.location + (string as NSString).length, length: 0)
        }

        if !textStorage.isEmpty {
            // Pasting very long text generates an obscure UI error producing an UITextView where the lower
            // part contains invisible characters. The exact root of the issue is still unclear but the following
            // lines of code work as a workaround.
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) { [weak self] in
                if let self {
                    let oldRange = self.selectedRange
                    self.selectedRange = NSRange(location: 0, length: 0)
                    // inserting blank text into the text storage will remove the invisible characters
                    self.textStorage.insert(NSAttributedString(string: ""), at: 0)
                    // setting the range (again) will ensure scrolling to the correct position
                    self.selectedRange = oldRange
                }
            }
        }
        self.textViewDidChange(self)
    }

    // MARK: - UITextViewDelegate

    open func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard shouldUpdateMentionText(in: range, changedText: text) else { return false }
        return bodyRangesDelegate?.textView?(textView, shouldChangeTextIn: range, replacementText: text) ?? true
    }

    open func textViewDidChangeSelection(_ textView: UITextView) {
        if let iOS15EditMenu {
            iOS15EditMenu.reset()
        }

        bodyRangesDelegate?.textViewDidChangeSelection?(textView)
        updateMentionState()
        // Leaving a word is what finishes it, so the caret moving away is
        // as much a reason to look again as a keystroke.
        scheduleSpellCheck()
    }

    open func textViewDidChange(_ textView: UITextView) {
        if let iOS15EditMenu {
            iOS15EditMenu.reset()
        }

        bodyRangesDelegate?.textViewDidChange?(textView)
        if editableBody.hydratedPlaintext.isEmpty { updateMentionState() }
        self.textAlignment = editableBody.naturalTextAlignment
        scheduleSpellCheck()
    }

    open func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        return bodyRangesDelegate?.textViewShouldBeginEditing?(textView) ?? true
    }

    open func textViewShouldEndEditing(_ textView: UITextView) -> Bool {
        if let iOS15EditMenu {
            iOS15EditMenu.reset()
        }

        return bodyRangesDelegate?.textViewShouldEndEditing?(textView) ?? true
    }

    open func textViewDidBeginEditing(_ textView: UITextView) {
        bodyRangesDelegate?.textViewDidBeginEditing?(textView)
    }

    open func textViewDidEndEditing(_ textView: UITextView) {
        bodyRangesDelegate?.textViewDidEndEditing?(textView)
    }

    open func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        return bodyRangesDelegate?.textView?(textView, shouldInteractWith: URL, in: characterRange, interaction: interaction) ?? true
    }

    open func textView(_ textView: UITextView, shouldInteractWith textAttachment: NSTextAttachment, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        return bodyRangesDelegate?.textView?(textView, shouldInteractWith: textAttachment, in: characterRange, interaction: interaction) ?? true
    }

    // MARK: - Text Formatting

    private func didSelectStyle(_ style: MessageBodyRanges.SingleStyle?) {
        guard selectedRange.length > 0 else {
            return
        }
        editableBody.beginEditing()
        if let style {
            editableBody.toggleStyle(style, in: selectedRange)
        } else {
            editableBody.removeFormatting(in: selectedRange)
        }
        editableBody.endEditing()
        textViewDidChange(self)
    }

    // MARK: - UIEditMenuInteractionDelegate-ish

    /// Not technically part of `UIEditMenuInteractionDelegate`, but exposed by
    /// `UITextInput` to allow us to configure the `UIEditMenuInteraction` that
    /// comes pre-configured on ourselves as a `UITextView`.
    override open func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard selectedRange.length > 0 else {
            // Only add the format menu if we've got text selected.
            return UIMenu(children: suggestedActions)
        }

        var formatMenuItems: [FormatEditMenuItem] = [
            .applyBold,
            .applyItalic,
            .applySpoiler,
            .applyStrikethrough,
            .applyMonospace,
        ]

        if editableBody.hasFormatting(in: selectedRange) {
            formatMenuItems.append(.removeFormatting)
        }

        let formatMenu = UIMenu(
            title: FormatEditMenuItem.showFormatMenu.title,
            options: [],
            children: formatMenuItems.map { menuItem in
                UIAction(
                    title: menuItem.title,
                    image: menuItem.image,
                ) { [self] _ in
                    let styleToApply: MessageBodyRanges.SingleStyle? = switch menuItem {
                    case .showFormatMenu: owsFail("Not possible")
                    case .removeFormatting: nil
                    case .applyBold: .bold
                    case .applyItalic: .italic
                    case .applyMonospace: .monospace
                    case .applyStrikethrough: .strikethrough
                    case .applySpoiler: .spoiler
                    }

                    didSelectStyle(styleToApply)
                }
            },
        )

        return UIMenu(children: [formatMenu] + suggestedActions)
    }
}

// MARK: -

/// Draws a red dotted line under misspelled words without touching the
/// text's attributes, and keeps the marked ranges in step with edits so they
/// stay under their words between one spelling check and the next.
final class MisspellingLayoutManager: NSLayoutManager {

    private var storedMisspelledRanges: [NSRange] = []

    var misspelledRanges: [NSRange] {
        get { storedMisspelledRanges }
        set {
            let stale = storedMisspelledRanges
            storedMisspelledRanges = newValue
            guard let textStorage else { return }
            let length = textStorage.length
            for range in stale + newValue {
                guard let clamped = range.intersection(NSRange(location: 0, length: length)), clamped.length > 0 else { continue }
                invalidateDisplay(forCharacterRange: clamped)
            }
        }
    }

    override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorage.EditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange,
    ) {
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
        guard editMask.contains(.editedCharacters), !storedMisspelledRanges.isEmpty else { return }
        // The range as it was before the edit: what replaced it is newCharRange.
        // Layout for everything from the edit on is being redone anyway, so
        // the moved ranges need no invalidation of their own.
        let replaced = NSRange(location: newCharRange.location, length: max(0, newCharRange.length - delta))
        storedMisspelledRanges = storedMisspelledRanges.compactMap { range in
            if range.upperBound < replaced.location {
                return range
            }
            if range.location > replaced.upperBound {
                return NSRange(location: range.location + delta, length: range.length)
            }
            // Touched by the edit: the word is being changed, so its verdict
            // no longer applies. The next check will say.
            return nil
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard
            !misspelledRanges.isEmpty,
            let textStorage,
            let context = UIGraphicsGetCurrentContext()
        else { return }

        let shownCharacters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let color = Theme.isDarkThemeEnabled ? Brand.vermilion : Brand.error
        let scale = max(1, UIScreen.main.scale)

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineCap(.butt)
        for range in misspelledRanges {
            guard
                let visible = range.intersection(shownCharacters),
                visible.length > 0,
                visible.upperBound <= textStorage.length
            else { continue }
            let glyphRange = self.glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
            guard glyphRange.length > 0, let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else { continue }

            // The size decides how thick the line is and how far it sits
            // below the baseline. The Qiuling face carries no underline
            // metrics of its own, so a tenth of the size is used: its marks
            // reach only a twentieth below the baseline, and the line must
            // clear them.
            let font = (textStorage.attribute(.font, at: visible.location, effectiveRange: nil) as? UIFont) ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
            let thickness = max(1, (font.pointSize / 20).rounded())
            let drop = font.pointSize / 10
            context.setLineWidth(thickness)
            context.setLineDash(phase: 0, lengths: [thickness, thickness])

            enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
                guard let inLine = glyphRange.intersection(lineGlyphRange), inLine.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: inLine, in: container)
                let baseline = lineRect.minY + self.location(forGlyphAt: inLine.location).y
                // Top edge on a device pixel, so the dots stay crisp.
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

// MARK: -

private enum FormatEditMenuItem: CaseIterable {
    case showFormatMenu
    case removeFormatting
    case applyBold
    case applyItalic
    case applyMonospace
    case applyStrikethrough
    case applySpoiler

    var title: String {
        switch self {
        case .showFormatMenu:
            OWSLocalizedString(
                "TEXT_MENU_FORMAT",
                comment: "Option in selected text edit menu to view text formatting options",
            )
        case .removeFormatting:
            OWSLocalizedString(
                "TEXT_MENU_REMOVE_FORMATTING",
                comment: "Option in selected text edit menu to remove all text formatting in the selected text range",
            )
        case .applyBold:
            OWSLocalizedString(
                "TEXT_MENU_BOLD",
                comment: "Option in selected text edit menu to make text bold",
            )
        case .applyItalic:
            OWSLocalizedString(
                "TEXT_MENU_ITALIC",
                comment: "Option in selected text edit menu to make text italic",
            )
        case .applyMonospace:
            OWSLocalizedString(
                "TEXT_MENU_MONOSPACE",
                comment: "Option in selected text edit menu to make text monospace",
            )
        case .applyStrikethrough:
            OWSLocalizedString(
                "TEXT_MENU_STRIKETHROUGH",
                comment: "Option in selected text edit menu to make text strikethrough",
            )
        case .applySpoiler:
            OWSLocalizedString(
                "TEXT_MENU_SPOILER",
                comment: "Option in selected text edit menu to make text spoiler",
            )
        }
    }

    var image: UIImage? {
        return switch self {
        case .showFormatMenu: nil
        case .removeFormatting: UIImage(named: "minus-circle")
        case .applyBold: UIImage(named: "text-format-bold")
        case .applyItalic: UIImage(named: "text-format-italic")
        case .applyMonospace: UIImage(named: "text-format-monospace")
        case .applyStrikethrough: UIImage(named: "text-format-strikethrough")
        case .applySpoiler: UIImage(named: "text-format-spoiler")
        }
    }
}

// MARK: -

/// Manages the "edit menu", i.e. the context menu presented when text is
/// selected, for `BodyRangesTextView` on iOS 15.
///
/// On iOS 16 and above, edit-menu configuration is supported via
/// `UIEditMenuInteraction`. On iOS 15, we do a whole bunch of complicated
/// interception of `UIAction`s and manipulation of `UIMenuController.shared`;
/// this type is intended to isolate that as much as possible.
///
/// The contents of this file were cut-pasted from `BodyRangesTextView` and
/// minimally adapated to accomodate being in a separate type.
@available(iOS, obsoleted: 16.0)
private class BodyRangesTextViewIOS15EditMenu {

    private unowned let textView: BodyRangesTextView
    private let didSelectStyleBlock: (MessageBodyRanges.SingleStyle?) -> Void

    private var isShowingFormatMenu = false

    init(
        textView: BodyRangesTextView,
        didSelectStyleBlock: @escaping (MessageBodyRanges.SingleStyle?) -> Void,
    ) {
        self.textView = textView
        self.didSelectStyleBlock = didSelectStyleBlock

        updateEditMenuItems()
    }

    // MARK: -

    var selectorsHandledByThisType: [Selector] {
        return FormatEditMenuItem.allCases.map { selectorFor(formatEditMenuItem: $0) }
    }

    func allowAction(_ action: Selector) -> Bool? {
        let isActionHandledByThisType = selectorsHandledByThisType.contains(action)

        if isShowingFormatMenu {
            // If we're showing the format menu, only allow format-menu actions.
            return isActionHandledByThisType
        }

        // Otherwise, we always allow actions we handle and defer on the rest.
        return isActionHandledByThisType ? true : nil
    }

    func reset() {
        isShowingFormatMenu = false
        updateEditMenuItems()

        if UIMenuController.shared.isMenuVisible {
            UIMenuController.shared.hideMenu(from: textView)
        }
    }

    // MARK: -

    private func updateEditMenuItems() {
        guard textView.selectedRange.length > 0 else {
            // We only want to mess with the edit menu when text is selected.
            UIMenuController.shared.menuItems = nil
            return
        }

        defer { UIMenuController.shared.update() }

        if isShowingFormatMenu {
            var formatMenuItems: [FormatEditMenuItem] = [
                .applyBold,
                .applyItalic,
                .applyMonospace,
                .applyStrikethrough,
                .applySpoiler,
            ]

            if textView.editableBody.hasFormatting(in: textView.selectedRange) {
                formatMenuItems.append(.removeFormatting)
            }

            UIMenuController.shared.menuItems = formatMenuItems.map { menuItem -> UIMenuItem in
                return UIMenuItem(title: menuItem.title, action: selectorFor(formatEditMenuItem: menuItem))
            }
        } else {
            UIMenuController.shared.menuItems = [
                UIMenuItem(
                    title: FormatEditMenuItem.showFormatMenu.title,
                    action: selectorFor(formatEditMenuItem: .showFormatMenu),
                ),
            ]
        }
    }

    private func selectorFor(formatEditMenuItem: FormatEditMenuItem) -> Selector {
        switch formatEditMenuItem {
        case .showFormatMenu: #selector(BodyRangesTextViewIOS15EditMenu.showFormatMenu)
        case .removeFormatting: #selector(BodyRangesTextViewIOS15EditMenu.removeFormatting)
        case .applyBold: #selector(BodyRangesTextViewIOS15EditMenu.applyBold)
        case .applyItalic: #selector(BodyRangesTextViewIOS15EditMenu.applyItalic)
        case .applySpoiler: #selector(BodyRangesTextViewIOS15EditMenu.applySpoiler)
        case .applyStrikethrough: #selector(BodyRangesTextViewIOS15EditMenu.applyStrikethrough)
        case .applyMonospace: #selector(BodyRangesTextViewIOS15EditMenu.applyMonospace)
        }
    }

    // MARK: -

    @objc
    private func showFormatMenu(_ sender: UIMenu) {
        isShowingFormatMenu = true

        // Update the menu items...
        updateEditMenuItems()

        // ...then wait for the menu to dismiss, and re-show it. (This system
        // doesn't support nested sub-menus.)
        DispatchQueue.main.async { [self] in
            guard let selectedTextRange = textView.selectedTextRange else {
                return
            }

            let selectionRects = textView.selectionRects(for: selectedTextRange)
            var completeRect = CGRect.null
            for rect in selectionRects {
                if completeRect.isNull {
                    completeRect = rect.rect
                } else {
                    completeRect = rect.rect.union(completeRect)
                }
            }
            UIMenuController.shared.showMenu(from: textView, rect: completeRect)
        }
    }

    @objc
    private func removeFormatting() { selectStyle(nil) }
    @objc
    private func applyBold() { selectStyle(.bold) }
    @objc
    private func applyItalic() { selectStyle(.italic) }
    @objc
    private func applySpoiler() { selectStyle(.spoiler) }
    @objc
    private func applyStrikethrough() { selectStyle(.strikethrough) }
    @objc
    private func applyMonospace() { selectStyle(.monospace) }

    private func selectStyle(_ style: MessageBodyRanges.SingleStyle?) {
        reset()
        didSelectStyleBlock(style)
    }
}
