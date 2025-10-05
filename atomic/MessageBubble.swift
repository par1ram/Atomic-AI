//
//  MessageBubble.swift
//  atomic
//
//  Компонент сообщения в стиле Telegram

import SwiftUI

struct MessageBubble: View {
    let message: TranscriptMessage
    let isUser: Bool

    var body: some View {
        VStack(alignment: isUser ? .leading : .trailing, spacing: 4) {
            Text(message.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isUser ? Color.blue.opacity(0.6) : Color.gray.opacity(0.6))
                )
                .textSelection(.enabled)

            Text(isUser ? "Вы" : "Интервьюер")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: 300, alignment: isUser ? .leading : .trailing)
    }
}
