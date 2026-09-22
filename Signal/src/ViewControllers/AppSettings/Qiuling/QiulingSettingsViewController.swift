//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Settings › Qiuling: which alphabet the app draws with, where its copy came
/// from, and the two things a person can do about it — check for a newer
/// drawing, and install the font for Safari and other apps.
class QiulingSettingsViewController: OWSTableViewController2 {

    private let fonts = QiulingFonts.shared
    private var isChecking = false
    private var isInstalling = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Qiuling"
        updateTableContents()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontsDidChange),
            name: QiulingFonts.fontDidChange,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontsDidChange),
            name: QiulingFonts.statusDidChange,
            object: nil,
        )
        // The keyboard is added in the Settings app, so the answer can change
        // while we are in the background or while another keyboard is up.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontsDidChange),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontsDidChange),
            name: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateTableContents()
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateTableContents()
    }

    @objc
    private func fontsDidChange() {
        AssertIsOnMainThread()
        updateTableContents()
    }

    // MARK: - Contents

    private func updateTableContents() {
        let status = fonts.status
        let contents = OWSTableContents()

        let alphabet = OWSTableSection()
        alphabet.headerTitle = "Alphabet"
        alphabet.add(.label(withText: "Alphabet", accessoryText: status.displayName, accessoryType: .none))
        alphabet.add(.label(withText: "Marks", accessoryText: Self.countFormatter.string(from: NSNumber(value: status.marksCount)) ?? "\(status.marksCount)", accessoryType: .none))
        // Whether the process can draw the script at all: if this ever says
        // the system font, the log has the registration errors.
        alphabet.add(.label(
            withText: "Rendering",
            accessoryText: status.isResolvable ? "Qiuling" : "System font — Qiuling did not load",
            accessoryType: .none,
        ))
        // Bold and italic are drawn faces of the font, not the system's fakes,
        // once the set carries them; a set without them says so.
        alphabet.add(.label(
            withText: "Styles",
            accessoryText: status.facesCount == QiulingFonts.faces.count ? "Regular, bold, italic, bold italic"
                : status.facesCount == 0 ? "Regular only" : "Regular + \(status.facesCount) of \(QiulingFonts.faces.count) styles",
            accessoryType: .none,
        ))
        if let version = status.version {
            alphabet.add(.label(
                withText: "Version",
                accessoryText: version + (status.isUsingDownloadedCopy ? " (downloaded)" : " (included with the app)"),
                accessoryType: .none,
            ))
        } else {
            alphabet.add(.label(
                withText: "Copy in use",
                accessoryText: status.isUsingDownloadedCopy ? "Downloaded update" : "Included with the app",
                accessoryType: .none,
            ))
        }
        if let buildDate = status.buildDate {
            alphabet.add(.label(withText: "Built", accessoryText: Self.dateFormatter.string(from: buildDate), accessoryType: .none))
        }
        if let latest = status.latestVersion {
            alphabet.add(.label(withText: "Latest available", accessoryText: latest, accessoryType: .none))
        }
        alphabet.footerTitle = "Qiuling is the script used in Practice, Recall and Write. Marks are the letters and letter groups it draws as one shape. The alphabet is still being drawn, so the app keeps it current."
        contents.add(alphabet)

        let updates = OWSTableSection()
        updates.headerTitle = "Updates"
        if isChecking {
            updates.add(Self.busyItem(name: "Checking…"))
        } else if status.updatesAvailable {
            updates.add(OWSTableItem.item(name: "Check for updates", textColor: .Signal.accent) { [weak self] in
                self?.checkForUpdates()
            })
        } else {
            updates.add(OWSTableItem.item(name: "Check for updates", textColor: Theme.secondaryTextAndIconColor))
        }
        updates.footerTitle = Self.updatesFooter(for: status)
        contents.add(updates)

        let otherApps = OWSTableSection()
        otherApps.headerTitle = "Other apps"
        let installState: String
        switch status.phoneWide {
        case .installed: installState = "Installed"
        case .olderCopy: installState = "Older copy installed"
        case .notInstalled: installState = "Not installed"
        }
        otherApps.add(.label(withText: "Safari and other apps", accessoryText: installState, accessoryType: .none))
        let installName = status.phoneWide == .olderCopy ? "Update for other apps" : "Install for other apps"
        if isInstalling {
            otherApps.add(Self.busyItem(name: "Installing…"))
        } else if status.phoneWide == .installed {
            otherApps.add(OWSTableItem.item(name: installName, textColor: Theme.secondaryTextAndIconColor))
        } else {
            otherApps.add(OWSTableItem.item(name: installName, textColor: .Signal.accent) { [weak self] in
                self?.installPhoneWide()
            })
        }
        otherApps.footerTitle = "Safari and other apps use a copy of the font installed on your iPhone. iOS asks for permission the first time. You can remove it later in Settings, under General, then Fonts."
        contents.add(otherApps)

        let keyboard = OWSTableSection()
        keyboard.headerTitle = "Keyboard"
        let isKeyboardAdded = Self.isKeyboardAdded
        keyboard.add(.label(withText: "Qiuling keyboard", accessoryText: isKeyboardAdded ? "Added" : "Not added", accessoryType: .none))
        keyboard.add(OWSTableItem.item(
            name: isKeyboardAdded ? "Keyboard settings" : "Add the keyboard",
            textColor: .Signal.accent,
        ) {
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        })
        keyboard.add(OWSTableItem.item(name: "Try the keyboard", textColor: .Signal.accent) { [weak self] in
            self?.navigationController?.pushViewController(QiulingKeyboardTryViewController(), animated: true)
        })
        keyboard.footerTitle = isKeyboardAdded
            ? "Hold the globe key on any keyboard to switch to Qiuling. Tap the lock key to compose privately: your message stays in the keyboard until you insert it as Qiuling, or copy it as a picture with Picture. Pictures need Allow Full Access for the keyboard, in Settings under General, Keyboard, Keyboards, Qiuling. The keyboard never connects to the internet."
            : "Type with Qiuling anywhere. In Settings, tap General, then Keyboard, then Keyboards, then Add New Keyboard, and choose Qiuling. Then hold the globe key on any keyboard to switch to it. The keys show marks instead of letters, so what you type is hard to read over your shoulder."
        contents.add(keyboard)

        let typing = OWSTableSection()
        typing.headerTitle = "Typing"
        typing.add(OWSTableItem.switch(
            withText: "Mark misspellings",
            isOn: { QiulingTypingSettings.marksMisspellings },
            actionBlock: { uiSwitch in
                QiulingTypingSettings.marksMisspellings = uiSwitch.isOn
            },
        ))
        typing.footerTitle = "Words the dictionary doesn't know get a red dotted line while you write a message. Qiuling reads fast, so a slip is easy to miss."
        contents.add(typing)

        self.contents = contents
    }

    // MARK: - Keyboard

    /// The keyboard extension's bundle id: the app's, plus ".keyboard".
    static var keyboardBundleIdentifier: String { "\(Bundle.main.bundleIdentifier!).keyboard" }

    /// Whether the person has added the Qiuling keyboard in Settings.
    ///
    /// The public API exposes no bundle identifier for an input mode, but a
    /// third-party keyboard's mode describes itself with one, so we look for
    /// ours in the description. The extension also declares the otherwise
    /// unused language tag "mis", which is the fallback should the
    /// description ever stop carrying the identifier.
    static var isKeyboardAdded: Bool {
        let identifier = keyboardBundleIdentifier
        return UITextInputMode.activeInputModes.contains { mode in
            if String(describing: mode).contains(identifier) { return true }
            return mode.primaryLanguage == "mis"
        }
    }

    /// An action row while its action runs: secondary text, a spinner where
    /// the accessory would be, and nothing to tap.
    private static func busyItem(name: String) -> OWSTableItem {
        OWSTableItem(customCellBlock: {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            let cell = OWSTableItem.buildCell(
                itemName: name,
                textColor: Theme.secondaryTextAndIconColor,
                accessoryContentView: spinner,
            )
            cell.isUserInteractionEnabled = false
            return cell
        })
    }

    private static func updatesFooter(for status: QiulingFonts.Status) -> String {
        let sentence: String
        if !status.updatesAvailable {
            sentence = "Updates aren't available in this build."
        } else if let lastCheck = status.lastCheck {
            switch lastCheck.outcome {
            case .upToDate:
                let which = status.version.map { " (\($0))" } ?? ""
                sentence = "Last checked \(relativeDescription(of: lastCheck.date)). You have the latest alphabet\(which)."
            case .updated:
                sentence = "Updated to the latest alphabet just now."
            case .failed:
                sentence = "Couldn't check for updates. Try again when you're online."
            }
        } else {
            sentence = "Not checked yet."
        }
        return sentence + " Qiuling checks about once an hour while the app is open."
    }

    /// "today at 9:41 AM", "yesterday at 9:41 AM", "on Sep 18 at 9:41 AM".
    private static func relativeDescription(of date: Date) -> String {
        let time = timeFormatter.string(from: date)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
        return "on \(dayFormatter.string(from: date)) at \(time)"
    }

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    // MARK: - Actions

    private func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        updateTableContents()
        Task { @MainActor in
            _ = await fonts.checkForUpdates()
            isChecking = false
            updateTableContents()
        }
    }

    private func installPhoneWide() {
        guard !isInstalling else { return }
        isInstalling = true
        updateTableContents()
        Task { @MainActor in
            // A decline is not an error worth an alert: the row just stays
            // "Not installed" and the action stays available.
            _ = await fonts.installPhoneWide()
            isInstalling = false
            updateTableContents()
        }
    }
}

