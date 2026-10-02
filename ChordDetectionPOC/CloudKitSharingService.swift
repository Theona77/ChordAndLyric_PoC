import CloudKit
import Foundation

enum CloudKitConfig {
    static let containerID = "iCloud.apple.ChordDetectionPOC"
    static let zoneName = "SharedSongs"
    static let recordType = "SharedSong"
    static let titleKey = "title"
    static let packageKey = "package"
    static let audioKey = "audio"
}

struct SharedSongItem: Identifiable, Hashable {
    let recordName: String
    let zoneName: String
    let zoneOwnerName: String
    let title: String
    let isOwnedByMe: Bool

    var id: String { "\(zoneOwnerName)/\(zoneName)/\(recordName)" }
}

struct FetchedSharedSong: Equatable {
    let title: String
    let packageJSON: Data
    let audioURL: URL
}

enum CloudKitShareError: LocalizedError {
    case notSignedIn
    case restricted
    case unavailable
    case noAudio
    case invalidAccount
    case missingPackage
    case emptyShare
    case saveFailed
    case lookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to iCloud in Settings to share songs."
        case .restricted:
            return "iCloud is restricted on this device, so sharing isn't available."
        case .unavailable:
            return "Couldn't reach iCloud. Check the network and try again."
        case .noAudio:
            return "There's no imported song to share yet."
        case .invalidAccount:
            return "Enter an Apple ID email or the phone number on that iCloud account."
        case .missingPackage:
            return "This share is missing its chord sheet data."
        case .emptyShare:
            return "The share was accepted, but no song was attached."
        case .saveFailed:
            return "Couldn't upload the song to iCloud."
        case .lookupFailed(let account):
            return "Couldn't find an iCloud user for \"\(account)\". Check the email, or send them the share link instead."
        }
    }
}

/// Uploads an analysed song to a private CloudKit zone and invites another Apple ID.
enum CloudKitSharingService {

    static var container: CKContainer { CKContainer(identifier: CloudKitConfig.containerID) }

    // MARK: Share

    /// Uploads audio + analysis and adds `account` (email or phone) as a read-only participant.
    /// Returns the share URL so it can also be sent via Messages/Mail.
    static func share(title: String, audioURL: URL, packageJSON: Data, account: String) async throws -> URL {
        try await ensureAccount()
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { throw CloudKitShareError.invalidAccount }

        let participant = try await participant(for: account)
        participant.permission = .readOnly
        participant.role = .privateUser

        let database = container.privateCloudDatabase
        try await ensureZone(in: database)

        let zoneID = CKRecordZone(zoneName: CloudKitConfig.zoneName).zoneID
        let record = CKRecord(
            recordType: CloudKitConfig.recordType,
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        )
        record[CloudKitConfig.titleKey] = title as CKRecordValue
        record[CloudKitConfig.packageKey] = packageJSON as CKRecordValue
        record[CloudKitConfig.audioKey] = CKAsset(fileURL: audioURL)

        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share.publicPermission = CKShare.ParticipantPermission.none
        share.addParticipant(participant)

        let savedShare = try await save(record: record, share: share, in: database)
        guard let url = savedShare.url else { throw CloudKitShareError.saveFailed }
        return url
    }

    // MARK: List / fetch

    static func listSongs() async throws -> [SharedSongItem] {
        try await ensureAccount()
        let mine = try await listSongs(in: container.privateCloudDatabase, owned: true)
        let shared = try await listSongs(in: container.sharedCloudDatabase, owned: false)
        return (mine + shared).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func fetch(_ item: SharedSongItem) async throws -> FetchedSharedSong {
        try await ensureAccount()
        let database = item.isOwnedByMe ? container.privateCloudDatabase : container.sharedCloudDatabase
        let recordID = CKRecord.ID(
            recordName: item.recordName,
            zoneID: CKRecordZone.ID(zoneName: item.zoneName, ownerName: item.zoneOwnerName)
        )
        return try unpacked(try await database.record(for: recordID))
    }

    static func fetch(recordID: CKRecord.ID, in database: CKDatabase) async throws -> FetchedSharedSong {
        try unpacked(try await database.record(for: recordID))
    }

    // MARK: Accept invitation

    static func accept(_ metadata: CKShare.Metadata) async throws -> FetchedSharedSong {
        let shareContainer = CKContainer(identifier: metadata.containerIdentifier)
        _ = try await shareContainer.accept(metadata)
        let database = shareContainer.sharedCloudDatabase
        if let rootID = metadata.hierarchicalRootRecordID {
            return try await fetch(recordID: rootID, in: database)
        }
        let zoneID = metadata.share.recordID.zoneID
        let items = try await listSongs(in: database, owned: false, only: [zoneID])
        guard let item = items.first else { throw CloudKitShareError.emptyShare }
        return try await fetch(item)
    }

    static func acceptShare(at url: URL) async throws -> FetchedSharedSong {
        let results = try await container.shareMetadatas(for: [url])
        guard let result = results[url] else { throw CloudKitShareError.emptyShare }
        switch result {
        case .success(let metadata):
            return try await accept(metadata)
        case .failure(let error):
            throw error
        }
    }

    static func isCloudKitShareURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme.contains("cloudkit") { return true }
        return host.contains("icloud.com") && (url.path.contains("share") || host.contains("share"))
    }

