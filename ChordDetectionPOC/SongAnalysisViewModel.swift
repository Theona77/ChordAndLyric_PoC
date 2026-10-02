import Foundation
import Observation
import Speech

// MARK: - Chord detection seam

struct ChordDetectionResult {
    let events: [ChordEvent]
    /// Keys found from the chords, including key changes.
    let keys: [KeyRegion]
    /// MIREX-style .lab text (Harte labels), for scoring against a reference with Tools/score.py.
    let labText: String
}

protocol ChordDetecting {
    /// - key: used to bias transitions toward chords in the key. nil = no key prior.
    func detectChords(url: URL, key: KeySummary?, engine: ChordEngineKind) async throws -> ChordDetectionResult
}

struct NoopChordDetector: ChordDetecting {
    func detectChords(url: URL, key: KeySummary?, engine: ChordEngineKind) async throws -> ChordDetectionResult {
        ChordDetectionResult(events: [], keys: [], labText: "")
    }
}

/// The real detector: runs `ChordEngine` off the main actor.
struct EngineChordDetector: ChordDetecting {
    var options = ChordEngineOptions()

    func detectChords(url: URL, key: KeySummary?, engine: ChordEngineKind) async throws -> ChordDetectionResult {
        let analysis = try await ChordEngine.run(kind: engine, url: url, keys: key?.regions ?? [], options: options)
        return ChordDetectionResult(
            events: analysis.segments.map { ChordEvent(symbol: $0.symbol, start: $0.start, duration: $0.duration) },
            keys: analysis.keys,
            labText: analysis.labText
        )
    }
}

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
}

// MARK: - View model

@MainActor
@Observable
final class SongAnalysisViewModel {

    var fileName: String?
    var importError: String?

    var key: LoadState<KeySummary> = .idle
    var lyrics: LoadState<[LyricLine]> = .idle
    /// Chords exactly as detected (recorded key, sharp-spelled).
    var chords: LoadState<[ChordEvent]> = .idle
    /// Keys found from the detected chords (key changes included). Empty until chords load.
    private(set) var chordKeys: [KeyRegion] = []

    // Playing setup
    var setup = PlayingSetup()
    var suggestion: CapoSuggestion?

    /// The shapes you play: detected chords shifted by transpose/capo and spelled for that key.
    var transposedChords: LoadState<[ChordEvent]> {
        guard case .loaded(let events) = chords,
              case .loaded(let summary) = key else { return chords }
        return .loaded(PlayingKeyPlanner.shapeChords(events, key: summary, localKeys: chordKeys, setup: setup))
    }

    /// Plays the imported song; the chord sheet seeks it when a chord is tapped.
    let player = PlaybackController()

    /// The chord sheet: transposed chords placed over the lyric words (or instrumental rows).
    /// Computed here rather than in the sheet view, which redraws ~20x a second during playback.
    var sheetLines: [SheetLine] {
        guard case .loaded(let events) = transposedChords else { return [] }
        var lines: [LyricLine] = []
        if case .loaded(let loaded) = lyrics { lines = loaded }
        return LeadSheet.build(chords: events, lyrics: lines)
    }

    /// Whether the chord list shows sounding chords or capo/transpose shapes.
    var keyCaption: String? {
        guard case .loaded(let summary) = key else { return nil }
        return PlayingKeyPlanner.chordListCaption(key: summary, setup: setup)
    }

    /// Remembered between launches.
    var lyricsLanguage = UserDefaults.standard.string(forKey: SongAnalysisViewModel.lyricsLanguageKey) ?? "en-US"
    private static let lyricsLanguageKey = "lyricsLanguage"
    var languageOptions: [LanguageOption] = []

    /// Which chord detector to use. Changing it re-runs only the chord step.
    private(set) var chordEngine: ChordEngineKind = .btc
    /// The last detection as a .lab file in the temporary directory, for sharing/scoring.
    private(set) var chordLabFile: URL?

    /// True once an imported (or shared) audio file is on disk and ready to upload.
    var canShare: Bool { currentFile != nil }

    private let chordDetector: any ChordDetecting
    private var analysisTask: Task<Void, Never>?
    private var chordsTask: Task<Void, Never>?  
    private var lyricsTask: Task<Void, Never>?
    private var currentFile: URL?

    /// Bumped on every new file. Any async result carrying an older value is dropped.
    private var generation = 0
    /// Bumped on every lyrics request (new file or language change), for the same reason.
    private var lyricsGeneration = 0
    /// Bumped on every chord run (new file or engine change).
    private var chordsGeneration = 0

    init(chordDetector: any ChordDetecting = EngineChordDetector()) {
        self.chordDetector = chordDetector
    }

    /// Results are applied only if they belong to the current file and their task wasn't cancelled.
    /// The token check is what matters: cancellation is cooperative, so a superseded task can
    /// still finish and come back with a value for the old file.
    private func isCurrent(_ gen: Int) -> Bool {
        gen == generation && !Task.isCancelled
    }

