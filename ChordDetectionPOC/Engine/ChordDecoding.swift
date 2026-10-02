//
//  ChordDecoding.swift
//  ChordDetectionPOC
//
//  The back end every chord engine shares:
//    1. cut the song into segments (one per beat, or fixed-length if there's no clear beat)
//    2. give each segment a score per chord state (the engines differ only here)
//    3. smooth with a key-aware HMM (Viterbi) and merge repeats into chord events
//

import Foundation

// MARK: - Configuration

nonisolated struct ChordDetectorConfig: Sendable {
    var analysisSampleRate = 22_050.0

    /// Segment length when beat tracking fails (no clear pulse).
    var fallbackSegmentDuration = 0.5

    /// Each beat is split into this many segments. 2 makes the result robust to the beat tracker
    /// picking double/half tempo or locking onto off-beats (+2-3 points on the synthetic set).
    var segmentsPerBeat = 2

    /// Probability of staying on the same chord from one segment to the next.
    /// Higher = fewer, longer chords.
    var stayProbability: Float = 0.85

    /// Log-penalty on moving to a chord outside the current key.
    var offKeyPenalty: Float = 1.5

    // Template engines (built-in chroma, Basic Pitch)

    var chroma = ChromaExtractor.Options()

    /// How strongly template similarity counts vs. the transition prior.
    var emissionSharpness: Float = 10

    /// Bonus for chords whose root is the loudest bass note (0 = ignore the bass).
    var bassWeight: Float = 3

    /// Fraction of `bassWeight` given when the bass plays another chord tone instead of the root,
    /// so slash chords (D/F#) aren't pushed toward the bass note's own chord (+3.5 points majmin on
    /// the synthetic set, which includes D/F# and G/B).
    var bassChordToneWeight: Float = 0.5

    // Slash chords

    /// Add the bass note to chords when it's a chord tone other than the root ("D/F#").
    var detectSlashChords = true

    /// Minimum share of the bass energy the bass note needs within a chord to count.
    /// The template engines' bass profile is peakier than BTC's CQT one, hence two values.
    var slashMinShareTemplates: Float = 0.5
    var slashMinShareBTC: Float = 0.35

    /// A segment quieter than this fraction of the song's median loudness counts as silence.
    var silenceRatio: Float = 0.1

    /// Template similarity assigned to "N" for non-silent segments.
    var noChordScore: Float = 0.4

    // BTC

    /// Multiplies BTC's average per-frame log-probability within a segment.
    /// Roughly "how many independent frames is a beat worth"; higher trusts the model over the prior.
    var btcEmissionWeight: Float = 4

    /// BTC already models musical context, so the key prior is gentler.
    var btcOffKeyPenalty: Float = 0.5
}

nonisolated struct DetectedSegment: Sendable {
    /// App spelling with sharps: "C#m7".
    let symbol: String
    /// Harte label for .lab files: "C#:min7".
    let harte: String
    let start: Double
    let duration: Double
}

// MARK: - Segmenting