// MARK: - Typing

/// What the person has chosen about writing messages. Read by the compose
/// box, which watches `UserDefaults.didChangeNotification` for changes.
enum QiulingTypingSettings {
    private static let marksMisspellingsKey = "Qiuling.marksMisspellings"

    /// Whether the compose box underlines words the dictionary doesn't know.
    static var marksMisspellings: Bool {
        get { UserDefaults.standard.object(forKey: marksMisspellingsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: marksMisspellingsKey) }
    }
}

// MARK: - Try the keyboard

/// A blank field to type into with the Qiuling keyboard. Nothing typed here
/// is kept: the text lives in the view and goes with it.
class QiulingKeyboardTryViewController: OWSTableViewController2, UITextViewDelegate {

    private let textView = UITextView()
    private let placeholder = UILabel()

    // The footer is owned here rather than described to the table: changing
    // its text in place keeps the table from reloading the cell that hosts
    // the text view, which would take the keyboard down mid-sentence.
    private lazy var footer: UITextView = buildFooterTextView(withDeepInsets: true)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Try the keyboard"

        // No autocorrect or smart punctuation: the keyboard types marks, and
        // the system would only rewrite them into something it recognises.
        textView.font = UIFont(name: QiulingFonts.family, size: 28) ?? .systemFont(ofSize: 28)
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.returnKeyType = .default
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.autoSetDimension(.height, toSize: 120, relation: .greaterThanOrEqual)

