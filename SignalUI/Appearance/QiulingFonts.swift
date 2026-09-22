//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import CryptoKit
import SignalServiceKit
import UIKit

/// The Qiuling write font, kept current over the air.
///
/// The app ships a copy of the font, but the alphabet is still being drawn,
/// so it also pulls the latest from the deployed trainer: a manifest at
/// `QiulingFontManifestURL` (Info.plist, injected at build time) names the
/// TTF and its SHA-256 per build id. When the hash differs from what is on
/// disk the file is fetched, verified, swapped in for this process, and
/// re-registered for the whole phone. A font change therefore reaches the
/// phone on the next launch after a deploy, with no app release.
///
/// The font is a SET of four files, not one: the regular and its bold,
/// italic and bold-italic faces, which the build derives from the same
/// drawings. All four share one family name, so message formatting — Signal
/// sets a bold range with `withSymbolicTraits(.traitBold)` — picks the drawn
/// face by itself once the set is registered; without the faces CoreText
/// fakes them, and its smeared bold closes the gaps the drawings keep. The
/// regular's hash identifies the set; the manifest lists the other faces
/// under `faces`, and a set is only taken when every face it names arrives.
///
/// The trainer is behind Deployment Protection; requests carry the project's
/// bypass token (`QiulingFontBypass`, also injected at build time and never
/// in source). Without a URL or token, everything here degrades to "use the
/// bundled font", which is what a build from a clean checkout does.
public final class QiulingFonts {

    public static let shared = QiulingFonts()

    /// The build id in the manifest, and the family that build produces.
    public static let buildId = "morph"
    public static let family = "QiulingMorphWrite-Regular"

    /// The derived faces, as the manifest keys them and as the build names
    /// the files (`QiulingMorphWrite-Bold`). The PostScript names are what
    /// `CTFontManagerCopyRegisteredFontDescriptors` reports back.
    public static let faces: [(key: String, suffix: String)] = [
        ("bold", "Bold"), ("italic", "Italic"), ("bolditalic", "BoldItalic"),
    ]
    static let familyStem = "QiulingMorphWrite"
    static var allFamilyNames: [String] { [family] + faces.map { "\(familyStem)-\($0.suffix)" } }

    private let defaults = UserDefaults.standard
    private let currentShaKey = "QiulingFonts.currentSha"
    private let currentFacesKey = "QiulingFonts.currentFaces"
    private let currentBuiltAtKey = "QiulingFonts.currentBuiltAt"
    private let latestBuiltAtKey = "QiulingFonts.latestBuiltAt"
    private let installedShaKey = "QiulingFonts.installedSha"
    private let installedFacesKey = "QiulingFonts.installedFaces"
    private let lastCheckKey = "QiulingFonts.lastCheck"
    private let lastCheckOutcomeKey = "QiulingFonts.lastCheckOutcome"
    private let lastCheckMessageKey = "QiulingFonts.lastCheckMessage"
    private let minimumCheckInterval: TimeInterval = 60 * 60

