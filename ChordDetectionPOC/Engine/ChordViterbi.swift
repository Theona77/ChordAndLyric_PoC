//
//  ChordViterbi.swift
//  ChordDetectionPOC
//

import Accelerate
import Foundation

// MARK: - Vocabulary

/// A chord type: app suffix ("m7"), Harte name ("min7") and intervals above the root.
nonisolated struct ChordQuality: Sendable {
    let suffix: String
    let harte: String
    let intervals: [Int]
    /// Added to template-matching scores; negative = harder to pick.
    let templateBias: Float
}

nonisolated struct ChordState: Sendable {
    let symbol: String
    /// 0...11, or -1 for "no chord".
    let root: Int
    /// Quality suffix: "", "m", "7", "dim", ...
    let suffix: String
    /// Harte quality ("maj", "min7", ...), or "" for "no chord".
    let harte: String
    /// L2-normalised 12-value pitch-class template (empty for "no chord").
    let template: [Float]
    /// Added to template emission scores; negative = harder to pick.
    let logBias: Float

    var isNoChord: Bool { root < 0 }

    /// "A:min7", "C", "N" — the format used by MIREX .lab files and mir_eval.
    var harteLabel: String {
        if isNoChord { return "N" }
        let name = NoteNaming.sharpNames[root]
        return harte == "maj" ? name : "\(name):\(harte)"
    }

    static let noChord = ChordState(symbol: "N", root: -1, suffix: "", harte: "", template: [], logBias: 0)

    init(symbol: String, root: Int, suffix: String, harte: String, template: [Float], logBias: Float) {
        self.symbol = symbol
        self.root = root
        self.suffix = suffix
        self.harte = harte
        self.template = template
        self.logBias = logBias
    }

    init(root: Int, quality: ChordQuality) {
        var v = [Float](repeating: 0, count: 12)
        for interval in quality.intervals { v[(root + interval) % 12] = 1 }
        let norm = Float(quality.intervals.count).squareRoot()
        self.init(
            symbol: NoteNaming.sharpNames[root] + quality.suffix,
            root: root,
            suffix: quality.suffix,
            harte: quality.harte,
            template: v.map { $0 / norm },
            logBias: quality.templateBias
        )
    }
}

