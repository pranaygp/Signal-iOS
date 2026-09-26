//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import Foundation
import SignalUI
import UIKit

// The reading trainer's engine, ported from the web trainer's `read.js`. No
// UI in here. A race is a queue of lines, a clock and a cursor: you see
// Qiuling and type Latin, and the interesting measurement falls out of the
// fact that one glyph carries two or three of the letters you type.

// MARK: - Segmenting

/// Splits text into exactly the glyphs the font draws.
///
/// The web trainer walks the ligature list, or the morpheme rules for a Morph
/// font. Here the font itself is asked: CoreText lays the word out in Qiuling
/// and each glyph's character range is a block. That agrees with what is on
/// screen whatever alphabet is current, with no second copy of the rules.
enum QiulingSegmenter {
    struct Block: Hashable {
        let text: String
        let range: Range<Int>   // character offsets in the line
        var isSpace: Bool { text == " " }
    }

    private static var cache = [String: [String]]()
    private static let lock = NSLock()

    static func segment(_ line: String) -> [Block] {
        var out = [Block]()
        var i = 0
        let chars = Array(line)
        while i < chars.count {
            if chars[i] == " " { out.append(Block(text: " ", range: i..<i + 1)); i += 1; continue }
            var j = i
            while j < chars.count, chars[j] != " " { j += 1 }
            let word = String(chars[i..<j])
            for piece in pieces(of: word) {
                out.append(Block(text: piece, range: i..<i + piece.count))
                i += piece.count
            }
        }
        return out
    }

    /// The glyph pieces of one word, by shaping it.
    static func pieces(of word: String) -> [String] {
        lock.lock(); if let hit = cache[word] { lock.unlock(); return hit }; lock.unlock()
        let font = UIFont(name: QiulingFonts.family, size: 32) ?? UIFont.systemFont(ofSize: 32)
        let attributed = NSAttributedString(string: word, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        var bounds = [Int]()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            bounds.append(contentsOf: indices)
        }
        bounds = Array(Set(bounds)).sorted()
        var result = [String]()
        let chars = Array(word)
        for (k, start) in bounds.enumerated() {
            let end = k + 1 < bounds.count ? bounds[k + 1] : chars.count
            if start < end, end <= chars.count { result.append(String(chars[start..<end])) }
        }
        if result.isEmpty { result = [word] }
        lock.lock(); cache[word] = result; lock.unlock()
        return result
    }

    static func clearCache() { lock.lock(); cache.removeAll(); gapCache = nil; lock.unlock() }

    private static var gapCache: String?

    /// The word space as the script's text views draw it: the space glyph by
    /// its private codepoint, then a zero-width space to break the line on.
    ///
    /// A U+0020 at the end of a line is whitespace to CoreText, so it hangs
    /// past the line's width instead of counting towards it — harmless in a
    /// face whose space is blank, but Qiuling's space is a drawn mark, and
    /// SwiftUI clips what hangs past the text's frame: the last space on a
    /// line was cut off, whole or in part. The same glyph under its private
    /// codepoint is not whitespace, so a line that ends on it is measured
    /// with it; the U+200B after it is where the line may break (the public
    /// site wraps its samples the same way). Same glyph, so the space's form
    /// and its kern still come out as the font chooses them. The codepoint is
    /// read off the font, which maps it to the same glyph as U+0020, so a
    /// font downloaded later is asked again (`clearCache`).
    static var wordGap: String {
        lock.lock(); if let hit = gapCache { lock.unlock(); return hit }; lock.unlock()
        let gap = findWordGap() ?? " "
        lock.lock(); gapCache = gap; lock.unlock()
        return gap
    }

    /// `text` with each U+0020 drawn as `wordGap`.
    static func gapped(_ text: String) -> String {
        let gap = wordGap
        return gap == " " ? text : text.replacingOccurrences(of: " ", with: gap)
    }

    private static func findWordGap() -> String? {
        guard let font = UIFont(name: QiulingFonts.family, size: 32) else { return nil }
        let ct = font as CTFont
        var space: CGGlyph = 0
        var sp: UniChar = 0x20
        guard CTFontGetGlyphsForCharacters(ct, &sp, &space, 1), space != 0 else { return nil }
        // The build files every private codepoint in plane 15.
        let lo: UInt32 = 0xF0000, hi: UInt32 = 0xFFFFD
        var units = [UniChar]()
        units.reserveCapacity(Int(hi - lo + 1) * 2)
        for cp in lo...hi {
            let v = cp - 0x10000
            units.append(UniChar(0xD800 + (v >> 10)))
            units.append(UniChar(0xDC00 + (v & 0x3FF)))
        }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        _ = CTFontGetGlyphsForCharacters(ct, units, &glyphs, units.count)
        for i in stride(from: 0, to: units.count, by: 2) where glyphs[i] == space {
            guard let scalar = Unicode.Scalar(lo + UInt32(i / 2)) else { continue }
            return String(scalar) + "\u{200B}"
        }
        return nil
    }