    // MARK: Private

    private static func ensureAccount() async throws {
        switch try await container.accountStatus() {
        case .available:
            return
        case .noAccount:
            throw CloudKitShareError.notSignedIn
        case .restricted:
            throw CloudKitShareError.restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            throw CloudKitShareError.unavailable
        @unknown default:
            throw CloudKitShareError.unavailable
        }
    }

    private static func ensureZone(in database: CKDatabase) async throws {
        let zones = try await database.allRecordZones()
        if zones.contains(where: { $0.zoneID.zoneName == CloudKitConfig.zoneName }) { return }
        _ = try await database.save(CKRecordZone(zoneName: CloudKitConfig.zoneName))
    }

    private static func save(record: CKRecord, share: CKShare, in database: CKDatabase) async throws -> CKShare {
        let (saveResults, _) = try await database.modifyRecords(saving: [record, share], deleting: [])
        var savedShare: CKShare?
        for (_, result) in saveResults {
            switch result {
            case .success(let saved):
                if let share = saved as? CKShare { savedShare = share }
            case .failure(let error):
                throw error
            }
        }
        guard let savedShare else { throw CloudKitShareError.saveFailed }
        return savedShare
    }

    private static func participant(for account: String) async throws -> CKShare.Participant {
        do {
            if account.contains("@") {
                return try await container.shareParticipant(forEmailAddress: account)
            }
            return try await container.shareParticipant(forPhoneNumber: account)
        } catch {
            throw CloudKitShareError.lookupFailed(account)
        }
    }

    private static func listSongs(in database: CKDatabase, owned: Bool, only zoneIDs: [CKRecordZone.ID]? = nil) async throws -> [SharedSongItem] {
        let zones: [CKRecordZone]
        if let zoneIDs {
            zones = zoneIDs.map { CKRecordZone(zoneID: $0) }
        } else {
            zones = try await database.allRecordZones()
        }

        var items: [SharedSongItem] = []
        let query = CKQuery(recordType: CloudKitConfig.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]

        for zone in zones {
            if owned && zone.zoneID.zoneName != CloudKitConfig.zoneName { continue }
            if !owned && zone.zoneID.zoneName != CloudKitConfig.zoneName { continue }
            do {
                let (matchResults, _) = try await database.records(
                    matching: query,
                    inZoneWith: zone.zoneID,
                    desiredKeys: [CloudKitConfig.titleKey],
                    resultsLimit: 50
                )
                for (_, result) in matchResults {
                    if case .success(let record) = result {
                        items.append(item(from: record, owned: owned))
                    }
                }
            } catch {
                items += try await listSongsByZoneChanges(in: database, zoneID: zone.zoneID, owned: owned)
            }
        }
        return items
    }

    /// Used when CloudKit hasn't created a query index yet (common on the first Development run).
    private static func listSongsByZoneChanges(in database: CKDatabase, zoneID: CKRecordZone.ID, owned: Bool) async throws -> [SharedSongItem] {
        var items: [SharedSongItem] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                if case .success(let modification) = result,
                   modification.record.recordType == CloudKitConfig.recordType {
                    items.append(item(from: modification.record, owned: owned))
                }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return items
    }

    private static func item(from record: CKRecord, owned: Bool) -> SharedSongItem {
        let title = record[CloudKitConfig.titleKey] as? String ?? "Song"
        let zone = record.recordID.zoneID
        return SharedSongItem(
            recordName: record.recordID.recordName,
            zoneName: zone.zoneName,
            zoneOwnerName: zone.ownerName,
            title: title,
            isOwnedByMe: owned
        )
    }

    private static func unpacked(_ record: CKRecord) throws -> FetchedSharedSong {
        guard record.recordType == CloudKitConfig.recordType else { throw CloudKitShareError.emptyShare }
        let title = record[CloudKitConfig.titleKey] as? String ?? "Song"
        guard let packageJSON = record[CloudKitConfig.packageKey] as? Data else {
            throw CloudKitShareError.missingPackage
        }
        guard let asset = record[CloudKitConfig.audioKey] as? CKAsset, let source = asset.fileURL else {
            throw CloudKitShareError.noAudio
        }

        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(title)")
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return FetchedSharedSong(title: title, packageJSON: packageJSON, audioURL: destination)
    }
}
