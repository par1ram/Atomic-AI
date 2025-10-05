//
//  TranscriptMessage.swift
//  atomic
//
//  Модель сообщения в транскрипции

import Foundation

enum Speaker {
    case user       // Кандидат (микрофон)
    case interviewer // Интервьюер (системный звук)
}

struct TranscriptMessage: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    var text: String           // Отображаемый текст (только новая часть для интервьюера)
    var fullText: String       // Полный накопленный текст (для отправки в Gemini)
    var isFinal: Bool
    let timestamp: Date

    init(speaker: Speaker, text: String, fullText: String? = nil, isFinal: Bool = false) {
        self.speaker = speaker
        self.text = text
        self.fullText = fullText ?? text  // Если fullText не указан, используем text
        self.isFinal = isFinal
        self.timestamp = Date()
    }
}
