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

    static func clearCache() { lock.lock(); cache.removeAll(); lock.unlock() }

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

/// What the trainer remembers: one row per race, and per mark how often it
/// was met, misread, and how long it took to recognise. Namespaced by
/// alphabet, since pooling two would average unrelated skills.
final class PracticeStore: ObservableObject {
    static let shared = PracticeStore()

    struct Session: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let seconds: Int
        let mode: String
        let wpm: Int
        let accuracy: Int
        let chars: Int
        let misread: Int
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

        init() {}

        // Files written before the drill existed have no `recall` key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
            marks = try c.decodeIfPresent([String: MarkRecord].self, forKey: .marks) ?? [:]
            recall = try c.decodeIfPresent([String: RecallItem].self, forKey: .recall) ?? [:]
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
        book.sessions.append(Session(date: Date(), seconds: Int(race.seconds), mode: mode, wpm: s.wpm, accuracy: s.accuracy, chars: s.chars, misread: s.misread))
        if book.sessions.count > 2000 { book.sessions.removeFirst(book.sessions.count - 2000) }
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

    var best: Int { book.sessions.map(\.wpm).max() ?? 0 }

    /// Marks you get wrong most, with enough sightings to mean something.
    func hardest(min: Int = 3) -> [(text: String, record: MarkRecord)] {
        book.marks.filter { $0.value.seen >= min && $0.value.wrong > 0 }
            .sorted { Double($0.value.wrong) / Double($0.value.seen) > Double($1.value.wrong) / Double($1.value.seen) }
            .map { ($0.key, $0.value) }
    }
}
