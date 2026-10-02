//
//  AudioDecoder.swift
//  ChordDetectionPOC
//
//  Created by Theona Arlinton on 01/10/26.
//

import AVFoundation

nonisolated enum ChordDetectionError: LocalizedError {
    case decodeFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let reason): return "Couldn't read the audio: \(reason)"
        case .emptyAudio: return "The audio file contains no samples."
        }
    }
}

/// Decodes any file AVAudioFile can open into mono Float32 at `sampleRate`.
/// 22,050 Hz is plenty for chords (everything useful is below ~5 kHz) and halves the work.
nonisolated enum AudioDecoder {

    nonisolated private final class ReadState: @unchecked Sendable {
        var finished = false
    }

    static func loadMono(url: URL, sampleRate targetRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat

        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            throw ChordDetectionError.decodeFailed("Unsupported audio format.")
        }

        let inCapacity: AVAudioFrameCount = 32_768
        let outCapacity = AVAudioFrameCount(Double(inCapacity) * targetRate / inFormat.sampleRate) + 4_096

        guard
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity),
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)
        else {
            throw ChordDetectionError.decodeFailed("Couldn't allocate audio buffers.")
        }

        let state = ReadState()
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * targetRate / inFormat.sampleRate) + 1)

        while true {
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
                if state.finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inBuffer.frameLength = 0
                do {
                    try file.read(into: inBuffer, frameCount: inCapacity)
                } catch {
                    state.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    state.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }

            if status == .error {
                throw ChordDetectionError.decodeFailed(convertError?.localizedDescription ?? "Conversion failed.")
            }

            if let channel = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }

            if status == .endOfStream || status == .inputRanDry { break }
        }

        guard !samples.isEmpty else { throw ChordDetectionError.emptyAudio }
        return samples
    }
}