    /// Everything the font can draw, as a–z and single spaces.
    static func normalise(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "[’‘']", with: "", options: .regularExpression)
        let letters = lowered.replacingOccurrences(of: "[^a-z]+", with: " ", options: .regularExpression)
        return letters.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Corpus

/// Twenty thousand sentences to read, and lines of real words drawn from
/// them. Loaded once, off the main thread.
final class PracticeCorpus {
    static let shared = PracticeCorpus()

    private(set) var sentences: [String] = []
    private(set) var frequencies: [(word: String, count: Int)] = []
    private var loaded = false
    private var recent: [String] = []
    private var seen = Set<String>()

    func loadIfNeeded() async {
        if loaded { return }
        let text = await Task.detached(priority: .userInitiated) { () -> String in
            guard let url = Bundle.main.url(forResource: "corpus", withExtension: "txt") else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
        sentences = text.split(separator: "\n").map(String.init).filter { $0.count > 1 }
        var counts = [String: Int]()
        for s in sentences { for w in s.split(separator: " ") where !w.isEmpty { counts[String(w), default: 0] += 1 } }
        frequencies = counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        loaded = true
    }

    /// A sentence not seen in the last thousand: with 20,000 sentences that
    /// makes a repeat inside one sitting essentially impossible.
    func nextSentence() -> String {
        guard !sentences.isEmpty else { return "the quick brown fox jumps over the lazy dog" }
        for _ in 0..<24 {
            let s = sentences.randomElement()!
            if !seen.contains(s) {
                seen.insert(s); recent.append(s)
                while recent.count > 1000 { seen.remove(recent.removeFirst()) }
                return s
            }
        }
        return sentences.randomElement()!
    }

    /// A line of real words in random order, about a sentence long, drawn from
    /// the 1,500 commonest weighted by frequency^0.85 — the hundred commonest
    /// get about half of all draws, their share of running English.
    private lazy var wordPicker: () -> String = {
        let vocab = Array(frequencies.prefix(1500))
        var cum = [Double](); var t = 0.0
        for (_, c) in vocab { t += pow(Double(c), 0.85); cum.append(t) }
        return {
            guard !vocab.isEmpty else { return "the" }
            let r = Double.random(in: 0..<t)
            var lo = 0, hi = cum.count - 1
            while lo < hi { let m = (lo + hi) / 2; if cum[m] < r { lo = m + 1 } else { hi = m } }
            return vocab[lo].word
        }
    }()

    func nextWordLine() -> String {
        var out = ""
        while out.count < 44 { out += (out.isEmpty ? "" : " ") + wordPicker() }
        return out
    }
}

// MARK: - Race

/// Stands in `typed` for a letter the space bar skipped over: never a letter
/// or a space, so it can only ever compare as wrong.
let raceSkip: Character = "·"

final class Race {
    struct Mark {
        let text: String
        let got: String
        let complete: Bool
        let decode: TimeInterval?   // block became current → first keystroke
        let total: TimeInterval
        let clean: Bool
    }
    struct Line {
        let text: String
        let blocks: [QiulingSegmenter.Block]
        var typed: String = ""
    }
    struct Key { let at: TimeInterval; let ok: Bool }

    let seconds: TimeInterval
    private let next: () -> String
    private(set) var lines: [Line] = []
    private(set) var lineIndex = 0
    private(set) var typed = ""
    private(set) var extra = ""
    private(set) var keys = 0, hits = 0, done = 0
    private(set) var marks: [Mark] = []
    private var firstSeen: [Int: Character] = [:]
    private(set) var keyLog: [Key] = []
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?

    private var lastBlock: QiulingSegmenter.Block?
    private var enteredAt: Date?
    private var firstKeyAt: Date?
    private var dirty = false

    init(seconds: TimeInterval, next: @escaping () -> String) {
        self.seconds = seconds
        self.next = next
        for _ in 0..<3 { lines.append(line(next())) }
    }

    private func line(_ text: String) -> Line { Line(text: text, blocks: QiulingSegmenter.segment(text)) }
    var current: Line { lines[lineIndex] }
    private var currentChars: [Character] { Array(current.text) }
    private func block(at pos: Int) -> QiulingSegmenter.Block? { current.blocks.first { $0.range.contains(pos) } }

    var isOver: Bool { endedAt != nil }
    func elapsed(_ now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return (endedAt ?? now).timeIntervalSince(startedAt)
    }
    func remaining(_ now: Date = Date()) -> TimeInterval { max(0, seconds - elapsed(now)) }
    func finish(_ now: Date = Date()) { if endedAt == nil { endedAt = now } }

