//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import SwiftUI
import UIKit

/// The practice tab's UIKit shell around the SwiftUI trainer.
@available(iOS 16, *)
final class PracticeHostViewController: UIHostingController<PracticeView> {
    init() {
        super.init(rootView: PracticeView())
        title = "Practice"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Brand.background
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The SwiftUI stack inside draws its own bars; the outer one would double them.
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }
}

/// Launching with `-QiulingPracticeOnly 1` (or that environment variable)
/// skips Signal entirely — no database, no registration — and shows the
/// trainer alone. For the simulator, where there is no account to link and
/// the point is to iterate on the trainer.
enum PracticeOnlyLaunch {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "QiulingPracticeOnly")
            || ProcessInfo.processInfo.environment["QIULING_PRACTICE_ONLY"] == "1"
    }

    /// Registers the bundled font (SignalUI would normally do this during its
    /// setup) and installs the trainer as the window's root.
    @MainActor
    static func launch(in window: UIWindow) {
        if let url = Bundle(for: SUIEnvironment.self).url(forResource: QiulingFonts.family, withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        if #available(iOS 16, *) {
            let nav = UINavigationController(rootViewController: PracticeHostViewController())
            nav.setNavigationBarHidden(true, animated: false)
            window.rootViewController = nav
        } else {
            window.rootViewController = UIViewController()
        }
        window.backgroundColor = Brand.background
        window.makeKeyAndVisible()
    }
}
