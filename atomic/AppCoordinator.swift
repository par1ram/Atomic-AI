//
//  AppCoordinator.swift
//  atomic
//
//  Координатор для управления всеми сервисами приложения

import Foundation
import AppKit
import AVFoundation
import Speech
import Combine


@MainActor
class AppCoordinator: ObservableObject {
    // MARK: - Constants

    private enum Constants {
        static let transcriptUpdateInterval: UInt64 = 500_000_000 // 0.5 seconds in nanoseconds
    }

    // MARK: - Published Properties

    @Published var isRunning = false
    @Published var messages: [TranscriptMessage] = []

    // MARK: - Private Properties

    private var audioService: WhisperAudioCaptureService?           // Микрофон (кандидат) - WhisperKit ~500ms
    private var systemAudioService: SystemAudioCaptureService?      // Системный звук (интервьюер) - SFSpeech ~100-200ms (БЫСТРО!)
    private var screenService: ScreenCaptureService?
    private var apiService: GeminiAPIService
    var overlayWindow: OverlayWindow?

    private var transcriptUpdateTask: Task<Void, Never>?

    // Храним текущие незавершенные сообщения отдельно
    private var currentUserMessage: TranscriptMessage?
    private var currentInterviewerMessage: TranscriptMessage?

    // История ответов AI (для избежания повторных ответов)
    private var aiResponseHistory: [String] = []

    init() {
        self.apiService = GeminiAPIService()
        self.overlayWindow = OverlayWindow(coordinator: nil)
        self.overlayWindow?.coordinator = self
    }

