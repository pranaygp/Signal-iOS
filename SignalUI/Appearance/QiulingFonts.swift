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
/// The trainer is behind Deployment Protection; requests carry the project's
/// bypass token (`QiulingFontBypass`, also injected at build time and never
/// in source). Without a URL or token, everything here degrades to "use the
/// bundled font", which is what a build from a clean checkout does.
public final class QiulingFonts {

    public static let shared = QiulingFonts()

    /// The build id in the manifest, and the family that build produces.
    public static let buildId = "morph"
    public static let family = "QiulingMorphWrite-Regular"

    private let defaults = UserDefaults.standard
    private let currentShaKey = "QiulingFonts.currentSha"
    private let currentBuiltAtKey = "QiulingFonts.currentBuiltAt"
    private let installedShaKey = "QiulingFonts.installedSha"
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

    /// The downloaded font this process should use instead of the bundled one, if any.
    private var currentDownloadedURL: URL? {
        guard let sha = defaults.string(forKey: currentShaKey) else { return nil }
        let url = fileURL(sha: sha)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file the current font comes from, and its hash: the downloaded copy
    /// when there is one, else the bundled file.
    private var currentFont: (url: URL, sha: String)? {
        if let url = currentDownloadedURL, let sha = defaults.string(forKey: currentShaKey) { return (url, sha) }
        guard let url = Self.bundledURL else { return nil }
        return (url, Self.bundledSha)
    }

    /// The URL currently registered for this process, so a swap can unregister it.
    private var processRegisteredURL: URL?

    // MARK: - Process registration

    /// Called by SignalUI's font registration, before it registers the bundle's
    /// fonts. Registers the downloaded copy, if there is one, and says so, so
    /// the bundled file of the same family is skipped rather than colliding.
    func registerCurrentForProcess() -> Bool {
        guard let url = currentDownloadedURL else { return false }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            Logger.warn("downloaded font failed to register, falling back to the bundled one: \(String(describing: error?.takeRetainedValue()))")
            defaults.removeObject(forKey: currentShaKey)
            defaults.removeObject(forKey: currentBuiltAtKey)
            return false
        }
        processRegisteredURL = url
        Logger.info("using downloaded Qiuling font \(url.lastPathComponent)")
        return true
    }

    /// Whether `registerCurrentForProcess` took over the family this bundle file provides.
    func providesFont(atBundleURL url: URL) -> Bool {
        processRegisteredURL != nil && url.deletingPathExtension().lastPathComponent == Self.family
    }

