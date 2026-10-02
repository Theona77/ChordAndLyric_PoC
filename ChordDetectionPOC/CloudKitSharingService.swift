import CloudKit
import Foundation

enum CloudKitConfig {
    static let containerID = "iCloud.apple.ChordDetectionPOC"
    static let zoneName = "SharedSongs"
    static let recordType = "SharedSong"
    static let titleKey = "title"
    static let packageKey = "package"
    static let packageAssetKey = "packageFile"
    static let audioKey = "audio"
    static let audioExtKey = "audioExt"

    static let songFieldKeys: [CKRecord.FieldKey] = [
        titleKey, packageKey, packageAssetKey, audioKey, audioExtKey
    ]
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
    case unreadableAudio

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
        case .unreadableAudio:
            return "The shared audio file couldn't be opened for playback."
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
        let packageFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try packageJSON.write(to: packageFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: packageFile) }

        record[CloudKitConfig.titleKey] = title as CKRecordValue
        // Bytes for small payloads; asset so a long lyric sheet isn't dropped by the 1 MB field cap.
        if packageJSON.count < 900_000 {
            record[CloudKitConfig.packageKey] = packageJSON as CKRecordValue
        }
        record[CloudKitConfig.packageAssetKey] = CKAsset(fileURL: packageFile)
        record[CloudKitConfig.audioKey] = CKAsset(fileURL: audioURL)
        let ext = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension
        record[CloudKitConfig.audioExtKey] = ext as CKRecordValue

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
        return try unpacked(try await fetchCompleteRecord(id: recordID, in: database))
    }

    static func fetch(recordID: CKRecord.ID, in database: CKDatabase) async throws -> FetchedSharedSong {
        try unpacked(try await fetchCompleteRecord(id: recordID, in: database))
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

    /// Listing uses `desiredKeys: [title]`, and CloudKit may then return that incomplete
    /// cached record from `record(for:)`. Fetch the song fields (including assets) explicitly.
    private static func fetchCompleteRecord(id: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord {
        let results = try await database.records(for: [id], desiredKeys: CloudKitConfig.songFieldKeys)
        guard let result = results[id] else { throw CloudKitShareError.emptyShare }
        switch result {
        case .success(let record):
            return record
        case .failure(let error):
            throw error
        }
    }

    private static func unpacked(_ record: CKRecord) throws -> FetchedSharedSong {
        guard record.recordType == CloudKitConfig.recordType else { throw CloudKitShareError.emptyShare }
        let title = record[CloudKitConfig.titleKey] as? String ?? "Song"
        guard let packageJSON = packageData(from: record) else {
            throw CloudKitShareError.missingPackage
        }
        guard let asset = record[CloudKitConfig.audioKey] as? CKAsset, let source = asset.fileURL else {
            throw CloudKitShareError.noAudio
        }

        let hinted = record[CloudKitConfig.audioExtKey] as? String
        let ext = audioExtension(forFileAt: source, hinted: hinted)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw CloudKitShareError.unreadableAudio }

        return FetchedSharedSong(title: title, packageJSON: packageJSON, audioURL: destination)
    }

    private static func packageData(from record: CKRecord) -> Data? {
        if let data = record[CloudKitConfig.packageKey] as? Data, !data.isEmpty {
            return data
        }
        if let asset = record[CloudKitConfig.packageAssetKey] as? CKAsset, let url = asset.fileURL {
            return try? Data(contentsOf: url)
        }
        if let string = record[CloudKitConfig.packageKey] as? String {
            return Data(string.utf8)
        }
        return nil
    }

    /// CloudKit asset cache files often have no extension; AVPlayer needs a real one.
    private static func audioExtension(forFileAt url: URL, hinted: String?) -> String {
        let hint = hinted?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if hint.count >= 2, hint.count <= 4, hint.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
            return hint
        }
        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count > 12 {
            if data.starts(with: [0x49, 0x44, 0x33]) { return "mp3" }
            if data[0] == 0xFF, data[1] & 0xE0 == 0xE0 { return "mp3" }
            if data.count > 11, data.subdata(in: 4..<8) == Data("ftyp".utf8) { return "m4a" }
            if data.starts(with: Data("RIFF".utf8)) { return "wav" }
        }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "m4a" : ext
    }
}