nonisolated enum ChordSegmenter {

    /// Beat-synchronous boundaries when a beat can be found, otherwise fixed-length segments.
    static func boundaries(samples: [Float], duration: Double, config: ChordDetectorConfig) -> (bounds: [Double], beats: [Double]?) {
        let beats = BeatTracker.track(samples: samples, sampleRate: config.analysisSampleRate)?.beats
        if let beats {
            let bounds = beatBoundaries(beats: beats, duration: duration, fallbackStep: config.fallbackSegmentDuration)
            return (subdivide(bounds, into: config.segmentsPerBeat), beats)
        }
        return (uniformBoundaries(duration: duration, step: config.fallbackSegmentDuration), nil)
    }

    /// [0, step, 2*step, ... , duration]
    static func uniformBoundaries(duration: Double, step: Double) -> [Double] {
        var bounds: [Double] = []
        var t = 0.0
        while t < duration {
            bounds.append(t)
            t += step
        }
        bounds.append(duration)
        return bounds
    }

    /// [0, beat1, beat2, ..., duration]. Gaps before the first and after the last beat are split
    /// into beat-sized pieces so intros/outros aren't one huge segment.
    static func beatBoundaries(beats: [Double], duration: Double, fallbackStep: Double) -> [Double] {
        let inside = beats.filter { $0 > 0 && $0 < duration }
        guard inside.count >= 2 else { return uniformBoundaries(duration: duration, step: fallbackStep) }

        let gaps = zip(inside.dropFirst(), inside).map { $0 - $1 }.sorted()
        let period = max(0.2, gaps[gaps.count / 2])

        var bounds: [Double] = [0]
        var t = inside[0] - period
        var lead: [Double] = []
        while t > period * 0.5 { lead.append(t); t -= period }
        bounds += lead.reversed()
        bounds += inside
        t = inside[inside.count - 1] + period
        while t < duration - period * 0.5 { bounds.append(t); t += period }
        bounds.append(duration)

        // Strictly increasing, no slivers.
        var cleaned: [Double] = [bounds[0]]
        for b in bounds.dropFirst() where b - cleaned[cleaned.count - 1] > 0.05 { cleaned.append(b) }
        if cleaned[cleaned.count - 1] < duration { cleaned[cleaned.count - 1] = duration }
        return cleaned
    }

    /// Splits every segment into `parts` equal pieces.
    static func subdivide(_ bounds: [Double], into parts: Int) -> [Double] {
        guard parts > 1, bounds.count >= 2 else { return bounds }
        var result: [Double] = []
        for (a, b) in zip(bounds, bounds.dropFirst()) {
            for i in 0..<parts { result.append(a + (b - a) * Double(i) / Double(parts)) }
        }
        result.append(bounds[bounds.count - 1])
        return result
    }

    /// Average the rows (one per frame, at `times`) that fall inside each [boundary[i], boundary[i+1]).
    /// A segment with no frame in it reuses the previous segment's value.
    static func aggregate(_ rows: [[Float]], times: [Double], boundaries: [Double]) -> [[Float]] {
        guard boundaries.count >= 2, let width = rows.first?.count else { return [] }

        var result: [[Float]] = []
        var index = 0
        for i in 0..<(boundaries.count - 1) {
            let start = boundaries[i], end = boundaries[i + 1]
            var sum = [Float](repeating: 0, count: width)
            var count = 0
            while index < times.count, times[index] < end {
                if times[index] >= start {
                    for p in 0..<width { sum[p] += rows[index][p] }
                    count += 1
                }
                index += 1
            }
            if count > 0 {
                result.append(sum.map { $0 / Float(count) })
            } else {
                result.append(result.last ?? sum)
            }
        }
        return result
    }
}

// MARK: - Template scores

nonisolated enum TemplateEmissions {

    /// Score every state for every segment from pitch-class profiles.
    /// - Parameters:
    ///   - treble: per-segment 12-value chroma.
    ///   - bass: per-segment 12-value bass chroma (same count), or empty to ignore the bass.
    ///   - loudness: per-segment loudness, for silence detection.
    static func scores(
        treble: [[Float]],
        bass: [[Float]],
        loudness: [Float],
        states: [ChordState],
        config: ChordDetectorConfig
    ) -> [[Float]] {
        guard !treble.isEmpty else { return [] }
        let median = loudness.sorted()[loudness.count / 2]
        let silenceThreshold = config.silenceRatio * median
        let beta = config.emissionSharpness
        let useBass = bass.count == treble.count && config.bassWeight > 0

        return treble.enumerated().map { index, chroma in
            // Contrast: subtract the mean, clip at zero, then L2-normalise.
            // Pulls the few strong pitch classes away from the noise floor.
            let mean = chroma.reduce(0, +) / 12
            let contrasted = chroma.map { max($0 - mean, 0) }
            let norm = contrasted.reduce(0) { $0 + $1 * $1 }.squareRoot()

            var row = [Float](repeating: 0, count: states.count)

            // Silence or a perfectly flat spectrum -> "no chord".
            if loudness[index] < silenceThreshold || norm < 1e-6 {
                for (j, state) in states.enumerated() { row[j] = state.isNoChord ? 0 : -beta }
                return row
            }

            // Bass: each pitch class's share of the bass energy, minus the 1/12 a flat profile gets.
            var bassShare = [Float](repeating: 0, count: 12)
            if useBass {
                let total = bass[index].reduce(0, +)
                if total > 1e-6 { bassShare = bass[index].map { $0 / total - 1 / 12 } }
            }

            let unit = contrasted.map { $0 / norm }
            for (j, state) in states.enumerated() {
                if state.isNoChord {
                    row[j] = beta * config.noChordScore
                } else {
                    var dot: Float = 0
                    var otherTone: Float = -1 / 12
                    for p in 0..<12 where state.template[p] > 0 {
                        dot += unit[p] * state.template[p]
                        if p != state.root { otherTone = max(otherTone, bassShare[p]) }
                    }
                    let bass = bassShare[state.root] + config.bassChordToneWeight * otherTone
                    row[j] = beta * dot + state.logBias + config.bassWeight * bass
                }
            }
            return row
        }
    }
}

