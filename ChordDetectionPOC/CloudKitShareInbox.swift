import CloudKit
import Foundation
import Observation

/// Receives CloudKit share invitations (link tap or system callback) and hands the song to the UI.
@MainActor
@Observable
final class CloudKitShareInbox {
    static let shared = CloudKitShareInbox()

    var pendingSong: FetchedSharedSong?
    var lastError: String?

    func accept(_ metadata: CKShare.Metadata) async {
        do {
            pendingSong = try await CloudKitSharingService.accept(metadata)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func acceptShare(at url: URL) async {
        guard CloudKitSharingService.isCloudKitShareURL(url) else { return }
        do {
            pendingSong = try await CloudKitSharingService.acceptShare(at: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func consumePendingSong() -> FetchedSharedSong? {
        let song = pendingSong
        pendingSong = nil
        return song
    }
}
