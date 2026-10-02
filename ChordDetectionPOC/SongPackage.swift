import Foundation

/// Snapshot of one analysed song: the imported audio is stored separately as a CloudKit asset.
struct SongPackage: Codable {
    var title: String
    var engineRaw: String
    var lyricsLanguage: String
    var transpose: Int
    var capo: Int
    var key: KeySummary?
    var chords: [ChordEvent]?
    var chordKeys: [KeyRegion]
    var lyrics: [LyricLine]?
    var labText: String?

    var engine: ChordEngineKind { ChordEngineKind(rawValue: engineRaw) ?? .btc }
}
