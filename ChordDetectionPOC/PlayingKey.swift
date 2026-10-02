//
//  PlayingKey.swift
//  ChordDetectionPOC
//
//  Two independent controls:
//    transpose: changes what you HEAR (semitones vs. the recording, -6...+5)
//    capo:      changes what you PLAY (shapes), not what you hear
//
//    sounding key = recorded tonic + transpose
//    shape key    = recorded tonic + transpose - capo
//

import Foundation

struct PlayingSetup: Equatable, Codable {
    static let transposeRange = -6...5
    static let capoRange = 0...7

    var transpose = 0
    var capo = 0

    /// Semitones applied to the detected chord symbols to get the shapes you play.
    var shapeShift: Int { NoteNaming.mod12(transpose - capo) }
}

struct KeyChange: Identifiable, Equatable {
    let time: TimeInterval
    let name: String
    var id: TimeInterval { time }
}

struct CapoSuggestion: Equatable {
    let capo: Int
    /// 0...1 share of playing time on easy (open) shapes, with the suggested capo and with none.
    let ease: Double
    let baselineEase: Double
    /// The most-played shapes with this capo, e.g. ["G", "C", "D", "Em"].
    let mainShapes: [String]

    var reason: String {
        let shapes = mainShapes.isEmpty ? "" : " (\(mainShapes.joined(separator: ", ")))"
        return "Mostly open shapes\(shapes): about \(percent(ease)) easy with capo \(capo), "
            + "vs \(percent(baselineEase)) with no capo."
    }

    private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}

enum PlayingKeyPlanner {

    // MARK: Names

    static func soundingName(key: KeySummary, setup: PlayingSetup) -> String {
        NoteNaming.keyName(pitchClass: key.tonicPitchClass + setup.transpose, isMinor: key.isMinor)
    }

    static func shapeName(key: KeySummary, setup: PlayingSetup) -> String {
        NoteNaming.keyName(pitchClass: key.tonicPitchClass + setup.shapeShift, isMinor: key.isMinor)
    }

    static func explanation(key: KeySummary, setup: PlayingSetup) -> String {
        if setup.transpose == 0 && setup.capo == 0 {
            return "Chords as recorded in \(key.dominantName). No capo."
        }
        var parts: [String] = []
        if setup.transpose != 0 {
            let n = abs(setup.transpose)
            parts.append("Transposed \(setup.transpose > 0 ? "up" : "down") \(n) semitone\(n == 1 ? "" : "s"), "
                         + "so it sounds in \(soundingName(key: key, setup: setup)).")
        } else {
            parts.append("Still sounds like the recording (\(soundingName(key: key, setup: setup))).")
        }
        let shapes = shapeName(key: key, setup: setup)
        parts.append(setup.capo > 0 ? "Capo \(setup.capo): play \(shapes) shapes." : "No capo: play \(shapes).")
        return parts.joined(separator: " ")
    }

    // MARK: Chords

    /// Detected chords (recorded key, sharp-spelled) -> the shapes you play, spelled for the shape key.
    /// - localKeys: keys found from the chords (key changes included). Each chord is spelled for the
    ///   key it's in, so after a G -> Ab modulation you get Eb/Ab/Db, not D#/G#/C#.
    ///   Empty = spell everything for `key`.
    static func shapeChords(_ chords: [ChordEvent], key: KeySummary, localKeys: [KeyRegion] = [],
                            setup: PlayingSetup) -> [ChordEvent] {
        func usesFlats(at time: TimeInterval) -> Bool {
            let local = localKeys.last { $0.start <= time + 0.01 } ?? localKeys.first
            return NoteNaming.keySpelling(
                pitchClass: (local?.tonic ?? key.tonicPitchClass) + setup.shapeShift,
                isMinor: local?.isMinor ?? key.isMinor
            ).usesFlats
        }

        return chords.map {
            ChordEvent(
                id: $0.id,
                symbol: NoteNaming.transpose($0.symbol, by: setup.shapeShift, useFlats: usesFlats(at: $0.start)),
                start: $0.start,
                duration: $0.duration
            )
        }
    }

    /// What the chord list shows: "As recorded (sounding pitch)" or "Shapes for capo 1 · sounds in Ab Major".
    /// Chord sheets online usually list capo shapes, so this matters when comparing.
    static func chordListCaption(key: KeySummary, setup: PlayingSetup) -> String {
        if setup.transpose == 0 && setup.capo == 0 { return "As recorded (sounding pitch)" }
        let sounding = soundingName(key: key, setup: setup)
        return setup.capo > 0
            ? "Shapes for capo \(setup.capo) · sounds in \(sounding)"
            : "Transposed · sounds in \(sounding)"
    }

    /// Key changes found in the chords, as shown to the player: "1:45 → Ab Major" (sounding key).
    /// Empty when the song stays in one key.
    static func keyChanges(_ localKeys: [KeyRegion], setup: PlayingSetup) -> [KeyChange] {
        guard localKeys.count > 1 else { return [] }
        return localKeys.dropFirst().map {
            KeyChange(time: $0.start, name: NoteNaming.keyName(pitchClass: $0.tonic + setup.transpose, isMinor: $0.isMinor))
        }
    }

    // MARK: Capo suggestion