        placeholder.text = "Type something"
        placeholder.font = .dynamicTypeBody
        placeholder.isUserInteractionEnabled = false

        applyTheme()
        buildTableContents()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardStateDidChange),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardStateDidChange),
            name: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    override func themeDidChange() {
        super.themeDidChange()
        applyTheme()
        // Recolour the persistent footer in place: rebuilding the table
        // would reload the cell and dismiss the keyboard.
        footer.textColor = Self.defaultFooterTextColor
        footer.backgroundColor = tableBackgroundColor
    }

    @objc
    private func keyboardStateDidChange() {
        AssertIsOnMainThread()
        updateFooter()
    }

    private func applyTheme() {
        textView.textColor = Brand.text
        textView.backgroundColor = Theme.tableCell2BackgroundColor
        placeholder.textColor = Theme.secondaryTextAndIconColor
    }

    private func footerText() -> String {
        QiulingSettingsViewController.isKeyboardAdded
            ? "Text you type here isn't saved."
            : "Add the Qiuling keyboard first, in Settings. Text you type here isn't saved."
    }

    private func updateFooter() {
        footer.text = footerText()
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    private func buildTableContents() {
        let contents = OWSTableContents()
        let section = OWSTableSection()
        section.add(OWSTableItem(customCellBlock: { [weak self] in
            let cell = OWSTableItem.newCell()
            cell.selectionStyle = .none
            guard let self else { return cell }

            // The table is built once, but the cell may still be re-created
            // by the table view, so the same text view moves into it and
            // keeps what was typed.
            self.textView.removeFromSuperview()
            self.placeholder.removeFromSuperview()
            cell.contentView.addSubview(self.textView)
            cell.contentView.addSubview(self.placeholder)
            self.textView.autoPinEdgesToSuperviewMargins()
            self.placeholder.autoPinEdge(.leading, to: .leading, of: self.textView)
            self.placeholder.autoPinEdge(.top, to: .top, of: self.textView)
            self.placeholder.isHidden = !self.textView.text.isEmpty
            return cell
        }))
        footer.text = footerText()
        section.customFooterView = footer
        section.customFooterHeight = UITableView.automaticDimension
        contents.add(section)
        self.contents = contents
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        // The cell grows with the text; tell the table so the field keeps
        // the whole message in view.
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }
}
