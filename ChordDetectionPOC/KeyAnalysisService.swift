import AVFoundation
import MusicUnderstanding

enum KeyAnalysisService {

    private struct KeyID: Hashable {
        let pitchClass: Int
        let isMinor: Bool
    }

    /// Key regions shorter than this are treated as detector jitter and folded into a neighbour.
    private static let minimumSegmentDuration: TimeInterval = 6

    static func analyzeKey(url: URL) async throws -> KeySummary {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let session = try await MusicUnderstandingSession(asset: asset)
        let result = try await session.analyze(for: [.key])

        guard let keyResult = result.key, !keyResult.ranges.isEmpty else {
            throw AnalysisError.noKeyFound
        }

        // 1. Normalise every range to (pitch class, mode). G# and Ab become the same key.
        var raw: [KeySegment] = []
        for ranged in keyResult.ranges {
            let tonicRaw = ranged.value.tonic.rawValue
            guard let tonic = NoteNaming.parseTonic(tonicRaw) else {
                print("Unrecognised tonic raw value: \(tonicRaw)")
                continue
            }
            let start = ranged.range.start.seconds
            let duration = ranged.range.duration.seconds
            guard start.isFinite, duration.isFinite, duration > 0 else { continue }
            raw.append(
                KeySegment(
                    tonicPitchClass: NoteNaming.pitchClass(of: tonic),
                    isMinor: NoteNaming.isMinor(ranged.value.mode.rawValue),
                    start: start,
                    duration: duration
                )
            )
        }
        raw.sort { $0.start < $1.start }

        // 2. Merge neighbours that are the same key, so "Ab" then "G#" isn't a fake key change,
        //    then absorb very short blips and merge again.
        let segments = mergeSameKey(absorbShort(mergeSameKey(raw)))

        // 3. Dominant key = most total time, grouped by pitch class + mode.
        var totals: [KeyID: TimeInterval] = [:]
        for seg in segments {
            totals[KeyID(pitchClass: seg.tonicPitchClass, isMinor: seg.isMinor), default: 0] += seg.duration
        }
        guard let dominant = totals.max(by: { $0.value < $1.value })?.key else {
            throw AnalysisError.noKeyFound
        }

        return KeySummary(
            tonicPitchClass: dominant.pitchClass,
            isMinor: dominant.isMinor,
            segments: segments
        )
    }

    // MARK: Segment clean-up

    private static func sameKey(_ a: KeySegment, _ b: KeySegment) -> Bool {
        a.tonicPitchClass == b.tonicPitchClass && a.isMinor == b.isMinor
    }

    /// `a` stretched to cover `b` as well (they're adjacent, `a` first).
    private static func extend(_ a: KeySegment, through b: KeySegment) -> KeySegment {
        KeySegment(
            tonicPitchClass: a.tonicPitchClass,
            isMinor: a.isMinor,
            start: a.start,
            duration: max(a.start + a.duration, b.start + b.duration) - a.start
        )
    }

    private static func mergeSameKey(_ input: [KeySegment]) -> [KeySegment] {
        var result: [KeySegment] = []
        for seg in input {
            if let last = result.last, sameKey(last, seg) {
                result[result.count - 1] = extend(last, through: seg)
            } else {
                result.append(seg)
            }
        }
        return result
    }

    /// Short segments are given to the previous segment (or the next one, at the very start).
    private static func absorbShort(_ input: [KeySegment]) -> [KeySegment] {
        guard input.count > 1 else { return input }
        var result: [KeySegment] = []
        var pendingStart: TimeInterval?          // start of short segments waiting for a successor

        for seg in input {
            if seg.duration < minimumSegmentDuration {
                if let last = result.last {
                    result[result.count - 1] = extend(last, through: seg)
                } else if pendingStart == nil {
                    pendingStart = seg.start
                }
                continue
            }
            if let start = pendingStart {
                result.append(KeySegment(
                    tonicPitchClass: seg.tonicPitchClass,
                    isMinor: seg.isMinor,
                    start: start,
                    duration: seg.start + seg.duration - start
                ))
                pendingStart = nil
            } else {
                result.append(seg)
            }
        }
        // Everything was short: keep the input rather than inventing a key.
        return result.isEmpty ? input : result
    }
}
