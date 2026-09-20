//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Every string the keyboard shows or speaks, in one place.
enum Strings {
    static let numbersKey = "123"
    static let lettersKey = "ABC"
    static let symbolsKey = "#+="
    static let spaceKey = "space"

    static let insert = "Insert"
    static let picture = "Picture"
    static let copied = "Copied"
    static let cleared = "Cleared"
    static let inserted = "Inserted"
    static let lettersCaption = "Letters"
    static let fullAccessNotice = "To send pictures, allow full access for this keyboard in Settings."
    static let pictureFailedNotice = "Couldn't make the picture. Try again."
    static let fontUnavailableNotice = "Qiuling isn't available, so the keys show letters."

    static let privateOn = "Private compose on"
    static let privateOff = "Private compose off"

    // VoiceOver
    static let deleteLabel = "Delete"
    static let deleteHint = "Hold to delete more"
    static let spaceLabel = "Space"
    static let numbersLabel = "Numbers"
    static let lettersLabel = "Letters"
    static let symbolsLabel = "Symbols"
    static let globeLabel = "Next keyboard"
    static let globeHint = "Hold to choose a keyboard"
    static let privateLabel = "Private compose"
    static let privateValueOn = "on"
    static let privateValueOff = "off"
    static let privateValueWaiting = "off, message waiting"
    static let privateHint = "Keeps what you type inside the keyboard until you insert it"
    static let stripNormalLabel = "What you've typed, in Qiuling"
    static let stripPrivateLabel = "Your message in Qiuling"
    static let stripEmptyValue = "Empty"
    static let stripPrivateHint = "Use the keys to type. Insert puts it in the text field. Press and hold to show it in letters."
    static let showLettersAction = "Show letters"
    static let insertHint = "Puts your message in the text field as Qiuling"
    static let pictureHint = "Copies your message as a picture to paste anywhere"

    /// The Return key's face, per the host's `returnKeyType`.
    static func returnLabel(for type: UIReturnKeyType) -> String {
        switch type {
        case .go: return "go"
        case .google, .yahoo, .search: return "search"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .send: return "send"
        case .done: return "done"
        case .continue: return "continue"
        case .emergencyCall: return "emergency call"
        case .default: return "return"
        @unknown default: return "return"
        }
    }

    /// Spoken name of the Return key: the label with a capital.
    static func returnAccessibilityLabel(for type: UIReturnKeyType) -> String {
        let label = returnLabel(for: type)
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Spoken names for the punctuation and symbols on the keys. Anything not
    /// listed is read as the character itself, which VoiceOver names.
    static func accessibilityName(for character: String) -> String {
        switch character {
        case ".": return "period"
        case ",": return "comma"
        case "?": return "question mark"
        case "!": return "exclamation mark"
        case "'": return "apostrophe"
        case "\"": return "quotation mark"
        case "-": return "hyphen"
        case "/": return "slash"
        case ":": return "colon"
        case ";": return "semicolon"
        case "(": return "left parenthesis"
        case ")": return "right parenthesis"
        case "$": return "dollar sign"
        case "&": return "ampersand"
        case "@": return "at sign"
        default: return character
        }
    }
}
