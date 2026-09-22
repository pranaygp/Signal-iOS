//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - Passages

/// Real excerpts to read: consecutive sentences from one book, kept as
/// printed, with the book they came from. The web trainer's
/// `tools/build_passages.py` writes `passages.json`; the corpus's shuffled
/// single sentences are five unrelated books in a row, and there is nothing
/// in that to have understood. After a run the English is shown back with its
/// source, so a reading in the script can be checked against what was taken
/// in.
final class PracticePassages {
    static let shared = PracticePassages()

    struct Book: Decodable { let title: String; let author: String }
    struct Run: Decodable { let b: Int; let s: [String] }
    private struct File: Decodable { let books: [String: Book]; let runs: [Run] }

    /// One excerpt as it will be read: the printed sentences, their a–z words,
    /// and where they came from.
    struct Excerpt {
        let sentences: [String]
        let book: Int
        let title: String
        let author: String
        var words: [String] { sentences.flatMap(PracticePassages.words) }
        var url: URL { URL(string: "https://www.gutenberg.org/ebooks/\(book)")! }
        var citation: String { author.isEmpty ? title : "\(author), \(title)" }
    }

    private(set) var books: [String: Book] = [:]
    private(set) var runs: [Run] = []
    private(set) var loaded = false
    private var recent: [Int] = []

