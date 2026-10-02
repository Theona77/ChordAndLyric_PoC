import AVFoundation
import Speech

nonisolated enum LyricsError: LocalizedError {
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let id):
            return "On-device transcription doesn't support the language \"\(id)\" on this iPhone. "
                + "Check Settings → General → Keyboard → Dictation Languages, or pick another language."
        }
    }
}

/// Vocal-to-text using the on-device SpeechAnalyzer (iOS 26+).
///
/// Two transcription modules, picked per language:
///  - SpeechTranscriber: Apple's newer, more accurate model, but only for a limited set of languages.
///  - DictationTranscriber: the keyboard-dictation model, which covers many more languages
///    (Indonesian among them). Used whenever SpeechTranscriber doesn't support the language.
///
/// Note: this transcribes the full mix. There's no vocal isolation, so accuracy
/// on sung vocals over loud instruments will vary a lot.
enum LyricsService {

    /// BCP-47 identifiers of every language either module can transcribe on this device.
    static func supportedLanguages() async -> [String] {
        var ids = Set<String>()
        if SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales { ids.insert(locale.identifier(.bcp47)) }
        }
        for locale in await DictationTranscriber.supportedLocales { ids.insert(locale.identifier(.bcp47)) }
        return Array(ids)
    }

    static func transcribe(
        url: URL,
        localeIdentifier: String
    ) async throws -> [LyricLine] {
        let requested = Locale(identifier: localeIdentifier)

        // 1. The newer model, when it knows this language (and the device supports it at all).
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            // Final results only (no volatile/partial results), with time ranges.
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            let collector = Task { () -> [LyricLine] in
                var lines: [LyricLine] = []
                for try await result in transcriber.results {
                    if let line = Self.line(text: result.text, range: result.range) { lines.append(line) }
                }
                return lines
            }
            return try await analyze(url: url, module: transcriber, collector: collector)
        }

        // 2. The dictation model: many more languages, including Indonesian.
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            let collector = Task { () -> [LyricLine] in
                var lines: [LyricLine] = []
                for try await result in transcriber.results {
                    if let line = Self.line(text: result.text, range: result.range) { lines.append(line) }
                }
                return lines
            }
            return try await analyze(url: url, module: transcriber, collector: collector)
        }

        throw LyricsError.unsupportedLanguage(localeIdentifier)
    }

    /// Downloads the module's on-device model if needed, feeds it the file and waits for the lines.
    private static func analyze(
        url: URL,
        module: any SpeechModule,
        collector: Task<[LyricLine], Error>
    ) async throws -> [LyricLine] {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            let file = try AVAudioFile(forReading: url)
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collector.value
        } catch {
            collector.cancel()
            throw error
        }
    }

    private static func line(text: AttributedString, range: CMTimeRange) -> LyricLine? {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        let start = range.start.seconds
        let end = start + range.duration.seconds
        return LyricLine(start: start, end: end, text: plain,
                         words: words(in: text, lineStart: start, lineEnd: end))
    }

    /// Word timings from the transcript's per-run audio time ranges (requested with `.audioTimeRange`).
    /// Runs without a time range share the line's time evenly, so every word gets a position.
    static func words(in text: AttributedString, lineStart: TimeInterval, lineEnd: TimeInterval) -> [LyricWord] {
        var timed: [(text: String, start: TimeInterval?, end: TimeInterval?)] = []
        for run in text.runs {
            let runText = String(text[run.range].characters)
            let range = run.audioTimeRange
            let pieces = runText.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !pieces.isEmpty else { continue }
            if let range, pieces.count == 1 {
                timed.append((pieces[0], range.start.seconds, range.start.seconds + range.duration.seconds))
            } else if let range {
                // Several words in one run: split its time range by character count.
                let total = Double(pieces.reduce(0) { $0 + $1.count })
                var t = range.start.seconds
                for piece in pieces {
                    let d = range.duration.seconds * Double(piece.count) / max(total, 1)
                    timed.append((piece, t, t + d))
                    t += d
                }
            } else {
                for piece in pieces { timed.append((piece, nil, nil)) }
            }
        }
        guard !timed.isEmpty else { return [] }

        // Fill missing times evenly between the known neighbours (or the line's ends).
        var result: [LyricWord] = []
        var i = 0
        while i < timed.count {
            if let s = timed[i].start, let e = timed[i].end, s.isFinite, e.isFinite {
                result.append(LyricWord(text: timed[i].text, start: s, end: max(e, s)))
                i += 1
                continue
            }
            var j = i
            while j < timed.count, timed[j].start == nil || !(timed[j].start!.isFinite) { j += 1 }
            let from = result.last?.end ?? lineStart
            let to = j < timed.count ? (timed[j].start ?? lineEnd) : lineEnd
            let step = max(to - from, 0) / Double(j - i)
            for k in i..<j {
                let s = from + step * Double(k - i)
                result.append(LyricWord(text: timed[k].text, start: s, end: s + step))
            }
            i = j
        }
        return result
    }
}
