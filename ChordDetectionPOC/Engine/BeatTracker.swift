//
//  BeatTracker.swift
//  ChordDetectionPOC
//

import Accelerate
import Foundation

/// Beat positions for the chord segmenter, computed from the audio itself.
///
/// Classic dynamic-programming beat tracker (Ellis 2007, the one librosa uses):
///  1. onset strength = positive spectral flux of the log spectrum
///  2. tempo = autocorrelation peak of the onset curve, weighted toward ~120 BPM
///  3. beats = the sequence that lands on strong onsets while keeping a near-constant period
nonisolated enum BeatTracker {

    nonisolated struct Result: Sendable {
        let beats: [Double]
        let bpm: Double
    }

    static func track(
        samples: [Float],
        sampleRate: Double,
        fftSize: Int = 2048,
        hopSize: Int = 512,
        minBPM: Double = 60,
        maxBPM: Double = 200,
        preferredBPM: Double = 120,
        tightness: Float = 100
    ) -> Result? {
        let onset = onsetStrength(samples: samples, fftSize: fftSize, hopSize: hopSize)
        let frameRate = sampleRate / Double(hopSize)
        guard onset.count > Int(frameRate * 4) else { return nil }          // need a few seconds

        guard let period = estimatePeriod(onset, frameRate: frameRate,
                                          minBPM: minBPM, maxBPM: maxBPM, preferredBPM: preferredBPM)
        else { return nil }

        let beatFrames = dynamicBeats(onset, period: period, tightness: tightness)
        guard beatFrames.count >= 4 else { return nil }

        // A frame's onset value describes the change into that frame, centred at its window.
        let offset = Double(fftSize / 2) / sampleRate
        let beats = beatFrames.map { Double($0) / frameRate + offset }
        return Result(beats: beats, bpm: 60 * frameRate / Double(period))
    }

    // MARK: 1. Onset strength

    private static func onsetStrength(samples: [Float], fftSize: Int, hopSize: Int) -> [Float] {
        let half = fftSize / 2
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard samples.count >= fftSize,
              let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var onset: [Float] = []

        var start = 0
        var first = true
        while start + fftSize <= samples.count {
            let windowed = samples.withUnsafeBufferPointer { sp in
                vDSP.multiply(UnsafeBufferPointer(rebasing: sp[start..<(start + fftSize)]), window)
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { mp in
                        vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                    }
                }
            }
            // Log compression so quiet hi-hats count, not just the kick.
            for k in 0..<half { mags[k] = log1p(100 * mags[k]) }

            if first {
                first = false
            } else {
                var flux: Float = 0
                for k in 1..<half { flux += max(0, mags[k] - previous[k]) }
                onset.append(flux)
            }
            swap(&previous, &mags)
            start += hopSize
        }
        guard !onset.isEmpty else { return [] }
        onset.insert(0, at: 0)                       // keep frame indices aligned with STFT frames

        // Remove the slowly-varying loudness trend, keep the peaks, normalise.
        let radius = 16
        var prefix = [Float](repeating: 0, count: onset.count + 1)
        for i in 0..<onset.count { prefix[i + 1] = prefix[i] + onset[i] }
        var detrended = [Float](repeating: 0, count: onset.count)
        for i in 0..<onset.count {
            let lo = max(0, i - radius), hi = min(onset.count, i + radius + 1)
            let localMean = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            detrended[i] = max(0, onset[i] - localMean)
        }
        let sd = vDSP.standardDeviation(detrended)
        return sd > 0 ? vDSP.divide(detrended, sd) : detrended
    }

    // MARK: 2. Tempo

    /// Beat period in onset frames, or nil if there's no periodic structure (silence, speech...).
    private static func estimatePeriod(
        _ onset: [Float], frameRate: Double, minBPM: Double, maxBPM: Double, preferredBPM: Double
    ) -> Int? {
        let minLag = max(1, Int((60 * frameRate / maxBPM).rounded(.down)))
        let maxLag = min(onset.count - 1, Int((60 * frameRate / minBPM).rounded(.up)))
        guard minLag < maxLag else { return nil }

        var bestLag = 0
        var bestScore: Float = 0
        onset.withUnsafeBufferPointer { op in
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(op.baseAddress!, 1, op.baseAddress! + lag, 1, &dot, vDSP_Length(onset.count - lag))
                dot /= Float(onset.count - lag)

                // Log-normal prior over tempo (1 octave std), so 2x / 0.5x errors are less likely.
                let bpm = 60 * frameRate / Double(lag)
                let octaves = log2(bpm / preferredBPM)
                let score = dot * Float(exp(-0.5 * octaves * octaves))
                if score > bestScore { bestScore = score; bestLag = lag }
            }
        }
        // The DP below absorbs small tempo drift, so whole-frame resolution (~23 ms) is enough.
        return bestLag > 0 ? bestLag : nil
    }

    // MARK: 3. Dynamic programming

    private static func dynamicBeats(_ onset: [Float], period: Int, tightness: Float) -> [Int] {
        let n = onset.count
        var score = [Float](repeating: 0, count: n)
        var backlink = [Int](repeating: -1, count: n)

        // Penalty for an inter-beat gap that isn't exactly one period (log-squared deviation).
        let minGap = max(1, period / 2), maxGap = period * 2
        var penalty = [Float](repeating: 0, count: maxGap + 1)
        for gap in minGap...maxGap {
            let dev = Float(log(Double(gap) / Double(period)))
            penalty[gap] = -tightness * dev * dev
        }

        for t in 0..<n {
            var best: Float = 0
            var bestPrev = -1
            if t >= minGap {
                for gap in minGap...min(maxGap, t) {
                    let candidate = score[t - gap] + penalty[gap]
                    if bestPrev < 0 || candidate > best { best = candidate; bestPrev = t - gap }
                }
            }
            // Starting a fresh chain is always allowed (that's how the first beat is found).
            if bestPrev >= 0, best > 0 {
                score[t] = onset[t] + best
                backlink[t] = bestPrev
            } else {
                score[t] = onset[t]
            }
        }

        // End on the best-scoring frame within the last period, then walk back.
        var end = max(0, n - period)
        for t in end..<n where score[t] > score[end] { end = t }

        var beats: [Int] = []
        var t = end
        while t >= 0 {
            beats.append(t)
            t = backlink[t]
        }
        beats.reverse()

        // Drop leading/trailing beats that sit on near-silence (intro/outro padding).
        let strong = beats.map { onset[$0] }
        let cutoff = 0.1 * (strong.sorted()[strong.count / 2])
        while let firstBeat = beats.first, onset[firstBeat] < cutoff, beats.count > 4 { beats.removeFirst() }
        while let lastBeat = beats.last, onset[lastBeat] < cutoff, beats.count > 4 { beats.removeLast() }
        return beats
    }
}