    /// How hard each shape is to play: 0 = easy open chord, 1 = full barre.
    /// Anything not listed (sharps/flats, most minor chords on C/F/G/B...) counts as a barre.
    private static let shapeDifficulty: [String: [String: Double]] = [
        "C": ["": 0, "7": 0.1, "maj7": 0, "sus2": 0.3, "sus4": 0.3],
        "D": ["": 0, "m": 0, "7": 0, "m7": 0, "maj7": 0, "sus2": 0, "sus4": 0, "dim": 0.4],
        "E": ["": 0, "m": 0, "7": 0, "m7": 0, "maj7": 0.1, "sus2": 0.3, "sus4": 0, "dim": 0.5],
        "F": ["": 0.7, "maj7": 0.2],
        "G": ["": 0, "7": 0, "maj7": 0.2, "sus2": 0.3, "sus4": 0.2],
        "A": ["": 0, "m": 0, "7": 0, "m7": 0, "maj7": 0, "sus2": 0, "sus4": 0, "dim": 0.4],
        "B": ["7": 0.1, "m": 0.8, "m7": 0.6],
    ]
    /// Diminished chords are a movable 4-fret shape: awkward but not a barre.
    private static let defaultDimDifficulty = 0.6

    static func ease(pitchClass: Int, suffix: String) -> Double {
        let root = NoteNaming.sharpNames[NoteNaming.mod12(pitchClass)]
        if let d = shapeDifficulty[root]?[suffix] { return 1 - d }
        return suffix == "dim" ? 1 - defaultDimDifficulty : 0
    }

    /// Small cost per fret, growing faster above fret 5 where the guitar starts to sound thin.
    private static func capoCost(_ capo: Int) -> Double {
        0.015 * Double(capo) + 0.04 * Double(max(0, capo - 5))
    }

    /// Best capo for the chosen transpose. Returns nil unless a capo is clearly easier than none.
    static func suggestCapo(key: KeySummary, chords: [ChordEvent], transpose: Int) -> CapoSuggestion? {
        let usage = chordUsage(chords)
        let baseline = ease(key: key, usage: usage, shapeShift: NoteNaming.mod12(transpose))

        var best = (capo: 0, ease: baseline, score: baseline)
        for capo in PlayingSetup.capoRange where capo > 0 {
            let e = ease(key: key, usage: usage, shapeShift: NoteNaming.mod12(transpose - capo))
            let score = e - capoCost(capo)
            if score > best.score + 1e-9 { best = (capo, e, score) }
        }

        guard best.capo > 0, best.ease - baseline >= 0.15 else { return nil }

        let shift = NoteNaming.mod12(transpose - best.capo)
        let useFlats = NoteNaming.keySpelling(pitchClass: key.tonicPitchClass + shift, isMinor: key.isMinor).usesFlats
        let shapes = (usage.isEmpty ? keyChords(key) : usage)
            .sorted { $0.weight > $1.weight }
            .prefix(4)
            .map { NoteNaming.pitchClassName($0.root + shift, useFlats: useFlats) + $0.suffix }

        return CapoSuggestion(capo: best.capo, ease: best.ease, baselineEase: baseline, mainShapes: Array(shapes))
    }

    /// Detected chords give the real picture; the key's main chords keep it sane when detection
    /// is noisy (or empty). The weight on the detected chords grows with how much music was detected.
    private static func ease(key: KeySummary, usage: [(root: Int, suffix: String, weight: Double)], shapeShift: Int) -> Double {
        let fromKey = weightedEase(keyChords(key), shapeShift: shapeShift)
        guard !usage.isEmpty else { return fromKey }
        let fromChords = weightedEase(usage, shapeShift: shapeShift)
        let distinct = Double(Set(usage.map { "\($0.root)\($0.suffix)" }).count)
        let trust = min(0.8, 0.4 + 0.1 * distinct)
        return trust * fromChords + (1 - trust) * fromKey
    }

    private static func weightedEase(_ items: [(root: Int, suffix: String, weight: Double)], shapeShift: Int) -> Double {
        var total = 0.0, easy = 0.0
        for item in items {
            total += item.weight
            easy += item.weight * ease(pitchClass: item.root + shapeShift, suffix: item.suffix)
        }
        return total > 0 ? easy / total : 0
    }

    /// Total time per distinct chord.
    private static func chordUsage(_ chords: [ChordEvent]) -> [(root: Int, suffix: String, weight: Double)] {
        var order: [String] = []
        var table: [String: (root: Int, suffix: String, weight: Double)] = [:]
        for chord in chords {
            guard let (root, suffix) = NoteNaming.splitChord(chord.symbol), chord.duration > 0 else { continue }
            let id = "\(root)|\(suffix)"
            if table[id] == nil { order.append(id); table[id] = (root, suffix, 0) }
            table[id]!.weight += chord.duration
        }
        return order.compactMap { table[$0] }
    }

    /// The key's common chords, weighted by how often they turn up in pop/rock.
    private static func keyChords(_ key: KeySummary) -> [(root: Int, suffix: String, weight: Double)] {
        let degrees: [(Int, String, Double)] = key.isMinor
            ? [(0, "m", 1.0), (3, "", 0.8), (5, "m", 0.8), (7, "m", 0.4), (7, "", 0.6), (8, "", 0.9), (10, "", 0.9)]
            : [(0, "", 1.0), (5, "", 1.0), (7, "", 1.0), (9, "m", 0.8), (2, "m", 0.5), (4, "m", 0.3)]
        return degrees.map { (root: NoteNaming.mod12(key.tonicPitchClass + $0.0), suffix: $0.1, weight: $0.2) }
    }
}
