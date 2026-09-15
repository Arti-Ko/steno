import AVFoundation
import Observation

@MainActor
@Observable
final class PlayerModel {
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    @ObservationIgnored let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var rate: Float = 1
    private(set) var loadedID: UUID?
    private(set) var videoURL: URL?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            MainActor.assumeIsolated {
                self?.currentTime = seconds
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
    }

    var hasMedia: Bool { player.currentItem != nil }

    func load(_ id: UUID, audioURL: URL?, videoURL: URL?, duration: Double) {
        guard loadedID != id else { return }
        player.pause()
        loadedID = id
        self.videoURL = videoURL
        self.duration = duration
        currentTime = 0
        player.replaceCurrentItem(with: (videoURL ?? audioURL).map { AVPlayerItem(url: $0) })
    }

    func unload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedID = nil
        videoURL = nil
        currentTime = 0
        duration = 0
    }

    func togglePlay() {
        guard hasMedia else { return }
        if isPlaying {
            player.pause()
            return
        }
        if duration > 0, currentTime >= duration - 0.25 {
            seek(to: 0)
        }
        player.playImmediately(atRate: rate)
    }

    func play(from seconds: Double) {
        seek(to: seconds)
        if !isPlaying {
            player.playImmediately(atRate: rate)
        }
    }

    func seek(to seconds: Double) {
        guard hasMedia else { return }
        let upperBound = duration > 0 ? duration : seconds
        let target = min(max(0, seconds), upperBound)
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying {
            player.rate = newRate
        }
    }
}
