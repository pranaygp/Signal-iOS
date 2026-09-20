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
    private let installedShaKey = "QiulingFonts.installedSha"
    private let lastCheckKey = "QiulingFonts.lastCheck"
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
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main,
        ) { [weak self] _ in self?.checkForUpdateIfDue() }
        checkForUpdateIfDue()
    }

    // MARK: - Over the air

    private var checking = false

    @MainActor
    private func checkForUpdateIfDue() {
        guard let manifestURL, bypassToken != nil else { return }
        let last = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > minimumCheckInterval, !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                try await checkForUpdate(manifestURL: manifestURL)
                defaults.set(Date(), forKey: lastCheckKey)
            } catch {
                Logger.warn("Qiuling font update check failed: \(error)")
            }
        }
    }

    private struct ManifestEntry: Decodable { let family: String; let file: String; let sha256: String; let blocks: String? }

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

    @MainActor
    private func checkForUpdate(manifestURL: URL) async throws {
        let (data, response) = try await URLSession.shared.data(for: request(manifestURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OWSGenericError("manifest: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let manifest = try JSONDecoder().decode([String: ManifestEntry].self, from: data)
        guard let entry = manifest[Self.buildId] else { throw OWSGenericError("manifest has no \(Self.buildId)") }
        guard entry.family == Self.family else { throw OWSGenericError("manifest family \(entry.family) is not \(Self.family)") }

        let have = defaults.string(forKey: currentShaKey) ?? Self.bundledSha
        guard entry.sha256 != have else { return }

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
        Logger.info("Qiuling font updated to \(sha.prefix(8))")

        swapForProcess(to: dest)
        installPhoneWideIfNeeded()
        NotificationCenter.default.post(name: Self.fontDidChange, object: nil)
    }

    /// Posted after a new font (and its block list) has been swapped in.
    public static let fontDidChange = Notification.Name("QiulingFonts.fontDidChange")

    /// Replace the process's copy of the family with the new file and ask the
    /// UI to redraw. Text already laid out keeps its old glyphs until it is
    /// rebuilt; the theme-change notification rebuilds most of it.
    @MainActor
    private func swapForProcess(to url: URL) {
        if let old = processRegisteredURL {
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

    // MARK: - Phone-wide

    /// Register the current font for every app on the phone (Settings ›
    /// General › Fonts), replacing an older copy. iOS confirms with the user
    /// the first time. Apple's font-provider entitlement is what allows it.
    @MainActor
    private func installPhoneWideIfNeeded() {
        let url = currentDownloadedURL ?? Self.bundledURL
        guard let url else { return Logger.warn("no Qiuling font to install") }
        let sha = defaults.string(forKey: currentShaKey) ?? Self.bundledSha
        if defaults.string(forKey: installedShaKey) == sha, !registeredPhoneWide().isEmpty { return }

        let stale = registeredPhoneWide()
        if !stale.isEmpty {
            CTFontManagerUnregisterFontURLs(stale as CFArray, .persistent) { _, _ in true }
        }
        CTFontManagerRegisterFontURLs([url] as CFArray, .persistent, true) { [defaults, installedShaKey] errors, done in
            let errors = errors as? [CFError] ?? []
            if done {
                DispatchQueue.main.async {
                    if errors.isEmpty {
                        defaults.set(sha, forKey: installedShaKey)
                        Logger.info("Qiuling installed for the whole phone (\(sha.prefix(8)))")
                    } else {
                        Logger.warn("Qiuling phone-wide registration: \(errors)")
                    }
                }
            }
            return true
        }
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
        guard let url = currentDownloadedURL ?? Self.bundledURL else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Bundled copy

    static let bundledURL: URL? = Bundle(for: QiulingFonts.self).url(forResource: family, withExtension: "ttf")
    static let bundledSha: String = {
        guard let url = bundledURL, let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()
}
