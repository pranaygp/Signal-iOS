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
