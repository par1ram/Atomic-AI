//
//  OverlayWindow.swift
//  atomic
//
//  Оверлейные окна для отображения транскрипции и ответов AI

import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
class OverlayWindow: ObservableObject {
    private var transcriptWindow: NSWindow?
    private var responseWindow: NSWindow?
    @Published var messages: [TranscriptMessage] = []
    @Published var response: String = ""
    weak var coordinator: AppCoordinator?

    var isVisible: Bool {
        return transcriptWindow?.isVisible ?? false
    }

    nonisolated init(coordinator: AppCoordinator?) {
        self.coordinator = coordinator
        Task { @MainActor in
            self.setupWindows()
        }
    }

    private func setupWindows() {
        setupTranscriptWindow()
        setupResponseWindow()
    }

    private func setupTranscriptWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        // Защита от демонстрации экрана
        window.sharingType = .none

        if let screen = NSScreen.main {
            let x = screen.frame.maxX - 470
            let y = screen.frame.maxY - 300
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let contentView = OverlayContentView(overlayWindow: self)
        window.contentView = NSHostingView(rootView: contentView)
        self.transcriptWindow = window
    }

    private func setupResponseWindow() {
        // Увеличенный размер окна для ответов
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        // Защита от демонстрации экрана
        window.sharingType = .none

        // Фиксированная позиция слева от transcript window
        if let screen = NSScreen.main {
            // Позиция слева от основного экрана
            let x = screen.frame.minX + 20
            let y = screen.frame.maxY - 520
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let contentView = ResponseWindowView(overlayWindow: self)
        window.contentView = NSHostingView(rootView: contentView)
        self.responseWindow = window
    }

    func show() {
        transcriptWindow?.orderFrontRegardless()
        // Показываем окно ответов только если есть текст
        if !response.isEmpty {
            responseWindow?.orderFrontRegardless()
        }
    }

    func hide() {
        transcriptWindow?.orderOut(nil)
        responseWindow?.orderOut(nil)
    }

    func updateMessages(_ newMessages: [TranscriptMessage]) {
        messages = newMessages
        // @Published автоматически обновит UI, не нужно пересоздавать view
    }

    func updateResponse(_ text: String) {
        print("🔄 OverlayWindow.updateResponse вызван с: '\(text.prefix(50))...'")

        // Обновляем текст - @Published автоматически обновит SwiftUI
        response = text

        // ВСЕГДА показываем окно при любом updateResponse (даже для лоадера)
        responseWindow?.orderFrontRegardless()

        print("✅ Response window показано, response.count = \(text.count)")
    }

    func clearTranscript() {
        messages.removeAll()
        response = ""
        responseWindow?.orderOut(nil)
        // @Published автоматически обновит UI
        print("🧹 Транскрипция и ответ очищены")
    }
}

// MARK: - Transcript Window View

struct OverlayContentView: View {
    @ObservedObject var overlayWindow: OverlayWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Заголовок компактный
            HStack {
                Image(systemName: "atom")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)

                Text("Atomic AI")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                // Hotkey подсказки горизонтально
                HStack(spacing: 12) {
                    Text("⌘↩ Ask")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("⌘R Clear")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("⌘\\ Hide")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // Чат с транскрипцией (стиль Telegram)
            VStack(alignment: .leading, spacing: 8) {
                Label("Live Transcript", systemImage: "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if overlayWindow.messages.isEmpty {
                                Text("Говорите...")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding()
                            } else {
                                ForEach(overlayWindow.messages) { message in
                                    HStack {
                                        if message.speaker == .user {
                                            // Сообщения пользователя слева
                                            MessageBubble(message: message, isUser: true)
                                            Spacer()
                                        } else {
                                            // Сообщения интервьюера справа
                                            Spacer()
                                            MessageBubble(message: message, isUser: false)
                                        }
                                    }
                                    .id(message.id)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: overlayWindow.messages.count) {
                        // Автоскролл к последнему сообщению
                        if let lastMessage = overlayWindow.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 450, height: 280)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .opacity(0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        
    }
}

// MARK: - Response Window View

struct ResponseWindowView: View {
    @ObservedObject var overlayWindow: OverlayWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Заголовок
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(.yellow)

                Text("AI Solution")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()
            }

            // Ответ AI с кодом
            ScrollView {
                Text(overlayWindow.response.isEmpty ? "Ожидание ответа..." : overlayWindow.response)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .padding(16)
        .frame(width: 600, height: 500)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .opacity(0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}