    func start() async {
        print("🚀 Запуск приложения...")
        guard !isRunning else {
            print("⚠️ Уже запущено")
            return
        }

        // Запросить разрешения
        let hasPermissions = await requestPermissions()
        guard hasPermissions else {
            print("❌ Нет разрешений")
            showAlert(message: "Требуются разрешения на микрофон, речь и захват экрана. Проверьте Системные настройки → Конфиденциальность.")
            return
        }

        isRunning = true
        print("✅ Разрешения получены, запускаем сервисы...")

        // Инициализировать сервисы (ГИБРИДНЫЙ ПОДХОД)
        audioService = WhisperAudioCaptureService()              // Микрофон (наш голос) - WhisperKit
        systemAudioService = SystemAudioCaptureService()         // Системный звук (интервьюер) - SFSpeech (быстрее!)
        screenService = ScreenCaptureService()

        // Показать оверлей
        overlayWindow?.show()
        print("✅ Оверлей показан")

        // Запустить захват
        do {
            try audioService?.startCapture()
            print("✅ Микрофон запущен")

            try await systemAudioService?.startCapture()
            print("✅ Системный звук запущен (SFSpeechRecognizer - быстро!)")

            try screenService?.startCapture()
            print("✅ Периодический захват экрана запущен (каждые 3 сек)")

            // Запустить обновление транскрипции в реальном времени
            startTranscriptUpdates()
            print("✅ Обновление транскрипции запущено")
        } catch {
            print("❌ Ошибка запуска: \(error)")
            showAlert(message: "Ошибка запуска: \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        isRunning = false

        transcriptUpdateTask?.cancel()
        transcriptUpdateTask = nil

        audioService?.stopCapture()
        Task { await systemAudioService?.stopCapture() }
        screenService?.stopCapture()

        overlayWindow?.hide()

        audioService = nil
        systemAudioService = nil
        screenService = nil
    }

    private func startTranscriptUpdates() {
        // Обновляем транскрипцию каждые 0.5 секунды
        transcriptUpdateTask = Task {
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(nanoseconds: Constants.transcriptUpdateInterval)

                guard !Task.isCancelled else { break }

                var hasChanges = false

                // Получить транскрипцию от микрофона (пользователь)
                let (userText, userIsFinal) = audioService?.getLatestTranscript() ?? ("", false)
                if !userText.isEmpty {
                    if let current = currentUserMessage {
                        // Обновляем только если текст или флаг изменились
                        if let index = messages.firstIndex(where: { $0.id == current.id }) {
                            if messages[index].text != userText || messages[index].isFinal != userIsFinal {
                                messages[index].text = userText
                                messages[index].isFinal = userIsFinal
                                hasChanges = true
                            }
                        }

                        // Если стало финальным - обнуляем текущее сообщение
                        if userIsFinal {
                            currentUserMessage = nil
                        }
                    } else if !userIsFinal {
                        // Создаем новое сообщение ТОЛЬКО если это незавершенная фраза
                        // (игнорируем финальные фразы без текущего сообщения - они уже в истории)
                        let newMessage = TranscriptMessage(speaker: .user, text: userText, isFinal: false)
                        messages.append(newMessage)
                        currentUserMessage = newMessage
                        hasChanges = true
                    }
                }

                // Получить транскрипцию системного звука (интервьюер)
                let (interviewerText, interviewerFullText, interviewerIsFinal) = systemAudioService?.getLatestTranscript() ?? ("", "", false)
                if !interviewerText.isEmpty {
                    if let current = currentInterviewerMessage {
                        // Обновляем только если текст или флаг изменились
                        if let index = messages.firstIndex(where: { $0.id == current.id }) {
                            if messages[index].text != interviewerText ||
                               messages[index].fullText != interviewerFullText ||
                               messages[index].isFinal != interviewerIsFinal {
                                messages[index].text = interviewerText
                                messages[index].fullText = interviewerFullText
                                messages[index].isFinal = interviewerIsFinal
                                hasChanges = true
                            }
                        }

                        // Если стало финальным - обнуляем текущее сообщение
                        if interviewerIsFinal {
                            currentInterviewerMessage = nil
                        }
                    } else if !interviewerIsFinal {
                        // Создаем новое сообщение ТОЛЬКО если это незавершенная фраза
                        // (игнорируем финальные фразы без текущего сообщения - они уже в истории)
                        let newMessage = TranscriptMessage(
                            speaker: .interviewer,
                            text: interviewerText,
                            fullText: interviewerFullText,
                            isFinal: false
                        )
                        messages.append(newMessage)
                        currentInterviewerMessage = newMessage
                        hasChanges = true
                    }
                }

                // Обновить UI только если были изменения
                if hasChanges {
                    overlayWindow?.updateMessages(messages)
                }
            }
        }
    }

    func sendRequest() async {
        print("📤 Отправка запроса по команде пользователя...")

        // Явно на MainActor - показываем лоадер
        await MainActor.run {
            overlayWindow?.updateResponse("⏳ Обработка...")
        }

        // Небольшая задержка чтобы пользователь увидел лоадер
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 секунды

        // Собрать диалог с пометками кто говорит (используем fullText для полного контекста)
        let conversationText = messages.map { message in
            let speaker = message.speaker == .user ? "[Я]" : "[Интервьюер]"
            return "\(speaker): \(message.fullText)"
        }.joined(separator: "\n")

        // Получить текст с экрана (уже готов из периодического захвата)
        let screenText = screenService?.getLatestText() ?? ""

        print("🔍 DEBUG: Conversation = '\(conversationText)'")
        print("🔍 DEBUG: Screen text = '\(screenText)'")
        print("🔍 DEBUG: Messages count = \(messages.count)")

        guard !conversationText.isEmpty || !screenText.isEmpty else {
            await MainActor.run {
                overlayWindow?.updateResponse("❌ Нет данных для отправки")
            }
            return
        }

        let prompt = buildPrompt(conversation: conversationText, screenText: screenText)

        do {
            print("🌐 Отправка запроса в Gemini...")
            let suggestion = try await apiService.getSuggestion(prompt: prompt)
            print("✅ Получен ответ от Gemini, длина: \(suggestion.count) символов")

            // Явно на MainActor - обновляем UI
            await MainActor.run {
                overlayWindow?.updateResponse(suggestion)
            }

            // Сохраняем ответ в историю
            aiResponseHistory.append(suggestion)
        } catch {
            print("❌ Ошибка при запросе к Gemini: \(error.localizedDescription)")
            await MainActor.run {
                overlayWindow?.updateResponse("❌ Ошибка API: \(error.localizedDescription)")
            }
        }
    }

    func toggleOverlay() {
        if overlayWindow?.isVisible == true {
            overlayWindow?.hide()
        } else {
            overlayWindow?.show()
        }
    }

    func clearTranscript() {
        audioService?.clearTranscript()
        screenService?.clearText()
        systemAudioService?.clearTranscript()
        messages.removeAll()
        currentUserMessage = nil
        currentInterviewerMessage = nil
        aiResponseHistory.removeAll()  // Очищаем историю ответов
        overlayWindow?.clearTranscript()
        print("🧹 Все данные очищены (транскрипция + экран + история AI)")
    }

    private func buildPrompt(conversation: String, screenText: String) -> String {
        var prompt = """
        Ты - мой AI помощник на техническом интервью. Я senior Golang разработчик, прохожу собеседование в топовую компанию (Яндекс, Google, Meta).

        ВАЖНО: Я захватываю ДВА источника звука:
        - [Я] = мой голос (кандидат)
        - [Интервьюер] = голос собеседующего из Google Meet/Zoom

        ТВОЯ ЗАДАЧА: помогать МНЕ отвечать на вопросы интервьюера. Анализируй диалог и давай КОНКРЕТНЫЙ ответ/решение, КОТОРЫЙ Я МОГУ СКАЗАТЬ ВСЛУХ.

        КОНТЕКСТ ИНТЕРВЬЮ:
        """

        if !screenText.isEmpty {
            prompt += "\n📱 Экран (задача/вопрос):\n\(screenText)\n"
        }

        if !conversation.isEmpty {
            prompt += "\n💬 ДИАЛОГ:\n\(conversation)\n"

            // Явно указываем что нужно сделать
            let lastInterviewerMessage = messages.last(where: { $0.speaker == .interviewer })
            if let lastQuestion = lastInterviewerMessage?.fullText, !lastQuestion.isEmpty {
                prompt += "\n❓ ПОСЛЕДНИЙ ВОПРОС ИНТЕРВЬЮЕРА КО МНЕ:\n\(lastQuestion)\n"
                prompt += "\n👉 Дай МНЕ готовый ответ на этот вопрос, который я могу сказать интервьюеру.\n"
            }
        } else if !screenText.isEmpty {
            prompt += "\n💬 ДИАЛОГ: (молчу, пока думаю над задачей)\n"
        }

        // Добавляем историю предыдущих ответов
        if !aiResponseHistory.isEmpty {
            prompt += "\n📚 ИСТОРИЯ МОИХ ПРОШЛЫХ ОТВЕТОВ (НЕ ОТВЕЧАЙ ПОВТОРНО НА ЭТИ ВОПРОСЫ):\n"
            for (index, response) in aiResponseHistory.enumerated() {
                prompt += "\nОтвет #\(index + 1):\n\(response)\n"
            }
        }

        prompt += """


        ПРАВИЛА ОТВЕТА:

        1. ЕСЛИ ИНТЕРВЬЮЕР ЗАДАЛ ВОПРОС (видишь "[Интервьюер]: ..."):
           → Это вопрос КО МНЕ, дай МНЕ готовый ответ от первого лица
           → Я скажу твой ответ интервьюеру вслух
           → Начинай сразу с сути, без "Вот ответ:" или "Можно сказать:"

        2. Если на ЭКРАНЕ АЛГОРИТМИЧЕСКАЯ ЗАДАЧА (LeetCode/Codility):
           - Дай ПОЛНОЕ рабочее решение на Golang прямо сейчас
           - Укажи сложность (time/space)
           - Кратко (2-3 предложения) объясни подход от первого лица
           - Формат для озвучивания интервьюеру

        3. Если ТЕОРЕТИЧЕСКИЙ ВОПРОС от интервьюера:
           - Ответь на вопрос от первого лица (10-15 предложений)
           - "Я использую...", "По моему опыту..."
           - Раскрой детали реализации и подводные камни
           - Как будто Я сам отвечаю интервьюеру

        4. ИСТОРИЯ ОТВЕТОВ:
           - Если вопрос уже есть в ИСТОРИИ → вычлени новый вопрос и ответь на него
           - Отвечай ТОЛЬКО на НОВЫЕ вопросы, которых НЕТ в истории

        5. ГЛАВНОЕ ПРАВИЛО:
           - Твой ответ = то, что Я СКАЖУ ВСЛУХ интервьюеру
           - Говори от первого лица ("я", "по моему опыту")
           - НЕ предлагай дополнительные вопросы
           - Будь кратким и точным

        ФОРМАТ (алгоритм):
        **Подход:** [1-2 предложения]
        
        **Сложность:** O(...)

        ```go
        func solution(...) {
            // код
        }
        ```

        ФОРМАТ (теория):
        [Прямой ответ на вопрос, 10-15 предложений, от первого лица]
        """

        return prompt
    }

    private func requestPermissions() async -> Bool {
        print("🔐 Запрос разрешений...")

        // Запрос разрешения на микрофон
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let audioGranted: Bool
        if audioStatus == .authorized {
            audioGranted = true
            print("🎤 Микрофон: ✅ (уже разрешено)")
        } else {
            audioGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    print("🎤 Микрофон: \(granted ? "✅" : "❌")")
                    continuation.resume(returning: granted)
                }
            }
        }

        // Запрос разрешения на распознавание речи
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let speechGranted: Bool
        if speechStatus == .authorized {
            speechGranted = true
            print("🗣️ Речь: ✅ (уже разрешено)")
        } else {
            speechGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    print("🗣️ Речь: \(status == .authorized ? "✅" : "❌")")
                    continuation.resume(returning: status == .authorized)
                }
            }
        }

        // Запрос разрешения на захват экрана
        // Сначала проверяем, есть ли уже разрешение
        var screenGranted = CGPreflightScreenCaptureAccess()
        if !screenGranted {
            // Если нет, запрашиваем
            screenGranted = CGRequestScreenCaptureAccess()
        }
        print("🖥️ Экран: \(screenGranted ? "✅" : "❌")")

        let allGranted = audioGranted && speechGranted && screenGranted
        print("🔐 Все разрешения: \(allGranted ? "✅" : "❌")")

        return allGranted
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Atomic AI"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