    private func crossInto(_ b: QiulingSegmenter.Block?, _ now: Date) {
        if let enteredAt, let was = lastBlock, !was.isSpace {
            var got = ""; var complete = true
            for p in was.range {
                if firstSeen[p] == nil { complete = false }
                got.append(firstSeen[p] ?? raceSkip)
            }
            marks.append(Mark(
                text: was.text, got: got, complete: complete,
                decode: firstKeyAt.map { $0.timeIntervalSince(enteredAt) },
                total: now.timeIntervalSince(enteredAt), clean: !dirty,
            ))
        }
        lastBlock = b; enteredAt = now; firstKeyAt = nil; dirty = false
    }

    private func start(_ now: Date) {
        startedAt = now
        crossInto(current.blocks.first, now)
    }

    private func stroke(_ ok: Bool, _ now: Date) {
        keys += 1
        if ok { hits += 1 } else { dirty = true }
        keyLog.append(Key(at: now.timeIntervalSince(startedAt!), ok: ok))
        if firstKeyAt == nil { firstKeyAt = now }
    }

    /// One keystroke: a character, or nil for backspace. Returns true when
    /// the race is over. The space bar is the resync point, as on every
    /// typing site — see the web engine for the full reasoning.
    @discardableResult
    func key(_ ch: Character?, _ now: Date = Date()) -> Bool {
        if endedAt != nil { return true }
        if startedAt == nil { start(now) }
        let text = currentChars
        let pos = typed.count

        guard let ch else {
            if !extra.isEmpty { extra.removeLast() } else if pos > 0 { typed.removeLast() }
            return false
        }

        let boundary = pos >= text.count || text[pos] == " "
        var endLine = false

        if ch == " ", !boundary || !extra.isEmpty {
            if extra.isEmpty, pos == 0 || text[pos - 1] == " " { return false }
            var sp = pos; while sp < text.count, text[sp] != " " { sp += 1 }
            stroke(false, now)
            extra = ""
            for p in pos..<sp {
                if firstSeen[p] == nil { firstSeen[p] = raceSkip }
                typed.append(raceSkip)
                if let b = block(at: p), b != lastBlock { crossInto(b, now) }
            }
            if sp < text.count { typed.append(" ") } else { endLine = true }
        } else if ch != " ", boundary {
            if extra.count < 8 { stroke(false, now); extra.append(ch) }
            return elapsed(now) >= seconds
        } else if pos >= text.count {
            stroke(true, now)
            endLine = true
        } else {
            stroke(ch == text[pos], now)
            if firstSeen[pos] == nil { firstSeen[pos] = ch }
            typed.append(ch)
        }

        if endLine {
            let typedChars = Array(typed)
            for p in 0..<text.count where p < typedChars.count && typedChars[p] == text[p] { done += 1 }
            done += 1
            lines[lineIndex].typed = typed
            lineIndex += 1
            typed = ""; extra = ""; firstSeen = [:]
            while lines.count < lineIndex + 3 { lines.append(line(next())) }
            crossInto(current.blocks.first, now)
            return elapsed(now) >= seconds
        }

        if let after = block(at: typed.count), after != lastBlock { crossInto(after, now) }
        return elapsed(now) >= seconds
    }

    struct Stats { let wpm: Int; let accuracy: Int; let chars: Int; let seconds: TimeInterval; let blocks: Int; let misread: Int }

    func stats(_ now: Date = Date()) -> Stats {
        let mins = max(elapsed(now), 0.001) / 60
        let text = currentChars
        let correct = done + Array(typed).enumerated().filter { $0.offset < text.count && $0.element == text[$0.offset] }.count
        return Stats(
            wpm: Int((Double(correct) / 5 / mins).rounded()),
            accuracy: keys > 0 ? Int((Double(hits) / Double(keys) * 100).rounded()) : 100,
            chars: correct, seconds: elapsed(now), blocks: marks.count,
            misread: marks.filter { $0.complete && $0.got != $0.text }.count,
        )
    }

    struct Second { let s: Int; let raw: Int; let avg: Int; let err: Int }

    func series(_ now: Date = Date()) -> [Second] {
        let n = Int(elapsed(now))
        var out = [Second](); var hits = 0; var i = 0
        for s in 1...max(n, 1) where s <= n {
            var ok = 0, err = 0
            while i < keyLog.count, keyLog[i].at < Double(s) { if keyLog[i].ok { ok += 1 } else { err += 1 }; i += 1 }
            hits += ok
            out.append(Second(s: s, raw: ok * 12, avg: Int((Double(hits) / 5 / (Double(s) / 60)).rounded()), err: err))
        }
        return out
    }

    struct Misreading: Identifiable { let text: String; let got: String; let n: Int; var id: String { text + "→" + got } }

    func misreadings() -> [Misreading] {
        var by = [String: (String, String, Int)]()
        for m in marks where m.complete && m.got != m.text {
            let k = m.text + "\u{0}" + m.got
            by[k] = (m.text, m.got, (by[k]?.2 ?? 0) + 1)
        }
        return by.values.map { Misreading(text: $0.0, got: $0.1, n: $0.2) }.sorted { $0.n > $1.n }
    }

    struct Slow: Identifiable { let text: String; let ms: Int; let n: Int; var id: String { text } }

