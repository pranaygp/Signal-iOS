//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Private compose: text typed on the keys stays in the strip's editor, in
/// memory, until the person inserts it as Qiuling or copies it as a picture.
/// The keys' edits go through here so they land at the editor's caret, which
/// a tap or the held space bar may have moved. Only the on/off switch is
/// persisted — never a word of the message, which lives and dies with the
/// extension process.
final class PrivateComposer {
    private static let flagKey = "privateCompose"

    /// The persisted preference. Whether it applies to the current field is
    /// `isActive`, which the controller derives from the host's traits.
    private(set) var isPrivate: Bool {
        didSet { UserDefaults.standard.set(isPrivate, forKey: Self.flagKey) }
    }
    private weak var editor: PrivateEditorView?

    init() {
        isPrivate = UserDefaults.standard.bool(forKey: Self.flagKey)
    }

    /// The editor that holds the message from now on.
    func attach(_ editor: PrivateEditorView) {
        self.editor = editor
    }

    var buffer: String { editor?.text ?? "" }
    var hasWaitingMessage: Bool { !buffer.isEmpty }

    func setPrivate(_ on: Bool) {
        isPrivate = on
    }

    /// Types at the caret, replacing any selection.
    func append(_ text: String) {
        editor?.insertText(text)
    }

    /// Removes the selection or the character before the caret; false when
    /// there was nothing to remove.
    @discardableResult
    func deleteLast() -> Bool {
        guard hasWaitingMessage else { return false }
        editor?.deleteBackwardOrSelection()
        return true
    }

    /// Deletes back through the word before the caret: trailing spaces, then the word.
    @discardableResult
    func deleteWord() -> Bool {
        guard let editor, hasWaitingMessage else { return false }
        if editor.selectedRange.length > 0 {
            editor.deleteBackwardOrSelection()
            return true
        }
        let before = editor.textBeforeCaret
        guard !before.isEmpty else { return false }
        editor.replaceBeforeCaret(count: Self.wordDeletionCount(before: before), with: "")
        return true
    }

    /// How many characters a word-delete removes from the end of `text`:
    /// the trailing spaces and the run of non-spaces before them (at least one).
    static func wordDeletionCount(before text: String) -> Int {
        var count = 0
        var index = text.endIndex
        while index > text.startIndex, text[text.index(before: index)] == " " {
            index = text.index(before: index)
            count += 1
        }
        while index > text.startIndex, text[text.index(before: index)] != " " {
            index = text.index(before: index)
            count += 1
        }
        return max(count, 1)
    }

    /// Double-tapping Space: the space before the caret becomes ". " when
    /// what came before it is a letter or a Qiuling mark.
    @discardableResult
    func applyDoubleSpacePeriod() -> Bool {
        guard let editor, editor.selectedRange.length == 0 else { return false }
        let before = editor.textBeforeCaret
        guard before.hasSuffix(" ") else { return false }
        guard let last = before.dropLast().unicodeScalars.last, Self.isLetterOrMark(last) else { return false }
        editor.replaceBeforeCaret(count: 1, with: ". ")
        return true
    }

    static func isLetterOrMark(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value >= QiulingEncoder.planeStart, scalar.value < QiulingEncoder.planeStart + QiulingEncoder.planeLength { return true }
        return scalar.properties.isAlphabetic
    }

    /// Walks the caret `offset` characters, as the held space bar asks.
    func moveCaret(by offset: Int) {
        editor?.moveCaret(by: offset)
    }

    func clear() {
        editor?.clear()
    }

    /// The message as encoded and as pictured.
    var normalisedBuffer: String { QiulingEncoder.normalise(buffer) }
}
