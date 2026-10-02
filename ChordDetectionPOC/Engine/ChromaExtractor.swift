//
//  ChromaExtractor.swift
//  ChordDetectionPOC
//
//  Created by Theona Arlinton on 01/10/26.
//

import Accelerate
import Foundation

nonisolated struct ChromaFrames: Sendable {
    /// One 12-value pitch-class vector per frame (C, C#, ... B), log-compressed. ~G2 to ~B6.
    let chroma: [[Float]]
    /// Same, from the bass register only (~G1 to ~B3). Empty when not computed.
    let bass: [[Float]]
    /// Loudness of each frame (used for silence detection).
    let rms: [Float]
    /// Centre time of each frame, in seconds.
    let times: [Double]
    /// Total audio duration, in seconds.
    let duration: Double
    /// Estimated deviation from A440 in semitones (-0.5...0.5). Informational.
    let tuning: Float
}

/// STFT -> drum removal -> spectral peaks -> tuning estimate -> 12 pitch classes, twice:
/// once for the mid/treble register and once (with a longer window) for the bass.
///
///  - Drum removal (harmonic-percussive separation, Fitzgerald 2010): pitched sound is steady over
///    time but narrow in frequency; drums are short but broadband. A median filter along time keeps
///    the first, one along frequency keeps the second, and a soft mask built from the two removes
///    most of the drums before any notes are picked.
///  - Only spectral peaks count, each with a sub-bin frequency, and the song's tuning offset is
///    removed before rounding to a semitone.
///  - The treble band starts at ~G2: below that a semitone is narrower than two bins of the
///    8192-point FFT. The bass gets its own 16384-point FFT so its notes can be resolved; it decides
///    the root (Am7 and C6 have the same notes, but not the same bass).
nonisolated enum ChromaExtractor {

    nonisolated private struct Peak {
        let midi: Float      // fractional MIDI note number
        let mag: Float       // linear magnitude, scaled
    }

    nonisolated struct Options: Sendable {
        var fftSize = 8192
        var hopSize = 2048
        var minFrequency: Double = 100       // ~G2
        var maxFrequency: Double = 2000
        var bassFFTSize = 16384
        var bassMinFrequency: Double = 48    // ~G1
        var bassMaxFrequency: Double = 250   // ~B3
        var removeDrums = true
        /// Median filter half-widths for drum removal: frames along time, bins along frequency.
        var harmonicRadius = 4               // 9 frames, ~0.8 s at the default hop
        var percussiveRadius = 8             // 17 bins
        var compressionGain: Float = 1000
        /// Ignore peaks below this fraction of the frame's strongest peak.
        var peakFloor: Float = 0.05
    }

    static func extract(samples: [Float], sampleRate: Double, options: Options = Options()) -> ChromaFrames {
        let duration = Double(samples.count) / sampleRate
        let fftSize = options.fftSize, hop = options.hopSize

        // Frame centres: a frame counts as long as its centre is inside the audio.
        var centres: [Int] = []
        var c = fftSize / 2
        while c < samples.count { centres.append(c); c += hop }

        guard !centres.isEmpty,
              var treble = BandSpectrogram(samples: samples, sampleRate: sampleRate, centres: centres,
                                           fftSize: fftSize,
                                           minFrequency: options.minFrequency, maxFrequency: options.maxFrequency)
        else {
            return ChromaFrames(chroma: [], bass: [], rms: [], times: [], duration: duration, tuning: 0)
        }
        var bass = BandSpectrogram(samples: samples, sampleRate: sampleRate, centres: centres,
                                   fftSize: options.bassFFTSize,
                                   minFrequency: options.bassMinFrequency, maxFrequency: options.bassMaxFrequency)

        if options.removeDrums {
            treble.removePercussion(harmonicRadius: options.harmonicRadius, percussiveRadius: options.percussiveRadius)
            bass?.removePercussion(harmonicRadius: options.harmonicRadius, percussiveRadius: options.percussiveRadius)
        }

        let treblePeaks = treble.peaks(floor: options.peakFloor)
        let bassPeaks = bass?.peaks(floor: options.peakFloor) ?? []

        // Tuning: most songs aren't exactly A440. Find the common offset, then fold relative to it.
        let tuning = estimateTuning(treblePeaks)
        let fold = { (peaks: [Peak]) -> [Float] in
            var v = [Float](repeating: 0, count: 12)
            for p in peaks {
                let note = Int((p.midi - tuning).rounded())
                v[((note % 12) + 12) % 12] += log1p(p.mag * options.compressionGain)
            }
            return v
        }

        return ChromaFrames(
            chroma: treblePeaks.map(fold),
            bass: bassPeaks.map(fold),
            rms: treble.rms,
            times: centres.map { Double($0) / sampleRate },
            duration: duration,
            tuning: tuning
        )
    }

    // MARK: Spectrogram of one frequency band

    /// Magnitudes for bins [lowBin - 1, highBin + 1] of every frame (the extra bin on each side is
    /// for peak picking), row-major: frame t, bin k at `mags[t * width + (k - lowBin + 1)]`.
    nonisolated private struct BandSpectrogram {
        let lowBin: Int
        let highBin: Int
        let width: Int
        let frames: Int
        let binHz: Double
        let scale: Float
        var mags: [Float]
        var rms: [Float]

        init?(samples: [Float], sampleRate: Double, centres: [Int], fftSize: Int,
              minFrequency: Double, maxFrequency: Double) {
            let half = fftSize / 2
            let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
            binHz = sampleRate / Double(fftSize)
            lowBin = max(2, Int((minFrequency / binHz).rounded(.up)))
            highBin = min(half - 2, Int((maxFrequency / binHz).rounded(.down)))
            guard lowBin < highBin,
                  let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
            defer { vDSP_destroy_fftsetup(setup) }

            width = highBin - lowBin + 3
            frames = centres.count
            scale = 0.5 / Float(fftSize)      // vDSP_fft_zrip returns 2x the true DFT
            mags = [Float](repeating: 0, count: frames * width)
            rms = [Float](repeating: 0, count: frames)

            var window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))

            var frame = [Float](repeating: 0, count: fftSize)
            var real = [Float](repeating: 0, count: half)
            var imag = [Float](repeating: 0, count: half)
            var spectrum = [Float](repeating: 0, count: half)

            for (t, centre) in centres.enumerated() {
                AudioFrames.copy(samples, start: centre - fftSize / 2, into: &frame)
                rms[t] = vDSP.rootMeanSquare(frame)
                let windowed = vDSP.multiply(frame, window)

                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBufferPointer { wp in
                            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        spectrum.withUnsafeMutableBufferPointer { mp in
                            vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                        }
                    }
                }
                // DC/Nyquist are packed into real[0]/imag[0] by zrip; bins >= 2 are unaffected.
                for k in (lowBin - 1)...(highBin + 1) {
                    mags[t * width + (k - lowBin + 1)] = spectrum[k]
                }
            }
        }

        /// Soft-mask harmonic/percussive separation; keeps the harmonic part.
        /// Written with raw pointers and an insertion-sort median: this runs ~1.5M small medians per
        /// song, and Swift array slicing/sorting made it the slowest step in Debug builds.
        mutating func removePercussion(harmonicRadius: Int, percussiveRadius: Int) {
            guard frames > 1 else { return }
            let count = mags.count, width = self.width, frames = self.frames
            var harmonic = [Float](repeating: 0, count: count)
            var percussive = [Float](repeating: 0, count: count)
            var scratch = [Float](repeating: 0, count: 2 * max(harmonicRadius, percussiveRadius) + 1)

            mags.withUnsafeBufferPointer { m in
                harmonic.withUnsafeMutableBufferPointer { h in
                    percussive.withUnsafeMutableBufferPointer { p in
                        scratch.withUnsafeMutableBufferPointer { buf in
                            // Along time, per bin.
                            for b in 0..<width {
                                for t in 0..<frames {
                                    let lo = max(0, t - harmonicRadius), hi = min(frames - 1, t + harmonicRadius)
                                    var n = 0
                                    for u in lo...hi { Self.insert(m[u * width + b], into: buf, count: &n) }
                                    h[t * width + b] = buf[n / 2]
                                }
                            }
                            // Along frequency, per frame.
                            for t in 0..<frames {
                                let row = t * width
                                for b in 0..<width {
                                    let lo = max(0, b - percussiveRadius), hi = min(width - 1, b + percussiveRadius)
                                    var n = 0
                                    for u in lo...hi { Self.insert(m[row + u], into: buf, count: &n) }
                                    p[row + b] = buf[n / 2]
                                }
                            }
                        }
                    }
                }
            }

            // mask = H^2 / (H^2 + P^2)
            mags.withUnsafeMutableBufferPointer { m in
                harmonic.withUnsafeBufferPointer { h in
                    percussive.withUnsafeBufferPointer { p in
                        for i in 0..<count {
                            let h2 = h[i] * h[i], p2 = p[i] * p[i]
                            let total = h2 + p2
                            m[i] *= total > 0 ? h2 / total : 0
                        }
                    }
                }
            }
        }

        /// Insertion into the sorted prefix buf[0..<count].
        @inline(__always)
        private static func insert(_ value: Float, into buf: UnsafeMutableBufferPointer<Float>, count: inout Int) {
            var i = count
            while i > 0, buf[i - 1] > value {
                buf[i] = buf[i - 1]
                i -= 1
            }
            buf[i] = value
            count += 1
        }

        /// Local maxima above `floor` x the frame's strongest bin, with sub-bin frequency.
        func peaks(floor: Float) -> [[Peak]] {
            (0..<frames).map { t -> [Peak] in
                let row = t * width
                var maxMag: Float = 0
                for b in 1...(width - 2) { maxMag = max(maxMag, mags[row + b]) }
                guard maxMag > 0 else { return [] }

                let threshold = maxMag * floor
                var result: [Peak] = []
                for b in 1...(width - 2) {
                    let m = mags[row + b]
                    guard m > threshold, m > mags[row + b - 1], m >= mags[row + b + 1] else { continue }

                    // Parabolic interpolation on log magnitude (much closer to a parabola around a
                    // Hann-window peak than linear magnitude) gives sub-bin accuracy.
                    let la = log(mags[row + b - 1] + 1e-12), lb = log(m), lc = log(mags[row + b + 1] + 1e-12)
                    let denom = la - 2 * lb + lc
                    var delta: Float = abs(denom) < 1e-9 ? 0 : 0.5 * (la - lc) / denom
                    delta = min(max(delta, -0.5), 0.5)

                    let k = Double(lowBin - 1 + b) + Double(delta)
                    let midi = Float(69 + 12 * log2(k * binHz / 440))
                    result.append(Peak(midi: midi, mag: m * scale))
                }
                return result
            }
        }
    }

    // MARK: Tuning

    /// Magnitude-weighted circular histogram of (midi - nearest semitone); returns its peak.
    private static func estimateTuning(_ frames: [[Peak]]) -> Float {
        let bins = 50                                  // 0.02-semitone resolution
        var hist = [Float](repeating: 0, count: bins)

        for peaks in frames {
            for p in peaks {
                let dev = p.midi - p.midi.rounded()    // -0.5...0.5
                let idx = min(bins - 1, max(0, Int((dev + 0.5) * Float(bins))))
                hist[idx] += p.mag
            }
        }

        var best = 0
        var bestValue: Float = 0
        for i in 0..<bins {
            // Smooth over neighbours; the histogram wraps around at +-0.5.
            let v = hist[(i + bins - 1) % bins] + hist[i] + hist[(i + 1) % bins]
            if v > bestValue { bestValue = v; best = i }
        }
        guard bestValue > 0 else { return 0 }
        return (Float(best) + 0.5) / Float(bins) - 0.5
    }
}

/// Shared helper: copy `frame.count` samples starting at `start` (which may be negative or run past
/// the end), zero-filling whatever falls outside the audio.
nonisolated enum AudioFrames {
    static func copy(_ samples: [Float], start: Int, into frame: inout [Float]) {
        let n = frame.count
        let from = max(start, 0), to = min(start + n, samples.count)
        frame.withUnsafeMutableBufferPointer { fp in
            fp.baseAddress!.update(repeating: 0, count: n)
            guard from < to else { return }
            samples.withUnsafeBufferPointer { sp in
                (fp.baseAddress! + (from - start)).update(from: sp.baseAddress! + from, count: to - from)
            }
        }
    }
}
