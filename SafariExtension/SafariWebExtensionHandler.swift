//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation
import SafariServices

/// The native side of the Qiuling Safari extension. The only thing the
/// background script asks for is the font: `{type: "font"}` is answered with
/// `{sha256, base64}` of the current Qiuling TTF, plus `faces: {bold: {sha256,
/// base64}, italic: …, bolditalic: …}` for the derived faces the set carries,
/// so a page's <b> and <i> get drawn faces rather than Safari's synthetic ones.
///
/// The extension keeps itself current the same way the app does: the manifest
/// at `QiulingFontManifestURL` names the TTF and its SHA-256 for this build
/// (and the faces under `faces`), and a set that differs from what is cached
/// is fetched, verified and kept in the extension's own container — all of it
/// or none, so the faces always match the regular. It shares no state with
/// the app on purpose — Safari can be up to date even when the app has not
/// been opened — and the copies bundled with the extension are the fallback
/// when there is no network, no manifest URL, or nothing cached yet.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let buildId = "morph"
    private static let family = "QiulingMorphWrite-Regular"
    /// Manifest key -> bundled file stem, for the derived faces.
    private static let faces: [(key: String, file: String)] = [
        ("bold", "QiulingMorphWrite-Bold"), ("italic", "QiulingMorphWrite-Italic"), ("bolditalic", "QiulingMorphWrite-BoldItalic"),
    ]
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
        // The cached set when it is whole, else the bundled one: never a
        // cached regular with bundled faces, which would be two drawings.
        let set = cachedSet() ?? bundledSet()
        guard let regular = set.regular else {
            return ["error": "no font available"]
        }
        var reply: [String: Any] = ["sha256": Self.sha(regular), "base64": regular.base64EncodedString()]
        var faces: [String: Any] = [:]
        for (key, data) in set.faces {
            faces[key] = ["sha256": Self.sha(data), "base64": data.base64EncodedString()]
        }
        reply["faces"] = faces
        return reply
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var store: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QiulingFonts", isDirectory: true)
    }
    private var defaults: UserDefaults { .standard }

    private struct FontSet {
        var regular: Data?
        var faces: [String: Data] = [:]
    }

    /// The downloaded set, if every file's bytes still match the hash it was
    /// saved under; a set missing any face is not offered.
    private func cachedSet() -> FontSet? {
        guard let sha = defaults.string(forKey: "currentSha") else { return nil }
        func read(_ sha: String) -> Data? {
            let url = store.appendingPathComponent("\(sha).ttf")
            guard let data = try? Data(contentsOf: url), Self.sha(data) == sha else { return nil }
            return data
        }
        guard let regular = read(sha) else { return nil }
        var set = FontSet(regular: regular)
        for (key, faceSha) in defaults.dictionary(forKey: "currentFaces") as? [String: String] ?? [:] {
            guard let data = read(faceSha) else { return nil }
            set.faces[key] = data
        }
        return set
    }

    private func bundledSet() -> FontSet {
        let bundle = Bundle(for: SafariWebExtensionHandler.self)
        func read(_ stem: String) -> Data? {
            bundle.url(forResource: stem, withExtension: "ttf").flatMap { try? Data(contentsOf: $0) }
        }
        var set = FontSet(regular: read(Self.family))
        for face in Self.faces {
            if let data = read(face.file) { set.faces[face.key] = data }
        }
        return set
    }

    // MARK: - Over the air

    private struct ManifestFace: Decodable { let file: String; let sha256: String }
    private struct ManifestEntry: Decodable {
        let family: String
        let file: String
        let sha256: String
        let faces: [String: ManifestFace]?
    }

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

    private func fetchVerified(_ file: String, sha256: String, manifestURL: URL) async throws -> Data {
        let url = manifestURL.deletingLastPathComponent().appendingPathComponent(file)
        let (bytes, response) = try await URLSession.shared.data(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200, Self.sha(bytes) == sha256 else {
            throw URLError(.badServerResponse)
        }
        return bytes
    }

    /// At most once every ten minutes, and never blocking the reply for long:
    /// a failed or slow check leaves the cached (or bundled) set in place.
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
            let wantFaces = (entry.faces ?? [:]).filter { key, _ in Self.faces.contains { $0.key == key } }
            let have = cachedSet() ?? bundledSet()
            let haveSha = have.regular.map(Self.sha)
            let haveFaces = have.faces.mapValues(Self.sha)
            guard entry.sha256 != haveSha || wantFaces.mapValues { $0.sha256 } != haveFaces else { return }

            // Every file first, then the store: half a set is worse than an old one.
            let regular = try await fetchVerified(entry.file, sha256: entry.sha256, manifestURL: manifestURL)
            var faces: [String: Data] = [:]
            for (key, face) in wantFaces {
                faces[key] = try await fetchVerified(face.file, sha256: face.sha256, manifestURL: manifestURL)
            }
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            var keep: Set<URL> = []
            for data in [regular] + Array(faces.values) {
                let dest = store.appendingPathComponent("\(Self.sha(data)).ttf")
                try data.write(to: dest, options: .atomic)
                keep.insert(dest)
            }
            for old in (try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(old) {
                try? FileManager.default.removeItem(at: old)
            }
            defaults.set(entry.sha256, forKey: "currentSha")
            defaults.set(wantFaces.mapValues { $0.sha256 }, forKey: "currentFaces")
        } catch {
            // Next time.
        }
    }
}
