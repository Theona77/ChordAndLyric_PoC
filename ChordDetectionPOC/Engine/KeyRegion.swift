//
//  KeyRegion.swift
//  ChordDetectionPOC
//

import Foundation

/// One stretch of the song in a single key. Starts are sorted; each region lasts until the next.
nonisolated struct KeyRegion: Sendable, Hashable {
    let start: TimeInterval
    let tonic: Int
    let isMinor: Bool
}

/// Fallback key finder for when MusicUnderstanding isn't available (the command-line evaluator,
/// or a failed key analysis): correlate the song's average chroma with the Krumhansl–Kessler
/// key profiles and take the best of the 24 keys.
nonisolated enum KeyEstimator {

    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func estimate(chroma: [[Float]]) -> KeyRegion? {
        guard !chroma.isEmpty else { return nil }
        var mean = [Float](repeating: 0, count: 12)
        for frame in chroma { for p in 0..<12 { mean[p] += frame[p] } }
        guard mean.contains(where: { $0 > 0 }) else { return nil }

        var best: (score: Float, tonic: Int, isMinor: Bool) = (-.infinity, 0, false)
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let profile = isMinor ? minorProfile : majorProfile
                let rotated = (0..<12).map { profile[NoteNaming.mod12($0 - tonic)] }
                let r = correlation(mean, rotated)
                if r > best.score { best = (r, tonic, isMinor) }
            }
        }
        return KeyRegion(start: 0, tonic: best.tonic, isMinor: best.isMinor)
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<12 {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        let den = (da * db).squareRoot()
        return den > 0 ? num / den : 0
    }
}

/// Finds key changes from the detected chords themselves.
///
/// MusicUnderstanding (or the chroma estimate) often reports one key for the whole song, which
/// misses the classic "up a semitone for the last chorus". For every chord, each of the 24 keys is
/// scored by how much of the surrounding ±12 s is diatonic to it (plus a bonus for time spent on its
/// tonic chord); a small bonus for the previous choice and for the song's main mode keeps it stable.
/// Regions shorter than 16 s are dropped.
nonisolated enum LocalKeyFinder {

    static func regions(
        for segments: [DetectedSegment],
        fallback: [KeyRegion],
        window: Double = 12,
        minimumRegion: Double = 16,
        stayBonus: Double = 0.15,
        modeBonus: Double = 0.05
    ) -> [KeyRegion] {
        let chords: [(start: Double, end: Double, root: Int, suffix: String)] = segments.compactMap {
            guard let (root, suffix) = NoteNaming.splitChord($0.symbol) else { return nil }
            return ($0.start, $0.start + $0.duration, root, suffix)
        }
        guard let lastChord = chords.last else { return fallback }

        let keys: [(tonic: Int, isMinor: Bool)] = (0..<12).flatMap { [(tonic: $0, isMinor: false), (tonic: $0, isMinor: true)] }
        let mainMode = fallback.first?.isMinor
        var previous: Int? = fallback.first.flatMap { f in keys.firstIndex { $0.tonic == f.tonic && $0.isMinor == f.isMinor } }

        // 1. Best key around each chord.
        var choice: [Int] = []
        for chord in chords {
            let mid = (chord.start + chord.end) / 2
            let lo = mid - window, hi = mid + window
            var scores = [Double](repeating: 0, count: keys.count)
            var total = 0.0
            for other in chords {
                let overlap = min(hi, other.end) - max(lo, other.start)
                guard overlap > 0 else { continue }
                total += overlap
                for (k, key) in keys.enumerated() {
                    let offset = NoteNaming.mod12(other.root - key.tonic)
                    if ChordTransitions.isDiatonic(offset: offset, suffix: other.suffix, isMinor: key.isMinor) {
                        scores[k] += overlap
                    }
                    if offset == 0, ChordTransitions.canBeTonic(suffix: other.suffix, isMinor: key.isMinor) {
                        scores[k] += 0.5 * overlap
                    }
                }
            }
            if let previous { scores[previous] += stayBonus * total }
            if let mainMode {
                for (k, key) in keys.enumerated() where key.isMinor == mainMode { scores[k] += modeBonus * total }
            }
            let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0
            choice.append(best)
            previous = best
        }

        // 2. Runs of the same key -> regions; drop short ones.
        var runs: [(start: Double, key: Int)] = []
        for (chord, key) in zip(chords, choice) where runs.last?.key != key {
            runs.append((chord.start, key))
        }
        let ends = runs.dropFirst().map { $0.start } + [lastChord.end]
        var kept: [(start: Double, key: Int)] = []
        for (run, end) in zip(runs, ends) {
            if !kept.isEmpty, end - run.start < minimumRegion { continue }
            if kept.last?.key == run.key { continue }
            kept.append(run)
        }
        guard !kept.isEmpty else { return fallback }
        kept[0].start = 0
        if kept.count > 1, kept[1].start - kept[0].start < minimumRegion {
            kept.removeFirst()
            kept[0].start = 0
        }

        var result: [KeyRegion] = []
        for run in kept {
            let key = keys[run.key]
            if let last = result.last, last.tonic == key.tonic, last.isMinor == key.isMinor { continue }
            result.append(KeyRegion(start: run.start, tonic: key.tonic, isMinor: key.isMinor))
        }
        return result
    }

    /// Same keys in the same order (start times ignored).
    static func sameKeys(_ a: [KeyRegion], _ b: [KeyRegion]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.tonic == $1.tonic && $0.isMinor == $1.isMinor }
    }
}
