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

The app also carries a Safari Web Extension, **Qiuling** (target
`SafariExtension`, bundle ID `<prefix>.q.safari`), which does on the phone
what the trainer's bookmarklet does on a desktop — iOS Safari cannot run a
bookmarklet from a page, but it can run an extension. Tapping Qiuling in
Safari's page menu (the `AA`/puzzle-piece button) toggles the current page:
on, every text element is set in the "Qiuling Reader" family with its
font-size and line-height doubled; off puts every inline style back exactly.
The button shows an `ON` badge while a page is toggled; a navigation makes a
fresh document, which is never styled.

The in-page routine is `web/reader.js` from the qiuling repo, carried
verbatim in `SafariExtension/Resources/background.js` (`QIULING_KEEP`,
`qiulingCss`, `qiulingApply`, scale 2) — the only change is the @font-face
`format("truetype")`, because the phone's font is a TTF. If the routine
changes upstream, copy it in again. The background script injects it with
`scripting.executeScript` and reads the page's state back the same way, so a
toggle is truthful even after Safari unloads the non-persistent background
page.

**Where the font comes from.** The extension asks its native handler
(`SafariWebExtensionHandler.swift`) with `sendNativeMessage("application.id",
{type: "font"})` and gets `{sha256, base64}` of the current TTF. The handler
reads the App Group container `group.<prefix>.signal.group` (prefix from the
extension's `OWSBundleIDPrefix` Info.plist key, like the other extensions):
`QiulingFonts/current.ttf`, checked against the `sha256` in
`QiulingFonts/current.json` (`{"family","sha256","buildId"}`) when that file
is present. The app is responsible for keeping those two files current —
bundled font on first launch, then whatever it downloads over the air. Until
the app has run once (a fresh install), the files are missing and the handler
answers with the copy of the TTF bundled in the extension
(`SafariExtension/Resources/QiulingMorphWrite-Regular.ttf`; refresh it when
the app's bundled font changes). The background script caches the reply in
`storage.local` keyed by sha and injects it as a `data:font/ttf;base64,…`
URL; it asks native again on browser start, on install, and on a tap when the
cache is more than an hour old, so a new font reaches Safari without a
reinstall. If native messaging fails outright it falls back to the bundled TTF
by its extension URL (`web_accessible_resources`).

**Enabling it on the phone.** Install the app, then Settings › Apps › Safari
› Extensions › Qiuling › on (or in Safari: page menu › Manage Extensions).
The first tap on a site asks for permission to read the page — "Allow for One
Day" or "Always Allow"; "Always Allow on Every Website" is the setting to pick
if you want one tap per page. The extension's entitlements are the app groups
only, so it signs with the same personal team as the rest.

In the simulator `Scripts/qiuling-sim.sh` builds and embeds it
(`Signal.app/PlugIns/SafariExtension.appex`, with `manifest.json` at the
bundle root). The script builds with `CODE_SIGNING_ALLOWED=NO`, and Safari
silently refuses to enable an unsigned extension (the switch will not flip),
so ad-hoc sign the built app before installing it if you want to try the
extension there:

```sh
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/Signal.app
for f in "$APP"/Frameworks/*.framework "$APP"/PlugIns/*.appex; do codesign -f -s - "$f"; done
codesign -f -s - "$APP" && xcrun simctl install <udid> "$APP"
```

Then enable it from Safari's page menu (the page icon left of the address
bar › Manage Extensions), open a page with `xcrun simctl openurl <udid>
https://…`, and tap Qiuling in the same menu.

A note on the project: the files under `SafariExtension/Resources` are added
to the target individually (`_locales` and `images` as folder references),
not as one `Resources` folder reference. A top-level `Resources/` directory
inside a flat iOS bundle makes CFBundle read it as the old version-0 layout
and lose the root `Info.plist`, and Xcode's embedded-binary validation then
fails with "Couldn't load Info dictionary".
