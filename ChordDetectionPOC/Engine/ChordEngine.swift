//
//  ChordEngine.swift
//  ChordDetectionPOC
//
//  Entry point for chord detection, shared by the app and the `chord-eval` command-line tool.
//

import Foundation

nonisolated enum ChordEngineKind: String, CaseIterable, Sendable, Identifiable {
    /// Built-in chroma (drum removal + bass) matched against chord templates.
    case templates
    /// Basic Pitch note transcription folded into chroma, then the same template matching.
    case basicPitch
    /// BTC transformer chord recogniser.
    case btc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .templates: return "Templates"
        case .basicPitch: return "Basic Pitch"
        case .btc: return "BTC (Core ML)"
        }
    }
}

nonisolated struct ChordEngineOptions: Sendable {
    var config = ChordDetectorConfig()
    /// Where to look for the Core ML models before the app bundle (used by the command-line tool).
    var modelDirectory: URL?
    /// Segment per beat (true) or per fixed 0.5 s step (false).
    var useBeats = true
    /// With no key supplied, estimate one from the audio so the key prior still applies.
    var estimateKeyWhenMissing = true
}

nonisolated struct ChordAnalysis: Sendable {
    let segments: [DetectedSegment]
    let duration: Double
    let beats: [Double]?
    /// Key regions found from the chords (key changes included), or the supplied/estimated keys.
    /// Used for the prior's second pass and for spelling chords (Ab, not G#, after a modulation).
    let keys: [KeyRegion]

    var labText: String { ChordLab.text(for: segments, duration: duration) }
}