    private func isCurrentLyrics(_ gen: Int, _ lyricsGen: Int) -> Bool {
        isCurrent(gen) && lyricsGen == lyricsGeneration
    }

    private func isCurrentChords(_ gen: Int, _ chordsGen: Int) -> Bool {
        isCurrent(gen) && chordsGen == chordsGeneration
    }

    // MARK: Entry point

    func load(from pickedURL: URL) {
        generation += 1
        let gen = generation

        analysisTask?.cancel()
        chordsTask?.cancel()
        lyricsTask?.cancel()
        removeCurrentFile()
        removeLabFile()
        importError = nil

        fileName = pickedURL.lastPathComponent
        key = .loading
        lyrics = .loading
        chords = .loading
        chordKeys = []
        setup = PlayingSetup()
        suggestion = nil

        analysisTask = Task {
            // 1. Copy (and if needed convert) into a file every framework can read.
            let localURL: URL
            do {
                localURL = try await AudioImport.prepare(pickedURL)
            } catch {
                guard isCurrent(gen) else { return }
                failImport(error)
                return
            }
            guard isCurrent(gen) else {
                try? FileManager.default.removeItem(at: localURL)
                return
            }
            currentFile = localURL
            player.load(localURL)

            // 2. Lyrics are independent, and only ever run through `lyricsTask`.
            startLyrics(localURL, gen: gen)

            // 3. Chords need the key (for the transition prior), so key goes first.
            await runKey(localURL, gen: gen)
            guard isCurrent(gen) else { return }
            refreshSuggestion()
            startChords(localURL, gen: gen)
        }
    }

    /// Don't leave the previous song's results (or spinners) on screen under a failed import.
    private func failImport(_ error: Error) {
        fileName = nil
        key = .idle
        lyrics = .idle
        chords = .idle
        chordKeys = []
        setup = PlayingSetup()
        suggestion = nil
        importError = error.localizedDescription
    }

    // MARK: Chord engine

    func setChordEngine(_ engine: ChordEngineKind) {
        guard engine != chordEngine else { return }
        chordEngine = engine
        guard let file = currentFile else { return }
        // While the key is still loading, the analysis task starts chords with the new engine.
        if case .loading = key { return }
        startChords(file, gen: generation)
    }

    // MARK: Playing setup

    func setTranspose(_ value: Int) {
        setup.transpose = min(max(value, PlayingSetup.transposeRange.lowerBound), PlayingSetup.transposeRange.upperBound)
        refreshSuggestion()
    }

    func setCapo(_ value: Int) {
        setup.capo = min(max(value, PlayingSetup.capoRange.lowerBound), PlayingSetup.capoRange.upperBound)
    }

    func applySuggestion() {
        if let suggestion { setup.capo = suggestion.capo }
    }

    /// Works from the key alone until chords arrive, then from both.
    private func refreshSuggestion() {
        guard case .loaded(let summary) = key else {
            suggestion = nil
            return
        }
        var events: [ChordEvent] = []
        if case .loaded(let detected) = chords { events = detected }
        suggestion = PlayingKeyPlanner.suggestCapo(key: summary, chords: events, transpose: setup.transpose)
    }

    // MARK: Jobs

    private func runKey(_ url: URL, gen: Int) async {
        do {
            let summary = try await KeyAnalysisService.analyzeKey(url: url)
            guard isCurrent(gen) else { return }
            key = .loaded(summary)
        } catch {
            guard isCurrent(gen) else { return }
            key = .failed(error.localizedDescription)
        }
    }

    private func startChords(_ url: URL, gen: Int) {
        chordsTask?.cancel()
        chordsGeneration += 1
        let chordsGen = chordsGeneration
        chords = .loading
        chordKeys = []
        removeLabFile()
        let engine = chordEngine
        chordsTask = Task {
            await runChords(url, engine: engine, gen: gen, chordsGen: chordsGen)
            guard isCurrentChords(gen, chordsGen) else { return }
            refreshSuggestion()
        }
    }

    private func runChords(_ url: URL, engine: ChordEngineKind, gen: Int, chordsGen: Int) async {
        var keySummary: KeySummary?
        if case .loaded(let k) = key { keySummary = k }   // nil if key analysis failed; the engine estimates one

        do {
            let result = try await chordDetector.detectChords(url: url, key: keySummary, engine: engine)
            guard isCurrentChords(gen, chordsGen) else { return }
            chordKeys = result.keys
            chords = .loaded(result.events)
            chordLabFile = writeLabFile(result.labText, engine: engine)
        } catch {
            guard isCurrentChords(gen, chordsGen) else { return }
            chords = .failed(error.localizedDescription)
        }
    }

