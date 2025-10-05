//
//  AudioConverter.swift
//  atomic
//
//  Конвертер аудио для WhisperKit (48kHz → 16kHz mono Float32)

import Foundation
import AVFoundation

class AudioConverter {
    private var converterCache: [String: AVAudioConverter] = [:]
    private let targetFormat: AVAudioFormat

    init?() {
        // WhisperKit требует 16kHz mono Float32
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        self.targetFormat = format
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Кэш ключ на основе параметров формата
        let formatKey = formatCacheKey(for: inputBuffer.format)

        // Получить или создать converter из кэша
        let converter: AVAudioConverter
        if let cachedConverter = converterCache[formatKey] {
            converter = cachedConverter
        } else {
            guard let newConverter = AVAudioConverter(from: inputBuffer.format, to: targetFormat) else {
                print("❌ Не удалось создать audio converter")
                return nil
            }
            converterCache[formatKey] = newConverter
            converter = newConverter
        }

        // Рассчитать размер выходного буфера
        let inputSampleRate = inputBuffer.format.sampleRate
        let outputSampleRate = targetFormat.sampleRate
        let ratio = outputSampleRate / inputSampleRate

        let outputFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            print("❌ Не удалось создать output buffer")
            return nil
        }

        var error: NSError?
        var inputUsed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputUsed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputUsed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error {
            print("❌ Ошибка конвертации: \(error?.localizedDescription ?? "unknown")")
            return nil
        }

        return outputBuffer
    }

    // Конвертация CMSampleBuffer → AVAudioPCMBuffer (для ScreenCaptureKit)
    func convertSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        guard let asbd = asbd else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        ) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == kCMBlockBufferNoErr, let dataPointer = dataPointer else {
            return nil
        }

        let channelData = buffer.floatChannelData?[0]
        let _ = channelData?.withMemoryRebound(to: Int8.self, capacity: length) { destination in
            memcpy(destination, dataPointer, length)
        }

        // Теперь конвертируем в 16kHz mono
        return convert(buffer)
    }

    // MARK: - Helper Methods

    private func formatCacheKey(for format: AVAudioFormat) -> String {
        return "\(format.sampleRate)_\(format.channelCount)_\(format.commonFormat.rawValue)_\(format.isInterleaved)"
    }
}
