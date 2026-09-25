import Testing
import WhisperKit
@testable import Steno

@Suite("Параметры декодирования")
struct DecodingOptionsTests {
    @Test("Порог первого токена выключен во всех режимах", arguments: [TranscriptionMode.cheetah, .dolphin, .whale])
    func firstTokenThresholdIsOff(mode: TranscriptionMode) {
        var options = TranscriptionOptions()
        options.mode = mode
        let decoding = TranscriptionEngine.decodingOptions(for: options)
        #expect(decoding.firstTokenLogProbThreshold == nil)
        #expect(decoding.temperatureFallbackCount == mode.temperatureFallbackCount)
        #expect(decoding.wordTimestamps)
        #expect(decoding.chunkingStrategy == .vad)
    }

    @Test("Язык: заданный передаётся, без него включается автоопределение")
    func languageDetection() {
        var options = TranscriptionOptions()
        options.language = "ru"
        #expect(TranscriptionEngine.decodingOptions(for: options).language == "ru")
        #expect(!TranscriptionEngine.decodingOptions(for: options).detectLanguage)
        options.language = nil
        #expect(TranscriptionEngine.decodingOptions(for: options).detectLanguage)
    }
}
