# Q — Signal in Qiuling

The app is called **Q** on the phone and its bundle ID is `<prefix>.q` (the
extensions are `<prefix>.q.SignalNSE` and `<prefix>.q.shareextension`). It is
Signal with Qiuling on top, and more of Qiuling will land here over time.

This branch sets message text in Qiuling — bubbles, the compose box and the
chat-list preview — so a glance at the screen shows the script, not English.
Everything else in the app is unchanged. The change is one Swift file,
`SignalUI/UIKitExtensions/UIFont+Qiuling.swift`, five one-line call-site
edits, and the font in `SignalUI/Fonts`.

## The font: bundled, phone-wide, and over the air

The bundled font is **Qiuling Morph** (`QiulingMorphWrite-Regular`, from
`node tools/build_font.js --alphabet morph` in the qiuling repo). Message text
is set in it; nothing else in the app is.

`QiulingFonts` (SignalUI) keeps it current without an app release. Every font
build publishes `web/fonts/<family>.ttf` and `web/fonts/manifest.json` into the
trainer; on launch and when the app becomes active (at most hourly) the app
reads the manifest, and if the hash for build id `morph` differs from what it
has, downloads the TTF, verifies it, swaps it in for the running process and
re-registers it for the whole phone. So: rebuild the font, push `main` (which
deploys the trainer), open the app — new glyphs. The bundled copy is the
fallback and what a clean checkout builds with.

The trainer is behind Deployment Protection, so the app sends the project's
bypass token. **The token is never in source**: `Config/qiuling.env`
(gitignored) holds `QIULING_FONT_BYPASS` and `QIULING_FONT_MANIFEST_URL`, and
`Scripts/qiuling-ship.sh` passes them as build settings that land in
`Info.plist`. Rotate it under the Vercel project's Deployment Protection
settings if a build ever leaks. Without the two settings the app just uses its
bundled font.

Phone-wide installation uses Apple's font-provider entitlement
(`com.apple.developer.user-fonts`): the current copy is registered
persistently, so it appears under Settings › General › Fonts for Pages, Word
and any app with a font menu. iOS confirms with the user the first time; a
changed file replaces the old registration.

## The Practice tab

A fourth tab in the home bar (Chats · Calls · Practice · Stories) carries the
reading trainer natively — SwiftUI, Liquid Glass on iOS 26, the Vermilion
palette — with the same features as `web/read.html`. It is built like the
other home tabs: the system navigation bar carries the title, the avatar and
settings button, and the actions; sections push through Signal's navigation
controller. The tab lands straight on the type race (sentences, words, or
your own text; 15–120 s); the bar's icons push recall (a mark and four
spellings) and progress across sittings, and its "…" menu holds write
(English in, a Qiuling picture out, to share into any chat) and the Safari
bookmark that sets pages in the script. Controls are the system's — segmented
pickers, glass buttons on iOS 26 with bordered fallbacks, menus, Charts,
ShareLink — tinted with the brand red; only the content cards are custom. It
lives in `Signal/Practice/`:

- `PracticeEngine.swift` — the race engine ported from `web/read.js`, plus the
  segmenter. Rather than carrying the ligature rules, it asks CoreText how the
  font shapes each word (`CTRunGetStringIndices`), so it agrees with the
  screen for whatever alphabet is current, downloaded copies included. The
  corpus (`Resources/corpus.txt`, the trainer's) and per-alphabet stats
  (`Application Support/Practice/<build>.json`) sit beside it.
- `TypeView.swift`, `PracticeSections.swift`, `PracticeTheme.swift` — the
  screens.
- `PracticeHostViewController.swift` — the tab's view controller (nav items,
  pushes), and the `-QiulingPracticeOnly 1` launch path.

### Trying it in the simulator

```sh
Scripts/qiuling-sim.sh          # build (incrementally), boot, install, open on the trainer
Scripts/qiuling-sim.sh full     # the whole app instead
```

The default launches with `-QiulingPracticeOnly 1`, which makes the app
delegate stop before any of Signal starts — no database, no registration —
and put the trainer up alone. Nothing else is reachable in that mode; it is
for iterating on the trainer without a phone. Taps from a script are best
sent with `idb ui tap` (`brew install idb-companion`, `uv tool install
fb-idb`); tools that move the Mac's mouse fight the person at the keyboard.

## Ship to TestFlight

