//
//  PlayingKeyCard.swift
//  ChordDetectionPOC
//

import SwiftUI

struct PlayingKeyCard: View {
    let key: KeySummary
    let setup: PlayingSetup
    let suggestion: CapoSuggestion?
    let onTranspose: (Int) -> Void
    let onCapo: (Int) -> Void
    let onApplySuggestion: () -> Void

    var body: some View {
        AnalysisCard(title: "Playing Key", systemImage: "guitars") {
            VStack(alignment: .leading, spacing: 12) {

                // What you hear vs. what you play.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sounds in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(PlayingKeyPlanner.soundingName(key: key, setup: setup))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Play shapes in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(PlayingKeyPlanner.shapeName(key: key, setup: setup))
                        .font(.title3.weight(.semibold))
                }

                Divider()

                Stepper(
                    value: Binding(get: { setup.transpose }, set: onTranspose),
                    in: PlayingSetup.transposeRange
                ) {
                    Text("Transpose  \(setup.transpose > 0 ? "+" : "")\(setup.transpose)")
                        .monospacedDigit()
                }

                Stepper(
                    value: Binding(get: { setup.capo }, set: onCapo),
                    in: PlayingSetup.capoRange
                ) {
                    Text(setup.capo == 0 ? "Capo  none" : "Capo  fret \(setup.capo)")
                        .monospacedDigit()
                }

                Text(PlayingKeyPlanner.explanation(key: key, setup: setup))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let suggestion, suggestion.capo != setup.capo {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Use suggested capo \(suggestion.capo)", action: onApplySuggestion)
                            .font(.footnote.weight(.semibold))
                        Text(suggestion.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