    /// The a–z words of one printed sentence, by the corpus's own rule.
    static func words(_ raw: String) -> [String] {
        QiulingSegmenter.normalise(raw).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    func loadIfNeeded() async {
        if loaded { return }
        let file = await Task.detached(priority: .userInitiated) { () -> File? in
            guard let url = Bundle.main.url(forResource: "passages", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(File.self, from: data)
        }.value
        books = file?.books ?? [:]
        runs = file?.runs ?? []
        loaded = true
    }

    var isAvailable: Bool { !runs.isEmpty }

    /// A run not read lately, with at least `min` words.
    private func pickRun(min: Int = 0) -> (index: Int, run: Run)? {
        guard !runs.isEmpty else { return nil }
        for _ in 0..<40 {
            let i = Int.random(in: 0..<runs.count)
            if recent.contains(i) { continue }
            let run = runs[i]
            if run.s.reduce(0, { $0 + PracticePassages.words($1).count }) < min { continue }
            recent.append(i)
            if recent.count > 60 { recent.removeFirst() }
            return (i, run)
        }
        return nil
    }

    private func excerpt(_ run: Run, sentences: [String]) -> Excerpt {
        let book = books[String(run.b)]
        return Excerpt(sentences: sentences, book: run.b, title: book?.title ?? "", author: book?.author ?? "")
    }

    /// About `n` words of one excerpt: whole sentences from a random start,
    /// to the end of the sentence that crosses `n`.
    func excerpt(words n: Int) -> Excerpt? {
        guard let (_, run) = pickRun(min: n) else { return nil }
        let counts = run.s.map { PracticePassages.words($0).count }
        let total = counts.reduce(0, +)
        var starts = [Int]()
        var rest = total
        for i in run.s.indices { if rest >= n { starts.append(i) }; rest -= counts[i] }
        let start = starts.randomElement() ?? 0
        var out = [String](); var got = 0
        for i in start..<run.s.count where got < n { out.append(run.s[i]); got += counts[i] }
        return excerpt(run, sentences: out)
    }

    /// Sentences for the typing race, in order, one excerpt after another.
    /// What it hands out is remembered so the results can show the English of
    /// exactly the lines that were read.
    final class Feed {
        private let passages: PracticePassages
        private var current: Run?
        private var index = 0
        private(set) var served: [(raw: String, run: Run)] = []

        init(_ passages: PracticePassages) { self.passages = passages }

        func next() -> String {
            if current == nil || index >= (current?.s.count ?? 0) {
                current = passages.pickRun()?.run
                index = 0
            }
            guard let run = current else { return PracticeCorpus.shared.nextSentence() }
            let raw = run.s[index]; index += 1
            served.append((raw, run))
            return PracticePassages.words(raw).joined(separator: " ")
        }

        /// The first `n` served lines, grouped into excerpts by book.
        func excerpts(first n: Int) -> [Excerpt] {
            var out = [Excerpt]()
            for (raw, run) in served.prefix(n) {
                if let last = out.last, last.book == run.b {
                    out[out.count - 1] = Excerpt(sentences: last.sentences + [raw], book: last.book, title: last.title, author: last.author)
                } else {
                    out.append(passages.excerpt(run, sentences: [raw]))
                }
            }
            return out
        }
    }

    func feed() -> Feed { Feed(self) }
}

// MARK: - Aligning what was heard

/// Word-level alignment of a transcript to a passage, ported from the web
/// trainer's `speak.js`: every passage word is read (a match or a
/// substitution), skipped, or an extra word was said. Ties break towards
/// reading the word — a wrong word said in the word's place is the usual
/// shape of a misreading. Only the passage up to the reader's furthest point
/// is scored; `frontier` is that point.
enum SpeechAlignment {
    enum Op: Equatable { case ok(target: Int, heard: Int), sub(target: Int, heard: Int), skip(target: Int), extra(heard: Int) }

    /// A heard word counts as the target when it is the target, or one letter
    /// off on a word of five letters or more — the recogniser's `their` for
    /// `there` is absorbed; `form` for `from` is two edits and stays an error.
    static func sameWord(_ target: String, _ heard: String) -> Bool {
        target == heard || (target.count >= 5 && editDistance(target, heard) <= 1)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i]
            for j in 1...b.count {
                cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func align(target: [String], heard: [String]) -> (ops: [Op], frontier: Int) {
        let m = target.count, n = heard.count
        var cost = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        var from = [[UInt8]](repeating: [UInt8](repeating: 0, count: n + 1), count: m + 1) // 1 diag 2 skip 3 extra
        for i in 0...m { cost[i][0] = i; from[i][0] = 2 }
        for j in 0...n { cost[0][j] = j; from[0][j] = 3 }
        if m > 0, n > 0 {
            for i in 1...m {
                for j in 1...n {
                    let hit = sameWord(target[i - 1], heard[j - 1])
                    var best = cost[i - 1][j - 1] + (hit ? 0 : 1); var f: UInt8 = 1
                    if cost[i - 1][j] + 1 < best { best = cost[i - 1][j] + 1; f = 2 }
                    if cost[i][j - 1] + 1 < best { best = cost[i][j - 1] + 1; f = 3 }
                    cost[i][j] = best; from[i][j] = f
                }
            }
        }
        // The cheapest alignment that consumes every heard word, ending wherever
        // in the passage that is; a tie between substitution and extra takes the
        // substitution.
        var bi = 0
        if m > 0 { for i in 1...m where cost[i][n] <= cost[bi][n] { bi = i } }
        var ops = [Op](); var i = bi, j = n
        while i > 0 || j > 0 {
            let f: UInt8 = i == 0 ? 3 : j == 0 ? 2 : from[i][j]
            switch f {
            case 1:
                ops.append(sameWord(target[i - 1], heard[j - 1]) ? .ok(target: i - 1, heard: j - 1) : .sub(target: i - 1, heard: j - 1))
                i -= 1; j -= 1
            case 2: ops.append(.skip(target: i - 1)); i -= 1
            default: ops.append(.extra(heard: j - 1)); j -= 1
            }
        }
        ops.reverse()
        var frontier = 0
        for op in ops {
            switch op { case .ok(let t, _), .sub(let t, _): frontier = t + 1; default: break }
        }
        // Trailing skips are words not reached, not words skipped.
        ops = ops.filter { if case .skip(let t) = $0 { return t < frontier }; return true }
        return (ops, frontier)
    }
}
