//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Private compose: text typed on the keys stays here, in memory, until the
/// person inserts it as Qiuling or copies it as a picture. Only the on/off
/// switch is persisted — never a word of the buffer, which lives and dies with
/// the extension process.
final class PrivateComposer {
    private static let flagKey = "privateCompose"

    /// The persisted preference. Whether it applies to the current field is
    /// `isActive`, which the controller derives from the host's traits.
    private(set) var isPrivate: Bool {
        didSet { UserDefaults.standard.set(isPrivate, forKey: Self.flagKey) }
    }
    private(set) var buffer = ""

    init() {
        isPrivate = UserDefaults.standard.bool(forKey: Self.flagKey)
    }

    var hasWaitingMessage: Bool { !buffer.isEmpty }

    func setPrivate(_ on: Bool) {
        isPrivate = on
    }

    func append(_ text: String) {
        buffer.append(text)
    }

    /// Removes the last character; false when there was nothing to remove.
    @discardableResult
    func deleteLast() -> Bool {
        guard !buffer.isEmpty else { return false }
        buffer.removeLast()
        return true
    }

    /// Deletes back through the last word: trailing spaces, then the word.
    @discardableResult
    func deleteWord() -> Bool {
        guard !buffer.isEmpty else { return false }
        let count = Self.wordDeletionCount(before: buffer)
        buffer.removeLast(count)
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

    /// Double-tapping Space: the trailing space becomes ". " when what came
    /// before it is a letter or a Qiuling mark.
    @discardableResult
    func applyDoubleSpacePeriod() -> Bool {
        guard buffer.hasSuffix(" ") else { return false }
        let withoutSpace = buffer.dropLast()
        guard let last = withoutSpace.unicodeScalars.last, Self.isLetterOrMark(last) else { return false }
        buffer = String(withoutSpace) + ". "
        return true
    }

    static func isLetterOrMark(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value >= QiulingEncoder.planeStart, scalar.value < QiulingEncoder.planeStart + QiulingEncoder.planeLength { return true }
        return scalar.properties.isAlphabetic
    }

    func clear() {
        buffer = ""
    }

    /// The buffer as shown and as encoded.
    var normalisedBuffer: String { QiulingEncoder.normalise(buffer) }
}
