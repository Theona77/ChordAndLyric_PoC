//
//  CoreMLModels.swift
//  ChordDetectionPOC
//
//  Loading and running the two Core ML models:
//   - BTCChords   (chord recognition, Park et al. 2019, MIT licence)
//   - BasicPitch  (note transcription, Spotify, Apache 2.0)
//  See ChordDetectionPOC/Models/README.md for where they come from.
//

import CoreML
import Foundation

nonisolated enum ModelStoreError: LocalizedError {
    case missing(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "The \(name) model isn't in the app. Check that ChordDetectionPOC/Models is part of the target."
        case .badOutput(let name):
            return "The \(name) model returned an unexpected output."
        }
    }
}

nonisolated enum ModelStore {

    /// Finds a resource in `directory` (if given), then in the main bundle.
    static func resourceURL(named name: String, extensions: [String], directory: URL?) -> URL? {
        for ext in extensions {
            if let directory {
                let url = directory.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        }
        return nil
    }

    /// Xcode compiles .mlpackage files into the app as .mlmodelc. The command-line tool gets
    /// the raw .mlpackage, which is compiled on the fly.
    static func loadModel(named name: String, directory: URL?) async throws -> MLModel {
        guard let url = resourceURL(named: name, extensions: ["mlmodelc", "mlpackage", "mlmodel"], directory: directory) else {
            throw ModelStoreError.missing(name)
        }
        let compiled = url.pathExtension == "mlmodelc" ? url : try await MLModel.compileModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// [1, T, C] multi-array -> [[Float]] of T rows, honouring strides.
    static func rows(of array: MLMultiArray) -> [[Float]] {
        guard array.shape.count == 3 else { return [] }
        let t = array.shape[1].intValue, c = array.shape[2].intValue
        let s1 = array.strides[1].intValue, s2 = array.strides[2].intValue

        if array.dataType == .float32 {
            return array.withUnsafeBufferPointer(ofType: Float.self) { ptr in
                (0..<t).map { i in (0..<c).map { j in ptr[i * s1 + j * s2] } }
            }
        }
        // Slow but always correct for other element types (e.g. Float16 outputs).
        return (0..<t).map { i in
            (0..<c).map { j in array[[0, i, j] as [NSNumber]].floatValue }
        }
    }
}

// MARK: - BTC

/// Frame-level chord probabilities from BTC.
nonisolated struct BTCRecognizer {

    static let modelName = "BTCChords"
    static let kernelsName = "BTCKernels"
    static let windowFrames = 108
    /// The checkpoint's feature mean. Padding with it normalises to 0, like BTC's own zero padding.
    static let featureMean: Float = -2.2279878897355596

    let model: MLModel
    let cqt: ConstantQ

    static func load(directory: URL?) async throws -> BTCRecognizer {
        guard let kernels = ModelStore.resourceURL(named: kernelsName, extensions: ["bin"], directory: directory) else {
            throw ConstantQ.LoadError.missing
        }
        let cqt = try ConstantQ(contentsOf: kernels)
        let model = try await ModelStore.loadModel(named: modelName, directory: directory)
        return BTCRecognizer(model: model, cqt: cqt)
    }

    /// Log-probabilities per CQT frame over `ChordVocabulary.btc` (168 chords + N; BTC's "X" is folded into N).
    func logProbabilities(_ spectrogram: ConstantQ.Spectrogram) throws -> [[Float]] {
        let frames = spectrogram.frames
        var result: [[Float]] = []
        result.reserveCapacity(frames.count)

        var start = 0
        while start < frames.count {
            try Task.checkCancellation()
            let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowFrames), NSNumber(value: ConstantQ.binCount)],
                                         dataType: .float32)
            let valid = min(Self.windowFrames, frames.count - start)
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, strides in
                let s1 = strides[1], s2 = strides[2]
                for t in 0..<Self.windowFrames {
                    for b in 0..<ConstantQ.binCount {
                        ptr[t * s1 + b * s2] = t < valid ? frames[start + t][b] : Self.featureMean
                    }
                }
            }

            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["logcqt": input]))
            guard let array = output.featureValue(for: "logprobs")?.multiArrayValue else {
                throw ModelStoreError.badOutput(Self.modelName)
            }
            let rows = ModelStore.rows(of: array)
            guard rows.count == Self.windowFrames, rows.first?.count == 170 else {
                throw ModelStoreError.badOutput(Self.modelName)
            }
            for t in 0..<valid {
                let row = rows[t]
                var folded = Array(row[0..<168])
                let a = row[168], b = row[169]                      // X, N
                let m = max(a, b)
                folded.append(m + log(exp(a - m) + exp(b - m)))
                result.append(folded)
            }
            start += Self.windowFrames
        }
        return result
    }
}

