//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SignalServiceKit
import SignalUI
import SwiftUI
import UIKit

/// The Practice tab. Built like the other home tabs: the system navigation
/// bar carries the title, the avatar/settings button and the actions, and
/// the sections are pushed through Signal's navigation controller. Reading
/// aloud is the tab's content — the measure closest to the eyes — and the
/// typed race is a section behind the keyboard icon.
@available(iOS 16, *)
final class PracticeHostViewController: UIHostingController<ReadView>, HomeTabViewController {
    private let reading = ReadModel()
    private let race = RaceModel()

    init() {
        super.init(rootView: ReadView(model: reading))
        title = "Practice"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.groupedBackground

        if !PracticeOnlyLaunch.isRequested {
            navigationItem.leftBarButtonItem = createSettingsBarButtonItem(
                databaseStorage: SSKEnvironment.shared.databaseStorageRef,
                buildActions: { [$0] },
                showAppSettings: { [weak self] in
                    self?.presentFormSheet(AppSettingsViewController.inModalNavigationController(), animated: true)
                },
            )
        } else {
            // Without Signal behind it there is no account to show; the one
            // settings page that still applies is the alphabet's own.
            let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
                self?.navigationController?.pushViewController(QiulingSettingsViewController(), animated: true)
            })
            settings.accessibilityLabel = "Qiuling settings"
            navigationItem.leftBarButtonItem = settings
        }

        let more = UIMenu(children: [
            UIAction(title: "Write a message", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                self?.pushWrite()
            },
            UIAction(title: "Read the web in Safari", image: UIImage(systemName: "safari")) { [weak self] _ in
                self?.push(ReadWebView(), title: "Read the web")
            },
        ])
        let moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: more)
        moreItem.accessibilityLabel = "More"
        let progress = UIBarButtonItem(image: UIImage(systemName: "chart.line.uptrend.xyaxis"), primaryAction: UIAction { [weak self] _ in
            self?.pushProgress()
        })
        progress.accessibilityLabel = "Progress"
        let recall = UIBarButtonItem(image: UIImage(systemName: "rectangle.stack"), primaryAction: UIAction { [weak self] _ in
            self?.pushRecall()
        })
        recall.accessibilityLabel = "Recall"
        let type = UIBarButtonItem(image: UIImage(systemName: "keyboard"), primaryAction: UIAction { [weak self] _ in
            self?.pushType()
        })
        type.accessibilityLabel = "Type"
        navigationItem.rightBarButtonItems = [moreItem, progress, recall, type]
    }

    private func pushType() {
        let controller = PracticeSectionViewController(rootView: AnyView(TypeView(model: race)))
        controller.title = "Type"
        navigationController?.pushViewController(controller, animated: true)
    }

    private func push(_ view: some View, title: String) {
        let controller = PracticeSectionViewController(rootView: AnyView(view))
        controller.title = title
        navigationController?.pushViewController(controller, animated: true)
    }

    private func pushRecall() {
        navigationController?.pushViewController(RecallHostViewController(), animated: true)
    }

    private func pushWrite() {
        navigationController?.pushViewController(WriteHostViewController(), animated: true)
    }

    private func pushProgress() {
        let progress = ProgressTabView(
            race: { [weak self] in self?.navigationController?.popToRootViewController(animated: true) },
            recall: { [weak self] in self?.pushRecall() },
            typing: { [weak self] in self?.push(TypingProgressView(), title: "Typing") },
            // The owned model is set up directly, not through its defaults: a
            // passage mid-read is dropped for the test asked for.
            readTest: { [weak self] english in
                guard let self else { return }
                reading.source = .test
                reading.script = english ? .english : .qiuling
                reading.start()
                navigationController?.popToRootViewController(animated: true)
            },
        )
        push(progress, title: "Progress")
    }
}

/// One pushed section: the grouped background behind the SwiftUI content.
@available(iOS 16, *)
final class PracticeSectionViewController: UIHostingController<AnyView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.groupedBackground
    }
}

/// Recall, with the direction in the bar and the sitting's score as the
/// bar's subtitle where the system offers one.
@available(iOS 16, *)
final class RecallHostViewController: UIHostingController<RecallView> {
    private let model = RecallModel()
    private var cancellables = Set<AnyCancellable>()
    private lazy var directionItem = UIBarButtonItem(image: UIImage(systemName: "arrow.left.arrow.right"), menu: directionMenu)

    init() {
        super.init(rootView: RecallView(model: model))
        title = "Recall"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.groupedBackground
        directionItem.accessibilityLabel = "Direction"
        navigationItem.rightBarButtonItem = directionItem

        model.$blocks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] blocks in self?.directionItem.isEnabled = !blocks.isEmpty }
            .store(in: &cancellables)
        model.$seen.combineLatest(model.$hit)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSubtitle() }
            .store(in: &cancellables)
    }

    /// Built afresh each time it opens, so the check mark follows the choice.
    private var directionMenu: UIMenu {
        UIMenu(options: .singleSelection, children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                completion(Recall.Mode.allCases.map { mode in
                    UIAction(title: mode.title, state: self.model.mode == mode ? .on : .off) { [weak self] _ in
                        self?.model.mode = mode
                    }
                })
            },
        ])
    }

    private func updateSubtitle() {
        if #available(iOS 26, *) {
            navigationItem.subtitle = model.score
        }
    }
}

/// Write, with Clear in the bar. The draft lives in `UserDefaults` under
/// the view's `@AppStorage` key, so clearing it there is enough. The key
/// contains a dot, which KVO would read as a key path, so the bar item
/// follows the defaults-changed notification instead.
@available(iOS 16, *)
final class WriteHostViewController: UIHostingController<WriteView> {
    private lazy var clearItem = UIBarButtonItem(title: "Clear", primaryAction: UIAction { _ in
        UserDefaults.standard.set("", forKey: WriteView.draftKey)
    })
    private var observer: NSObjectProtocol?

    init() {
        super.init(rootView: WriteView())
        title = "Write"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.groupedBackground
        navigationItem.rightBarButtonItem = clearItem
        updateClear()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.updateClear()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateClear() {
        let draft = UserDefaults.standard.string(forKey: WriteView.draftKey) ?? ""
        clearItem.isEnabled = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        for url in QiulingFonts.bundledURLs {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        if #available(iOS 16, *) {
            window.rootViewController = OWSNavigationController(rootViewController: PracticeHostViewController())
        } else {
            window.rootViewController = UIViewController()
        }
        window.backgroundColor = UIColor.Signal.groupedBackground
        window.makeKeyAndVisible()
    }
}
