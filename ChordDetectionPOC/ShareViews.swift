import SwiftUI

// MARK: - Invite someone by Apple ID

struct ShareSongSheet: View {
    let songTitle: String
    let onShare: (String) async throws -> URL

    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var isSharing = false
    @State private var errorMessage: String?
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID email or phone", text: $account)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isSharing)
                } footer: {
                    Text("They need ChordLab and an iCloud account. You'll share the audio plus the generated key, chords, and lyrics — they won't have to analyse the song again.")
                }

                if isSharing {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Uploading to iCloud…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if let shareURL {
                    Section("Invitation sent") {
                        Text("Added \(account). You can also send them this link.")
                            .foregroundStyle(.secondary)
                        ShareLink(item: shareURL) {
                            Label("Send share link", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Share \"\(songTitle)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") {
                        Task { await send() }
                    }
                    .disabled(account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSharing)
                }
            }
        }
    }

    private func send() async {
        errorMessage = nil
        shareURL = nil
        isSharing = true
        defer { isSharing = false }
        do {
            shareURL = try await onShare(account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Songs you've shared / that were shared with you

struct SharedSongsSheet: View {
    let onOpen: (SharedSongItem) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [SharedSongItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var openingID: String?

    private var received: [SharedSongItem] { items.filter { !$0.isOwnedByMe } }
    private var sent: [SharedSongItem] { items.filter(\.isOwnedByMe) }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && items.isEmpty {
                    ProgressView("Loading iCloud…")
                } else if let errorMessage, items.isEmpty {
                    ContentUnavailableView(
                        "Couldn't load shares",
                        systemImage: "icloud.slash",
                        description: Text(errorMessage)
                    )
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "No shared songs",
                        systemImage: "person.2",
                        description: Text("Songs you share, and songs shared with you, show up here.")
                    )
                } else {
                    List {
                        if !received.isEmpty {
                            Section("Shared with me") {
                                ForEach(received) { item in
                                    songRow(item)
                                }
                            }
                        }
                        if !sent.isEmpty {
                            Section("Shared by me") {
                                ForEach(sent) { item in
                                    songRow(item)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Shared songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func songRow(_ item: SharedSongItem) -> some View {
        Button {
            Task { await open(item) }
        } label: {
            HStack {
                Label(item.title, systemImage: item.isOwnedByMe ? "square.and.arrow.up" : "square.and.arrow.down")
                    .foregroundStyle(.primary)
                Spacer()
                if openingID == item.id {
                    ProgressView()
                }
            }
        }
        .disabled(openingID != nil)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await CloudKitSharingService.listSongs()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ item: SharedSongItem) async {
        openingID = item.id
        defer { openingID = nil }
        do {
            try await onOpen(item)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
