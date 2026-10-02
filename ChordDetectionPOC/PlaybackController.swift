//
//  PlaybackController.swift
//  ChordDetectionPOC
//

import AVFoundation
import Observation

/// Plays the imported song for practising along with the chords: play/pause, seek, ±10 s and
/// speed changes that keep the pitch (so a slowed-down song still matches the chord shapes).
@MainActor
@Observable
final class PlaybackController {

    static let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5]

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1
    private(set) var isReady = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: Task<Void, Never>?
    /// While the user drags the slider, the periodic observer mustn't fight the thumb.
    @ObservationIgnored private var isScrubbing = false

    // MARK: Loading

    func load(_ url: URL) {
        unload()
        configureAudioSession()

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral          // best quality for music when slowed down
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }

        endObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                self?.isPlaying = false
            }
        }

        Task { [weak self] in
            let seconds = (try? await item.asset.load(.duration))?.seconds ?? 0
            guard let self, self.player === player else { return }
            self.duration = seconds.isFinite ? seconds : 0
            self.isReady = true
        }
    }

    /// Stops playback and releases the file (call before the file is deleted).
    func unload() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        endObserver?.cancel()
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
    }

    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Jump to `time` and start playing (used when tapping a chord or a line).
    func play(from time: TimeInterval) {
        seek(to: time)
        play()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(time, 0), duration > 0 ? duration : time)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player?.defaultRate = newRate
        if isPlaying { player?.rate = newRate }
    }

    // MARK: Scrubbing

    func beginScrubbing() { isScrubbing = true }

    func scrub(to time: TimeInterval) { currentTime = time }

    func endScrubbing() {
        isScrubbing = false
        seek(to: currentTime)
    }
}
