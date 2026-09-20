//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import Foundation
import UIKit

/// The bundled Qiuling font, reachable two ways: registered with the process
/// so `UIFont(name:)` finds it for labels, and as a CoreText font made straight
/// from the file, which works even when registration was refused.
final class QiulingFont {
    static let shared = QiulingFont()

    static let familyName = "QiulingMorphWrite-Regular"
    static let fileName = "QiulingMorphWrite-Regular"
    static let markCount = 26

    /// Set once registration has been attempted; `isAvailable` is then final.
    private(set) var isAvailable = false
    private(set) var descriptor: CTFontDescriptor?
    private var fontCache: [CGFloat: CTFont] = [:]
    private var unionCache: [CGFloat: CGRect] = [:]
    private let lock = NSLock()

    private init() {}

    func register() {
        guard let url = Bundle.main.url(forResource: Self.fileName, withExtension: "ttf") else { return }
        // A refusal (other than "already registered", which a reshown keyboard
        // hits) only means UIFont lookups fail; the descriptor path still works.
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        if let data = try? Data(contentsOf: url) {
            let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
            descriptor = descriptors?.first
        }
        isAvailable = UIFont(name: Self.familyName, size: 12) != nil && descriptor != nil
    }

    func uiFont(size: CGFloat) -> UIFont? {
        UIFont(name: Self.familyName, size: size)
    }

    /// A CoreText font of the file at `size`, independent of registration.
    func ctFont(size: CGFloat) -> CTFont? {
        guard let descriptor else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = fontCache[size] { return cached }
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        fontCache[size] = font
        return font
    }

    /// The union of the a–z ink boxes at `size`, relative to the baseline
    /// origin with y up. Keys and callouts centre marks on this so a redrawn
    /// alphabet moves nothing in code.
    func unionBox(size: CGFloat) -> CGRect {
        lock.lock()
        if let cached = unionCache[size] { lock.unlock(); return cached }
        lock.unlock()
        guard let font = ctFont(size: 100) else { return CGRect(x: 0, y: 0, width: size, height: size) }
        var characters = (0..<Self.markCount).map { UniChar(0x61 + $0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        let rect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, glyphs.count)
        let scale = size / 100
        let box = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        lock.lock(); unionCache[size] = box; lock.unlock()
        return box
    }

    /// The largest size at which the a–z union box fits inside `box`.
    func fittedSize(in box: CGSize) -> CGFloat {
        let union = unionBox(size: 100)
        guard union.width > 0, union.height > 0 else { return min(box.width, box.height) }
        return 100 * min(box.width / union.width, box.height / union.height)
    }

    /// The glyph for a single character, or nil when the font lacks it.
    func glyph(for character: String, size: CGFloat) -> (CGGlyph, CTFont)? {
        guard let font = ctFont(size: size) else { return nil }
        var characters = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count), let glyph = glyphs.first, glyph != 0 else { return nil }
        return (glyph, font)
    }
}

/// Turns Latin text into the private-use scalars the font draws, so a
/// message reads as Qiuling in any app that has the font and in the app's own
/// bubbles. The table is glyph → scalar, built from what the font itself
/// returns for every private-use point it knows; encoding then asks CoreText
/// to shape the text exactly as the screen would and reads the glyphs back.
final class QiulingEncoder {
    static let shared = QiulingEncoder()

    static let planeStart: UInt32 = 0xF0000
    static let planeLength: UInt32 = 60000

    private(set) var isReady = false
    private var table: [CGGlyph: UInt32] = [:]
    private var buildStarted = false
    private var readyHandlers: [() -> Void] = []

    private init() {}

    /// Builds the table off the main queue; `onReady` runs on the main queue.
    func prepare(onReady: @escaping () -> Void) {
        if isReady { onReady(); return }
        readyHandlers.append(onReady)
        guard !buildStarted else { return }
        buildStarted = true
        DispatchQueue.global(qos: .utility).async {
            let built = Self.buildTable()
            DispatchQueue.main.async {
                self.table = built
                self.isReady = true
                let handlers = self.readyHandlers
                self.readyHandlers = []
                handlers.forEach { $0() }
            }
        }
    }

