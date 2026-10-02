//
//  AudioImport.swift
//  ChordDetectionPOC
//
//  Gets a picked file into a form every part of the app can read (AVAudioFile for chords and
//  lyrics, AVURLAsset for MusicUnderstanding, AVPlayer for playback).
//

import AVFoundation
import Foundation

nonisolated enum AudioImportError: LocalizedError {
    case unreadable(fileName: String)
    case conversionFailed(fileName: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "iPhone can't read \"\(name)\". It may not be the format its name says: files from "
                + "YouTube downloaders are often WebM/Opus saved as .mp3 or .m4a. Convert it to MP3 or "
                + "M4A (or import the video file itself) and try again."
        case .conversionFailed(let name, let reason):
            return "Couldn't convert \"\(name)\" to a readable audio file: \(reason)"
        }
    }
}

nonisolated enum AudioImport {

    /// Copies the picked file into the temporary folder and makes sure it decodes.
    /// Anything AVAudioFile can't read directly but AVFoundation can open as media (videos,
    /// mislabelled containers) is converted to AAC .m4a. Returns the file the app should use.
    @concurrent
    static func prepare(_ picked: URL) async throws -> URL {
        let copy = try coordinatedCopy(of: picked)
        if isDecodable(copy) { return copy }

        defer { try? FileManager.default.removeItem(at: copy) }
        return try await convertToM4A(copy, displayName: picked.lastPathComponent)
    }

    /// Coordinated read: makes the file provider (iCloud Drive, other apps) finish downloading
    /// before the copy, instead of copying a placeholder.
    static func coordinatedCopy(of url: URL) throws -> URL {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }

    /// True when AVAudioFile opens the file *and* can decode its first samples (a header can parse
    /// fine while the data doesn't).
    static func isDecodable(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
        else { return false }
        do {
            try file.read(into: buffer, frameCount: 4096)
        } catch {
            return false
        }
        return buffer.frameLength > 0
    }

    private static func convertToM4A(_ url: URL, displayName: String) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw AudioImportError.unreadable(fileName: displayName) }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\((displayName as NSString).deletingPathExtension).m4a")
        do {
            try await session.export(to: output, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw AudioImportError.conversionFailed(fileName: displayName, reason: error.localizedDescription)
        }
        guard isDecodable(output) else {
            try? FileManager.default.removeItem(at: output)
            throw AudioImportError.unreadable(fileName: displayName)
        }
        return output
    }
}