// MARK: - Slash chords

nonisolated enum SlashChords {

    /// Semitones above the root -> Harte bass degree.
    private static let degrees: [Int: String] = [2: "2", 3: "b3", 4: "3", 5: "4", 6: "b5", 7: "5",
                                                 8: "#5", 9: "6", 10: "b7", 11: "7"]
    private static let qualityBySuffix: [String: ChordQuality] = Dictionary(
        uniqueKeysWithValues: ChordVocabulary.qualities.values.map { ($0.suffix, $0) }
    )

    /// Adds the bass note to each chord when it clearly plays a chord tone other than the root.
    /// - Parameters:
    ///   - bass: per-frame 12-value bass profile (linear energy), at `times`.
    ///   - minShare: the bass note's minimum share of the bass energy over the chord.
    ///
    /// One reinterpretation: a minor 7th over its own 5th is almost always the relative major over
    /// its 3rd (Bm7 with F# in the bass -> D/F#, Cm7 with G -> Eb/G). Chord models without slash
    /// chords in their vocabulary pick the m7 because it contains every note that's sounding.
    static func apply(to segments: [DetectedSegment], bass: [[Float]], times: [Double], minShare: Float) -> [DetectedSegment] {
        guard !bass.isEmpty, bass.count == times.count else { return segments }
        var index = 0
        return segments.map { segment in
            let end = segment.start + segment.duration
            var profile = [Float](repeating: 0, count: 12)
            while index < times.count, times[index] < segment.start { index += 1 }
            var i = index
            while i < times.count, times[i] < end {
                for p in 0..<12 { profile[p] += bass[i][p] }
                i += 1
            }
            let total = profile.reduce(0, +)
            guard total > 1e-9,
                  let (root, suffix) = NoteNaming.splitChord(segment.symbol),
                  let quality = qualityBySuffix[suffix],
                  let note = profile.indices.max(by: { profile[$0] < profile[$1] }),
                  profile[note] / total >= minShare
            else { return segment }

            let interval = NoteNaming.mod12(note - root)
            if suffix == "m7", interval == 7 {
                return make(root: NoteNaming.mod12(root + 3), quality: qualityBySuffix[""]!, bassInterval: 4, like: segment)
            }
            if interval != 0, quality.intervals.contains(interval) {
                return make(root: root, quality: quality, bassInterval: interval, like: segment)
            }
            return segment
        }
    }

    private static func make(root: Int, quality: ChordQuality, bassInterval: Int, like segment: DetectedSegment) -> DetectedSegment {
        let state = ChordState(root: root, quality: quality)
        let bassName = NoteNaming.sharpNames[NoteNaming.mod12(root + bassInterval)]
        return DetectedSegment(
            symbol: state.symbol + "/" + bassName,
            harte: state.harteLabel + "/" + (degrees[bassInterval] ?? "1"),
            start: segment.start,
            duration: segment.duration
        )
    }
}

// MARK: - Decoding

