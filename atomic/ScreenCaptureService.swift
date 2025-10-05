//
//  ScreenCaptureService.swift
//  atomic
//
//  Сервис для захвата экрана и извлечения текста через OCR

import Foundation
import ScreenCaptureKit
import Vision

class ScreenCaptureService {
    // MARK: - Constants

    private enum Constants {
        static let captureInterval: UInt64 = 3_000_000_000 // 3 seconds in nanoseconds
        static let ocrLanguages = ["ru-RU", "en-US"]
    }

    // MARK: - Properties

    private var latestText = ""
    private var captureTask: Task<Void, Never>?
    private var isCaptureInProgress = false

    func startCapture() throws {
        // Периодический захват экрана для быстрой отправки
        captureTask = Task {
            while !Task.isCancelled {
                if !isCaptureInProgress {
                    await captureAndExtractText()
                }

                // Захват каждые 3 секунды (баланс между актуальностью и нагрузкой)
                try? await Task.sleep(nanoseconds: Constants.captureInterval)
            }
        }
    }

    func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
    }

    func getLatestText() -> String {
        return latestText
    }

    func clearText() {
        latestText = ""
        print("🧹 Текст с экрана очищен")
    }

    private func captureAndExtractText() async {
        isCaptureInProgress = true
        defer { isCaptureInProgress = false }

        do {
            // Получить доступные дисплеи
            let content = try await SCShareableContent.current

            guard let display = content.displays.first else {
                print("⚠️ Нет доступных дисплеев для захвата")
                return
            }

            // Создать конфигурацию для захвата
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()

            // Используем нативное разрешение экрана для точности OCR
            configuration.width = display.width
            configuration.height = display.height
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            // Захватить кадр
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            // Извлечь текст с помощью Vision
            let text = await extractText(from: image)

            if !text.isEmpty {
                latestText = text
                print("📸 Захвачен текст с экрана (\(text.count) символов)")
            }

        } catch {
            print("❌ Ошибка захвата экрана: \(error.localizedDescription)")
        }
    }

    private func extractText(from cgImage: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil else {
                    continuation.resume(returning: "")
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: " ")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = Constants.ocrLanguages
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
}
