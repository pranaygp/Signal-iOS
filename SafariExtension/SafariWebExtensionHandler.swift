//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation
import SafariServices

/// The native side of the Qiuling Safari extension. The only thing the
/// background script asks for is the font: `{type: "font"}` is answered with
/// `{sha256, base64}` of the current Qiuling TTF.
///
/// The extension keeps itself current the same way the app does: the manifest
/// at `QiulingFontManifestURL` names the TTF and its SHA-256 for this build,
/// and a copy that differs from what is cached is fetched, verified and kept
/// in the extension's own container. It shares no state with the app on
/// purpose — Safari can be up to date even when the app has not been opened —
/// and the copy bundled with the extension is the fallback when there is no
/// network, no manifest URL, or nothing cached yet.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let buildId = "morph"
    private static let family = "QiulingMorphWrite-Regular"
    // Ten minutes, not an hour: a fix pushed while you are reading should be
    // a Safari restart away, and the check is one small GET.
    private static let checkInterval: TimeInterval = 10 * 60

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        let type = (message as? [String: Any])?["type"] as? String

        guard type == "font" else {
            complete(context, ["error": "unknown message type: \(type ?? "nil")"])
            return
        }
        Task {
            await refreshIfDue()
            complete(context, fontReply())
        }
    }

    private func complete(_ context: NSExtensionContext, _ reply: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    // MARK: - The font

    private func fontReply() -> [String: Any] {
        guard let data = cachedFontData() ?? bundledFontData() else {
            return ["error": "no font available"]
        }
        return ["sha256": Self.sha(data), "base64": data.base64EncodedString()]
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var store: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QiulingFonts", isDirectory: true)
    }
    private var defaults: UserDefaults { .standard }

    /// The downloaded copy, if its bytes still match the hash it was saved under.
    private func cachedFontData() -> Data? {
        guard let sha = defaults.string(forKey: "currentSha") else { return nil }
        let url = store.appendingPathComponent("\(sha).ttf")
        guard let data = try? Data(contentsOf: url), Self.sha(data) == sha else { return nil }
        return data
    }

    private func bundledFontData() -> Data? {
        let bundle = Bundle(for: SafariWebExtensionHandler.self)
        guard let url = bundle.url(forResource: Self.family, withExtension: "ttf") else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Over the air

    private struct ManifestEntry: Decodable { let family: String; let file: String; let sha256: String }

    private var manifestURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "QiulingFontManifestURL") as? String).flatMap { URL(string: $0) }
    }
    private var bypassToken: String? {
        (Bundle.main.object(forInfoDictionaryKey: "QiulingFontBypass") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if let bypassToken { r.setValue(bypassToken, forHTTPHeaderField: "x-vercel-protection-bypass") }
        return r
    }

    /// At most once an hour, and never blocking the reply for long: a failed
    /// or slow check leaves the cached (or bundled) font in place.
    private func refreshIfDue() async {
        guard let manifestURL, bypassToken != nil else { return }
        let last = defaults.object(forKey: "lastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        defaults.set(Date(), forKey: "lastCheck")
        do {
            let (data, response) = try await URLSession.shared.data(for: request(manifestURL))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let manifest = try JSONDecoder().decode([String: ManifestEntry].self, from: data)
            guard let entry = manifest[Self.buildId], entry.family == Self.family else { return }
            let have = defaults.string(forKey: "currentSha") ?? bundledFontData().map(Self.sha)
            guard entry.sha256 != have else { return }

            let fontURL = manifestURL.deletingLastPathComponent().appendingPathComponent(entry.file)
            let (bytes, fontResponse) = try await URLSession.shared.data(for: request(fontURL))
            guard (fontResponse as? HTTPURLResponse)?.statusCode == 200, Self.sha(bytes) == entry.sha256 else { return }

            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            let dest = store.appendingPathComponent("\(entry.sha256).ttf")
            try bytes.write(to: dest, options: .atomic)
            for old in (try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)) ?? [] where old != dest {
                try? FileManager.default.removeItem(at: old)
            }
            defaults.set(entry.sha256, forKey: "currentSha")
        } catch {
            // Next hour.
        }
    }
}
