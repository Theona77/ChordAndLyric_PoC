import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main screen

struct ContentView: View {
    @State private var model = SongAnalysisViewModel()
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        importHeader

                        if model.fileName != nil {
                            KeyCard(state: model.key)

                            if case .loaded(let keySummary) = model.key {
                                PlayingKeyCard(
                                    key: keySummary,
                                    setup: model.setup,
                                    suggestion: model.suggestion,
                                    onTranspose: { model.setTranspose($0) },
                                    onCapo: { model.setCapo($0) },
                                    onApplySuggestion: { model.applySuggestion() }
                                )
                            }

                            ChordSheetCard(
                                chords: model.transposedChords,
                                lines: model.sheetLines,
                                lyrics: model.lyrics,
                                keyChanges: PlayingKeyPlanner.keyChanges(model.chordKeys, setup: model.setup),
                                caption: model.keyCaption,
                                engine: model.chordEngine,
                                labFile: model.chordLabFile,
                                languages: model.languageOptions,
                                selectedLanguage: model.lyricsLanguage,
                                player: model.player,
                                scrollProxy: proxy,
                                onSelectEngine: { model.setChordEngine($0) },
                                onSelectLanguage: { model.changeLyricsLanguage(to: $0) }
                            )
                        }
                    }
                    .padding()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.fileName != nil {
                    PlayerBar(player: model.player)
                }
            }
            .navigationTitle("ChordLab")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.loadLanguageOptions() }
            .fileImporter(
                isPresented: $showImporter,
                // Videos too: their soundtrack is extracted on import.
                allowedContentTypes: [.audio, .movie]
            ) { result in
                switch result {
                case .success(let url): model.load(from: url)
                case .failure(let error): model.importError = error.localizedDescription
                }
            }
        }
    }

    private var importHeader: some View {
        VStack(spacing: 12) {
            Button {
                showImporter = true
            } label: {
                Label(
                    model.fileName == nil ? "Choose a song" : "Choose another song",
                    systemImage: "square.and.arrow.down"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let name = model.fileName {
                Label(name, systemImage: "music.note")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let error = model.importError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Reusable pieces

struct AnalysisCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Renders idle / loading / failed uniformly and hands `.loaded` to the caller.
struct StateContent<Value, Loaded: View>: View {
    let state: LoadState<Value>
    @ViewBuilder var loaded: (Value) -> Loaded

    var body: some View {
        switch state {
        case .idle:
            Text("Waiting for a song…").foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Analyzing…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .loaded(let value):
            loaded(value)
        }
    }
}

struct ChordChip: View {
    let symbol: String
    var isActive = false

    var body: some View {
        Text(symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isActive ? Color.accentColor : Color.accentColor.opacity(0.15), in: Capsule())
    }
}

// MARK: - 1. Key

struct KeyCard: View {
    let state: LoadState<KeySummary>

    var body: some View {
        AnalysisCard(title: "Key", systemImage: "music.quarternote.3") {
            StateContent(state: state) { summary in
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.dominantName)
                        .font(.system(size: 40, weight: .bold, design: .rounded))

                    if let alt = summary.enharmonicName {
                        Text("Also written \(alt)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if summary.segments.count > 1 {
                        Text("Key changes detected")
                            .font(.subheadline.weight(.medium))
                            .padding(.top, 4)
                        ForEach(summary.segments) { segment in
                            HStack {
                                Text(segment.start.clock)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(segment.name)
                                Spacer()
                                Text("\(segment.duration.clock) long")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }

                    Text("Detected with the MusicUnderstanding framework")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
