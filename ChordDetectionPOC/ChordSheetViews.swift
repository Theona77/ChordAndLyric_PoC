//
//  ChordSheetViews.swift
//  ChordDetectionPOC
//
//  The player bar and the chord sheet (chords over lyrics, tap to play from there).
//

import SwiftUI

// MARK: - Player bar

struct PlayerBar: View {
    let player: PlaybackController

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { min(player.currentTime, max(player.duration, 0.1)) },
                               set: { player.scrub(to: $0) }),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    editing ? player.beginScrubbing() : player.endScrubbing()
                }
            )
            .disabled(!player.isReady)

            HStack {
                Text(player.currentTime.clock)
                    .monospacedDigit()
                Spacer()
                Button { player.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel("Back 10 seconds")

                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                }
                .padding(.horizontal, 16)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button { player.skip(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel("Forward 10 seconds")
                Spacer()
                Text(player.duration.clock)
                    .monospacedDigit()
            }
            .font(.title3)
            .disabled(!player.isReady)

            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(PlaybackController.rates, id: \.self) { rate in
                    Text(rate == 1 ? "1×" : String(format: "%g×", rate)).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!player.isReady)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Chord sheet card

struct ChordSheetCard: View {
    enum Mode: String, CaseIterable, Identifiable {
        case sheet = "Sheet"
        case timeline = "Timeline"
        var id: String { rawValue }
    }

    let chords: LoadState<[ChordEvent]>
    /// Built by the view model from chords + lyrics (not here: this view redraws during playback).
    let lines: [SheetLine]
    let lyrics: LoadState<[LyricLine]>
    let keyChanges: [KeyChange]
    let caption: String?
    let engine: ChordEngineKind
    let labFile: URL?
    let languages: [LanguageOption]
    let selectedLanguage: String
    let player: PlaybackController
    let scrollProxy: ScrollViewProxy
    let onSelectEngine: (ChordEngineKind) -> Void
    let onSelectLanguage: (String) -> Void

    @State private var mode: Mode = .sheet
    @State private var follow = true

    private var activeLineID: Int? {
        let t = player.currentTime
        return lines.last { $0.start - LeadSheet.leadIn <= t }?.id
    }

    var body: some View {
        AnalysisCard(title: "Chords", systemImage: "pianokeys") {
            Picker("Detector", selection: Binding(get: { engine }, set: onSelectEngine)) {
                ForEach(ChordEngineKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Spacer()
                Toggle(isOn: $follow) { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                    .toggleStyle(.button)
                    .accessibilityLabel("Follow playback")
            }

            if let caption {
                Text(caption).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(keyChanges) { change in
                Label("Key change at \(change.time.clock) → \(change.name)", systemImage: "arrow.up.right")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack {
                lyricsStatus
                Spacer()
                if !languages.isEmpty {
                    Menu {
                        Picker("Song language", selection: Binding(get: { selectedLanguage }, set: onSelectLanguage)) {
                            ForEach(languages) { Text($0.name).tag($0.id) }
                        }
                    } label: {
                        Label(languages.first { $0.id == selectedLanguage }?.name ?? selectedLanguage,
                              systemImage: "globe")
                    }
                }
            }
            .font(.footnote)

            StateContent(state: chords) { events in
                if events.isEmpty {
                    Text("No chords were detected in this recording.")
                        .foregroundStyle(.secondary)
                } else if mode == .sheet {
                    sheet
                } else {
                    timeline(events)
                }
            }

            if let labFile {
                ShareLink(item: labFile) {
                    Label("Export .lab", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                }
            }
        }
        .onChange(of: activeLineID) { _, id in
            guard follow, player.isPlaying, mode == .sheet, let id else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                scrollProxy.scrollTo(SheetLineView.scrollID(id), anchor: .center)
            }
        }
    }

    @ViewBuilder
    private var lyricsStatus: some View {
        switch lyrics {
        case .loading:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Transcribing lyrics…") }
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .loaded(let lines) where lines.isEmpty:
            Text("No vocals recognised").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var sheet: some View {
        let active = activeLineID
        let t = player.currentTime
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(lines) { line in
                SheetLineView(
                    line: line,
                    isActive: line.id == active,
                    activeChordID: line.id == active ? activeChord(in: line, at: t) : nil,
                    onPlay: { player.play(from: max(0, $0)) }
                )
            }
        }
    }

    private func activeChord(in line: SheetLine, at t: TimeInterval) -> UUID? {
        line.tokens.flatMap(\.chords).last { $0.start <= t && t < $0.end }?.id
    }

    private func timeline(_ events: [ChordEvent]) -> some View {
        let t = player.currentTime
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], alignment: .leading, spacing: 10) {
            ForEach(events) { chord in
                let isActive = chord.start <= t && t < chord.end && player.currentTime > 0
                Button { player.play(from: chord.start) } label: {
                    VStack(spacing: 2) {
                        ChordChip(symbol: chord.symbol, isActive: isActive)
                        Text(chord.start.clock)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - One sheet line

struct SheetLineView: View, Equatable {
    let line: SheetLine
    let isActive: Bool
    let activeChordID: UUID?
    let onPlay: (TimeInterval) -> Void

    static func scrollID(_ id: Int) -> String { "sheet-line-\(id)" }

    static func == (a: SheetLineView, b: SheetLineView) -> Bool {
        a.line == b.line && a.isActive == b.isActive && a.activeChordID == b.activeChordID
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { onPlay(line.start - LeadSheet.leadIn) } label: {
                Text(line.start.clock)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play from \(line.start.clock)")

            FlowLayout(spacing: line.isInstrumental ? 14 : 5, lineSpacing: 8) {
                ForEach(line.tokens) { token in
                    tokenView(token)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isActive ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .id(Self.scrollID(line.id))
    }

    @ViewBuilder
    private func tokenView(_ token: SheetToken) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if token.chords.isEmpty {
                // Keeps words on one baseline whether or not they carry a chord.
                Text(" ").font(.subheadline.weight(.bold)).accessibilityHidden(true)
            } else {
                HStack(spacing: 4) {
                    ForEach(token.chords) { chord in
                        Button { onPlay(chord.start) } label: {
                            Text(chord.symbol)
                                .font(line.isInstrumental ? .title3.weight(.semibold) : .subheadline.weight(.bold))
                                .foregroundStyle(chord.id == activeChordID ? Color.white : Color.accentColor)
                                .padding(.horizontal, 4)
                                .background(chord.id == activeChordID ? Color.accentColor : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chord.symbol), play from \(chord.start.clock)")
                    }
                }
            }
            if let word = token.word {
                Text(word).font(.body)
            }
        }
    }
}

// MARK: - Flow layout

/// Lays children out left to right, wrapping onto new rows (like words in a paragraph).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