`Scripts/qiuling-ship.sh` archives and uploads with no Xcode UI, authenticated
by an App Store Connect API key; its header lists the five settings it needs
in `Config/qiuling.env`. From the qiuling repo, `tools/ship_signal.sh`
rebuilds the font, copies it here, commits, and runs it. On the phone,
TestFlight's automatic updates keep the app — and so the font — current.

Entitlements are trimmed to what a personal team can sign (app groups,
keychain, hardened process, fonts); push, Apple Pay, associated domains,
iCloud, data protection and the carrier/Wi-Fi entitlements are gone, per
Signal's own BUILDING.md.

## Build by hand

Needs a Mac with Xcode and an Apple developer account.

```sh
git clone --recurse-submodules <this fork> && cd Signal-iOS && git checkout qiuling
make dependencies
open Signal.xcworkspace
```

In Xcode, for the Signal, SignalShareExtension and SignalNSE targets: set
**Team** to yours and set `SIGNAL_BUNDLEID_PREFIX` in the project settings to
something of your own, then on Capabilities turn off Push Notifications,
Apple Pay, Communication Notifications and Data Protection (keep Background
Modes and App Groups). Build and run on the phone.

## Linking from Signal on the same phone

Linking is built around a second device holding the camera. From App Store
Signal on the *same* phone, the QR screen's **Copy code for another screen**
opens a fresh 90-second socket (the server's limit), copies the code to the
Universal Clipboard, freezes rotation and keeps this process alive in the
background (`BackgroundKeepAlive`: a background task plus silence under the
`audio` background mode). Paste on a Mac (Preview › ⌘N) and scan the Mac from
Signal's Linked Devices with the scanner already open.

History transfer works too, with one change on our side: Signal's
link-and-sync aborts on *either* device the moment it leaves the foreground,
and on one phone the primary has to be in front while it uploads. Qiuling's
secondary path (`LinkAndSyncManager.waitForBackupAndRestore` and the upload
long-poll) now checks only for cancellation, and the whole link is held open
for up to 30 minutes. Stay in Signal until its upload finishes, then switch
to Qiuling for the download and restore.

## Xcode version

Build with **Xcode 26**, not 27. Signal has not adopted the UIScene lifecycle,
and iOS 27 kills at launch any app linked against the iOS 27 SDK that hasn't
(`UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`). Linked
against iOS 26 it runs fine on iOS 27. `Scripts/qiuling-ship.sh` pins this via
`DEVELOPER_DIR`; lift the pin once upstream Signal adopts scenes.

## What to expect

- **No push notifications.** Signal's server pushes to Signal's bundle ID, not
  yours, so messages arrive only while this build is open or refreshing in the
  background. This is the real cost of a self-built Signal, and the reason to
  keep it as a second device or a second number rather than your main one.
- The app is a separate install from the App Store Signal and registers as its
  own device. Link it as a secondary device to your account, or register a
  second number in it.
- Notification banners are drawn by iOS in the system font and cannot be
  styled; turn off previews (Settings › Notifications › Signal) if that matters.
- Typing happens on the ordinary keyboard, so autocorrect suggestions above it
  are still English.

## Switching alphabets

Drop a newer `*Write-Regular.ttf` from the qiuling repo into `SignalUI/Fonts`,
add it to the SignalUI target's resources, and change `qiulingFontName` in
`UIFont+Qiuling.swift` to its PostScript name. `qiulingScale` is how much
larger than Latin the script is set; 1.8 reads well for 1.5.

## Safari extension

iOS Safari cannot run a bookmarklet from a page, so the app ships a Safari
Web Extension (`SafariExtension/`, bundle id `…q.safari`). Once turned on
(Settings › Apps › Safari › Extensions › Qiuling, or Safari's page menu ›
Manage Extensions), the Qiuling button in Safari's page menu sets the current
page in the script at twice its size and puts it back on a second tap — the
same routine as `web/reader.js`, with an ON badge while a page is set.

The extension keeps its own font current, independently of the app: the
native handler (`SafariWebExtensionHandler.swift`) checks the same manifest
the app does, at most hourly, with the same build-time-injected URL and bypass
token (`QiulingFontManifestURL`/`QiulingFontBypass` in its Info.plist), and
caches a verified copy in its own container. Sharing state with the app
through an App Group was the first design, but assigning an App Group to a
new App ID needs an Apple ID signed into Xcode (the App Store Connect API
cannot do it), and Safari being current without the app having been opened
is the better behaviour anyway. The copy of the TTF bundled in
`SafariExtension/Resources` is the fallback; `tools/ship_signal.sh` refreshes
it with the app's.

Signing: the extension's App ID and a development profile ("Qiuling Safari
Development", every development certificate, all devices) were created
through the App Store Connect API (see the `asc.py` sketch in git history of
this file if it needs redoing); the target signs manually with that profile,
and `-exportArchive` creates the store profile itself with the API key.
Signing into Xcode again and switching the target to automatic would also
work.

In the simulator, `Scripts/qiuling-sim.sh` ad-hoc signs the built app so the
extension can be enabled; then Safari › page menu › Manage Extensions ›
Qiuling, open a page (`xcrun simctl openurl <udid> https://…`), and tap
Qiuling in the same menu.

The files under `SafariExtension/Resources` are added to the target
individually (`_locales` and `images` as folder references) rather than as
one blue folder: a top-level `Resources/` inside a flat .appex is read as the
old bundle layout and the extension's Info.plist is then not found.

## Keyboard

The app also ships a system keyboard (`KeyboardExtension/`, bundle id
`…q.keyboard`, display name "Qiuling"). Its keys carry the marks of the
current alphabet instead of letters — the letter is only shown, small, in the
pop-up while a key is held — so typing is practice, and what is on the screen
is hard to read over a shoulder. The strip above the keys shows what has been
typed into the field, set in Qiuling. Otherwise it behaves like the system
keyboard: slide-to-correct, two-thumb typing, a held Delete that speeds up and
then eats words, `123` and `#+=` layers, the globe. Holding a letter opens a
row of the letter groups the font draws as one mark (from
`mappings-morph.json`, bundled beside the font); lifting on one types its
letters.

In normal use the keyboard types ordinary Latin, so the receiving app sees
English. The lock key on the bottom-left row turns on **private compose**: the
strip becomes the composer, keys go into a buffer inside the keyboard, and
nothing reaches the field until **Insert** (or Return). Insert encodes the
buffer into the font's private-use code points, so the text reads as Qiuling
in any app that has the font — this app's bubbles included — and as boxes in
one that does not. The rule (`QiulingEncoder.swift`): shape the text with
CoreText exactly as the screen would, and map each glyph back to the
private-use point the font reaches it from (built once per process by asking
the font for the glyph of every point in U+F0000…, letters filling only what
the points left). Spaces always stay U+0020 whichever contextual space glyph
was chosen; digits, punctuation the alphabet lacks and line breaks pass
through unchanged. **Picture** copies the buffer as a PNG (the Write screen's
parameters, local-only pasteboard, expires in five minutes); this needs Allow
Full Access, and the strip says so when it is off. The buffer lives only in
memory for the extension's life; the one persisted setting is the on/off
flag. Secure fields force it off. Press and hold the composer to see the
buffer in letters.

Enable it under Settings › General › Keyboard › Keyboards › Add New Keyboard
› Qiuling, then hold the globe on any keyboard. In the simulator,
`Scripts/qiuling-sim.sh` ad-hoc signs the extension so it can be enabled the
same way. The keyboard never connects to the internet: the font it draws with
is the copy in `KeyboardExtension/Resources`, which `tools/ship_signal.sh`
refreshes and stages with the app's and Safari's. As with the Safari
extension, the resources are added to the target as individual files, not a
blue `Resources/` folder.

Height: the keyboard asks for 260pt portrait (44 strip + 216 keys) and 200
landscape through one priority-999 constraint on its view, installed in
`updateViewConstraints` once the view is in the host's hierarchy — the
template pattern; Apple DTS says the host settles on it a few hundred
milliseconds after appearance. The iOS 26.5 simulator host ignores it (444pt
in the app's Practice field; 874pt and growing per launch in Safari), and the
Apple developer forums report the same for `allowsSelfSizing` and an
`intrinsicContentSize` override, so neither is used. Whatever height the host
gives, the rows keep their natural pitch anchored to the bottom of the view; an
over-tall host shows a blank band of backdrop above the strip. Whether a
device honours the constraint is unverified.

Signing follows the Safari extension: the App ID and a "Qiuling Keyboard
Development" profile (every development certificate, all devices) were made
through the App Store Connect API (`Scripts/qiuling-asc.py`), the target signs
manually with that profile, and `-exportArchive` makes the store profile.
