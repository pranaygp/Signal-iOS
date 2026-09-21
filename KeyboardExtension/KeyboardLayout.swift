//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum KeyboardLayer {
    case letters
    case numbers
    case symbols
}

/// What a key does. Character keys carry the text they type; the rest are the
/// system-style controls around them.
enum KeyKind: Equatable {
    case character(String)
    case privateCompose
    case delete
    /// The row-4 layer key: to Numbers from Letters, to Letters otherwise.
    case layer(KeyboardLayer)
    /// The row-3 page key inside the Numbers layer.
    case page(KeyboardLayer)
    case globe
    case space
    case returnKey

    var isCharacter: Bool {
        if case .character = self { return true }
        return false
    }

    /// Keys that are drawn on the grey "special" face and light up when pressed.
    var isSpecial: Bool { !isCharacter && self != .space }
}

struct KeySpec {
    let kind: KeyKind
    /// Long-press alternates, typed through the same row as letter groups.
    let alternates: [String]

    init(_ kind: KeyKind, alternates: [String] = []) {
        self.kind = kind
        self.alternates = alternates
    }

    /// True for a–z: drawn as a Qiuling mark, and eligible for the groups row.
    var isLetter: Bool {
        if case .character(let text) = kind, text.count == 1, let scalar = text.unicodeScalars.first {
            return scalar.value >= 0x61 && scalar.value <= 0x7A
        }
        return false
    }

    /// Characters the font draws as marks: the letters plus period and comma.
    var isMark: Bool {
        if isLetter { return true }
        if case .character(let text) = kind { return text == "." || text == "," }
        return false
    }

    var isDigit: Bool {
        if case .character(let text) = kind, text.count == 1, let scalar = text.unicodeScalars.first {
            return scalar.value >= 0x30 && scalar.value <= 0x39
        }
        return false
    }
}

/// The numbers that place every key, derived from the width the host gives
/// us. They follow the iOS 26 system keyboard as measured pixel by pixel on a
/// 402pt iPhone: 6.5pt outer margins, ten 33.5pt keys with 6pt gaps filling
/// the width, 43pt keys on a 54pt pitch, 8pt corners. Narrower phones scale
/// the key and gap together so a row still fills the width exactly; iPad
/// keeps the same proportions on taller keys.
struct KeyboardMetrics {
    let width: CGFloat
    let isLandscape: Bool
    let isPad: Bool
    let safeLeft: CGFloat
    let safeRight: CGFloat

    /// The system's ratio of gap to key: 6 to 33.5 on a 389pt row.
    private static let gapPerKey: CGFloat = 6 / 33.5
    private static let referenceKeyHeight: CGFloat = 43

    var edgeLeft: CGFloat { 6.5 + (isLandscape && !isPad ? safeLeft : 0) }
    var edgeRight: CGFloat { 6.5 + (isLandscape && !isPad ? safeRight : 0) }
    private var rowWidth: CGFloat { width - edgeLeft - edgeRight }
    /// Ten keys and nine gaps span the row: k = row / (10 + 9·ratio).
    var keyWidth: CGFloat { rowWidth / (10 + 9 * Self.gapPerKey) }
    var gap: CGFloat { keyWidth * Self.gapPerKey }
    /// Row 3's side keys (private compose, delete; the layer pages).
    var sideWidth: CGFloat { 1.35 * keyWidth }
    /// Row 4's 123 and return keys: each ends flush with the near edge of
    /// row 3's first or last letter, as the system's do, which with the
    /// letters block centred is 2.5 keys and 1.5 gaps.
    var cornerKeyWidth: CGFloat { 2.5 * keyWidth + 1.5 * gap }
    var keyHeight: CGFloat {
        if isPad { return isLandscape ? 76 : 56 }
        return isLandscape ? 32 : Self.referenceKeyHeight
    }
    var verticalGap: CGFloat {
        if isPad { return 12 }
        return isLandscape ? 7 : 11
    }
    var topInset: CGFloat { isLandscape && !isPad ? 6 : 8 }
    /// Below the last row, before the dock or the view's bottom.
    var bottomInset: CGFloat { 3 }
    var rowPitch: CGFloat { keyHeight + verticalGap }
    var stripHeight: CGFloat { isLandscape && !isPad ? 38 : 44 }
    /// Four rows at their pitch inside the insets; the dock, when the host
    /// draws one, sits below this in the safe-area inset.
    var keyAreaHeight: CGFloat { topInset + 4 * keyHeight + 3 * verticalGap + bottomInset }
    var totalHeight: CGFloat { stripHeight + keyAreaHeight }
    /// 8pt on a 43pt key, scaled with the key so iPad's taller keys stay as round.
    var cornerRadius: CGFloat { 8 * keyHeight / Self.referenceKeyHeight }

    /// The point size of the system keyboard's letter labels; marks are sized
    /// to read at the same optical height (see `KeyboardViewController`).
    var systemLabelSize: CGFloat {
        if isPad { return isLandscape ? 30 : 28 }
        return isLandscape ? 22 : 24
    }
    /// The most room a mark may take on a key, whatever its optical size.
    var markBox: CGSize { CGSize(width: keyWidth - 6, height: keyHeight - 8) }
    /// The system's 123 and Return labels measure 18pt on the phone.
    var specialLabelSize: CGFloat { isPad ? 20 : (isLandscape ? 16 : 18) }
    var stripFontSize: CGFloat { isLandscape && !isPad ? 20 : 24 }
    var stripCellWidth: CGFloat { width < 360 ? 56 : 64 }

