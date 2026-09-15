import AVFoundation
import Observation

/// Запись с микрофона в m4a для последующей расшифровки.
@MainActor
@Observable
final class AudioRecorder {
    enum Phase: Equatable {
        case idle
        case recording
        case finished(URL)
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    /// Уровень сигнала 0…1.
    private(set) var level: Double = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTimer: Timer?

    private static let silenceFloor: Float = -50

    func start() async {
        errorMessage = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errorMessage = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон."
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = FileManager.default.temporaryDirectory.appending(path: "Запись \(formatter.string(from: .now)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorMessage = "Не удалось начать запись."
                return
            }
            self.recorder = recorder
            elapsed = 0
            phase = .recording
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateMeter()
                }
            }
        } catch {
            errorMessage = "Не удалось начать запись: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let recorder else { return }
        recorder.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        self.recorder = nil
        phase = .finished(recorder.url)
    }

    func discard() {
        let url: URL? = switch phase {
        case .finished(let finishedURL): finishedURL
        case .recording: recorder?.url
        case .idle: nil
        }
        recorder?.stop()
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        level = 0
        elapsed = 0
        phase = .idle
    }

    private func updateMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        let power = recorder.averagePower(forChannel: 0)
        level = Double(max(0, (power - Self.silenceFloor) / -Self.silenceFloor))
    }
}