    private static func buildTable() -> [CGGlyph: UInt32] {
        guard let font = QiulingFont.shared.ctFont(size: 24) else { return [:] }
        var table: [CGGlyph: UInt32] = [:]

        // First writer wins, so the private-use pass claims every glyph it
        // can and the Latin pass afterwards only fills what is left.
        func record(_ scalars: [UInt32]) {
            var characters: [UniChar] = []
            var owners: [UInt32] = []
            for scalar in scalars {
                guard let unicode = Unicode.Scalar(scalar) else { continue }
                let units = Array(String(Character(unicode)).utf16)
                characters.append(contentsOf: units)
                owners.append(contentsOf: [UInt32](repeating: scalar, count: units.count))
            }
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
            for (i, glyph) in glyphs.enumerated() where glyph != 0 && table[glyph] == nil {
                table[glyph] = owners[i]
            }
        }

        var chunk: [UInt32] = []
        chunk.reserveCapacity(1024)
        for offset in 0..<planeLength {
            chunk.append(planeStart + offset)
            if chunk.count == 1024 {
                record(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { record(chunk) }
        // The same glyph reached from both a letter and its point encodes as the point.
        record(Array(0x61...0x7A) + [0x20])

        // Spaces never encode to a point; the rule in `encode` keeps them U+0020
        // anyway, but the table should not offer the option.
        var space: [UniChar] = [0x20]
        var spaceGlyph: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(font, &space, &spaceGlyph, 1)
        table[spaceGlyph[0]] = nil
        for point in GroupMappings.shared.spaceVariantPoints {
            if let unicode = Unicode.Scalar(point) {
                var units = Array(String(Character(unicode)).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: units.count)
                CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
                if glyphs[0] != 0 { table[glyphs[0]] = nil }
            }
        }
        return table
    }

    /// Lowercases and drops apostrophes, as the app's segmenter does; digits,
    /// punctuation, spaces and line breaks were typed on purpose and stay.
    static func normalise(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[’‘']", with: "", options: .regularExpression)
    }

    func encode(_ text: String) -> String {
        let source = Self.normalise(text)
        guard isReady, !source.isEmpty, let font = QiulingFont.shared.ctFont(size: 24) else { return source }
        let attributed = NSAttributedString(string: source, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return source }
        let utf16 = Array(source.utf16)

        struct Piece { let start: Int; let text: String }
        var pieces: [Piece] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let range = CTRunGetStringRange(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont
            let isQiuling = (CTFontCopyPostScriptName(runFont) as String) == QiulingFont.familyName

            let order = indices.indices.sorted { indices[$0] < indices[$1] }
            for (n, i) in order.enumerated() {
                let start = Int(indices[i])
                let end = n + 1 < order.count ? Int(indices[order[n + 1]]) : Int(range.location + range.length)
                guard end > start else { continue }
                let substring = String(utf16: utf16[start..<end]) ?? ""
                let onlySpaces = substring.unicodeScalars.allSatisfy { $0.value == 0x20 }
                if !onlySpaces, isQiuling, let point = table[glyphs[i]], let scalar = Unicode.Scalar(point) {
                    pieces.append(Piece(start: start, text: String(Character(scalar))))
                } else {
                    pieces.append(Piece(start: start, text: substring))
                }
            }
        }
        return pieces.sorted { $0.start < $1.start }.map(\.text).joined()
    }
}

/// `mappings-morph.json`: the letter groups the font draws as one mark, keyed
/// by their letters. The keyboard uses it for the long-press groups row and to
/// keep contextual spaces out of the reverse table.
final class GroupMappings {
    static let shared = GroupMappings()

    private let mapping: [String: UInt32]

    private init() {
        var loaded: [String: UInt32] = [:]
        if let url = Bundle.main.url(forResource: "mappings-morph", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                if let number = value as? NSNumber { loaded[key] = number.uint32Value }
            }
        }
        mapping = loaded
    }

    var spaceVariantPoints: [UInt32] {
        mapping.filter { $0.key.hasPrefix(" ") }.map(\.value)
    }

    /// Groups of two or more letters beginning with `letter`, shortest first.
    func groups(startingWith letter: String) -> [String] {
        mapping.keys
            .filter { $0.count >= 2 && !$0.hasPrefix(" ") && $0.hasPrefix(letter) }
            .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
    }
}

private extension String {
    init?(utf16 slice: ArraySlice<UInt16>) {
        self.init(decoding: slice, as: UTF16.self)
    }
}
