//
//  NoteNaming.swift
//  ChordDetectionPOC
//
//  Created by Theona Arlinton on 01/10/26.
//

import Foundation

/// Everything about spelling notes and keys.
///
/// Keys are stored as (pitch class, mode) only. The letter name is derived at display time
/// from a fixed table, so "G#" and "Ab" from the framework end up as the same key with
/// one canonical spelling.
nonisolated enum NoteNaming {

    nonisolated struct ParsedTonic {
        let letter: Character      // "A"..."G"
        let accidental: Int        // -1 flat, 0 natural, +1 sharp
    }

    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    private static let naturalPitchClass: [Character: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
    ]

    static func mod12(_ x: Int) -> Int { ((x % 12) + 12) % 12 }

    // MARK: Parsing framework values

    /// Reads raw values like "c", "cSharp", "C#", "bFlat", "Bb". Returns nil if unrecognised.
    /// I couldn't confirm the exact `Tonic` raw values, so this accepts the common spellings.
    static func parseTonic(_ raw: String) -> ParsedTonic? {
        let s = raw.lowercased()
        guard let first = s.first, "abcdefg".contains(first) else { return nil }
        let rest = s.dropFirst()

        var accidental = 0
        if rest.contains("sharp") || rest.hasPrefix("#") || rest.hasPrefix("♯") {
            accidental = 1
        } else if rest.contains("flat") || rest.hasPrefix("♭") || rest.hasPrefix("b") {
            accidental = -1
        }
        return ParsedTonic(letter: Character(first.uppercased()), accidental: accidental)
    }

    static func pitchClass(of t: ParsedTonic) -> Int {
        mod12((naturalPitchClass[t.letter] ?? 0) + t.accidental)
    }

    static func isMinor(_ modeRaw: String) -> Bool {
        modeRaw.lowercased().contains("minor")
    }

    // MARK: Spelling

    /// "C#" / "Db" for pitch class 1.
    static func pitchClassName(_ pitchClass: Int, useFlats: Bool) -> String {
        (useFlats ? flatNames : sharpNames)[mod12(pitchClass)]
    }

    /// Canonical spelling for a key: the one with the fewest accidentals in its signature,
    /// with the usual tie-breaks (Db major over C# major, F# major over Gb major, G# minor over Ab minor).
    static func keySpelling(pitchClass: Int, isMinor: Bool) -> (tonic: String, usesFlats: Bool) {
        let pc = mod12(pitchClass)
        let flatKeys: Set<Int> = isMinor
            ? [2, 7, 0, 5, 10, 3]       // D G C F Bb Eb minor
            : [5, 10, 3, 8, 1]          // F Bb Eb Ab Db major
        let isFlat = flatKeys.contains(pc)
        return (pitchClassName(pc, useFlats: isFlat), isFlat)
    }

    /// Canonical display name, e.g. (8, false) -> "Ab Major", (8, true) -> "G# Minor".
    static func keyName(pitchClass: Int, isMinor: Bool) -> String {
        "\(keySpelling(pitchClass: pitchClass, isMinor: isMinor).tonic) \(isMinor ? "Minor" : "Major")"
    }

    // MARK: Chord symbols

    /// "Bbm7" -> (10, "m7"); "D/F#" -> (2, ""): the bass part of a slash chord is dropped
    /// (see `bassPitchClass`). nil for "N" and anything that isn't a chord.
    static func splitChord(_ symbol: String) -> (root: Int, suffix: String)? {
        let chord = symbol.split(separator: "/", maxSplits: 1).first.map(String.init) ?? symbol
        guard let first = chord.first, let natural = naturalPitchClass[first] else { return nil }
        var pc = natural
        var rest = chord.dropFirst()
        if rest.first == "#" { pc += 1; rest = rest.dropFirst() }
        else if rest.first == "b" { pc -= 1; rest = rest.dropFirst() }
        return (mod12(pc), String(rest))
    }

    /// "D/F#" -> 6. nil when there's no bass note.
    static func bassPitchClass(_ symbol: String) -> Int? {
        let parts = symbol.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return splitChord(String(parts[1]))?.root
    }

    /// Shifts a chord symbol (slash bass included) by `shift` semitones, spelled for the target key.
    static func transpose(_ symbol: String, by shift: Int, useFlats: Bool) -> String {
        guard let (pc, suffix) = splitChord(symbol) else { return symbol }
        var result = pitchClassName(pc + shift, useFlats: useFlats) + suffix
        if let bass = bassPitchClass(symbol) {
            result += "/" + pitchClassName(bass + shift, useFlats: useFlats)
        }
        return result
    }
}