    private func startLyrics(_ url: URL, gen: Int) {
        lyricsTask?.cancel()
        lyricsGeneration += 1
        let lyricsGen = lyricsGeneration
        let language = lyricsLanguage
        lyrics = .loading
        lyricsTask = Task { await runLyrics(url, language: language, gen: gen, lyricsGen: lyricsGen) }
    }

    private func runLyrics(_ url: URL, language: String, gen: Int, lyricsGen: Int) async {
        do {
            let lines = try await LyricsService.transcribe(url: url, localeIdentifier: language)
            guard isCurrentLyrics(gen, lyricsGen) else { return }
            lyrics = .loaded(lines)
        } catch {
            // Errors from a superseded request (including CancellationError) are dropped;
            // the newer request owns `lyrics`.
            guard isCurrentLyrics(gen, lyricsGen) else { return }
            lyrics = .failed(error.localizedDescription)
        }
    }

    // MARK: Lyrics language

    func loadLanguageOptions() async {
        let ids = await LyricsService.supportedLanguages()
        languageOptions = ids
            .map { LanguageOption(id: $0, name: Locale.current.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name < $1.name }

        // First launch: default to the phone's language (e.g. Indonesian) when it's supported.
        if UserDefaults.standard.string(forKey: Self.lyricsLanguageKey) == nil,
           let deviceLanguage = Locale.current.language.languageCode?.identifier,
           let match = languageOptions.first(where: { $0.id == Locale.current.identifier(.bcp47) })
            ?? languageOptions.first(where: { $0.id.hasPrefix(deviceLanguage + "-") || $0.id == deviceLanguage }) {
            changeLyricsLanguage(to: match.id)
        }
    }

    func changeLyricsLanguage(to identifier: String) {
        guard identifier != lyricsLanguage else { return }
        lyricsLanguage = identifier
        UserDefaults.standard.set(identifier, forKey: Self.lyricsLanguageKey)
        guard let file = currentFile else { return }
        startLyrics(file, gen: generation)
    }

    // MARK: CloudKit sharing

    func share(with account: String) async throws -> URL {
        guard let audio = currentFile, let package = makePackage() else {
            throw CloudKitShareError.noAudio
        }
        let json = try JSONEncoder().encode(package)
        return try await CloudKitSharingService.share(
            title: package.title,
            audioURL: audio,
            packageJSON: json,
            account: account
        )
    }

    func openShared(_ item: SharedSongItem) async throws {
        let fetched = try await CloudKitSharingService.fetch(item)
        applyShared(fetched)
    }

    func applyShared(_ fetched: FetchedSharedSong) {
        let package: SongPackage
        do {
            package = try JSONDecoder().decode(SongPackage.self, from: fetched.packageJSON)
        } catch {
            importError = error.localizedDescription
            return
        }

        generation += 1
        lyricsGeneration += 1
        chordsGeneration += 1
        analysisTask?.cancel()
        chordsTask?.cancel()
        lyricsTask?.cancel()
        removeCurrentFile()
        removeLabFile()
        importError = nil

        fileName = fetched.title
        currentFile = fetched.audioURL
        player.load(fetched.audioURL)
        key = package.key.map { .loaded($0) } ?? .failed("This share didn't include key data.")
        chords = package.chords.map { .loaded($0) } ?? .failed("This share didn't include chords.")
        lyrics = package.lyrics.map { .loaded($0) } ?? .idle
        chordKeys = package.chordKeys
        setup = PlayingSetup(transpose: package.transpose, capo: package.capo)
        chordEngine = package.engine
        lyricsLanguage = package.lyricsLanguage
        suggestion = nil
        if let lab = package.labText, !lab.isEmpty {
            chordLabFile = writeLabFile(lab, engine: chordEngine)
        }
        refreshSuggestion()
    }

    private func makePackage() -> SongPackage? {
        guard let fileName else { return nil }
        return SongPackage(
            title: fileName,
            engineRaw: chordEngine.rawValue,
            lyricsLanguage: lyricsLanguage,
            transpose: setup.transpose,
            capo: setup.capo,
            key: {
                if case .loaded(let value) = key { return value }
                return nil
            }(),
            chords: {
                if case .loaded(let value) = chords { return value }
                return nil
            }(),
            chordKeys: chordKeys,
            lyrics: {
                if case .loaded(let value) = lyrics { return value }
                return nil
            }(),
            labText: chordLabFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        )
    }

    // MARK: File handling

    private func removeCurrentFile() {
        player.unload()
        if let currentFile { try? FileManager.default.removeItem(at: currentFile) }
        currentFile = nil
    }

    private func writeLabFile(_ text: String, engine: ChordEngineKind) -> URL? {
        guard !text.isEmpty else { return nil }
        let base = (fileName as NSString?)?.deletingPathExtension ?? "chords"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)-\(engine.rawValue).lab")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func removeLabFile() {
        if let chordLabFile { try? FileManager.default.removeItem(at: chordLabFile) }
        chordLabFile = nil
    }
}
