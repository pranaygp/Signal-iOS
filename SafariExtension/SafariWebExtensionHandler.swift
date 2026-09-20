//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation
import SafariServices

/// The native side of the Qiuling Safari extension. The only thing the
/// background script asks for is the font: `{type: "font"}` is answered with
/// `{sha256, base64}` of the current Qiuling TTF.
///
/// The app keeps the current font (bundled or downloaded over the air) in the
/// shared App Group container as `QiulingFonts/current.ttf`, with
/// `QiulingFonts/current.json` (`{"family","sha256","buildId"}`) beside it.
/// Before the app has run once on a fresh install those files do not exist,
/// so the copy of the TTF bundled with this extension is the fallback.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        let type = (message as? [String: Any])?["type"] as? String

        let reply: [String: Any]
        switch type {
        case "font":
            reply = fontReply()
        default:
            reply = ["error": "unknown message type: \(type ?? "nil")"]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    // MARK: - The font

    private func fontReply() -> [String: Any] {
        guard let data = currentFontData() else {
            return ["error": "no font available"]
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ["sha256": sha, "base64": data.base64EncodedString()]
    }

    /// The app-group copy if it is there and intact, else the bundled TTF.
    private func currentFontData() -> Data? {
        if let data = appGroupFontData() {
            return data
        }
        return bundledFontData()
    }

    private func appGroupFontData() -> Data? {
        guard
            let prefix = Bundle.main.object(forInfoDictionaryKey: "OWSBundleIDPrefix") as? String,
            !prefix.isEmpty,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.\(prefix).signal.group"
            )
        else {
            return nil
        }
        let directory = container.appendingPathComponent("QiulingFonts", isDirectory: true)
        let ttfURL = directory.appendingPathComponent("current.ttf")
        let jsonURL = directory.appendingPathComponent("current.json")
        guard let data = try? Data(contentsOf: ttfURL), !data.isEmpty else {
            return nil
        }
        // If the app wrote a manifest, the file must match it; a half-written
        // swap must not reach the page.
        if
            let json = try? Data(contentsOf: jsonURL),
            let manifest = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let expected = manifest["sha256"] as? String,
            !expected.isEmpty
        {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                return nil
            }
        }
        return data
    }

    private func bundledFontData() -> Data? {
        let bundle = Bundle(for: SafariWebExtensionHandler.self)
        let name = "QiulingMorphWrite-Regular"
        let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Resources")
            ?? bundle.url(forResource: name, withExtension: "ttf")
        guard let url else { return nil }
        return try? Data(contentsOf: url)
    }
}