    func noteBundledFontRegistered(at url: URL) {
        if processRegisteredURL == nil, url.deletingPathExtension().lastPathComponent == Self.family {
            processRegisteredURL = url
        }
    }

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
        /// When the font in use was built, if known.
        public let buildDate: Date?
        /// The last update check, or nil if there has never been one.
        public let lastCheck: LastCheck?
        /// Whether this build knows where to look for updates.
        public let updatesAvailable: Bool
        public let phoneWide: PhoneWideStatus
        /// How many letters and letter groups the font draws as one shape.
        public let marksCount: Int
    }

    /// Posted whenever anything in `status` may have changed.
    public static let statusDidChange = Notification.Name("QiulingFonts.statusDidChange")

    public var status: Status {
        let current = currentFont
        let downloaded = currentDownloadedURL != nil
        return Status(
            family: Self.family,
            buildId: Self.buildId,
            sha: current?.sha ?? "",
            isUsingDownloadedCopy: downloaded,
            buildDate: downloaded ? downloadedBuildDate : Self.bundledBuildDate,
            lastCheck: lastCheck,
            updatesAvailable: manifestURL != nil && bypassToken != nil,
            phoneWide: phoneWideStatus(currentSha: current?.sha),
            marksCount: blocks.count,
        )
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
            ?? currentDownloadedURL.flatMap(Self.builtDate(ofFontAt:))
    }

    /// When the bundled font was built: the app's build stamp when the build
    /// script left one, else the file's own date, which the copy into the
    /// bundle preserves.
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

    private func phoneWideStatus(currentSha: String?) -> PhoneWideStatus {
        let registered = registeredPhoneWide()
        guard !registered.isEmpty else { return .notInstalled }
        if let currentSha, defaults.string(forKey: installedShaKey) == currentSha { return .installed }
        return .olderCopy
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

    private struct ManifestEntry: Decodable {
        let family: String
        let file: String
        let sha256: String
        let blocks: String?
        let builtAt: String?
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

    /// Returns whether a new font was downloaded and swapped in.
    @MainActor
    private func checkForUpdate(manifestURL: URL) async throws -> Bool {
        let (data, response) = try await URLSession.shared.data(for: request(manifestURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OWSGenericError("manifest: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let manifest = try JSONDecoder().decode([String: ManifestEntry].self, from: data)
        guard let entry = manifest[Self.buildId] else { throw OWSGenericError("manifest has no \(Self.buildId)") }
        guard entry.family == Self.family else { throw OWSGenericError("manifest family \(entry.family) is not \(Self.family)") }

        let have = defaults.string(forKey: currentShaKey) ?? Self.bundledSha
        guard entry.sha256 != have else {
            // The manifest may have learnt the build date since the copy landed.
            if let builtAt = entry.builtAt, defaults.string(forKey: currentShaKey) != nil {
                defaults.set(builtAt, forKey: currentBuiltAtKey)
            }
            return false
        }

        let fontURL = manifestURL.deletingLastPathComponent().appendingPathComponent(entry.file)
        let (bytes, fontResponse) = try await URLSession.shared.data(for: request(fontURL))
        guard (fontResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw OWSGenericError("font: HTTP \((fontResponse as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard sha == entry.sha256 else { throw OWSGenericError("font hash mismatch") }

        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let dest = fileURL(sha: sha)
        try bytes.write(to: dest, options: .atomic)
        var keep: Set<URL> = [dest]
        if let blocksFile = entry.blocks {
            let blocksURL = manifestURL.deletingLastPathComponent().appendingPathComponent(blocksFile)
            if let (blocks, r) = try? await URLSession.shared.data(for: request(blocksURL)), (r as? HTTPURLResponse)?.statusCode == 200,
               (try? JSONDecoder().decode([String].self, from: blocks)) != nil {
                let blocksDest = storeDirectory.appendingPathComponent("\(sha).blocks.json")
                try blocks.write(to: blocksDest, options: .atomic)
                keep.insert(blocksDest)
            }
        }
        // Keep only the new files; anything else in the store is superseded.
        for old in (try? FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(old) {
            try? FileManager.default.removeItem(at: old)
        }
        defaults.set(sha, forKey: currentShaKey)
        if let builtAt = entry.builtAt {
            defaults.set(builtAt, forKey: currentBuiltAtKey)
        } else {
            defaults.removeObject(forKey: currentBuiltAtKey)
        }
        Logger.info("Qiuling font updated to \(sha.prefix(8))")

        swapForProcess(to: dest)
        mirrorForExtension()
        installPhoneWideIfNeeded()
        NotificationCenter.default.post(name: Self.fontDidChange, object: nil)
        return true
    }

    /// Posted after a new font (and its block list) has been swapped in.
    public static let fontDidChange = Notification.Name("QiulingFonts.fontDidChange")

    /// Replace the process's copy of the family with the new file and ask the
    /// UI to redraw. Text already laid out keeps its old glyphs until it is
    /// rebuilt; the theme-change notification rebuilds most of it.
    @MainActor
    private func swapForProcess(to url: URL) {
        // A launch that registered the bundled file itself (the practice-only
        // simulator run) never told us; the bundled file is what to replace.
        if let old = processRegisteredURL ?? Self.bundledURL {
            CTFontManagerUnregisterFontsForURL(old as CFURL, .process, nil)
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            processRegisteredURL = url
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        } else {
            Logger.warn("could not swap font in-process: \(String(describing: error?.takeRetainedValue())); it applies on next launch")
        }
    }

    // MARK: - Safari extension

    /// The Safari extension cannot read this app's container, so the font in
    /// use is mirrored into the shared App Group: `QiulingFonts/current.ttf`
    /// beside a `current.json` naming its family, hash and build. Written at
    /// launch and after every swap; skipped when the mirror already matches.
    private func mirrorForExtension() {
        guard let current = currentFont else { return }
        let group = "group.\(Bundle.main.bundleIdPrefix).signal.group"
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return Logger.warn("no App Group container for \(group); the Safari extension gets no font")
        }
        let directory = container.appendingPathComponent("QiulingFonts", isDirectory: true)
        let fontDest = directory.appendingPathComponent("current.ttf")
        let infoDest = directory.appendingPathComponent("current.json")
        let info: [String: String] = ["family": Self.family, "sha256": current.sha, "buildId": Self.buildId]
        DispatchQueue.global(qos: .utility).async {
            do {
                if
                    let existing = try? Data(contentsOf: infoDest),
                    let existingInfo = try? JSONDecoder().decode([String: String].self, from: existing),
                    existingInfo == info,
                    FileManager.default.fileExists(atPath: fontDest.path)
                {
                    return
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(contentsOf: current.url).write(to: fontDest, options: .atomic)
                try JSONEncoder().encode(info).write(to: infoDest, options: .atomic)
                Logger.info("mirrored Qiuling font \(current.sha.prefix(8)) for the Safari extension")
            } catch {
                Logger.warn("could not mirror the Qiuling font for the Safari extension: \(error)")
            }
        }
    }

    // MARK: - Phone-wide

    /// Register the current font for every app on the phone (Settings ›
    /// General › Fonts) when the installed copy is not the one in use.
    @MainActor
    private func installPhoneWideIfNeeded() {
        guard let current = currentFont else { return Logger.warn("no Qiuling font to install") }
        if defaults.string(forKey: installedShaKey) == current.sha, !registeredPhoneWide().isEmpty { return }
        Task { _ = await installPhoneWide() }
    }

    /// Register the current font for every app on the phone, replacing an
    /// older copy. iOS confirms with the user the first time. Apple's
    /// font-provider entitlement is what allows it.
    @MainActor
    public func installPhoneWide() async -> Result<Void, Error> {
        guard let current = currentFont else { return .failure(OWSGenericError("no Qiuling font to install")) }

        let stale = registeredPhoneWide().filter { $0 != current.url }
        if !stale.isEmpty {
            CTFontManagerUnregisterFontURLs(stale as CFArray, .persistent) { _, _ in true }
        }
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            // The handler runs once per font and once more when done; only the
            // last call may resume, and only once.
            var resumed = false
            var collected: [CFError] = []
            CTFontManagerRegisterFontURLs([current.url] as CFArray, .persistent, true) { errors, done in
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
            Logger.info("Qiuling installed for the whole phone (\(current.sha.prefix(8)))")
        case .failure(let error):
            Logger.warn("Qiuling phone-wide registration: \(error)")
        }
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return result
    }

    private func registeredPhoneWide() -> [URL] {
        let descriptors = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
        return descriptors.compactMap { d -> URL? in
            guard
                let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String, name == Self.family,
                let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL
            else { return nil }
            return url
        }
    }

    /// The bytes of the font in use — the downloaded copy if there is one.
    public func currentFontData() -> Data? {
        guard let url = currentFont?.url else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Bundled copy

    static let bundledURL: URL? = Bundle(for: QiulingFonts.self).url(forResource: family, withExtension: "ttf")
    static let bundledSha: String = {
        guard let url = bundledURL, let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()
}