nonisolated enum ChordVocabulary {

    static var noteNames: [String] { NoteNaming.sharpNames }

    /// Every chord type the app knows, keyed by Harte name.
    static let qualities: [String: ChordQuality] = {
        let list: [ChordQuality] = [
            ChordQuality(suffix: "",      harte: "maj",     intervals: [0, 4, 7],     templateBias: 0.0),
            ChordQuality(suffix: "m",     harte: "min",     intervals: [0, 3, 7],     templateBias: 0.0),
            ChordQuality(suffix: "7",     harte: "7",       intervals: [0, 4, 7, 10], templateBias: -0.4),
            ChordQuality(suffix: "maj7",  harte: "maj7",    intervals: [0, 4, 7, 11], templateBias: -0.5),
            ChordQuality(suffix: "m7",    harte: "min7",    intervals: [0, 3, 7, 10], templateBias: -0.4),
            // Csus2 and Gsus4 share pitch classes: sus2's slightly lower bias makes the tie
            // deterministic, and the key prior (root in the scale) usually decides.
            // Sung melody notes (a 2nd or 4th over a triad) make plain chords look "sus"; at -0.7
            // sus chords were over-detected ~2.4x on the synthetic set, -1.3 brings it near 1.3x.
            ChordQuality(suffix: "sus4",  harte: "sus4",    intervals: [0, 5, 7],     templateBias: -1.3),
            ChordQuality(suffix: "sus2",  harte: "sus2",    intervals: [0, 2, 7],     templateBias: -1.35),
            ChordQuality(suffix: "dim",   harte: "dim",     intervals: [0, 3, 6],     templateBias: -0.5),
            ChordQuality(suffix: "aug",   harte: "aug",     intervals: [0, 4, 8],     templateBias: -0.8),
            ChordQuality(suffix: "6",     harte: "maj6",    intervals: [0, 4, 7, 9],  templateBias: -0.6),
            ChordQuality(suffix: "m6",    harte: "min6",    intervals: [0, 3, 7, 9],  templateBias: -0.6),
            ChordQuality(suffix: "mMaj7", harte: "minmaj7", intervals: [0, 3, 7, 11], templateBias: -0.8),
            ChordQuality(suffix: "dim7",  harte: "dim7",    intervals: [0, 3, 6, 9],  templateBias: -0.7),
            ChordQuality(suffix: "m7b5",  harte: "hdim7",   intervals: [0, 3, 6, 10], templateBias: -0.7),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.harte, $0) })
    }()

    /// Template-matching vocabulary: 12 roots x 8 qualities + "N" = 97 states.
    /// Kept small on purpose: with plain templates, 6ths and m7b5s are mostly confused with 7ths.
    static let all: [ChordState] = {
        let names = ["maj", "min", "7", "maj7", "min7", "sus4", "sus2", "dim"]
        var result: [ChordState] = []
        for root in 0..<12 {
            for name in names { result.append(ChordState(root: root, quality: qualities[name]!)) }
        }
        result.append(.noChord)
        return result
    }()

    static var noChordIndex: Int { all.count - 1 }

    /// BTC large-vocabulary output order: index = root * 14 + quality, then 168 = "X" (unknown), 169 = "N".
    static let btcQualityOrder = ["min", "maj", "dim", "aug", "min6", "maj6", "min7", "minmaj7",
                                  "maj7", "7", "dim7", "hdim7", "sus2", "sus4"]

    /// BTC states: its 168 chords, then a single "N" that also absorbs "X".
    static let btc: [ChordState] = {
        var result: [ChordState] = []
        for root in 0..<12 {
            for name in btcQualityOrder { result.append(ChordState(root: root, quality: qualities[name]!)) }
        }
        result.append(.noChord)
        return result
    }()
}

// MARK: - Transitions

nonisolated enum ChordTransitions {

    /// Flat S x S matrix of log P(to | from), row = from. No key knowledge.
    static func uniform(stateCount S: Int, stayProbability: Float) -> [Float] {
        let stay = log(stayProbability)
        let move = log((1 - stayProbability) / Float(S - 1))
        var matrix = [Float](repeating: move, count: S * S)
        for i in 0..<S { matrix[i * S + i] = stay }
        return matrix
    }

    /// Key-aware version. Staying put keeps `stayProbability`; the remaining mass is shared
    /// between target chords with two adjustments:
    ///  - chords outside the key are down-weighted by `offKeyPenalty` (log units)
    ///  - moves by a fourth or fifth get `fifthBonus` (I-IV, I-V, V-I, ii-V, ...)
    /// Every row still sums to 1.
    static func keyed(
        states: [ChordState],
        tonic: Int,
        isMinor: Bool,
        stayProbability: Float,
        offKeyPenalty: Float = 1.5,
        fifthBonus: Float = 0.5
    ) -> [Float] {
        let S = states.count
        let targetPrior = states.map { state -> Float in
            guard !state.isNoChord else { return 0 }
            let offset = ((state.root - tonic) % 12 + 12) % 12
            return isDiatonic(offset: offset, suffix: state.suffix, isMinor: isMinor) ? 0 : -offKeyPenalty
        }

        var matrix = [Float](repeating: 0, count: S * S)
        for i in 0..<S {
            var weights = [Float](repeating: 0, count: S)
            var total: Float = 0
            for j in 0..<S where j != i {
                var w = targetPrior[j]
                if !states[i].isNoChord, !states[j].isNoChord {
                    let interval = ((states[j].root - states[i].root) % 12 + 12) % 12
                    if interval == 5 || interval == 7 { w += fifthBonus }
                }
                weights[j] = exp(w)
                total += weights[j]
            }
            for j in 0..<S {
                matrix[i * S + j] = (j == i)
                    ? log(stayProbability)
                    : log((1 - stayProbability) * weights[j] / total)
            }
        }
        return matrix
    }

    // MARK: Diatonic membership

    nonisolated private enum Family { case major, minor, dim, any }

    private static func family(of suffix: String) -> Family {
        switch suffix {
        case "", "maj7", "7", "6":      return .major     // "7" is a dominant, still a major-family triad
        case "m", "m7", "m6", "mMaj7":  return .minor
        case "dim", "dim7", "m7b5":     return .dim
        default:                        return .any       // sus, aug: judged by root only
        }
    }

    // offset above tonic -> triad family
    private static let majorScale: [Int: Family] = [0: .major, 2: .minor, 4: .minor, 5: .major, 7: .major, 9: .minor, 11: .dim]
    private static let minorScale: [Int: Family] = [0: .minor, 2: .dim, 3: .major, 5: .minor, 7: .minor, 8: .major, 10: .major]

    /// True when a chord with this suffix can be the key's tonic chord (C or Csus4 in C major, Am in A minor).
    static func canBeTonic(suffix: String, isMinor: Bool) -> Bool {
        let f = family(of: suffix)
        return f == .any || f == (isMinor ? .minor : .major)
    }

    static func isDiatonic(offset: Int, suffix: String, isMinor: Bool) -> Bool {
        guard let expected = (isMinor ? minorScale : majorScale)[offset] else { return false }
        let actual = family(of: suffix)
        if actual == .any || actual == expected { return true }
        // Harmonic minor: major V is very common in minor keys.
        if isMinor, offset == 7, actual == .major { return true }
        return false
    }
}

