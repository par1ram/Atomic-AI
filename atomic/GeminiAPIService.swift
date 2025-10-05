//
//  GeminiAPIService.swift
//  atomic
//
//  Сервис для отправки запросов к Google Gemini API

import Foundation

class GeminiAPIService {
    private let apiKey: String
    // Используем gemini-2.5-flash с отключенным thinking mode
    private let apiURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

    init() {
        // ВАЖНО: API ключ берется из переменной окружения GEMINI_API_KEY
        // Установите её перед запуском: export GEMINI_API_KEY="your_key_here"
        // Или добавьте в Xcode: Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty {
            self.apiKey = envKey
        } else {
            self.apiKey = ""
            print("⚠️ ВНИМАНИЕ: Используется fallback API ключ. Установите GEMINI_API_KEY в environment!")
        }
    }

    func getSuggestion(prompt: String, retryCount: Int = 0) async throws -> String {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "GeminiAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Установите API ключ Gemini в переменную окружения GEMINI_API_KEY"])
        }

        let url = URL(string: apiURL)!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.7,
                "maxOutputTokens": 4096,
                "topP": 0.9,
                "topK": 40,
                "candidateCount": 1,
                "stopSequences": [],
                "responseModalities": ["TEXT"],
                "responseMimeType": "text/plain"
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("📤 Отправка запроса в Gemini...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Нет HTTP ответа"])
        }

        print("📥 Статус: \(httpResponse.statusCode)")

        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Нет данных"
            print("❌ Ошибка API: \(errorText)")
            throw NSError(domain: "GeminiAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorText)"])
        }

        // Декодируем ответ
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let jsonString = String(data: data, encoding: .utf8) ?? "Нет данных"
        print("📄 Полный JSON ответ:\n\(jsonString)")

        // Парсинг ответа Gemini 2.5 (структура может отличаться)
        if let candidates = json?["candidates"] as? [[String: Any]],
           let firstCandidate = candidates.first {

            // Проверяем finishReason
            if let finishReason = firstCandidate["finishReason"] as? String {
                print("🏁 Finish reason: \(finishReason)")
            }

            // Пытаемся получить content
            if let content = firstCandidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                print("✅ Получен ответ из parts: \(text.prefix(100))...")
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Альтернативная структура - текст напрямую в content
            if let content = firstCandidate["content"] as? [String: Any],
               let text = content["text"] as? String {
                print("✅ Получен ответ из content.text: \(text.prefix(100))...")
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Ещё один вариант - текст напрямую в candidate
            if let text = firstCandidate["text"] as? String {
                print("✅ Получен ответ из candidate.text: \(text.prefix(100))...")
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        print("❌ Не удалось найти текст в ответе")

        // Retry логика - повторяем до 3 раз при пустом ответе
        if retryCount < 3 {
            print("🔄 Повторная попытка \(retryCount + 1)/3...")
            return try await getSuggestion(prompt: prompt, retryCount: retryCount + 1)
        }

        throw NSError(domain: "GeminiAPI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось распарсить ответ после 3 попыток. Проверьте логи."])
    }
}
