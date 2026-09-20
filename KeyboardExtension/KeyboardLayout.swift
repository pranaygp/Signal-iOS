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
/// us. Portrait and landscape have their own vertical rhythm; iPad stretches
/// the same rows.
struct KeyboardMetrics {
    let width: CGFloat
    let isLandscape: Bool
    let isPad: Bool
    let safeLeft: CGFloat
    let safeRight: CGFloat

    var gap: CGFloat { isPad ? 12 : 6 }
    var edgeLeft: CGFloat { (isPad ? 6 : 3) + (isLandscape && !isPad ? safeLeft : 0) }
    var edgeRight: CGFloat { (isPad ? 6 : 3) + (isLandscape && !isPad ? safeRight : 0) }
    var keyWidth: CGFloat { (width - edgeLeft - edgeRight - 9 * gap) / 10 }
    var sideWidth: CGFloat { 1.25 * keyWidth + gap / 2 }
    var keyHeight: CGFloat {
        if isPad { return isLandscape ? 76 : 56 }
        return isLandscape ? 30 : 42
    }
    var verticalGap: CGFloat {
        if isPad { return 10 }
        return isLandscape ? 7 : 12
    }
    var topInset: CGFloat { isLandscape && !isPad ? 6 : 8 }
    var bottomInset: CGFloat { isLandscape && !isPad ? 15 : 4 }
    var rowPitch: CGFloat { keyHeight + verticalGap }
    var stripHeight: CGFloat { isLandscape && !isPad ? 38 : 44 }
    var keyAreaHeight: CGFloat {
        if isPad { return isLandscape ? 352 : 264 }
        return isLandscape ? 162 : 216
    }
    var totalHeight: CGFloat { stripHeight + keyAreaHeight }
    var cornerRadius: CGFloat { 5 }

    /// The box the a–z marks are fitted into on a key.
    var markBox: CGSize {
        if isPad { return CGSize(width: 30, height: 34) }
        return isLandscape ? CGSize(width: 18, height: 20) : CGSize(width: 22, height: 26)
    }
    var stripFontSize: CGFloat { isLandscape && !isPad ? 20 : 24 }
    var stripCellWidth: CGFloat { width < 360 ? 56 : 64 }

    /// The y of the given row's top within the key area. On iPad the same rows
    /// stretch to fill the taller area; on iPhone the pitch is fixed.
    func rowTop(_ row: Int) -> CGFloat {
        if isPad {
            let pitch = (keyAreaHeight - topInset - bottomInset - keyHeight) / 3
            return topInset + CGFloat(row) * pitch
        }
        return topInset + CGFloat(row) * rowPitch
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

        // Row 3: side keys at the edges, the character keys centred as a block.
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
        let blockStart = (m.width - blockWidth) / 2
        for (i, text) in row3.enumerated() {
            let frame = CGRect(x: blockStart + CGFloat(i) * pitch, y: y3, width: k, height: h)
            placed.append(PlacedKey(spec: character(text), frame: frame, row: 2, isFirstInRow: false, isLastInRow: false))
        }
        placed.append(PlacedKey(spec: KeySpec(.delete), frame: CGRect(x: m.width - m.edgeRight - s, y: y3, width: s, height: h), row: 2, isFirstInRow: false, isLastInRow: true))

        // Row 4: layer key, optional globe, space, return.
        let y4 = m.rowTop(3)
        let layerKind: KeyKind = layer == .letters ? .layer(.numbers) : .layer(.letters)
        let layerWidth = needsGlobe ? s : 2 * s + g
        placed.append(PlacedKey(spec: KeySpec(layerKind), frame: CGRect(x: m.edgeLeft, y: y4, width: layerWidth, height: h), row: 3, isFirstInRow: true, isLastInRow: false))
        var spaceStart = m.edgeLeft + layerWidth + g
        if needsGlobe {
            placed.append(PlacedKey(spec: KeySpec(.globe), frame: CGRect(x: spaceStart, y: y4, width: s, height: h), row: 3, isFirstInRow: false, isLastInRow: false))
            spaceStart += s + g
        }
        let returnWidth = 2 * s + g
        let returnX = m.width - m.edgeRight - returnWidth
        placed.append(PlacedKey(spec: KeySpec(.space), frame: CGRect(x: spaceStart, y: y4, width: returnX - g - spaceStart, height: h), row: 3, isFirstInRow: false, isLastInRow: false))
        placed.append(PlacedKey(spec: KeySpec(.returnKey), frame: CGRect(x: returnX, y: y4, width: returnWidth, height: h), row: 3, isFirstInRow: false, isLastInRow: true))
        return placed
    }
}
