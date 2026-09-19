//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import CryptoKit
import SignalServiceKit
import SignalUI
import UIKit

/// Makes the bundled Qiuling font available to every app on the phone, not
/// just this one, so a TestFlight build is also how the font gets updated.
///
/// This is Apple's font-provider mechanism (the `com.apple.developer.user-fonts`
/// entitlement): a persistent registration puts the font under Settings ›
/// General › Fonts, where Pages, Word and any app with a font menu can use it.
/// iOS asks the user to confirm the first time; after that a changed file is
/// swapped in silently by unregistering the old copy first.
enum QiulingFontInstaller {

    private static let fontResources = ["QiulingOneFiveWrite-Regular"]
    private static let installedHashKey = "QiulingFontInstaller.installedHash"

    /// Call once the UI is up: the confirmation sheet needs a window.
    static func installIfNeeded() {
        AssertIsOnMainThread()
        let bundle = Bundle(for: SUIEnvironment.self)
        let urls = fontResources.compactMap { bundle.url(forResource: $0, withExtension: "ttf") }
        guard !urls.isEmpty else {
            return Logger.warn("no Qiuling font in the bundle")
        }

        let hash = urls
            .compactMap { try? Data(contentsOf: $0) }
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            .joined(separator: ",")
        let defaults = UserDefaults.standard
        if defaults.string(forKey: installedHashKey) == hash, !registeredCopies().isEmpty {
            return
        }

        // An older copy under the same name blocks the new one, so it goes first.
        let stale = registeredCopies()
        if !stale.isEmpty {
            CTFontManagerUnregisterFontURLs(stale as CFArray, .persistent) { _, _ in true }
        }

        CTFontManagerRegisterFontURLs(urls as CFArray, .persistent, true) { errors, done in
            let errors = errors as? [CFError] ?? []
            if done {
                DispatchQueue.main.async {
                    if errors.isEmpty {
                        defaults.set(hash, forKey: installedHashKey)
                        Logger.info("Qiuling installed for the whole phone")
                    } else {
                        Logger.warn("Qiuling font registration: \(errors)")
                    }
                }
            }
            return true
        }
    }

    /// The Qiuling files currently registered for the phone, if any.
    private static func registeredCopies() -> [URL] {
        let descriptors = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
        return descriptors.compactMap { d -> URL? in
            guard
                let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String,
                fontResources.contains(name),
                let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL
            else { return nil }
            return url
        }
    }
}
