//
//  ConstantQ.swift
//  ChordDetectionPOC
//

import Accelerate
import Foundation

/// The log constant-Q spectrogram BTC was trained on: 22050 Hz, hop 2048, 144 bins from C1 at
/// 24 bins per octave, log(|CQT| + 1e-6).
///
/// librosa computes its CQT octave by octave with resampling; this computes the same filter bank in
/// one pass with a 32768-point FFT. The sparse frequency-domain filters are exported by
/// Tools/btc/convert_btc.py (BTCKernels.bin) from the Python reference, which was checked against
/// librosa: BTC's predictions agree on 99.1% of frames.
///
/// Like BTC's preprocessing, the audio is processed in independent 10-second chunks, each
/// zero-padded at its edges, giving 108 frames per full chunk.
nonisolated struct ConstantQ: Sendable {

    static let sampleRate = 22_050.0
    static let hopLength = 2048
    static let chunkLength = 220_500                 // 10 s
    static let binCount = 144
    /// log(1e-6): the value of a silent bin.
    static let floorValue = Float(log(1e-6))

    nonisolated struct Row: Sendable {
        let indices: [Int]
        let real: [Float]
        let imag: [Float]
    }

    let fftSize: Int
    let rows: [Row]
    /// Filter lengths in samples; the response of bin b is divided by sqrt(lengths[b]).
    let lengths: [Float]

    nonisolated struct Spectrogram: Sendable {
        /// [frame][bin], log-magnitude.
        let frames: [[Float]]
        /// Centre time of each frame, in seconds.
        let times: [Double]
    }

    nonisolated enum LoadError: LocalizedError {
        case missing
        case corrupt

        var errorDescription: String? {
            switch self {
            case .missing: return "BTCKernels.bin wasn't found. Run Tools/btc/convert_btc.py and add its output to the app."
            case .corrupt: return "BTCKernels.bin is damaged or from an incompatible version."
            }
        }
    }

    // MARK: Loading

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        var offset = 0

        func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw LoadError.corrupt }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<(offset + size)) }
            offset += size
            return T(littleEndian: value)
        }
        func readFloats(_ count: Int) throws -> [Float] {
            try (0..<count).map { _ in Float(bitPattern: try read(UInt32.self)) }
        }

        guard data.count >= 16, data.prefix(4) == Data("BTCK".utf8) else { throw LoadError.corrupt }
        offset = 4
        guard try read(Int32.self) == 1 else { throw LoadError.corrupt }
        let fftSize = Int(try read(Int32.self))
        let bins = Int(try read(Int32.self))
        guard bins == Self.binCount, fftSize > 0, fftSize & (fftSize - 1) == 0 else { throw LoadError.corrupt }

        let lengths = try readFloats(bins)
        var rows: [Row] = []
        for _ in 0..<bins {
            let count = Int(try read(Int32.self))
            guard count >= 0, count <= fftSize / 2 + 1 else { throw LoadError.corrupt }
            let indices = try (0..<count).map { _ in Int(try read(Int32.self)) }
            guard indices.allSatisfy({ $0 >= 0 && $0 <= fftSize / 2 }) else { throw LoadError.corrupt }
            rows.append(Row(indices: indices, real: try readFloats(count), imag: try readFloats(count)))
        }
        self.fftSize = fftSize
        self.rows = rows
        self.lengths = lengths
    }

    // MARK: Transform

    /// Log-CQT of mono 22050 Hz audio, chunked like BTC's preprocessing.
    func logSpectrogram(samples: [Float]) -> Spectrogram {
        let half = fftSize / 2
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Spectrogram(frames: [], times: [])
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        let inverseRootLength = lengths.map { 1 / $0.squareRoot() }

        var frames: [[Float]] = []
        var times: [Double] = []

        // BTC: full 10 s chunks while more than a chunk remains, then the remainder as the last chunk.
        var chunkStart = 0
        while true {
            let isLast = samples.count <= chunkStart + Self.chunkLength
            let chunkEnd = isLast ? samples.count : chunkStart + Self.chunkLength
            let chunk = Array(samples[chunkStart..<chunkEnd])
            let frameCount = 1 + chunk.count / Self.hopLength      // librosa, centre = true

            for t in 0..<frameCount {
                AudioFrames.copy(chunk, start: t * Self.hopLength - half, into: &frame)

                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }

                // zrip packs DC into real[0] and Nyquist into imag[0], and returns 2x the DFT.
                var column = [Float](repeating: 0, count: Self.binCount)
                for (b, row) in rows.enumerated() {
                    var sumRe: Float = 0, sumIm: Float = 0
                    for (n, k) in row.indices.enumerated() {
                        let xr: Float, xi: Float
                        if k == 0 { xr = real[0]; xi = 0 }
                        else if k == half { xr = imag[0]; xi = 0 }
                        else { xr = real[k]; xi = imag[k] }
                        sumRe += row.real[n] * xr - row.imag[n] * xi
                        sumIm += row.real[n] * xi + row.imag[n] * xr
                    }
                    let magnitude = 0.5 * (sumRe * sumRe + sumIm * sumIm).squareRoot() * inverseRootLength[b]
                    column[b] = log(magnitude + 1e-6)
                }
                frames.append(column)
                times.append(Double(chunkStart + t * Self.hopLength) / Self.sampleRate)
            }

            if isLast { break }
            chunkStart = chunkEnd
        }
        return Spectrogram(frames: frames, times: times)
    }

    /// Bass profile from a log-CQT frame: linear magnitude of the semitone bins from C1 to ~B3.
    static func bass(_ logFrame: [Float]) -> [Float] {
        var c = [Float](repeating: 0, count: 12)
        for b in stride(from: 0, to: min(60, logFrame.count), by: 2) {
            c[(b / 2) % 12] += exp(logFrame[b])
        }
        return c
    }

    /// Pitch-class profile from a log-CQT frame (bins on exact semitones only), for key estimation.
    static func chroma(_ logFrame: [Float]) -> [Float] {
        var c = [Float](repeating: 0, count: 12)
        for b in stride(from: 0, to: logFrame.count, by: 2) {
            c[(b / 2) % 12] += max(0, logFrame[b] - floorValue)
        }
        return c
    }
}