    /// Slowest blocks by median decode time, clean attempts only.
    func slowest(min: Int = 2) -> [Slow] {
        var by = [String: [TimeInterval]]()
        for m in marks { if let d = m.decode, m.clean { by[m.text, default: []].append(d) } }
        return by.filter { $0.value.count >= min }.map { t, v in
            let s = v.sorted(); return Slow(text: t, ms: Int((s[s.count / 2] * 1000).rounded()), n: v.count)
        }.sorted { $0.ms > $1.ms }
    }
}

// MARK: - Recall drill

/// The flash-card side of the trainer: every drawn block is an item, asked in
/// both directions, scheduled by Leitner box so the marks you keep missing
/// come round more often than the ones you have down. Shared with the web
/// trainer's `stats.js` rule for rule.
enum Recall {
    enum Direction: String, Codable, CaseIterable {
        case read, write
        var caption: String { self == .read ? "what does this say?" : "which mark is this?" }
    }
    enum Mode: String, CaseIterable {
        case both, read, write
        var direction: Direction? { switch self { case .both: nil; case .read: .read; case .write: .write } }
    }
    enum Label: Int, Comparable {
        case struggling, learning, mastered, new
        static func < (a: Label, b: Label) -> Bool { a.rawValue < b.rawValue }
        var name: String { switch self { case .new: "new"; case .struggling: "struggling"; case .learning: "learning"; case .mastered: "mastered" } }
    }

    /// Three wrong answers that look like the right one: same length and one
    /// letter different where the alphabet allows, then same length, then
    /// anything. The choice should be between look-alikes, not mark and noise.
    static func decoys(for answer: String, in blocks: [String]) -> [String] {
        let a = Array(answer)
        let sameLength = blocks.filter { $0 != answer && $0.count == answer.count }
        var out = [String]()
        var pool = sameLength.filter { zip(Array($0), a).filter { $0 != $1 }.count == 1 }.shuffled()
        out.append(contentsOf: pool.prefix(3))
        if out.count < 3 {
            pool = sameLength.filter { !out.contains($0) }.shuffled()
            out.append(contentsOf: pool.prefix(3 - out.count))
        }
        if out.count < 3 {
            pool = blocks.filter { $0 != answer && !out.contains($0) }.shuffled()
            out.append(contentsOf: pool.prefix(3 - out.count))
        }
        return out
    }

    private static let boxWeight: [Double] = [8, 5, 3, 2, 1, 0.5]

    /// How keen the drill is to show one card. Unseen items sit near the top
    /// so everything gets introduced; a slow-but-right item is nudged up.
    static func weight(_ r: PracticeStore.RecallRecord) -> Double {
        var w = r.seen == 0 ? 6 : boxWeight[min(5, max(0, r.box))]
        if let ms = r.msMean, ms > 2500 { w *= 1.5 }
        return w
    }

    /// The next card, sampled in proportion to weight over every (mark,
    /// direction) the mode allows. The last three marks are held out so a
    /// mark never comes straight back, unless the alphabet is too small for that.
    static func pick(blocks: [String], mode: Mode, book: PracticeStore.Book, recent: [String]) -> (mark: String, direction: Direction)? {
        guard !blocks.isEmpty else { return nil }
        let directions = mode.direction.map { [$0] } ?? Direction.allCases
        let holdOut = blocks.count >= 4 ? Set(recent.suffix(3)) : []
        var candidates = [(String, Direction, Double)]()
        for b in blocks where !holdOut.contains(b) {
            for d in directions { candidates.append((b, d, weight(book.recall[b]?[d] ?? .init()))) }
        }
        let total = candidates.reduce(0) { $0 + $1.2 }
        guard total > 0 else { return nil }
        var r = Double.random(in: 0..<total)
        for (b, d, w) in candidates { r -= w; if r < 0 { return (b, d) } }
        let last = candidates.last!
        return (last.0, last.1)
    }

    /// Where a mark stands, judged by its weaker direction.
    static func label(_ item: PracticeStore.RecallItem?) -> Label {
        guard let item, item.read.seen > 0 || item.write.seen > 0 else { return .new }
        func one(_ r: PracticeStore.RecallRecord) -> Label {
            if r.box >= 5 { return .mastered }
            if r.box == 0, r.seen >= 2 { return .struggling }
            return .learning
        }
        return min(one(item.read), one(item.write))
    }
}

// MARK: - Stats between sittings

/// The microphone is switched off for now: the recogniser cannot tell "I"
/// from "eye", and its scoring is not yet worth the noise it adds. The code
/// stays behind this switch; a reading is the reader's time alone.
enum PracticeFeatures {
    static let microphone = false
}

/// What the trainer remembers: one row per race, and per mark how often it
/// was met, misread, and how long it took to recognise. Namespaced by
/// alphabet, since pooling two would average unrelated skills.
final class PracticeStore: ObservableObject {
    static let shared = PracticeStore()