    /// The y of the given row's top within the key area.
    func rowTop(_ row: Int) -> CGFloat {
        topInset + CGFloat(row) * rowPitch
    }
}

struct PlacedKey {
    let spec: KeySpec
    let frame: CGRect
    let row: Int
    /// Position within the row; edge keys flare their callouts inward only.
    let isFirstInRow: Bool
    let isLastInRow: Bool
}

enum KeyboardLayout {
    private static let lettersRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    private static let numbersRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]
    private static let symbolsRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
    ]

    static func alternates(for character: String) -> [String] {
        switch character {
        case "0": return ["°"]
        case "-": return ["–", "—"]
        case "$": return ["¢", "€", "£", "¥"]
        case "\"": return ["“", "”", "„", "»"]
        case "'": return ["‘", "’"]
        case "?": return ["¿"]
        case "!": return ["¡"]
        case ".": return ["…"]
        default: return []
        }
    }

    static func keys(layer: KeyboardLayer, metrics m: KeyboardMetrics, needsGlobe: Bool) -> [PlacedKey] {
        var placed: [PlacedKey] = []
        let rows: [[String]]
        switch layer {
        case .letters: rows = lettersRows
        case .numbers: rows = numbersRows
        case .symbols: rows = symbolsRows
        }
        let k = m.keyWidth, g = m.gap, s = m.sideWidth, h = m.keyHeight
        let pitch = k + g

        func character(_ text: String) -> KeySpec {
            KeySpec(.character(text), alternates: layer == .letters ? [] : alternates(for: text))
        }

        // Rows 1 and 2: k-wide keys, centred — which offsets a nine-key
        // second row by half a pitch, as on the system keyboard, and leaves a
        // ten-key one flush.
        for (row, texts) in rows.prefix(2).enumerated() {
            let rowWidth = CGFloat(texts.count) * k + CGFloat(texts.count - 1) * g
            let start = m.edgeLeft + (m.width - m.edgeLeft - m.edgeRight - rowWidth) / 2
            let y = m.rowTop(row)
            for (i, text) in texts.enumerated() {
                let frame = CGRect(x: start + CGFloat(i) * pitch, y: y, width: k, height: h)
                placed.append(PlacedKey(spec: character(text), frame: frame, row: row, isFirstInRow: i == 0, isLastInRow: i == texts.count - 1))
            }
        }

        // Row 3: side keys at the edges, the character keys centred as a
        // block, leaving the wider gaps beside the side keys that the system
        // keyboard has.
        let row3 = rows[2]
        let y3 = m.rowTop(2)
        let leftKind: KeyKind
        switch layer {
        case .letters: leftKind = .privateCompose
        case .numbers: leftKind = .page(.symbols)
        case .symbols: leftKind = .page(.numbers)
        }
        placed.append(PlacedKey(spec: KeySpec(leftKind), frame: CGRect(x: m.edgeLeft, y: y3, width: s, height: h), row: 2, isFirstInRow: true, isLastInRow: false))
        let blockWidth = CGFloat(row3.count) * k + CGFloat(row3.count - 1) * g
        let blockStart = m.edgeLeft + (m.width - m.edgeLeft - m.edgeRight - blockWidth) / 2
        for (i, text) in row3.enumerated() {
            let frame = CGRect(x: blockStart + CGFloat(i) * pitch, y: y3, width: k, height: h)
            placed.append(PlacedKey(spec: character(text), frame: frame, row: 2, isFirstInRow: false, isLastInRow: false))
        }
        placed.append(PlacedKey(spec: KeySpec(.delete), frame: CGRect(x: m.width - m.edgeRight - s, y: y3, width: s, height: h), row: 2, isFirstInRow: false, isLastInRow: true))

        // Row 4: layer key, optional globe, space, return. With a globe the
        // layer key shrinks to a side key so the pair spans the corner key.
        let y4 = m.rowTop(3)
        let layerKind: KeyKind = layer == .letters ? .layer(.numbers) : .layer(.letters)
        let corner = m.cornerKeyWidth
        let layerWidth = needsGlobe ? (corner - g) / 2 : corner
        placed.append(PlacedKey(spec: KeySpec(layerKind), frame: CGRect(x: m.edgeLeft, y: y4, width: layerWidth, height: h), row: 3, isFirstInRow: true, isLastInRow: false))
        var spaceStart = m.edgeLeft + layerWidth + g
        if needsGlobe {
            placed.append(PlacedKey(spec: KeySpec(.globe), frame: CGRect(x: spaceStart, y: y4, width: layerWidth, height: h), row: 3, isFirstInRow: false, isLastInRow: false))
            spaceStart += layerWidth + g
        }
        let returnX = m.width - m.edgeRight - corner
        placed.append(PlacedKey(spec: KeySpec(.space), frame: CGRect(x: spaceStart, y: y4, width: returnX - g - spaceStart, height: h), row: 3, isFirstInRow: false, isLastInRow: false))
        placed.append(PlacedKey(spec: KeySpec(.returnKey), frame: CGRect(x: returnX, y: y4, width: corner, height: h), row: 3, isFirstInRow: false, isLastInRow: true))
        return placed
    }
}