    private var manifestURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "QiulingFontManifestURL") as? String).flatMap { URL(string: $0) }
    }
    private var bypassToken: String? {
        (Bundle.main.object(forInfoDictionaryKey: "QiulingFontBypass") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QiulingFonts", isDirectory: true)
    }
    private func fileURL(sha: String) -> URL { storeDirectory.appendingPathComponent("\(sha).ttf") }

    // MARK: - The set in use

    /// One font set: the regular and whichever faces came with it, each a
    /// file and its hash. `sha` (the regular's) names the set.
    struct FontSet {
        let url: URL
        let sha: String
        /// face key -> (file, hash), for the faces present.
        let faces: [String: (url: URL, sha: String)]

        var urls: [URL] { [url] + Self.orderedFaces.compactMap { faces[$0]?.url } }
        var isComplete: Bool { faces.count == QiulingFonts.faces.count }
        var faceShas: [String: String] { faces.mapValues { $0.sha } }
        static let orderedFaces = QiulingFonts.faces.map { $0.key }
    }

    /// The downloaded set this process should use instead of the bundled one, if any.
    private var downloadedSet: FontSet? {
        guard let sha = defaults.string(forKey: currentShaKey) else { return nil }
        let url = fileURL(sha: sha)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var faces: [String: (url: URL, sha: String)] = [:]
        for (key, faceSha) in defaults.dictionary(forKey: currentFacesKey) as? [String: String] ?? [:] {
            let faceURL = fileURL(sha: faceSha)
            if FileManager.default.fileExists(atPath: faceURL.path) { faces[key] = (faceURL, faceSha) }
        }
        return FontSet(url: url, sha: sha, faces: faces)
    }

    /// The set the current font comes from: the downloaded one when there is
    /// one, else the bundled files.
    private var currentSet: FontSet? { downloadedSet ?? Self.bundledSet }

    /// The URLs currently registered for this process, so a swap can unregister them.
    private var processRegisteredURLs: [URL] = []

    // MARK: - Process registration

    /// Called by SignalUI's font registration, before it registers the bundle's
    /// fonts. Registers the downloaded set, if there is one, and says so, so
    /// the bundled files of the same family are skipped rather than colliding.
    func registerCurrentForProcess() -> Bool {
        guard let set = downloadedSet else { return false }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(set.url as CFURL, .process, &error) else {
            Logger.warn("downloaded font failed to register, falling back to the bundled one: \(String(describing: error?.takeRetainedValue()))")
            forgetDownloaded()
            return false
        }
        processRegisteredURLs = [set.url]
        // A face that fails leaves the regular in place; CoreText synthesises
        // that one style as it did before there were faces.
        for (key, face) in set.faces {
            if CTFontManagerRegisterFontsForURL(face.url as CFURL, .process, &error) {
                processRegisteredURLs.append(face.url)
            } else {
                Logger.warn("downloaded \(key) face failed to register: \(String(describing: error?.takeRetainedValue()))")
            }
        }
        Logger.info("using downloaded Qiuling font \(set.url.lastPathComponent) with \(set.faces.count) faces")
        return true
    }

    private func forgetDownloaded() {
        defaults.removeObject(forKey: currentShaKey)
        defaults.removeObject(forKey: currentFacesKey)
        defaults.removeObject(forKey: currentBuiltAtKey)
    }

    /// Whether `registerCurrentForProcess` took over the family this bundle file provides.
    func providesFont(atBundleURL url: URL) -> Bool {
        !processRegisteredURLs.isEmpty && Self.isFamilyFile(url)
    }

    func noteBundledFontRegistered(at url: URL) {
        if Self.isFamilyFile(url), !processRegisteredURLs.contains(url), downloadedSet == nil {
            processRegisteredURLs.append(url)
        }
    }

    /// Whether a bundle file is one of this family's four faces.
    static func isFamilyFile(_ url: URL) -> Bool {
        allFamilyNames.contains(url.deletingPathExtension().lastPathComponent)
    }

    /// The bundled files of the family, for a launch path that registers
    /// fonts itself (the practice-only simulator run).
    public static var bundledURLs: [URL] { bundledSet?.urls ?? [] }

    // MARK: - Launch

    /// Call once the UI is up: the phone-wide install can show a sheet.
    @MainActor
    public func start() {
        installPhoneWideIfNeeded()
        mirrorForExtension()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main,
        ) { [weak self] _ in Task { @MainActor in self?.checkForUpdateIfDue() } }
        checkForUpdateIfDue()
    }

    // MARK: - Status

    /// How the last update check ended.
    public enum CheckOutcome: Equatable {
        case upToDate
        case updated
        case failed(String)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public struct LastCheck: Equatable {
        public let date: Date
        public let outcome: CheckOutcome
    }

    /// Whether the copy installed for every app on the phone is the one in use.
    public enum PhoneWideStatus: Equatable {
        case installed
        case olderCopy
        case notInstalled
    }

    /// Everything Settings › Qiuling shows, read in one go.
    public struct Status {
        public let family: String
        public let buildId: String
        /// The build id as a name: "Morph".
        public var displayName: String { buildId.prefix(1).uppercased() + buildId.dropFirst() }
        public let sha: String
        public let isUsingDownloadedCopy: Bool
        /// How many of the derived faces (bold, italic, bold italic) the set in use carries.
        public let facesCount: Int
        /// When the font in use was built, if known.
        public let buildDate: Date?
        /// The last update check, or nil if there has never been one.
        public let lastCheck: LastCheck?
        /// Whether this build knows where to look for updates.
        public let updatesAvailable: Bool
        public let phoneWide: PhoneWideStatus
        /// How many letters and letter groups the font draws as one shape.
        public let marksCount: Int
        /// The font in use, as `YYYYMMDDHHmm` (UTC) of when it was built — the
        /// same scheme as the app's own build number, so "is this the latest"
        /// is one glance at two numbers. Nil when the copy's date is unknown.
        public let version: String?
        /// The version the server offered at the last successful check, if any.
        public let latestVersion: String?
    }

    /// Posted whenever anything in `status` may have changed.
    public static let statusDidChange = Notification.Name("QiulingFonts.statusDidChange")

    public var status: Status {
        let current = currentSet
        let downloaded = downloadedSet != nil
        return Status(
            family: Self.family,
            buildId: Self.buildId,
            sha: current?.sha ?? "",
            isUsingDownloadedCopy: downloaded,
            facesCount: current?.faces.count ?? 0,
            buildDate: downloaded ? downloadedBuildDate : Self.bundledBuildDate,
            lastCheck: lastCheck,
            updatesAvailable: manifestURL != nil && bypassToken != nil,
            phoneWide: phoneWideStatus(current: current),
            marksCount: blocks.count,
            version: (downloaded ? downloadedBuildDate : Self.bundledBuildDate).map(Self.version(of:)),
            latestVersion: defaults.string(forKey: latestBuiltAtKey).flatMap(Self.date(fromISO8601:)).map(Self.version(of:)),
        )
    }

    /// `202609212126` for a font built 2026-09-21 21:26 UTC.
    public static func version(of built: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm"
        return f.string(from: built)
    }

    private var lastCheck: LastCheck? {
        guard let date = defaults.object(forKey: lastCheckKey) as? Date else { return nil }
        switch defaults.string(forKey: lastCheckOutcomeKey) {
        case "updated": return LastCheck(date: date, outcome: .updated)
        case "failed": return LastCheck(date: date, outcome: .failed(defaults.string(forKey: lastCheckMessageKey) ?? ""))
        // Checks recorded before outcomes were, all of which succeeded.
        default: return LastCheck(date: date, outcome: .upToDate)
        }
    }

    private func record(_ outcome: CheckOutcome) {
        defaults.set(Date(), forKey: lastCheckKey)
        switch outcome {
        case .upToDate:
            defaults.set("upToDate", forKey: lastCheckOutcomeKey)
            defaults.removeObject(forKey: lastCheckMessageKey)
        case .updated:
            defaults.set("updated", forKey: lastCheckOutcomeKey)
            defaults.removeObject(forKey: lastCheckMessageKey)
        case .failed(let message):
            defaults.set("failed", forKey: lastCheckOutcomeKey)
            defaults.set(message, forKey: lastCheckMessageKey)
        }
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(fromISO8601 string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601.date(from: string)
    }

    private var downloadedBuildDate: Date? {
        defaults.string(forKey: currentBuiltAtKey).flatMap(Self.date(fromISO8601:))
            ?? downloadedSet.flatMap { Self.builtDate(ofFontAt: $0.url) }
    }

    /// When the alphabet itself was built: the font's own `head.modified`,
    /// which the build tool stamps. File dates say when the app was built.
    private static let bundledBuildDate: Date? = bundledURL.flatMap(builtDate(ofFontAt:))

    static func builtDate(ofFontAt url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url), data.count > 12 else { return nil }
        func u16(_ o: Int) -> Int { Int(data[o]) << 8 | Int(data[o + 1]) }
        func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }
        let tables = u16(4)
        for i in 0..<tables {
            let rec = 12 + i * 16
            guard rec + 16 <= data.count else { return nil }
            if data[rec..<rec + 4].elementsEqual("head".utf8) {
                let off = u32(rec + 8) + 28
                guard off + 8 <= data.count else { return nil }
                let modified = Int64(u32(off)) << 32 | Int64(u32(off + 4))
                // The head table counts seconds from 1904.
                return Date(timeIntervalSince1970: TimeInterval(modified) - 2_082_844_800)
            }
        }
        return nil
    }

    private func phoneWideStatus(current: FontSet?) -> PhoneWideStatus {
        let registered = registeredPhoneWide()
        guard !registered.isEmpty else { return .notInstalled }
        if let current, isInstalledPhoneWide(current) { return .installed }
        return .olderCopy
    }

    /// Whether the phone-wide registration is this whole set: the regular's
    /// hash and every face's, so a set that gained faces counts as new.
    private func isInstalledPhoneWide(_ set: FontSet) -> Bool {
        defaults.string(forKey: installedShaKey) == set.sha
            && (defaults.dictionary(forKey: installedFacesKey) as? [String: String] ?? [:]) == set.faceShas
    }

    // MARK: - Over the air

    private var inFlightCheck: Task<CheckOutcome, Never>?

    @MainActor
    private func checkForUpdateIfDue() {
        guard manifestURL != nil, bypassToken != nil, inFlightCheck == nil else { return }
        // A failed check is retried on the next chance rather than waiting out the hour.
        if let lastCheck, !lastCheck.outcome.isFailure, Date().timeIntervalSince(lastCheck.date) < minimumCheckInterval {
            return
        }
        Task { _ = await checkForUpdates() }
    }

    /// Check the manifest now, whatever the hourly schedule says, and record
    /// how it went. A check already under way is joined rather than repeated.
    @MainActor
    public func checkForUpdates() async -> CheckOutcome {
        if let inFlightCheck { return await inFlightCheck.value }
        guard let manifestURL, bypassToken != nil else { return .failed("Updates aren't available in this build.") }
        let task = Task { @MainActor () -> CheckOutcome in
            do {
                return try await checkForUpdate(manifestURL: manifestURL) ? .updated : .upToDate
            } catch {
                Logger.warn("Qiuling font update check failed: \(error)")
                return .failed(error.localizedDescription)
            }
        }
        inFlightCheck = task
        let outcome = await task.value
        inFlightCheck = nil
        record(outcome)
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return outcome
    }

    private struct ManifestFace: Decodable {
        let file: String
        let sha256: String
    }

    private struct ManifestEntry: Decodable {
        let family: String
        let file: String
        let sha256: String
        let blocks: String?
        let builtAt: String?
        /// The derived faces, keyed as `QiulingFonts.faces` is. Absent from a
        /// manifest written before there were any.
        let faces: [String: ManifestFace]?
    }

    /// The ligature list for the current build — the blocks the font draws —
    /// downloaded beside the font when the manifest names one, else bundled.
    public var blocks: [String] {
        let downloaded = defaults.string(forKey: currentShaKey).map { storeDirectory.appendingPathComponent("\($0).blocks.json") }
        let url = downloaded.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.main.url(forResource: "blocks", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let bypassToken { r.setValue(bypassToken, forHTTPHeaderField: "x-vercel-protection-bypass") }
        return r
    }

    /// One file of the set: fetched from beside the manifest and checked
    /// against the hash the manifest gave for it.
    private func fetchVerified(_ file: String, sha256: String, manifestURL: URL) async throws -> Data {
        let url = manifestURL.deletingLastPathComponent().appendingPathComponent(file)
        let (bytes, response) = try await URLSession.shared.data(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OWSGenericError("\(file): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard Self.sha(bytes) == sha256 else { throw OWSGenericError("\(file): hash mismatch") }
        return bytes
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns whether a new font set was downloaded and swapped in.
    @MainActor
    private func checkForUpdate(manifestURL: URL) async throws -> Bool {
        let (data, response) = try await URLSession.shared.data(for: request(manifestURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OWSGenericError("manifest: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let manifest = try JSONDecoder().decode([String: ManifestEntry].self, from: data)
        guard let entry = manifest[Self.buildId] else { throw OWSGenericError("manifest has no \(Self.buildId)") }
        guard entry.family == Self.family else { throw OWSGenericError("manifest family \(entry.family) is not \(Self.family)") }

        if let builtAt = entry.builtAt {
            defaults.set(builtAt, forKey: latestBuiltAtKey)
        }
        // The set actually in use — not a recorded sha whose file is gone,
        // which once left the app saying "you have the latest" while drawing
        // with the bundled font. A set whose regular matches but whose faces
        // do not (a manifest that gained them) is an update too.
        let have = currentSet ?? Self.bundledSet
        let wantFaces = (entry.faces ?? [:]).mapValues { $0.sha256 }
        guard entry.sha256 != have?.sha || wantFaces != (have?.faceShas ?? [:]) else {
            // The manifest may have learnt the build date since the copy landed.
            if let builtAt = entry.builtAt, downloadedSet != nil {
                defaults.set(builtAt, forKey: currentBuiltAtKey)
            }
            return false
        }

        // Every file first, then the swap: half a set is worse than an old one.
        let regular = try await fetchVerified(entry.file, sha256: entry.sha256, manifestURL: manifestURL)
        var faces: [String: (data: Data, sha: String)] = [:]
        for (key, face) in entry.faces ?? [:] where Self.faces.contains(where: { $0.key == key }) {
            faces[key] = (try await fetchVerified(face.file, sha256: face.sha256, manifestURL: manifestURL), face.sha256)
        }

        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let dest = fileURL(sha: entry.sha256)
        try regular.write(to: dest, options: .atomic)
        var keep: Set<URL> = [dest]
        for (_, face) in faces {
            let faceDest = fileURL(sha: face.sha)
            try face.data.write(to: faceDest, options: .atomic)
            keep.insert(faceDest)
        }
        if let blocksFile = entry.blocks {
            let blocksURL = manifestURL.deletingLastPathComponent().appendingPathComponent(blocksFile)
            if let (blocks, r) = try? await URLSession.shared.data(for: request(blocksURL)), (r as? HTTPURLResponse)?.statusCode == 200,
               (try? JSONDecoder().decode([String].self, from: blocks)) != nil {
                let blocksDest = storeDirectory.appendingPathComponent("\(entry.sha256).blocks.json")
                try blocks.write(to: blocksDest, options: .atomic)
                keep.insert(blocksDest)
            }
        }
        // Keep only the new files; anything else in the store is superseded.
        for old in (try? FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(old) {
            try? FileManager.default.removeItem(at: old)
        }
        defaults.set(entry.sha256, forKey: currentShaKey)
        defaults.set(faces.mapValues { $0.sha }, forKey: currentFacesKey)
        if let builtAt = entry.builtAt {
            defaults.set(builtAt, forKey: currentBuiltAtKey)
        } else {
            defaults.removeObject(forKey: currentBuiltAtKey)
        }
        Logger.info("Qiuling font updated to \(entry.sha256.prefix(8)) with \(faces.count) faces")

        if let set = downloadedSet { swapForProcess(to: set) }
        mirrorForExtension()
        installPhoneWideIfNeeded()
        NotificationCenter.default.post(name: Self.fontDidChange, object: nil)
        return true
    }

    /// Posted after a new font (and its block list) has been swapped in.
    public static let fontDidChange = Notification.Name("QiulingFonts.fontDidChange")

    /// Replace the process's copy of the family with the new set and ask the
    /// UI to redraw. Text already laid out keeps its old glyphs until it is
    /// rebuilt; the theme-change notification rebuilds most of it.
    @MainActor
    private func swapForProcess(to set: FontSet) {
        // A launch that registered the bundled files itself (the practice-only
        // simulator run) never told us; the bundled files are what to replace.
        let old = processRegisteredURLs.isEmpty ? Self.bundledURLs : processRegisteredURLs
        for url in old {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        }
        processRegisteredURLs = []
        var error: Unmanaged<CFError>?
        for url in set.urls {
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                processRegisteredURLs.append(url)
            } else {
                Logger.warn("could not swap \(url.lastPathComponent) in-process: \(String(describing: error?.takeRetainedValue())); it applies on next launch")
            }
        }
        if !processRegisteredURLs.isEmpty {
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }

    // MARK: - Safari extension

    /// The Safari extension cannot read this app's container, so the set in
    /// use is mirrored into the shared App Group: `QiulingFonts/current.ttf`
    /// and `current-<face>.ttf` beside a `current.json` naming the family,
    /// the build and each file's hash. Written at launch and after every
    /// swap; skipped when the mirror already matches.
    private func mirrorForExtension() {
        guard let current = currentSet else { return }
        let group = "group.\(Bundle.main.bundleIdPrefix).signal.group"
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return Logger.warn("no App Group container for \(group); the Safari extension gets no font")
        }
        let directory = container.appendingPathComponent("QiulingFonts", isDirectory: true)
        let infoDest = directory.appendingPathComponent("current.json")
        var info: [String: String] = ["family": Self.family, "sha256": current.sha, "buildId": Self.buildId]
        var files: [(from: URL, to: URL)] = [(current.url, directory.appendingPathComponent("current.ttf"))]
        for (key, face) in current.faces {
            info[key] = face.sha
            files.append((face.url, directory.appendingPathComponent("current-\(key).ttf")))
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                if
                    let existing = try? Data(contentsOf: infoDest),
                    let existingInfo = try? JSONDecoder().decode([String: String].self, from: existing),
                    existingInfo == info,
                    files.allSatisfy({ FileManager.default.fileExists(atPath: $0.to.path) })
                {
                    return
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in files {
                    try Data(contentsOf: file.from).write(to: file.to, options: .atomic)
                }
                try JSONEncoder().encode(info).write(to: infoDest, options: .atomic)
                Logger.info("mirrored Qiuling font \(current.sha.prefix(8)) (\(current.faces.count) faces) for the Safari extension")
            } catch {
                Logger.warn("could not mirror the Qiuling font for the Safari extension: \(error)")
            }
        }
    }

    // MARK: - Phone-wide

    /// Register the current set for every app on the phone (Settings ›
    /// General › Fonts) when the installed copy is not the one in use.
    @MainActor
    private func installPhoneWideIfNeeded() {
        guard let current = currentSet else { return Logger.warn("no Qiuling font to install") }
        if isInstalledPhoneWide(current), !registeredPhoneWide().isEmpty { return }
        Task { _ = await installPhoneWide() }
    }

    /// Register the current set for every app on the phone, replacing an
    /// older copy. All four faces go in one call, so Settings › Fonts shows
    /// one family with four styles and Pages' B and I buttons reach them.
    /// iOS confirms with the user the first time. Apple's font-provider
    /// entitlement is what allows it.
    @MainActor
    public func installPhoneWide() async -> Result<Void, Error> {
        guard let current = currentSet else { return .failure(OWSGenericError("no Qiuling font to install")) }

        let wanted = Set(current.urls)
        let stale = registeredPhoneWide().filter { !wanted.contains($0) }
        if !stale.isEmpty {
            CTFontManagerUnregisterFontURLs(stale as CFArray, .persistent) { _, _ in true }
        }
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            // The handler runs once per font and once more when done; only the
            // last call may resume, and only once.
            var resumed = false
            var collected: [CFError] = []
            CTFontManagerRegisterFontURLs(current.urls as CFArray, .persistent, true) { errors, done in
                // Errors can arrive on an earlier call than the final one.
                collected += errors as? [CFError] ?? []
                guard done, !resumed else { return true }
                resumed = true
                if let error = collected.first {
                    continuation.resume(returning: .failure(error as Error))
                } else {
                    continuation.resume(returning: .success(()))
                }
                return true
            }
        }
        switch result {
        case .success:
            defaults.set(current.sha, forKey: installedShaKey)
            defaults.set(current.faceShas, forKey: installedFacesKey)
            Logger.info("Qiuling installed for the whole phone (\(current.sha.prefix(8)), \(current.faces.count) faces)")
        case .failure(let error):
            Logger.warn("Qiuling phone-wide registration: \(error)")
        }
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return result
    }

    private func registeredPhoneWide() -> [URL] {
        let descriptors = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
        let names = Set(Self.allFamilyNames)
        return descriptors.compactMap { d -> URL? in
            guard
                let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String, names.contains(name),
                let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL
            else { return nil }
            return url
        }
    }

    /// The bytes of the font in use — the downloaded copy if there is one.
    public func currentFontData() -> Data? {
        guard let url = currentSet?.url else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Bundled copy

    static let bundledURL: URL? = Bundle(for: QiulingFonts.self).url(forResource: family, withExtension: "ttf")
    static let bundledSha: String = bundledURL.flatMap { try? Data(contentsOf: $0) }.map(sha) ?? ""

    /// The bundled regular and whichever faces the bundle carries.
    static let bundledSet: FontSet? = {
        guard let url = bundledURL else { return nil }
        let bundle = Bundle(for: QiulingFonts.self)
        var faces: [String: (url: URL, sha: String)] = [:]
        for face in QiulingFonts.faces {
            if let faceURL = bundle.url(forResource: "\(familyStem)-\(face.suffix)", withExtension: "ttf"),
               let data = try? Data(contentsOf: faceURL) {
                faces[face.key] = (faceURL, sha(data))
            }
        }
        return FontSet(url: url, sha: bundledSha, faces: faces)
    }()
}
