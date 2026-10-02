import Foundation

// MARK: - Load state

enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

// MARK: - Key
struct KeySegment: Identifiable, Hashable {
    let id = UUID()
    let tonicPitchClass: Int
    let isMinor: Bool
    let start: TimeInterval
    let duration: TimeInterval

    var name: String { NoteNaming.keyName(pitchClass: tonicPitchClass, isMinor: isMinor) }
}

struct KeySummary {
    /// Stored as pitch class + mode only; spelling comes from `NoteNaming.keySpelling`.
    let tonicPitchClass: Int
    let isMinor: Bool
    let segments: [KeySegment]

    var dominantName: String { NoteNaming.keyName(pitchClass: tonicPitchClass, isMinor: isMinor) }

    var usesFlats: Bool {
        NoteNaming.keySpelling(pitchClass: tonicPitchClass, isMinor: isMinor).usesFlats
    }

    /// "G# Major" when the key is shown as "Ab Major". Nil if there's no flat/sharp alternative.
    var enharmonicName: String? {
        let main = NoteNaming.keySpelling(pitchClass: tonicPitchClass, isMinor: isMinor).tonic
        let alt = NoteNaming.pitchClassName(tonicPitchClass, useFlats: !usesFlats)
        return alt == main ? nil : "\(alt) \(isMinor ? "Minor" : "Major")"
    }

    /// Plain, Sendable copy of the key timeline for the chord detector (which runs off the main actor).
    var regions: [KeyRegion] {
        let fallback = [KeyRegion(start: 0, tonic: tonicPitchClass, isMinor: isMinor)]
        let fromSegments = segments.map { KeyRegion(start: $0.start, tonic: $0.tonicPitchClass, isMinor: $0.isMinor) }
        return fromSegments.isEmpty ? fallback : fromSegments
    }
}

// MARK: - Lyrics

struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Word timings, used to place chords over the right word. Never empty for a non-empty line.
    let words: [LyricWord]
}

// MARK: - Chords

struct ChordEvent: Identifiable, Hashable {
    /// Kept when a chord is transposed/respelled, so views don't see a "new" chord every redraw.
    let id: UUID
    let symbol: String          // e.g. "Am7"
    let start: TimeInterval
    let duration: TimeInterval

    var end: TimeInterval { start + duration }

    init(id: UUID = UUID(), symbol: String, start: TimeInterval, duration: TimeInterval) {
        self.id = id
        self.symbol = symbol
        self.start = start
        self.duration = duration
    }
}

// MARK: - Errors

enum AnalysisError: LocalizedError {
    case noKeyFound
    case unsupportedLocale

    var errorDescription: String? {
        switch self {
        case .noKeyFound:
            return "No key could be detected for this audio."
        case .unsupportedLocale:
            return "On-device transcription isn't available for this language."
        }
    }
}

// MARK: - Helpers

extension TimeInterval {
    /// 83.4 -> "1:23"
    var clock: String {
        let total = Int(self.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
