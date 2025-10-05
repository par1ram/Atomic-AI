//
//  WhisperAudioCaptureService.swift
//  atomic
//
//  Сервис для захвата микрофона с транскрипцией через WhisperKit

import Foundation
import AVFoundation
import WhisperKit

@MainActor
class WhisperAudioCaptureService {
    // MARK: - Constants

    private enum Constants {
        static let bufferDuration: TimeInterval = 2.0
        static let sampleRate: Double = 16000
        static let silenceThreshold: TimeInterval = 1.5
        static let soundDetectionThreshold: Float = 0.01
        static let whisperModel = "base"
        static let language = "ru"
    }

    // MARK: - Properties

    private let audioEngine = AVAudioEngine()
    private var whisperKit: WhisperKit?
    private let audioConverter = AudioConverter()

    private var latestTranscript = ""
    private var audioBuffer: [Float] = []

    private var transcriptionTask: Task<Void, Never>?
    private var isInitialized = false

    // Отслеживание пауз для определения финальности фразы
    private var lastSoundTime: Date?
    private var isFinalTranscript = false

    init() {
        Task {
            await initializeWhisper()
        }
    }

    private func initializeWhisper() async {
        print("🎤 Инициализация WhisperKit для микрофона...")
        do {
            // Используем base модель - хороший баланс скорости и качества для русского
            // Для лучшего качества можно использовать "large-v3", но медленнее
            whisperKit = try await WhisperKit(WhisperKitConfig(model: Constants.whisperModel))
            isInitialized = true
            print("✅ WhisperKit инициализирован для микрофона")
        } catch {
            print("❌ Ошибка инициализации WhisperKit для микрофона: \(error)")
        }
    }

    func startCapture() throws {
        guard isInitialized else {
            print("⚠️ WhisperKit еще не инициализирован, ждем...")
            // Повторная попытка через 1 секунду
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                try? self.startCapture()
            }
            return
        }

        print("🎤 Запуск захвата микрофона...")

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Установить tap на input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                self?.processAudioBuffer(buffer)
            }
        }

        // Запустить audio engine
        audioEngine.prepare()
        try audioEngine.start()

        print("✅ Микрофон запущен")
    }

    func stopCapture() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        transcriptionTask?.cancel()
        transcriptionTask = nil
        print("🛑 Микрофон остановлен")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let convertedBuffer = audioConverter?.convert(buffer) else {
            return
        }

        guard let channelData = convertedBuffer.floatChannelData?[0] else {
            return
        }

        let frameLength = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        // Проверяем наличие звука (амплитуда выше порога)
        let hasSound = samples.contains { abs($0) > Constants.soundDetectionThreshold }
        if hasSound {
            lastSoundTime = Date()
            // Если был звук после финальной фразы - начинаем новую
            if isFinalTranscript {
                isFinalTranscript = false
                latestTranscript = "" // Очищаем старый текст для новой фразы
                print("🎤 Новая фраза начата")
            }
        } else if let lastSound = lastSoundTime,
                  Date().timeIntervalSince(lastSound) > Constants.silenceThreshold,
                  !isFinalTranscript {
            // Пауза больше порога - фраза завершена (только если еще не финальная)
            isFinalTranscript = true
            print("✅ [Пользователь] Фраза завершена (пауза)")
        }

        audioBuffer.append(contentsOf: samples)

        // Транскрибируем когда накопили достаточно данных
        let requiredSamples = Int(Constants.bufferDuration * Constants.sampleRate)
        if audioBuffer.count >= requiredSamples {
            let chunk = Array(audioBuffer.prefix(requiredSamples))
            // Оптимизация: используем dropFirst вместо removeFirst (избегаем копирования всего массива)
            audioBuffer = Array(audioBuffer.dropFirst(requiredSamples))

            // Запустить транскрипцию асинхронно
            transcriptionTask?.cancel()
            transcriptionTask = Task { [weak self] in
                await self?.transcribeChunk(chunk)
            }
        }
    }

    private func transcribeChunk(_ samples: [Float]) async {
        guard let whisperKit = whisperKit else { return }

        do {
            // Настройки для русского языка
            let options = DecodingOptions(
                task: .transcribe,
                language: Constants.language,
                temperature: 0.0,
                usePrefillPrompt: true,
                detectLanguage: false
            )

            let results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )

            // WhisperKit возвращает массив TranscriptionResult
            if let firstResult = results.first, !firstResult.text.isEmpty {
                // Убрать лишние пробелы и форматирование
                let cleaned = firstResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

                // Фильтр: игнорируем технические метки и шум
                let ignoredPatterns = ["[музыка]", "[music]", "[аплодисменты]", "[applause]", "[шум]", "[noise]"]
                let isNoiseOnly = ignoredPatterns.contains { cleaned.lowercased().contains($0) } && cleaned.count < 20

                // Проверяем что есть реальные слова (минимум 2 символа и содержит буквы)
                let hasRealWords = cleaned.count >= 2 && cleaned.rangeOfCharacter(from: .letters) != nil

                // Обновляем только если текст изменился (предотвращает спам)
                if !isNoiseOnly && hasRealWords && cleaned != latestTranscript {
                    latestTranscript = cleaned
                    print("🎤 [Пользователь]: \(cleaned)")
                }
            }
        } catch {
            // Игнорируем ошибки транскрипции пустых фрагментов
            if !samples.allSatisfy({ abs($0) < Constants.soundDetectionThreshold }) {
                print("⚠️ Ошибка транскрипции микрофона: \(error)")
            }
        }
    }

    func getLatestTranscript() -> (text: String, isFinal: Bool) {
        return (latestTranscript, isFinalTranscript)
    }

    func clearTranscript() {
        print("🧹 Очистка транскрипции микрофона...")
        latestTranscript = ""
        audioBuffer.removeAll()
        lastSoundTime = nil
        isFinalTranscript = false
        print("✅ Транскрипция микрофона очищена")
    }
}
