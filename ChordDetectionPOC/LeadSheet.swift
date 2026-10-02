//
//  LeadSheet.swift
//  ChordDetectionPOC
//
//  Lays chords out like a chord sheet: each chord above the lyric word it falls on, and
//  instrumental parts (intro, interludes, or songs without recognised lyrics) as rows of chords.
//

import Foundation

struct SheetToken: Identifiable, Hashable {
    let id: Int
    /// Chords that start on this word (usually zero or one).
    let chords: [ChordEvent]
    /// The lyric word, or nil for a chord-only token.
    let word: String?
    let start: TimeInterval
}

struct SheetLine: Identifiable, Hashable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let tokens: [SheetToken]
    var isInstrumental: Bool { tokens.allSatisfy { $0.word == nil } }
}

enum LeadSheet {

    /// A chord starting up to this long before a lyric line belongs to it: the band usually changes
    /// chord on the downbeat just before the singer comes in.
    static let leadIn: TimeInterval = 1.0
    /// Instrumental rows hold at most this many chords.
    static let chordsPerRow = 4

    static func build(chords: [ChordEvent], lyrics: [LyricLine]) -> [SheetLine] {
        let chords = chords.sorted { $0.start < $1.start }
        let lyrics = lyrics.filter { !$0.words.isEmpty }.sorted { $0.start < $1.start }

        var lines: [SheetLine] = []
        var nextID = 0
        func makeID() -> Int { defer { nextID += 1 }; return nextID }

        var pending: [ChordEvent] = []           // instrumental chords waiting for a row
        func flushInstrumental() {
            var i = 0
            while i < pending.count {
                let row = Array(pending[i..<min(i + chordsPerRow, pending.count)])
                let tokens = row.map { SheetToken(id: makeID(), chords: [$0], word: nil, start: $0.start) }
                lines.append(SheetLine(id: makeID(), start: row[0].start, end: row[row.count - 1].end, tokens: tokens))
                i += chordsPerRow
            }
            pending.removeAll()
        }

        var c = 0
        for (index, line) in lyrics.enumerated() {
            let lineStart = line.start - leadIn
            let nextStart = index + 1 < lyrics.count ? lyrics[index + 1].start - leadIn : .infinity
            // A line owns chords until its last word ends (plus a little), but never past the next line.
            let lineEnd = min(max(line.end, line.words[line.words.count - 1].end) + 0.5, nextStart)

            while c < chords.count, chords[c].start < lineStart {
                pending.append(chords[c]); c += 1
            }
            flushInstrumental()

            var perWord = [[ChordEvent]](repeating: [], count: line.words.count)
            while c < chords.count, chords[c].start < lineEnd {
                let chord = chords[c]
                // The first word still sounding when the chord starts (or the last word).
                let w = line.words.firstIndex { $0.end > chord.start } ?? (line.words.count - 1)
                perWord[w].append(chord)
                c += 1
            }
            // Like a printed sheet: if the line starts mid-chord, repeat that chord on the first word.
            if perWord[0].isEmpty,
               let sounding = chords.last(where: { $0.start <= line.words[0].start && $0.end > line.words[0].start }) {
                perWord[0] = [sounding]
            }

            let tokens = line.words.enumerated().map { i, word in
                SheetToken(id: makeID(), chords: perWord[i], word: word.text, start: word.start)
            }
            lines.append(SheetLine(id: makeID(), start: line.start, end: lineEnd, tokens: tokens))
        }

        while c < chords.count { pending.append(chords[c]); c += 1 }
        flushInstrumental()
        return lines
    }
}