// MARK: - Basic Pitch

/// Note activations from Basic Pitch, windowed exactly like basic_pitch.inference.
nonisolated struct BasicPitchTranscriber {

    static let modelName = "BasicPitch"
    static let sampleRate = 22_050.0
    static let windowSamples = 43_844              // 2 s minus one hop
    static let framesPerWindow = 172
    static let overlapFrames = 30
    static let hop = 256
    static let lowestMidi = 21                     // A0; 88 keys

    let model: MLModel

    static func load(directory: URL?) async throws -> BasicPitchTranscriber {
        BasicPitchTranscriber(model: try await ModelStore.loadModel(named: modelName, directory: directory))
    }

    nonisolated struct Notes: Sendable {
        /// [frame][88] activation 0...1 for MIDI 21...108.
        let activations: [[Float]]
        let times: [Double]
    }

    func transcribe(samples: [Float]) throws -> Notes {
        let overlap = Self.overlapFrames * Self.hop                 // 7680
        let windowHop = Self.windowSamples - overlap                // 36164
        let keep = Self.framesPerWindow - Self.overlapFrames        // 142 frames per window
        let padded = [Float](repeating: 0, count: overlap / 2) + samples

        var activations: [[Float]] = []
        var times: [Double] = []
        var window = [Float](repeating: 0, count: Self.windowSamples)
        var w = 0
        var start = 0
        while start < padded.count {
            try Task.checkCancellation()
            AudioFrames.copy(padded, start: start, into: &window)
            let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples), 1], dataType: .float32)
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, strides in
                for i in 0..<Self.windowSamples { ptr[i * strides[1]] = window[i] }
            }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_2": input]))
            // Identity = contour (264), Identity_1 = note (88), Identity_2 = onset (88).
            guard let notes = output.featureValue(for: "Identity_1")?.multiArrayValue else {
                throw ModelStoreError.badOutput(Self.modelName)
            }
            let rows = ModelStore.rows(of: notes)
            guard rows.count == Self.framesPerWindow, rows.first?.count == 88 else {
                throw ModelStoreError.badOutput(Self.modelName)
            }
            let half = Self.overlapFrames / 2
            for f in half..<(Self.framesPerWindow - half) {
                activations.append(rows[f])
                times.append(Double(w * windowHop + (f - half) * Self.hop) / Self.sampleRate)
            }
            w += 1
            start += windowHop
        }

        // basic_pitch.inference.unwrap_output: trim to the original length.
        let expected = Int(Double(samples.count) / Double(windowHop) * Double(keep))
        let n = min(expected, activations.count)
        return Notes(activations: Array(activations[0..<n]), times: Array(times[0..<n]))
    }

    /// Fold note activations into treble and bass pitch-class profiles.
    /// Treble = notes from C3 up. Bass = the single lowest note below G3 that's clearly sounding
    /// (activation >= 0.3), weighted by its activation: summing everything below G3 also caught the
    /// low notes of piano/guitar voicings and blurred the bass line (+0.7 majmin, +3.9 with slash
    /// chords on the synthetic set).
    static func chroma(_ notes: Notes) -> (treble: [[Float]], bass: [[Float]], loudness: [Float]) {
        var treble: [[Float]] = [], bass: [[Float]] = [], loudness: [Float] = []
        for frame in notes.activations {
            var t = [Float](repeating: 0, count: 12), b = [Float](repeating: 0, count: 12)
            var total: Float = 0
            var lowestFound = false
            for (i, a) in frame.enumerated() {
                let midi = lowestMidi + i
                if midi >= 48 { t[midi % 12] += a }
                if !lowestFound, midi < 55, a >= 0.3 {
                    b[midi % 12] = a
                    lowestFound = true
                }
                total += a
            }
            treble.append(t); bass.append(b); loudness.append(total)
        }
        return (treble, bass, loudness)
    }
}