// MARK: - Viterbi

nonisolated enum ViterbiDecoder {

    /// - Parameters:
    ///   - logEmissions: [time][state] log-scores.
    ///   - logTransitions: one or more flat S x S matrices of log P(to | from), row = from.
    ///   - transitionIndex: which matrix to use for the step *into* time t (t >= 1).
    ///     nil = always the first matrix. Lets the prior follow key changes.
    /// - Returns: the best state index for each time step.
    static func decode(logEmissions: [[Float]], logTransitions: [[Float]], transitionIndex: [Int]? = nil) -> [Int] {
        let T = logEmissions.count
        guard T > 0, !logTransitions.isEmpty else { return [] }
        let S = logEmissions[0].count

        // Column-major copies (row = "to"), so each target state's incoming scores are contiguous
        // and the inner loop is one vDSP add + max.
        let incoming: [[Float]] = logTransitions.map { m in
            var tr = [Float](repeating: 0, count: S * S)
            vDSP_mtrans(m, 1, &tr, 1, vDSP_Length(S), vDSP_Length(S))
            return tr
        }

        var delta = logEmissions[0]
        var next = [Float](repeating: 0, count: S)
        var scratch = [Float](repeating: 0, count: S)
        var backPointers = [Int32](repeating: 0, count: T * S)

        for t in 1..<T {
            let matrix = incoming[transitionIndex?[t] ?? 0]
            matrix.withUnsafeBufferPointer { mp in
                for j in 0..<S {
                    var best: Float = 0
                    var bestPrev: vDSP_Length = 0
                    vDSP_vadd(delta, 1, mp.baseAddress! + j * S, 1, &scratch, 1, vDSP_Length(S))
                    vDSP_maxvi(scratch, 1, &best, &bestPrev, vDSP_Length(S))
                    next[j] = best + logEmissions[t][j]
                    backPointers[t * S + j] = Int32(bestPrev)
                }
            }
            // Keep numbers small; only differences matter.
            let peak = vDSP.maximum(next)
            delta = vDSP.add(-peak, next)
        }

        var path = [Int](repeating: 0, count: T)
        path[T - 1] = delta.indices.max(by: { delta[$0] < delta[$1] }) ?? 0
        for t in stride(from: T - 1, to: 0, by: -1) {
            path[t - 1] = Int(backPointers[t * S + path[t]])
        }
        return path
    }
}
