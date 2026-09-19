# Signal in Qiuling

This branch sets message text in Qiuling — bubbles, the compose box and the
chat-list preview — so a glance at the screen shows the script, not English.
Everything else in the app is unchanged. The change is one Swift file,
`SignalUI/UIKitExtensions/UIFont+Qiuling.swift`, five one-line call-site
edits, and the font in `SignalUI/Fonts`.

## Build

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