nonisolated enum ChordDecoder {

    /// Viterbi over segment scores, then merge runs into chord events ("N" dropped).
    static func decode(
        scores: [[Float]],
        boundaries: [Double],
        states: [ChordState],
        keys: [KeyRegion],
        stayProbability: Float,
        offKeyPenalty: Float
    ) -> [DetectedSegment] {
        guard !scores.isEmpty else { return [] }
        let (matrices, index) = transitions(keys: keys, boundaries: boundaries, states: states,
                                            stayProbability: stayProbability, offKeyPenalty: offKeyPenalty)
        let path = ViterbiDecoder.decode(logEmissions: scores, logTransitions: matrices, transitionIndex: index)
        return merge(path: path, boundaries: boundaries, states: states)
    }

    /// Decode, find key changes in the result, and decode again with them if they differ from
    /// `keys` (so chords after a modulation aren't penalised as off-key). Returns the keys used.
    static func decodeRefiningKeys(
        scores: [[Float]],
        boundaries: [Double],
        states: [ChordState],
        keys: [KeyRegion],
        stayProbability: Float,
        offKeyPenalty: Float
    ) -> (segments: [DetectedSegment], keys: [KeyRegion]) {
        let first = decode(scores: scores, boundaries: boundaries, states: states, keys: keys,
                           stayProbability: stayProbability, offKeyPenalty: offKeyPenalty)
        let local = LocalKeyFinder.regions(for: first, fallback: keys)
        guard !local.isEmpty else { return (first, keys) }
        guard !keys.isEmpty, offKeyPenalty > 0, !LocalKeyFinder.sameKeys(local, keys) else { return (first, local) }
        let second = decode(scores: scores, boundaries: boundaries, states: states, keys: local,
                            stayProbability: stayProbability, offKeyPenalty: offKeyPenalty)
        return (second, local)
    }

    /// One transition matrix per distinct key, and which one applies at each segment.
    /// The key at a segment is the key region containing its start time.
    static func transitions(
        keys: [KeyRegion],
        boundaries: [Double],
        states: [ChordState],
        stayProbability: Float,
        offKeyPenalty: Float
    ) -> (matrices: [[Float]], index: [Int]?) {
        guard !keys.isEmpty, offKeyPenalty > 0 else {
            return ([ChordTransitions.uniform(stateCount: states.count, stayProbability: stayProbability)], nil)
        }

        let sorted = keys.sorted { $0.start < $1.start }
        var matrices: [[Float]] = []
        var matrixFor: [KeyRegion: Int] = [:]
        var index: [Int] = []
        var region = 0

        for t in 0..<(boundaries.count - 1) {
            while region + 1 < sorted.count, sorted[region + 1].start <= boundaries[t] { region += 1 }
            // Ignore `start` so the same key shares one matrix.
            let id = KeyRegion(start: 0, tonic: sorted[region].tonic, isMinor: sorted[region].isMinor)
            if matrixFor[id] == nil {
                matrixFor[id] = matrices.count
                matrices.append(ChordTransitions.keyed(
                    states: states,
                    tonic: id.tonic,
                    isMinor: id.isMinor,
                    stayProbability: stayProbability,
                    offKeyPenalty: offKeyPenalty
                ))
            }
            index.append(matrixFor[id]!)
        }
        return (matrices, index)
    }

    /// Collapse runs of the same state into one event, dropping "no chord".
    static func merge(path: [Int], boundaries: [Double], states: [ChordState]) -> [DetectedSegment] {
        guard !path.isEmpty else { return [] }
        var result: [DetectedSegment] = []
        var runStart = 0

        for t in 1...path.count {
            let atEnd = (t == path.count)
            if atEnd || path[t] != path[runStart] {
                let state = states[path[runStart]]
                if !state.isNoChord {
                    let start = boundaries[runStart]
                    let end = boundaries[t]
                    result.append(DetectedSegment(symbol: state.symbol, harte: state.harteLabel,
                                                  start: start, duration: end - start))
                }
                runStart = t
            }
        }
        return result
    }
}