    struct Session: Codable, Identifiable {
        var id = UUID()
        let date: Date
        /// The clock set for a typed race; the time taken for a reading.
        let seconds: Int
        /// sentences | words for the typed race; read | read-test | read-english
        /// for reading aloud. Typed and spoken speeds never share a chart.
        let mode: String
        let wpm: Int
        let accuracy: Int
        let chars: Int
        let misread: Int
        /// A reading's passage length. Files from before there were readings
        /// have no such key, and decode it as nil.
        var words: Int? = nil
        /// Whether a recogniser scored the reading: true → wpm is words
        /// correct, false → words read, nil → a row from before the flag.
        var listened: Bool? = nil
        /// The passage read, `book:run:start`, so a later English reading of
        /// the same excerpt can be found. Typed rows have none.
        var excerptID: String? = nil
        /// Cumulative exposure to the script as it stood when this session
        /// ended, in seconds and in marks read; the x of the learning curve.
        /// Sessions from before the field are restamped on load.
        var cumSecs: Int? = nil
        var cumMarks: Int? = nil

        var isReading: Bool { mode.hasPrefix("read") }
        /// Everything in the script counts; the English baselines are the
        /// mouth's or the fingers' speed and count for nothing here.
        var isExposure: Bool { !mode.hasSuffix("english") }
    }
    /// The running total of practice. Kept beside the session list because
    /// that list is trimmed, and a learning curve against cumulative practice
    /// has to keep counting past the trim.
    struct Exposure: Codable {
        var runs = 0
        var secs = 0
        var marks = 0
    }
    struct MarkRecord: Codable {
        var seen = 0
        var wrong = 0
        var decodeSum: Double = 0
        var decodeN = 0
        var meanDecodeMs: Int? { decodeN > 0 ? Int(decodeSum / Double(decodeN) * 1000) : nil }
    }
    /// One direction of the recall drill for one mark: a Leitner box and the
    /// running numbers behind it. Mirrors the web trainer's record field for
    /// field so the two can be compared, or one day merged.
    struct RecallRecord: Codable {
        var box = 0
        var seen = 0
        var right = 0
        var streak = 0
        var msMean: Double?
        var last: Double?
        var confusions: [String: Int] = [:]

        var accuracy: Int? { seen > 0 ? Int((Double(right) / Double(seen) * 100).rounded()) : nil }
        var topConfusion: String? { confusions.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key }
    }
    struct RecallItem: Codable {
        var read = RecallRecord()
        var write = RecallRecord()
        subscript(_ d: Recall.Direction) -> RecallRecord {
            get { d == .read ? read : write }
            set { if d == .read { read = newValue } else { write = newValue } }
        }
    }
    struct Book: Codable {
        var sessions: [Session] = []
        var marks: [String: MarkRecord] = [:]
        var recall: [String: RecallItem] = [:]
        var total = Exposure()

        init() {}

        // Files written before the drill existed have no `recall` key, and
        // those from before the learning curve have no `total`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
            marks = try c.decodeIfPresent([String: MarkRecord].self, forKey: .marks) ?? [:]
            recall = try c.decodeIfPresent([String: RecallItem].self, forKey: .recall) ?? [:]
            if let t = try c.decodeIfPresent(Exposure.self, forKey: .total), sessions.allSatisfy({ $0.cumSecs != nil }) {
                total = t
            } else {
                restamp()
            }
        }

        /// Rebuild the total from the sessions and stamp each with it — exact
        /// for a book that has never been trimmed, which is every book so far.
        mutating func restamp() {
            var t = Exposure()
            for i in sessions.indices {
                if sessions[i].isExposure {
                    t.runs += 1; t.secs += sessions[i].seconds; t.marks += sessions[i].words ?? sessions[i].chars
                }
                sessions[i].cumSecs = t.secs; sessions[i].cumMarks = t.marks
            }
            total = t
        }

        /// Fold one session in: the total first, then the row stamped with it.
        mutating func append(_ s: Session, marks: Int) {
            var s = s
            if s.isExposure { total.runs += 1; total.secs += s.seconds; total.marks += marks }
            s.cumSecs = total.secs; s.cumMarks = total.marks
            sessions.append(s)
            if sessions.count > 2000 { sessions.removeFirst(sessions.count - 2000) }
        }
    }

    @Published private(set) var book = Book()
    private let build = QiulingFonts.buildId

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Practice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(build).json")
    }

