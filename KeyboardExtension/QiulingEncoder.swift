//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// `Scripts/qiuling-encoder-test.swift` compiles this file on macOS against the
// bundled font, so everything the encoder itself needs stays on Foundation and
// CoreText; only the UIFont conveniences are gated.

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
        #if canImport(UIKit)
        isAvailable = UIFont(name: Self.familyName, size: 12) != nil && descriptor != nil
        #else
        isAvailable = descriptor != nil
        #endif
    }

    #if canImport(UIKit)
    func uiFont(size: CGFloat) -> UIFont? {
        UIFont(name: Self.familyName, size: size)
    }
    #endif

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

/// The encoding itself, over one CoreText font: a table from glyph to the
/// private-use scalar the font reaches it from, built by asking the font for
/// the glyph of every point in the plane, letters filling only what the points
/// left. Encoding shapes the text exactly as the screen would and reads the
/// glyphs back through the table.
///
/// Not every glyph the lookups can produce has a point. The morpheme rules use
/// boundary duplicates — `s.suf`, the plural s that closes `jumps` — which are
/// a letter's drawing under another name so later lookups leave it alone, and
/// the font build gives those no point of their own. A glyph the table does not
/// know therefore falls back to the points of the letters it covers, one by
/// one; the drawing is the same, and a plain letter never reaches the field.
struct QiulingEncoderCore {
    static let planeStart: UInt32 = 0xF0000
    static let planeLength: UInt32 = 60000

    let font: CTFont
    private(set) var table: [CGGlyph: UInt32] = [:]
    /// Each letter a–z (as its UTF-16 unit) to its own point.
    private(set) var letterPoints: [UInt16: UInt32] = [:]

    /// `spaceVariantPoints` are the points of the contextual space drawings,
    /// which must never encode: a space stays U+0020 whichever form was drawn.
    init(font: CTFont, spaceVariantPoints: [UInt32]) {
        self.font = font

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
        for offset in 0..<Self.planeLength {
            chunk.append(Self.planeStart + offset)
            if chunk.count == 1024 {
                record(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { record(chunk) }
        // The same glyph reached from both a letter and its point encodes as the point.
        record(Array(0x61...0x7A) + [0x20])

        for point in spaceVariantPoints {
            if let glyph = Self.glyph(of: point, in: font) { table[glyph] = nil }
        }
        if let glyph = Self.glyph(of: 0x20, in: font) { table[glyph] = nil }

        for letter in UInt32(0x61)...0x7A {
            if let glyph = Self.glyph(of: letter, in: font), let point = table[glyph] {
                letterPoints[UInt16(letter)] = point
            }
        }
    }

    private static func glyph(of scalar: UInt32, in font: CTFont) -> CGGlyph? {
        guard let unicode = Unicode.Scalar(scalar) else { return nil }
        var units = Array(String(Character(unicode)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs[0] == 0 ? nil : glyphs[0]
    }

    /// Lowercases and drops apostrophes, as the app's segmenter does; digits,
    /// punctuation, spaces and line breaks were typed on purpose and stay.
    static func normalise(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[’‘']", with: "", options: .regularExpression)
    }

    /// One shaped glyph and the stretch of the source it stands for.
    struct ShapedGlyph {
        let glyph: CGGlyph
        let range: Range<Int>
        let covered: String
        let isQiulingFont: Bool
        let point: UInt32?
    }

    /// The text as CoreText lays it out, in source order.
    func shape(_ source: String) -> [ShapedGlyph] {
        let attributed = NSAttributedString(string: source, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        let utf16 = Array(source.utf16)
        let qiulingName = CTFontCopyPostScriptName(font) as String

        var shaped: [ShapedGlyph] = []
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
            let isQiuling = (CTFontCopyPostScriptName(runFont) as String) == qiulingName

            let order = indices.indices.sorted { indices[$0] < indices[$1] }
            for (n, i) in order.enumerated() {
                let start = Int(indices[i])
                let end = n + 1 < order.count ? Int(indices[order[n + 1]]) : Int(range.location + range.length)
                guard end > start else { continue }
                shaped.append(ShapedGlyph(
                    glyph: glyphs[i],
                    range: start..<end,
                    covered: String(decoding: utf16[start..<end], as: UTF16.self),
                    isQiulingFont: isQiuling,
                    point: isQiuling ? table[glyphs[i]] : nil
                ))
            }
        }
        return shaped.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    func encode(_ text: String) -> String {
        let source = Self.normalise(text)
        guard !source.isEmpty else { return source }
        var out = ""
        for glyph in shape(source) {
            let onlySpaces = glyph.covered.unicodeScalars.allSatisfy { $0.value == 0x20 }
            if !onlySpaces, let point = glyph.point, let scalar = Unicode.Scalar(point) {
                out.unicodeScalars.append(scalar)
            } else {
                out += lettersEncoded(glyph.covered)
            }
        }
        return out
    }

    /// `text` with each letter a–z replaced by its own point; anything else
    /// passes through.
    private func lettersEncoded(_ text: String) -> String {
        var out = ""
        for unit in text.utf16 {
            if let point = letterPoints[unit], let scalar = Unicode.Scalar(point) {
                out.unicodeScalars.append(scalar)
            } else if let scalar = Unicode.Scalar(UInt32(unit)) {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// Turns Latin text into the private-use scalars the font draws, so a
/// message reads as Qiuling in any app that has the font and in the app's own
/// bubbles. The work is `QiulingEncoderCore`'s; this owns the one table for
/// the process and builds it off the main queue.
final class QiulingEncoder {
    static let shared = QiulingEncoder()

    static let planeStart = QiulingEncoderCore.planeStart
    static let planeLength = QiulingEncoderCore.planeLength

    private(set) var isReady = false
    private var core: QiulingEncoderCore?
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
            let built = QiulingFont.shared.ctFont(size: 24).map {
                QiulingEncoderCore(font: $0, spaceVariantPoints: GroupMappings.shared.spaceVariantPoints)
            }
            DispatchQueue.main.async {
                self.core = built
                self.isReady = true
                let handlers = self.readyHandlers
                self.readyHandlers = []
                handlers.forEach { $0() }
            }
        }
    }

    static func normalise(_ text: String) -> String {
        QiulingEncoderCore.normalise(text)
    }

    func encode(_ text: String) -> String {
        guard isReady, let core else { return Self.normalise(text) }
        return core.encode(text)
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
