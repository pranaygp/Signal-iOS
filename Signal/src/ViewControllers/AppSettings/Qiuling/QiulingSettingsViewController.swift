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
        if let buildDate = status.buildDate {
            alphabet.add(.label(withText: "Built", accessoryText: Self.dateFormatter.string(from: buildDate), accessoryType: .none))
        }
        alphabet.add(.label(
            withText: "Copy in use",
            accessoryText: status.isUsingDownloadedCopy ? "Downloaded update" : "Included with the app",
            accessoryType: .none,
        ))
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

        self.contents = contents
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
                sentence = "Last checked \(relativeDescription(of: lastCheck.date)). You have the latest alphabet."
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