nonisolated enum ChordEngine {

    /// Runs off the main actor (`@concurrent`), so the UI stays responsive.
    /// - Parameter keys: the song's key timeline, e.g. from MusicUnderstanding. Empty = unknown.
    @concurrent
    static func run(kind: ChordEngineKind, url: URL, keys: [KeyRegion], options: ChordEngineOptions) async throws -> ChordAnalysis {
        let config = options.config
        let samples = try AudioDecoder.loadMono(url: url, sampleRate: config.analysisSampleRate)
        try Task.checkCancellation()
        return try await run(kind: kind, samples: samples, keys: keys, options: options)
    }

    @concurrent
    static func run(kind: ChordEngineKind, samples: [Float], keys: [KeyRegion], options: ChordEngineOptions) async throws -> ChordAnalysis {
        let config = options.config
        let duration = Double(samples.count) / config.analysisSampleRate

        let segmentation: (bounds: [Double], beats: [Double]?)
        if options.useBeats {
            segmentation = ChordSegmenter.boundaries(samples: samples, duration: duration, config: config)
        } else {
            segmentation = (ChordSegmenter.uniformBoundaries(duration: duration, step: config.fallbackSegmentDuration), nil)
        }
        let bounds = segmentation.bounds
        try Task.checkCancellation()

        switch kind {
        case .templates:
            let frames = ChromaExtractor.extract(samples: samples, sampleRate: config.analysisSampleRate,
                                                 options: config.chroma)
            try Task.checkCancellation()
            let keys = resolvedKeys(keys, chroma: frames.chroma, options: options)
            let treble = ChordSegmenter.aggregate(frames.chroma, times: frames.times, boundaries: bounds)
            let bass = ChordSegmenter.aggregate(frames.bass, times: frames.times, boundaries: bounds)
            let loudness = ChordSegmenter.aggregate(frames.rms.map { [$0] }, times: frames.times, boundaries: bounds).map { $0[0] }
            return decodeTemplates(treble: treble, bass: bass, loudness: loudness, bounds: bounds,
                                   duration: duration, beats: segmentation.beats, keys: keys, config: config,
                                   frameBass: frames.bass, frameTimes: frames.times)

        case .basicPitch:
            let transcriber = try await BasicPitchTranscriber.load(directory: options.modelDirectory)
            let notes = try transcriber.transcribe(samples: samples)
            try Task.checkCancellation()
            let folded = BasicPitchTranscriber.chroma(notes)
            let keys = resolvedKeys(keys, chroma: folded.treble, options: options)
            let treble = ChordSegmenter.aggregate(folded.treble, times: notes.times, boundaries: bounds)
            let bass = ChordSegmenter.aggregate(folded.bass, times: notes.times, boundaries: bounds)
            let loudness = ChordSegmenter.aggregate(folded.loudness.map { [$0] }, times: notes.times, boundaries: bounds).map { $0[0] }
            return decodeTemplates(treble: treble, bass: bass, loudness: loudness, bounds: bounds,
                                   duration: duration, beats: segmentation.beats, keys: keys, config: config,
                                   frameBass: folded.bass, frameTimes: notes.times)

        case .btc:
            let recognizer = try await BTCRecognizer.load(directory: options.modelDirectory)
            let spectrogram = recognizer.cqt.logSpectrogram(samples: samples)
            try Task.checkCancellation()
            let logProbs = try recognizer.logProbabilities(spectrogram)
            let keys = resolvedKeys(keys, chroma: spectrogram.frames.map(ConstantQ.chroma), options: options)
            let scores = ChordSegmenter.aggregate(logProbs, times: spectrogram.times, boundaries: bounds)
                .map { row in row.map { $0 * config.btcEmissionWeight } }
            let decoded = ChordDecoder.decodeRefiningKeys(scores: scores, boundaries: bounds, states: ChordVocabulary.btc,
                                                          keys: keys, stayProbability: config.stayProbability,
                                                          offKeyPenalty: config.btcOffKeyPenalty)
            let segments = config.detectSlashChords
                ? SlashChords.apply(to: decoded.segments, bass: spectrogram.frames.map(ConstantQ.bass),
                                    times: spectrogram.times, minShare: config.slashMinShareBTC)
                : decoded.segments
            return ChordAnalysis(segments: segments, duration: duration, beats: segmentation.beats, keys: decoded.keys)
        }
    }

    private static func decodeTemplates(
        treble: [[Float]], bass: [[Float]], loudness: [Float], bounds: [Double],
        duration: Double, beats: [Double]?, keys: [KeyRegion], config: ChordDetectorConfig,
        frameBass: [[Float]], frameTimes: [Double]
    ) -> ChordAnalysis {
        let states = ChordVocabulary.all
        let scores = TemplateEmissions.scores(treble: treble, bass: bass, loudness: loudness,
                                              states: states, config: config)
        let decoded = ChordDecoder.decodeRefiningKeys(scores: scores, boundaries: bounds, states: states, keys: keys,
                                                      stayProbability: config.stayProbability,
                                                      offKeyPenalty: config.offKeyPenalty)
        let segments = config.detectSlashChords
            ? SlashChords.apply(to: decoded.segments, bass: frameBass, times: frameTimes,
                                minShare: config.slashMinShareTemplates)
            : decoded.segments
        return ChordAnalysis(segments: segments, duration: duration, beats: beats, keys: decoded.keys)
    }

    private static func resolvedKeys(_ keys: [KeyRegion], chroma: [[Float]], options: ChordEngineOptions) -> [KeyRegion] {
        if !keys.isEmpty || !options.estimateKeyWhenMissing { return keys }
        return KeyEstimator.estimate(chroma: chroma).map { [$0] } ?? []
    }
}

// MARK: - .lab export

nonisolated enum ChordLab {
    /// MIREX-style lab: "start end label" per line, Harte labels, "N" filling the gaps.
    static func text(for segments: [DetectedSegment], duration: Double?) -> String {
        var lines: [String] = []
        var cursor = 0.0
        for s in segments {
            if s.start > cursor + 1e-3 { lines.append(line(cursor, s.start, "N")) }
            lines.append(line(s.start, s.start + s.duration, s.harte))
            cursor = s.start + s.duration
        }
        if let duration, duration > cursor + 1e-3 { lines.append(line(cursor, duration, "N")) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func line(_ start: Double, _ end: Double, _ label: String) -> String {
        String(format: "%.3f\t%.3f\t", start, end) + label
    }
}
