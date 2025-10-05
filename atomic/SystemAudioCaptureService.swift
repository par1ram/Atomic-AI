//
//  SystemAudioCaptureService.swift
//  atomic
//
//  Сервис для захвата системного аудио (звук интервьюера) с нативным SFSpeechRecognizer
//  БЫСТРЫЙ: ~100-200ms задержка (в 5-10 раз быстрее WhisperKit)

import Foundation
import ScreenCaptureKit
import Speech
import AVFoundation

class SystemAudioCaptureService: NSObject {
    // MARK: - Constants

    private enum Constants {
        static let locale = Locale(identifier: "ru-RU")
        static let silenceThreshold: TimeInterval = 1.5
        static let pauseCheckInterval: TimeInterval = 0.5
    }

    // MARK: - Properties

    private var stream: SCStream?
    private let speechRecognizer = SFSpeechRecognizer(locale: Constants.locale)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var latestTranscript = ""
    private var fullAccumulatedText = "" // Полный накопленный текст от SFSpeech
    private var isFinalTranscript = false

    // Отслеживание пауз для определения финальности
    private var lastResultTime: Date?

    func startCapture() async throws {
        // Получить доступные источники аудио
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Нет доступных дисплеев"])
        }

        // Создать фильтр для захвата ВСЕХ приложений (системный звук)
        // Исключаем себя, чтобы не было петли
        let excludedApps = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        // Настройка конфигурации для аудио
        let config = SCStreamConfiguration()

        // КЛЮЧЕВОЕ: включаем захват системного аудио
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // Исключаем свой звук
        config.sampleRate = 48000
        config.channelCount = 2

        // Минимальная видео конфигурация (ScreenCaptureKit требует хоть что-то)
        // Делаем минимальный framerate чтобы уменьшить ошибки "output NOT found"
        config.width = 1
        config.height = 1
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
        config.queueDepth = 1

        // Создать stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        // Добавить аудио output
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.capture.queue"))

        // Запустить
        try await stream?.startCapture()

        // Запустить распознавание речи
        startSpeechRecognition()
    }

    func stopCapture() async {
        try? await stream?.stopCapture()
        stream = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func startSpeechRecognition() {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true

        guard let recognitionRequest = recognitionRequest else { return }

        recognitionTask = setupRecognitionTask(with: recognitionRequest)

        // Проверка пауз для финальности
        Timer.scheduledTimer(withTimeInterval: Constants.pauseCheckInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            // Устанавливаем финальность ТОЛЬКО ОДИН РАЗ при паузе
            if let lastTime = self.lastResultTime,
               Date().timeIntervalSince(lastTime) > Constants.silenceThreshold,
               !self.isFinalTranscript,
               !self.latestTranscript.isEmpty {
                self.isFinalTranscript = true
                print("✅ [Интервьюер] Фраза завершена (пауза)")

                // Рестартуем распознавание чтобы начать с чистого листа
                self.restartRecognition()
            }
        }
    }

    private func restartRecognition() {
        // Останавливаем текущую сессию распознавания
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        // Сбрасываем накопленный текст
        fullAccumulatedText = ""

        // Запускаем новую сессию распознавания с чистого листа
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true

        guard let recognitionRequest = recognitionRequest else { return }

        recognitionTask = setupRecognitionTask(with: recognitionRequest)

        print("🔄 SFSpeech распознавание перезапущено")
    }

    // MARK: - Shared Recognition Task Setup

    private func setupRecognitionTask(with request: SFSpeechAudioBufferRecognitionRequest) -> SFSpeechRecognitionTask? {
        return speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcript = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Обновляем только если текст изменился (предотвращает спам)
                if transcript != self.fullAccumulatedText && !transcript.isEmpty {
                    // Вычисляем только НОВУЮ часть текста (вычитаем предыдущий)
                    let previousText = self.fullAccumulatedText
                    self.fullAccumulatedText = transcript

                    // Извлекаем только добавленную часть
                    let newPart = transcript.hasPrefix(previousText) && !previousText.isEmpty
                        ? String(transcript.dropFirst(previousText.count)).trimmingCharacters(in: .whitespaces)
                        : transcript

                    if !newPart.isEmpty {
                        self.latestTranscript = newPart
                        self.lastResultTime = Date()
                        self.isFinalTranscript = false
                        print("🔊 [Интервьюер] Новая часть: \(newPart)")
                        print("🔊 [Интервьюер] Полный текст: \(transcript)")
                    }
                }

                // Apple отмечает финальность результата
                if result.isFinal && !self.isFinalTranscript {
                    self.isFinalTranscript = true
                    print("✅ [Интервьюер] Фраза завершена (SFSpeech)")
                }
            }

            if let error = error {
                // Игнорируем "No speech detected" - это нормально когда молчат
                let errorMessage = error.localizedDescription
                if !errorMessage.contains("No speech detected") {
                    print("❌ Ошибка распознавания системного аудио: \(errorMessage)")
                }
            }
        }
    }

    func getLatestTranscript() -> (text: String, fullText: String, isFinal: Bool) {
        return (latestTranscript, fullAccumulatedText, isFinalTranscript)
    }

    func clearTranscript() {
        latestTranscript = ""
        fullAccumulatedText = ""
        isFinalTranscript = false
        lastResultTime = nil

        // Используем тот же метод restartRecognition для консистентности
        restartRecognition()

        print("🧹 Системный транскрипт очищен")
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ Stream остановлен с ошибкой: \(error)")
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // ТОЛЬКО аудио, игнорируем видео полностью
        guard type == .audio else {
            return
        }

        // Передать аудио буфер в Speech Recognition
        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
    }
}
