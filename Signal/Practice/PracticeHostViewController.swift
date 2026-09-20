//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import SwiftUI
import UIKit

/// The Practice tab. Built like the other home tabs: the system navigation
/// bar carries the title, the avatar/settings button and the actions, and
/// the sections are pushed through Signal's navigation controller. The type
/// race is the tab's content.
@available(iOS 16, *)
final class PracticeHostViewController: UIHostingController<TypeView>, HomeTabViewController {
    private let race = RaceModel()

    init() {
        super.init(rootView: TypeView(model: race))
        title = "Practice"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Brand.background

        if !PracticeOnlyLaunch.isRequested {
            navigationItem.leftBarButtonItem = createSettingsBarButtonItem(
                databaseStorage: SSKEnvironment.shared.databaseStorageRef,
                buildActions: { [$0] },
                showAppSettings: { [weak self] in
                    self?.presentFormSheet(AppSettingsViewController.inModalNavigationController(), animated: true)
                },
            )
        }

        let more = UIMenu(children: [
            UIAction(title: "Write a message", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                self?.push(WriteView(), title: "Write")
            },
            UIAction(title: "Read the web in Qiuling", image: UIImage(systemName: "safari")) { [weak self] _ in
                self?.push(ReadWebView(), title: "Read the web")
            },
        ])
        let recall = UIBarButtonItem(image: UIImage(systemName: "eye"), primaryAction: UIAction { [weak self] _ in
            self?.push(RecallView(), title: "Recall")
        })
        recall.accessibilityLabel = "Recall"
        let progress = UIBarButtonItem(image: UIImage(systemName: "chart.xyaxis.line"), primaryAction: UIAction { [weak self] _ in
            self?.push(ProgressTabView(), title: "Progress")
        })
        progress.accessibilityLabel = "Progress"
        let moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: more)
        moreItem.accessibilityLabel = "More"
        navigationItem.rightBarButtonItems = [moreItem, progress, recall]
    }

    private func push(_ view: some View, title: String) {
        let controller = PracticeSectionViewController(rootView: AnyView(view))
        controller.title = title
        navigationController?.pushViewController(controller, animated: true)
    }
}

/// One pushed section: the paper background behind the SwiftUI content.
@available(iOS 16, *)
final class PracticeSectionViewController: UIHostingController<AnyView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Brand.background
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
            window.rootViewController = OWSNavigationController(rootViewController: PracticeHostViewController())
        } else {
            window.rootViewController = UIViewController()
        }
        window.backgroundColor = Brand.background
        window.makeKeyAndVisible()
    }
}
