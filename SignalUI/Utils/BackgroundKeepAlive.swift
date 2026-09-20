//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import SignalServiceKit
import UIKit

/// Keeps the process running while the app is in the background, for the
/// few flows that need it on this app: linking from Signal on the same
/// phone, where the primary must be in front while this app waits on a
/// socket or for an archive upload. A background task alone buys ~30 s; the
/// app declares the `audio` background mode, so this also plays silence,
/// which is what keeps a process alive indefinitely. Always bounded by a
/// deadline so a forgotten release cannot leave it running.
@MainActor
public final class BackgroundKeepAlive {

    public static let shared = BackgroundKeepAlive()

    private var task: OWSBackgroundTask?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var reason = ""

    /// Start (or extend) the hold. A later call replaces the deadline.
    public func hold(reason: String, seconds: TimeInterval) {
        self.reason = reason
        timer?.invalidate()
        if task == nil {
            task = OWSBackgroundTask(label: "BackgroundKeepAlive.\(reason)", completionBlock: nil)
        }
        if player == nil {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                let p = try AVAudioPlayer(data: Self.silence, fileTypeHint: AVFileType.wav.rawValue)
                p.numberOfLoops = -1
                p.volume = 0
                p.play()
                player = p
            } catch {
                Logger.warn("keep-alive audio unavailable: \(error)")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.release() }
        }
        Logger.info("holding the process open for \(reason), up to \(Int(seconds))s")
    }

    public func release() {
        guard task != nil || player != nil else { return }
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        task = nil
        Logger.info("released the process hold for \(reason)")
    }

    /// One second of 8 kHz mono 16-bit silence as a WAV, built in memory.
    private static let silence: Data = {
        let rate: UInt32 = 8000, bytes = rate * 2
        var d = Data()
        func le32(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
        func le16(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
        d.append("RIFF".data(using: .ascii)!); le32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
        le32(16); le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
        d.append("data".data(using: .ascii)!); le32(bytes)
        d.append(Data(count: Int(bytes)))
        return d
    }()
}
