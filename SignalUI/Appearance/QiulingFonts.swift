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
        /// Whether `other` is one of this set's files, whichever way the
        /// system spells the path (`/private/var` and `/var` are one place).
        func contains(_ other: URL) -> Bool { urls.contains { QiulingFonts.sameFile($0, other) } }
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

    /// The URLs registered for this process at launch. They never change
    /// while the process runs: on the phone, CoreText reports success for a
    /// re-registration of the family under a new file but the name then
    /// resolves to nothing until the process restarts, so an update is
    /// stored and applied at the next launch, never swapped in live.
    private var processRegisteredURLs: [URL] = []
    /// The set those URLs belong to — what this process draws with.
    private var activeSet: FontSet?
    /// Whether making the process font work meant removing a phone-wide
    /// registration this launch; the phone-wide install then waits for the
    /// next launch rather than putting the conflict straight back.
    private var clearedPhoneWideThisLaunch = false

    enum RegisterFailure: Error, CustomStringConvertible {
        case coreText(CFError)
        case unresolvable
        var description: String {
            switch self {
            case .coreText(let e): return QiulingFonts.describe(e)
            case .unresolvable: return "registered without error, but the font name does not resolve in this process"
            }
        }
        var isBadFile: Bool {
            if case .coreText(let e) = self { return QiulingFonts.badFileCodes.contains(CFErrorGetCode(e)) }
            return false
        }
    }

    // MARK: - Process registration
    //
    // One rule governs everything below: the process must always end up with
    // a Qiuling regular it can draw with. CoreText refuses to register a font
    // for the process when a font with the same PostScript name is already
    // registered phone-wide FROM A DIFFERENT FILE (it accepts the same file
    // in both scopes). That is exactly the state an over-the-air update
    // creates — the new regular is a new file, the old one is still installed
    // phone-wide — and without handling it the swap fails, the downloaded set
    // is dropped, and the bundled copy then fails for the same reason: the
    // app draws in the system font with no error on screen. So a set is
    // registered by first clearing this app's own phone-wide registrations
    // of the family that point elsewhere, and registration is verified by
    // looking the family up, not by trusting return codes alone.

    /// CoreText's "this file is already registered in that scope", which is
    /// success for our purposes.
    private static let alreadyRegistered = 105
    /// Errors about the file itself, after which the downloaded set is not
    /// worth keeping.
    private static let badFileCodes: Set<Int> = [101, 103, 104]

    /// Whether the regular can be created by name for this process.
    static var isResolvable: Bool {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == family
    }

    /// Register one file for the process; `alreadyRegistered` counts as done.
    private func registerFile(_ url: URL) -> Result<Void, CFError> {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return .success(()) }
        let err = error!.takeRetainedValue()
        return CFErrorGetCode(err) == Self.alreadyRegistered ? .success(()) : .failure(err)
    }

    /// Register `set` for the process, clearing a conflicting phone-wide
    /// registration of ours if that is what stands in the way. Returns the
    /// URLs now registered, or the regular's error.
    private func registerForProcess(_ set: FontSet) -> Result<[URL], RegisterFailure> {
        var attempt = registerFile(set.url)
        if case .failure(let err) = attempt {
            // Our phone-wide registrations of the family from other files —
            // the bundled copy, when the download is what we want now.
            let conflicting = registeredPhoneWide().filter { !set.contains($0) }
            if !conflicting.isEmpty {
                Logger.warn("registering \(set.url.lastPathComponent) failed (\(CFErrorGetCode(err))); clearing \(conflicting.count) phone-wide registration(s) from other files and retrying")
                unregisterPhoneWide(conflicting)
                clearedPhoneWideThisLaunch = true
                attempt = registerFile(set.url)
            }
        }
        if case .failure(let err) = attempt { return .failure(.coreText(err)) }
        // The return code is not the truth on the phone; the name resolving is.
        guard Self.isResolvable else {
            CTFontManagerUnregisterFontsForURL(set.url as CFURL, .process, nil)
            return .failure(.unresolvable)
        }
        var urls = [set.url]
        // A face that fails leaves the regular in place; CoreText synthesises
        // that one style as it did before there were faces.
        for key in FontSet.orderedFaces {
            guard let face = set.faces[key] else { continue }
            switch registerFile(face.url) {
            case .success: urls.append(face.url)
            case .failure(let err): Logger.warn("\(key) face \(face.url.lastPathComponent) failed to register: \(err)")
            }
        }
        return .success(urls)
    }

    /// Called by SignalUI's font registration, before it registers the bundle's
    /// fonts. Registers the current set — the downloaded one when there is one
    /// and it can be, else the bundled files — and says so, so the caller skips
    /// the bundled files of the family rather than colliding with them.
    func registerCurrentForProcess() -> Bool {
        if let set = downloadedSet {
            switch registerForProcess(set) {
            case .success(let urls):
                processRegisteredURLs = urls
                activeSet = set
                clearProblem()
                Logger.info("using downloaded Qiuling font \(set.url.lastPathComponent) with \(urls.count - 1) faces")
                logStatus("launch")
                return true
            case .failure(let err):
                Logger.warn("downloaded font failed to register, falling back to the bundled one: \(err)")
                noteProblem("Downloaded font \(set.url.lastPathComponent) could not be registered: \(err)")
                if err.isBadFile { forgetDownloaded() }
            }
        }
        guard let bundled = Self.bundledSet else { return false }
        switch registerForProcess(bundled) {
        case .success(let urls):
            processRegisteredURLs = urls
            activeSet = bundled
            if downloadedSet == nil { clearProblem() }
            logStatus("launch")
            return true
        case .failure(let err):
            Logger.error("bundled Qiuling font failed to register: \(err)")
            noteProblem("Neither the downloaded nor the bundled font could be registered: \(err)")
            logStatus("launch")
            return false
        }
    }

    // MARK: - Problems, kept for Settings

    /// The last thing that went wrong with the font itself — a registration
    /// the system refused — as Settings › Qiuling shows it. Cleared when the
    /// set the app wants is registered cleanly.
    private let lastProblemKey = "QiulingFonts.lastProblem"
    private let lastProblemAtKey = "QiulingFonts.lastProblemAt"

    private func noteProblem(_ message: String) {
        defaults.set(message, forKey: lastProblemKey)
        defaults.set(Date(), forKey: lastProblemAtKey)
    }

    private func clearProblem() {
        defaults.removeObject(forKey: lastProblemKey)
        defaults.removeObject(forKey: lastProblemAtKey)
    }

    static func describe(_ error: CFError) -> String {
        let ns = error as Error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    /// Everything about the font's state on this device, as text to paste
    /// into a bug report: what is in use, what the phone has installed, what
    /// the store holds, and the last errors.
    public func diagnostics() -> String {
        let f = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("Qiuling font diagnostics — \(f.string(from: Date()))")
        lines.append("app build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
        lines.append("family: \(Self.family)  build id: \(Self.buildId)")
        lines.append("resolvable in process: \(Self.isResolvable)")
        lines.append("process registrations (\(processRegisteredURLs.count)):")
        for url in processRegisteredURLs { lines.append("  \(Self.short(url))") }
        let persistent = registeredPhoneWideDescriptors()
        lines.append("phone-wide registrations (\(persistent.count)):")
        for (d, url) in persistent {
            let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String ?? "?"
            let exists = FileManager.default.fileExists(atPath: url.path)
            lines.append("  \(name)  \(Self.short(url))\(exists ? "" : "  [FILE MISSING]")")
        }
        lines.append("active set (drawing with): \(activeSet.map { "\($0.sha.prefix(12)) + \($0.faces.count) faces" } ?? "none")")
        lines.append("downloaded set (next launch): \(downloadedSet.map { "\($0.sha.prefix(12)) + \($0.faces.count) faces" } ?? "none")")
        lines.append("bundled set: \(Self.bundledSet.map { "\($0.sha.prefix(12)) + \($0.faces.count) faces" } ?? "none")")
        lines.append("defaults: currentSha=\(defaults.string(forKey: currentShaKey)?.prefix(12) ?? "nil") installedSha=\(defaults.string(forKey: installedShaKey)?.prefix(12) ?? "nil")"
                     + " currentFaces=\((defaults.dictionary(forKey: currentFacesKey) as? [String: String])?.count ?? 0) installedFaces=\((defaults.dictionary(forKey: installedFacesKey) as? [String: String])?.count ?? 0)")
        let store = (try? FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        lines.append("store (\(store.count) files):")
        for url in store {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            lines.append("  \(url.lastPathComponent)  \(size) B")
        }
        lines.append("manifest url: \(manifestURL?.absoluteString ?? "none")  bypass token: \(bypassToken == nil ? "missing" : "present")")
        if let lastCheck {
            lines.append("last check: \(f.string(from: lastCheck.date)) — \(lastCheck.outcome)")
        } else {
            lines.append("last check: never")
        }
        lines.append("latest offered: \(defaults.string(forKey: latestBuiltAtKey) ?? "unknown")")
        if let problem = defaults.string(forKey: lastProblemKey), let at = defaults.object(forKey: lastProblemAtKey) as? Date {
            lines.append("last problem: \(f.string(from: at)) — \(problem)")
        } else {
            lines.append("last problem: none")
        }
        return lines.joined(separator: "\n")
    }

    private static func short(_ url: URL) -> String {
        let parts = url.pathComponents
        return parts.count > 2 ? ".../" + parts.suffix(2).joined(separator: "/") : url.path
    }

    /// One line saying whether the script can be drawn right now, and by what.
    private func logStatus(_ context: String) {
        let persistent = registeredPhoneWide()
        let missing = persistent.filter { !FileManager.default.fileExists(atPath: $0.path) }.count
        Logger.info("Qiuling font status (\(context)): resolvable=\(Self.isResolvable) process=\(processRegisteredURLs.count) file(s)"
                    + " phoneWide=\(persistent.count) file(s)\(missing > 0 ? " (\(missing) missing on disk)" : "")"
                    + " downloaded=\(downloadedSet != nil)")
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
        if Self.isFamilyFile(url), !processRegisteredURLs.contains(url) {
            processRegisteredURLs.append(url)
            if activeSet == nil { activeSet = Self.bundledSet }
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
        logStatus("start")
        mirrorForExtension()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main,
        ) { [weak self] _ in Task { @MainActor in self?.checkForUpdateIfDue() } }
        Task { @MainActor in
            await installPhoneWideIfNeeded()
            checkForUpdateIfDue()
        }
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
        /// Whether the process can draw with the font at all right now.
        public let isResolvable: Bool
        /// The last registration failure, for Settings; nil when the set in use registered cleanly.
        public let problem: String?
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
        /// A downloaded update that this process is not drawing with yet; it
        /// applies at the next launch.
        public let pendingVersion: String?
    }

    /// Posted whenever anything in `status` may have changed.
    public static let statusDidChange = Notification.Name("QiulingFonts.statusDidChange")

    public var status: Status {
        // What the process draws with is the truth here; what is on disk for
        // the next launch is the pending update.
        let active = activeSet ?? Self.bundledSet
        let activeIsDownloaded = active != nil && active?.sha != Self.bundledSet?.sha
        let activeDate = active.flatMap { $0.sha == Self.bundledSet?.sha ? Self.bundledBuildDate : Self.builtDate(ofFontAt: $0.url) }
        let onDisk = currentSet
        let pending = (onDisk != nil && onDisk?.sha != active?.sha) ? onDisk : nil
        return Status(
            family: Self.family,
            buildId: Self.buildId,
            sha: active?.sha ?? "",
            isUsingDownloadedCopy: activeIsDownloaded,
            isResolvable: Self.isResolvable,
            problem: defaults.string(forKey: lastProblemKey),
            facesCount: processRegisteredURLs.isEmpty ? 0 : processRegisteredURLs.count - 1,
            buildDate: activeDate,
            lastCheck: lastCheck,
            updatesAvailable: manifestURL != nil && bypassToken != nil,
            phoneWide: phoneWideStatus(),
            marksCount: blocks.count,
            version: activeDate.map(Self.version(of:)),
            latestVersion: defaults.string(forKey: latestBuiltAtKey).flatMap(Self.date(fromISO8601:)).map(Self.version(of:)),
            pendingVersion: pending.flatMap { downloadedBuildDate ?? Self.builtDate(ofFontAt: $0.url) }.map(Self.version(of:)),
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

    private func phoneWideStatus() -> PhoneWideStatus {
        let registered = registeredPhoneWide()
        guard !registered.isEmpty else { return .notInstalled }
        if let bundled = Self.bundledSet, isInstalledPhoneWide(bundled) { return .installed }
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
        // The list for the set this process DRAWS with, so segmentation and
        // the glyphs on screen always agree; a pending update's list waits
        // with it for the next launch.
        let downloaded = (activeSet ?? downloadedSet).flatMap { $0.sha == Self.bundledSet?.sha ? nil : storeDirectory.appendingPathComponent("\($0.sha).blocks.json") }
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
        defaults.set(entry.sha256, forKey: currentShaKey)
        defaults.set(faces.mapValues { $0.sha }, forKey: currentFacesKey)
        if let builtAt = entry.builtAt {
            defaults.set(builtAt, forKey: currentBuiltAtKey)
        } else {
            defaults.removeObject(forKey: currentBuiltAtKey)
        }
        Logger.info("Qiuling font \(entry.sha256.prefix(8)) with \(faces.count) faces downloaded; it applies at the next launch")

        // Not swapped in: this process keeps drawing with the set it started
        // with (see `processRegisteredURLs`). The Safari extension reads the
        // mirror at its own next start, so it gets the new set right away.
        mirrorForExtension()
        cleanUpStore()
        logStatus("update stored")
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return true
    }

    /// Delete store files that no registration (ours or the phone's) refers to.
    private func cleanUpStore() {
        let inUse = (currentSet?.urls ?? []) + registeredPhoneWide() + processRegisteredURLs
        let blocks = currentSet.map { storeDirectory.appendingPathComponent("\($0.sha).blocks.json") }
        for file in (try? FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil)) ?? [] {
            if inUse.contains(where: { Self.sameFile($0, file) }) || file == blocks { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Posted after a new font (and its block list) has been swapped in.
    public static let fontDidChange = Notification.Name("QiulingFonts.fontDidChange")

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

    /// Register the bundled set for every app on the phone (Settings ›
    /// General › Fonts) when what is installed is not this build's copy.
    ///
    /// The BUNDLED set, always: iOS installs phone-wide only files inside the
    /// app's own bundle (CTFontManagerError 306 for anything else), so other
    /// apps get the drawings each app build ships and a downloaded update
    /// reaches them with the next build. This app's own text is unaffected —
    /// it draws with the process registration.
    @MainActor
    private func installPhoneWideIfNeeded() async {
        guard let bundled = Self.bundledSet else { return Logger.warn("no bundled Qiuling font to install") }
        if clearedPhoneWideThisLaunch {
            return Logger.warn("not installing phone-wide this launch: a phone-wide registration had to be cleared for the process font to register")
        }
        if isInstalledPhoneWide(bundled), !registeredPhoneWide().isEmpty { return }
        _ = await installPhoneWide()
    }

    /// Unregister phone-wide registrations one by one, synchronously, so the
    /// caller knows they are gone before it registers anything in their place.
    /// A registration whose file has since been deleted may refuse to go by
    /// URL; it is then removed by its descriptor, which is how the registry
    /// itself refers to it.
    private func unregisterPhoneWide(_ urls: [URL]) {
        let registered = registeredPhoneWideDescriptors()
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerUnregisterFontsForURL(url as CFURL, .persistent, &error) { continue }
            Logger.warn("could not unregister phone-wide \(url.lastPathComponent) by URL: \(String(describing: error?.takeRetainedValue())); trying its descriptor")
            guard let descriptor = registered.first(where: { Self.sameFile($0.url, url) })?.descriptor else { continue }
            let done = DispatchSemaphore(value: 0)
            var failed: [CFError] = []
            CTFontManagerUnregisterFontDescriptors([descriptor] as CFArray, .persistent) { errors, isDone in
                failed += errors as? [CFError] ?? []
                if isDone { done.signal() }
                return true
            }
            if done.wait(timeout: .now() + 3) == .timedOut {
                Logger.warn("unregistering \(url.lastPathComponent) by descriptor did not finish in time")
            } else if let first = failed.first {
                Logger.warn("unregistering \(url.lastPathComponent) by descriptor failed: \(first)")
            }
        }
    }

    private func registeredPhoneWideDescriptors() -> [(descriptor: CTFontDescriptor, url: URL)] {
        let descriptors = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
        let names = Set(Self.allFamilyNames)
        return descriptors.compactMap { d in
            guard
                let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String, names.contains(name),
                let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL
            else { return nil }
            return (d, url)
        }
    }

    /// Register the bundled set for every app on the phone, replacing an
    /// older copy. All four faces go in one call, so Settings › Fonts shows
    /// one family with four styles and Pages' B and I buttons reach them.
    /// iOS confirms with the user the first time. Apple's font-provider
    /// entitlement is what allows it.
    @MainActor
    public func installPhoneWide() async -> Result<Void, Error> {
        guard let current = Self.bundledSet else { return .failure(OWSGenericError("no bundled Qiuling font to install")) }

        unregisterPhoneWide(registeredPhoneWide().filter { !current.contains($0) })
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
            noteProblem("Installing for other apps failed: \((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)")
        }
        logStatus("phone-wide install")
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return result
    }

    private func registeredPhoneWide() -> [URL] {
        registeredPhoneWideDescriptors().map { $0.url }
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
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