    init() {
        if let data = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(Book.self, from: data) { book = b }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: url, options: .atomic) }
    }

    func record(race: Race, mode: String) {
        let s = race.stats()
        guard s.seconds >= 5 else { return }
        book.append(Session(date: Date(), seconds: Int(race.seconds), mode: mode, wpm: s.wpm, accuracy: s.accuracy, chars: s.chars, misread: s.misread), marks: s.blocks)
        for m in race.marks where m.complete {
            var r = book.marks[m.text] ?? MarkRecord()
            r.seen += 1
            if m.got != m.text { r.wrong += 1 }
            if let d = m.decode, m.clean { r.decodeSum += d; r.decodeN += 1 }
            book.marks[m.text] = r
        }
        save()
    }

    func reset() { book = Book(); save() }

    func recall(_ mark: String, _ d: Recall.Direction) -> RecallRecord { book.recall[mark]?[d] ?? RecallRecord() }

    /// One answered card. A right answer climbs one box; a wrong one falls
    /// two, so a mark you thought you knew comes back soon. The response time
    /// is folded into a moving mean, clamped so a wander away from the phone
    /// does not count as a slow read.
    func recallAnswer(mark: String, direction d: Recall.Direction, picked: String, ms: Double) {
        var item = book.recall[mark] ?? RecallItem()
        var r = item[d]
        let clamped = min(8000, max(0, ms))
        r.msMean = r.msMean.map { $0 * 0.7 + clamped * 0.3 } ?? clamped
        r.last = Date().timeIntervalSince1970 * 1000
        r.seen += 1
        if picked == mark {
            r.right += 1; r.streak += 1; r.box = min(5, r.box + 1)
        } else {
            r.streak = 0; r.box = max(0, r.box - 2); r.confusions[picked, default: 0] += 1
        }
        item[d] = r
        book.recall[mark] = item
        save()
    }

    /// One reading, saved unless it was too short to mean anything.
    func record(reading r: ReadResult, mode: String) {
        guard r.seconds >= 3 else { return }
        book.append(Session(
            date: Date(), seconds: Int(r.seconds.rounded()), mode: mode, wpm: r.wpm,
            accuracy: r.accuracy, chars: 0, misread: r.errors, words: r.words,
            // With the microphone switched off a reading is neither scored nor
            // unscored; the flag stays empty so old scored runs pair with it freely.
            listened: PracticeFeatures.microphone ? r.listened : nil, excerptID: r.excerpt.key,
        ), marks: r.words)
        save()
    }

    /// Practice so far, in the script, all modes: "48 min" or "2.7 h".
    var exposureText: String { LearningCurve.minutes(Double(book.total.secs) / 60) }

    var typedSessions: [Session] { book.sessions.filter { !$0.isReading } }
    var readSessions: [Session] { book.sessions.filter { $0.isReading && $0.mode != "read-english" } }
    var readTests: [Session] { book.sessions.filter { $0.mode == "read-test" } }
    var englishReadings: [Session] { book.sessions.filter { $0.mode == "read-english" } }
    /// Every run in the script, typed and spoken: the x of the learning curve
    /// and the clock the break table reads gaps from.
    var exposureSessions: [Session] { book.sessions.filter(\.isExposure) }

    /// The typed race's best, as before.
    var best: Int { typedSessions.map(\.wpm).max() ?? 0 }

    // MARK: The share of English, aloud

    /// One Qiuling test against its English baseline. The baseline is the
    /// median of up to three English readings taken within two weeks before
    /// the test (or in the same sitting after it), like-for-like on the
    /// microphone where the flag is known. Mirrors `ratioSeries` in the web
    /// trainer's `stats.js`; the two must agree to the integer.
    struct RatioPoint: Identifiable {
        let id: UUID
        let date: Date
        let wpm: Int
        let accuracy: Int
        let listened: Bool?
        /// Qiuling ÷ English, in percent; nil when there is no English at all.
        let percent: Int?
        /// The trailing mean of the last three percents: the headline.
        var trend: Int?
        let baseline: Int?
        let baselineN: Int
        let baselineAt: Date?
        let ageDays: Int
        /// Every English reading came after the sitting.
        let provisional: Bool
        /// The nearest English reading was older than two weeks.
        let stale: Bool
        /// The pool and the test disagree on the microphone.
        let mixed: Bool
        var scored: Bool { listened == true && !mixed }
        /// Drawn as an open dot: read loosely.
        var hollow: Bool { stale || provisional || (PracticeFeatures.microphone && (mixed || listened == false)) }
    }
    struct RatioSeries {
        let points: [RatioPoint]
        /// Percentage points a week, by least squares, once four tests span two weeks.
        let slope: Double?
        let headline: Int?
        let delta: Int?
        let baselineN: Int
        let englishAt: Date?
        let tests: Int
        let unpaired: Int
    }

    private static let sittingMs: Int64 = 7_200_000
    private static let freshMs: Int64 = 1_209_600_000
    private static let poolSize = 3
    private static let trendMinN = 4
    private static let trendMinSpanMs: Int64 = freshMs

    /// The middle value, or the mean of the two middle ones. Never rounded.
    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    func ratioSeries(test: String = "read-test", base: String = "read-english", now: Date = Date()) -> RatioSeries {
        func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
        let asc = book.sessions.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
        let tests = asc.filter { $0.mode == test && $0.wpm > 0 }
        let bases = asc.filter { $0.mode == base && $0.wpm > 0 }

        var points = [RatioPoint]()
        var valid = [Int]()
        var unpaired = 0
        for t in tests {
            let tAt = ms(t.date)
            var cand = bases.filter { ms($0.date) <= tAt + Self.sittingMs }
            var provisional = false
            if cand.isEmpty, !bases.isEmpty { cand = bases; provisional = true }
            if let l = t.listened {
                let same = cand.filter { $0.listened == l }
                if !same.isEmpty { cand = same }
            }
            let pool: [Session]
            if provisional {
                pool = Array(cand.prefix(Self.poolSize))
            } else {
                let fresh = cand.filter { ms($0.date) >= tAt - Self.freshMs }
                pool = fresh.isEmpty ? (cand.last.map { [$0] } ?? []) : Array(fresh.suffix(Self.poolSize))
            }
            guard !pool.isEmpty else {
                points.append(RatioPoint(
                    id: t.id, date: t.date, wpm: t.wpm, accuracy: t.accuracy, listened: t.listened,
                    percent: nil, trend: nil, baseline: nil, baselineN: 0, baselineAt: nil, ageDays: 0,
                    provisional: false, stale: false, mixed: false,
                ))
                unpaired += 1
                continue
            }
            let baseline = Self.median(pool.map { Double($0.wpm) })
            let pct = Int((100 * Double(t.wpm) / baseline).rounded())
            let baselineAt = pool.map { ms($0.date) }.max()!
            let ageDays = max(0, Int(floor(Double(tAt - baselineAt) / 864e5)))
            let stale = !provisional && (tAt - baselineAt) > Self.freshMs
            let mixed = pool.contains { $0.listened != nil && t.listened != nil && $0.listened != t.listened }
            valid.append(pct)
            let window = valid.suffix(min(3, valid.count))
            let trend = Int((Double(window.reduce(0, +)) / Double(window.count)).rounded())
            points.append(RatioPoint(
                id: t.id, date: t.date, wpm: t.wpm, accuracy: t.accuracy, listened: t.listened,
                percent: pct, trend: trend, baseline: Int(baseline.rounded()), baselineN: pool.count,
                baselineAt: Date(timeIntervalSince1970: Double(baselineAt) / 1000), ageDays: ageDays,
                provisional: provisional, stale: stale, mixed: mixed,
            ))
        }

        let v = points.filter { $0.percent != nil }
        var slope: Double?
        if let first = v.first, let last = v.last, v.count >= Self.trendMinN, ms(last.date) - ms(first.date) >= Self.trendMinSpanMs {
            let t0 = ms(first.date)
            let xs = v.map { Double(ms($0.date) - t0) / 604_800_000 }
            let ys = v.map { Double($0.percent!) }
            let n = Double(v.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var sxy = 0.0, sxx = 0.0
            for i in v.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
            if sxx > 1e-9 { slope = sxy / sxx }
        }
        let headline = v.last?.trend
        let delta: Int? = v.count >= 2 ? headline.flatMap { h in v[v.count - 2].trend.map { h - $0 } } : nil
        return RatioSeries(
            points: points, slope: slope, headline: headline, delta: delta, baselineN: v.last?.baselineN ?? 0,
            englishAt: bases.last?.date, tests: tests.count, unpaired: unpaired,
        )
    }

    /// The goal, aloud, read off `ratioSeries`: the Qiuling test against the
    /// English test on the same kind of passage. The mouth is in both, so what
    /// is left is the script; 100 is the daily-driver line.
    struct ReadingGoal {
        let qiuling: Int?
        let english: Int?
        let percent: Int?
        let delta: Int?
        let baselineN: Int
        let englishAt: Date?
        let tests: Int
        let scored: Bool
        let misreadPercent: Int?
    }
    var readingGoal: ReadingGoal {
        let r = ratioSeries()
        let recent = readTests.suffix(3)
        let scored = recent.filter { $0.listened == true }
        func mean(_ xs: [Int]) -> Double { Double(xs.reduce(0, +)) / Double(xs.count) }
        return ReadingGoal(
            qiuling: recent.isEmpty ? nil : Int(mean(recent.map(\.wpm)).rounded()),
            english: r.points.last?.baseline,
            percent: r.headline, delta: r.delta, baselineN: r.baselineN, englishAt: r.englishAt, tests: r.tests,
            scored: r.points.last?.scored ?? false,
            misreadPercent: scored.isEmpty ? nil : Int((100 - mean(scored.map(\.accuracy))).rounded()),
        )
    }

    /// Marks you get wrong most, with enough sightings to mean something.
    func hardest(min: Int = 3) -> [(text: String, record: MarkRecord)] {
        book.marks.filter { $0.value.seen >= min && $0.value.wrong > 0 }
            .sorted { Double($0.value.wrong) / Double($0.value.seen) > Double($1.value.wrong) / Double($1.value.seen) }
            .map { ($0.key, $0.value) }
    }
}

