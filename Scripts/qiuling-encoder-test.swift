#!/usr/bin/env swift
// Checks that the keyboard's encoder never lets a plain letter through: every
// scalar it produces for Latin text is a space, a character the font does not
// draw (digits, most punctuation), or a private-use point in the font's plane.
//
//   swift Scripts/qiuling-encoder-test.swift
//
// `KeyboardExtension/QiulingEncoder.swift` is compiled as it ships, with the
// harness below, against the bundled font and mappings. Exit status is the
// number of failing inputs; each is printed with its glyph runs.

import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let encoderSource = root.appendingPathComponent("KeyboardExtension/QiulingEncoder.swift").path
let fontPath = root.appendingPathComponent("KeyboardExtension/Resources/QiulingMorphWrite-Regular.ttf").path
let mappingsPath = root.appendingPathComponent("KeyboardExtension/Resources/mappings-morph.json").path

let harness = #"""
import CoreText
import Foundation

let arguments = CommandLine.arguments
let fontPath = arguments[1], mappingsPath = arguments[2]

guard let data = FileManager.default.contents(atPath: fontPath),
      let descriptor = (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.first else {
    print("could not load \(fontPath)"); exit(1)
}
let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)

var spaceVariants: [UInt32] = []
if let json = FileManager.default.contents(atPath: mappingsPath),
   let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
    spaceVariants = object.filter { $0.key.hasPrefix(" ") }.compactMap { ($0.value as? NSNumber)?.uint32Value }
}
guard !spaceVariants.isEmpty else { print("no space variants in \(mappingsPath)"); exit(1) }

let started = Date()
let core = QiulingEncoderCore(font: font, spaceVariantPoints: spaceVariants)
let tableTime = Date().timeIntervalSince(started)

// Characters the font draws from Latin: only these must come back as points.
var drawn = Set<UInt32>()
for scalar in UInt32(0x21)...0x7E {
    var unit: [UniChar] = [UniChar(scalar)]
    var glyph: [CGGlyph] = [0]
    if CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph[0] != 0 { drawn.insert(scalar) }
}

var inputs = ["what is", "s", "is", "this is it", "the quick brown fox jumps over the lazy dog", "hello",
              "what is this", "jumps", "us", "ss", "whats", "what iss", "readings", "what is ", " what is",
              "what  is", "what is.", "yes, it is", "1 is 2", "its"]
inputs += (0..<26).map { String(UnicodeScalar(UInt8(0x61 + $0))) }
var words: [String] = []
if let dictionary = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
    words = dictionary.split(separator: "\n").map { $0.lowercased() }.filter { $0.allSatisfy { $0.isLetter } }
}
var generator = SystemRandomNumberGenerator()
inputs += (0..<300).compactMap { _ in words.randomElement(using: &generator) }
inputs += (0..<100).compactMap { _ in (0..<3).compactMap { _ in words.randomElement(using: &generator) }.joined(separator: " ") }

func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.value == 0x20 || scalar.value == 0x0A { return true }
    if scalar.value >= QiulingEncoderCore.planeStart, scalar.value < QiulingEncoderCore.planeStart + QiulingEncoderCore.planeLength { return true }
    return !drawn.contains(scalar.value)
}

var failures = 0
var pointsOut = 0
for input in inputs {
    let out = core.encode(input)
    let leaked = out.unicodeScalars.filter { !isAllowed($0) }
    pointsOut += out.unicodeScalars.filter { $0.value >= QiulingEncoderCore.planeStart }.count
    let roundTrip = QiulingEncoderCore.normalise(input).unicodeScalars.filter { $0.value == 0x20 }.count
        == out.unicodeScalars.filter { $0.value == 0x20 }.count
    guard leaked.isEmpty, roundTrip else {
        failures += 1
        print("FAIL \(input.debugDescription)")
        print("  out: " + out.unicodeScalars.map { String(format: "U+%X", $0.value) }.joined(separator: " "))
        if !roundTrip { print("  space count changed") }
        for glyph in core.shape(QiulingEncoderCore.normalise(input)) {
            let point = glyph.point.map { String(format: "U+%X", $0) } ?? "no point"
            print("  glyph \(glyph.glyph) range \(glyph.range) \(glyph.covered.debugDescription) \(glyph.isQiulingFont ? "" : "other font ")-> \(point)")
        }
        continue
    }
}
print("table \(core.table.count) glyphs in \(String(format: "%.2f", tableTime))s; \(inputs.count) inputs, \(pointsOut) points, \(failures) failing")
exit(Int32(min(failures, 255)))
"""#

let work = FileManager.default.temporaryDirectory.appendingPathComponent("qiuling-encoder-test-\(ProcessInfo.processInfo.processIdentifier)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let harnessPath = work.appendingPathComponent("main.swift").path
try harness.write(toFile: harnessPath, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("encoder-test").path

func run(_ command: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments
    try! process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compiled = run("swiftc", ["-O", "-suppress-warnings", encoderSource, harnessPath, "-o", binary])
guard compiled == 0 else { print("compile failed"); exit(1) }
exit(run(binary, [fontPath, mappingsPath]))