// MARK: - The learning curve

/// Kolers (1975) had students read up to 160 pages of inverted text: the log
/// of their reading time fell in a straight line against the log of pages
/// read — a power law — and they neared normal speed inside those pages.
/// Kolers (1976) brought them back after a year and the skill had kept. So
/// the two questions to keep asking are: is my curve straight on log axes,
/// and what does a break cost? The web trainer's `stats.js` asks the same
/// two, the same way, so the phone's numbers match the browser's.
enum LearningCurve {
    struct Point: Identifiable {
        let id: UUID
        let minutes: Double
        let wpm: Int
        let date: Date
    }
    struct Fit {
        let points: [Point]
        /// The exponent: at 0.3, ten times the practice buys about double the speed.
        let k: Double
        let a: Double
        let r2: Double
        func predict(_ minutes: Double) -> Double { exp(a + k * log(minutes)) }
        /// Minutes of exposure at which the line reaches `wpm`; nil when it is
        /// flat or falling, since then it never does.
        func minutesTo(_ wpm: Int) -> Double? {
            guard k > 0.01, wpm > 0 else { return nil }
            return exp((log(Double(wpm)) - a) / k)
        }
    }

    static func points(_ sessions: [PracticeStore.Session]) -> [Point] {
        sessions.compactMap { s in
            guard let c = s.cumSecs, c > 0, s.wpm > 0 else { return nil }
            return Point(id: s.id, minutes: Double(c) / 60, wpm: s.wpm, date: s.date)
        }
    }

    /// Least squares of log(wpm) on log(minutes). Three runs and some spread
    /// in x, or nothing: two runs a minute apart fit any line at all.
    static func powerLaw(_ sessions: [PracticeStore.Session]) -> Fit? {
        let pts = points(sessions)
        guard pts.count >= 3 else { return nil }
        let lx = pts.map { log($0.minutes) }, ly = pts.map { log(Double($0.wpm)) }
        let n = Double(pts.count)
        let mx = lx.reduce(0, +) / n, my = ly.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in pts.indices {
            sxy += (lx[i] - mx) * (ly[i] - my); sxx += (lx[i] - mx) * (lx[i] - mx); syy += (ly[i] - my) * (ly[i] - my)
        }
        guard sxx > 1e-6 else { return nil }
        let k = sxy / sxx
        return Fit(points: pts, k: k, a: my - k * mx, r2: syy > 0 ? sxy * sxy / (sxx * syy) : 0)
    }

    struct Break: Identifiable {
        /// The gap's end. Gaps sharing one first-back row are folded into one.
        let id: Date
        /// When the first of the series came back, as the web's "back on".
        let date: Date
        var days: Int
        /// Mean speed of the three runs before the gap, the first run back,
        /// and the mean of the three after it.
        let before: Int
        let first: Int
        let after: Int
        var firstPercent: Int { before > 0 ? Int((Double(first) / Double(before) * 100).rounded()) : 0 }
        var afterPercent: Int { before > 0 ? Int((Double(after) / Double(before) * 100).rounded()) : 0 }
    }

    /// Every gap of `minDays` or more in `exposure` — all practice in the
    /// script, typed and spoken — scored on `series`: the last three of it
    /// before the gap, the first of it after, and the three after that. A gap
    /// with nothing of the series on one side is skipped. Potter lost her
    /// cipher over decades away; Kolers' readers kept theirs across a year.
    /// Where you sit shows up as `first` against `before`, break by break.
    static func breaks(exposure: [PracticeStore.Session], series: [PracticeStore.Session], minDays: Int = 2) -> [Break] {
        var out: [Break] = []
        func mean(_ s: [PracticeStore.Session]) -> Int {
            s.isEmpty ? 0 : Int((Double(s.map(\.wpm).reduce(0, +)) / Double(s.count)).rounded())
        }
        for i in 1..<max(1, exposure.count) {
            let gapStart = exposure[i - 1].date, gapEnd = exposure[i].date
            let days = gapEnd.timeIntervalSince(gapStart) / 86400
            guard days >= Double(minDays) else { continue }
            let pre = Array(series.filter { $0.date <= gapStart }.suffix(3))
            let post = Array(series.filter { $0.date >= gapEnd }.prefix(3))
            guard !pre.isEmpty, let firstBack = post.first else { continue }
            // Several gaps with nothing of the series between them are one
            // absence as far as the series can tell: keep the longest.
            if let dup = out.firstIndex(where: { $0.date == firstBack.date }) {
                out[dup].days = max(out[dup].days, Int(days.rounded())); continue
            }
            out.append(Break(
                id: gapEnd, date: firstBack.date, days: Int(days.rounded()),
                before: mean(pre), first: firstBack.wpm, after: mean(post)
            ))
        }
        return out
    }

    /// "48 min" under an hour and a half, "2.7 h" past it.
    static func minutes(_ m: Double) -> String {
        m < 90 ? "\(Int(m.rounded())) min" : String(format: "%.1f h", m / 60)
    }
}
