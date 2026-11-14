import Foundation
import Photos
import UIKit

enum SaveDestination: String, CaseIterable, Identifiable {
    case photoLibrary
    case customFolder
    var id: String { rawValue }
}

enum FolderStatus {
    case none          // no folder chosen
    case available     // bookmark resolves and folder is reachable
    case unavailable   // chosen, but not reachable right now (e.g. USB drive unplugged)
}

struct SaveOutcome {
    var success: Bool
    var savedToFolder: Bool
    var message: String?
}

enum StorageError: LocalizedError {
    case unreachable
    case notWritable
    case libraryDenied

    var errorDescription: String? {
        switch self {
        case .unreachable: return "The folder isn't available."
        case .notWritable: return "The folder isn't writable. Read-only or NTFS drives can't be written to by iOS."
        case .libraryDenied: return "Photo Library access was denied. Enable it in Settings."
        }
    }
}

/// Decides where captured photos/videos go: a user-chosen folder (including folders on a USB drive
/// attached through a Lightning-to-USB adapter) or the Photo Library as a fallback.
final class StorageManager: ObservableObject {
    static let shared = StorageManager()

    private enum Keys {
        static let destination = "saveDestination"
        static let bookmark = "customFolderBookmark"
        static let folderName = "customFolderName"
    }

    private let defaults = UserDefaults.standard

    @Published var destination: SaveDestination {
        didSet { defaults.set(destination.rawValue, forKey: Keys.destination) }
    }
    @Published private(set) var folderName: String?
    @Published private(set) var folderStatus: FolderStatus = .none

    var hasFolder: Bool { defaults.data(forKey: Keys.bookmark) != nil }

    private init() {
        destination = SaveDestination(rawValue: UserDefaults.standard.string(forKey: Keys.destination) ?? "") ?? .photoLibrary
        folderName = UserDefaults.standard.string(forKey: Keys.folderName)
        refreshStatus()
    }

    // MARK: - Folder selection

    /// Called with the URL returned by the folder picker.
    @discardableResult
    func setFolder(_ url: URL) -> Result<Void, Error> {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try testWrite(in: url)
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: Keys.bookmark)
            defaults.set(url.lastPathComponent, forKey: Keys.folderName)
            folderName = url.lastPathComponent
            folderStatus = .available
            destination = .customFolder
            return .success(())
        } catch {
            return .failure(StorageError.notWritable)
        }
    }

    func clearFolder() {
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.folderName)
        folderName = nil
        folderStatus = .none
        if destination == .customFolder { destination = .photoLibrary }
    }

    /// Re-checks whether the chosen folder (e.g. a USB drive) is currently reachable.
    func refreshStatus() {
        DispatchQueue.global(qos: .utility).async {
            let status = self.computeStatus()
            DispatchQueue.main.async { self.folderStatus = status }
        }
    }

    /// URL of the chosen folder, if the bookmark still resolves. Used to open the folder in Files.
    func folderURL() -> URL? { resolveFolder() }

    private func computeStatus() -> FolderStatus {
        guard defaults.data(forKey: Keys.bookmark) != nil else { return .none }
        guard let url = resolveFolder() else { return .unavailable }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return (exists && isDir.boolValue) ? .available : .unavailable
    }

    private func resolveFolder() -> URL? {
        guard let data = defaults.data(forKey: Keys.bookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale {
            let accessing = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Keys.bookmark)
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    // MARK: - Saving

    func savePhoto(data: Data, ext: String, liveMovie: URL?) async -> SaveOutcome {
        let base = Self.timestampName(prefix: "IMG")
        defer { if let l = liveMovie { try? FileManager.default.removeItem(at: l) } }
        return await save(
            folderWrite: { folder in
                try self.writeFile(data, name: "\(base).\(ext)", in: folder)
                if let live = liveMovie {
                    try self.copyFile(live, name: "\(base).mov", in: folder)
                }
            },
            libraryWrite: {
                try await self.addToLibrary(photoData: data, pairedVideo: liveMovie, video: nil)
            }
        )
    }

    func saveVideo(at url: URL) async -> SaveOutcome {
        let name = Self.timestampName(prefix: "VID") + ".mov"
        defer { try? FileManager.default.removeItem(at: url) }
        return await save(
            folderWrite: { folder in
                try self.copyFile(url, name: name, in: folder)
            },
            libraryWrite: {
                try await self.addToLibrary(photoData: nil, pairedVideo: nil, video: url)
            }
        )
    }

    private var currentDestination: SaveDestination {
        SaveDestination(rawValue: defaults.string(forKey: Keys.destination) ?? "") ?? .photoLibrary
    }

    private func save(folderWrite: (URL) throws -> Void,
                      libraryWrite: () async throws -> Void) async -> SaveOutcome {
        var note: String?
        if currentDestination == .customFolder {
            do {
                try withFolder(folderWrite)
                refreshStatus()
                return SaveOutcome(success: true, savedToFolder: true, message: nil)
            } catch {
                refreshStatus()
                note = "Folder not available – saved to Photo Library"
            }
        }
        do {
            try await libraryWrite()
            return SaveOutcome(success: true, savedToFolder: false, message: note)
        } catch {
            return SaveOutcome(success: false, savedToFolder: false,
                               message: "Couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: - Folder I/O

    private func withFolder(_ body: (URL) throws -> Void) throws {
        guard let folder = resolveFolder() else { throw StorageError.unreachable }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw StorageError.unreachable
        }
        try body(folder)
    }

    private func testWrite(in folder: URL) throws {
        let test = folder.appendingPathComponent(".camera_write_test")
        try coordinatedWrite(to: test) { url in
            try Data("ok".utf8).write(to: url)
        }
        try? FileManager.default.removeItem(at: test)
    }

    private func writeFile(_ data: Data, name: String, in folder: URL) throws {
        let dest = uniqueURL(in: folder, name: name)
        try coordinatedWrite(to: dest) { url in
            try data.write(to: url)
        }
    }

    private func copyFile(_ source: URL, name: String, in folder: URL) throws {
        let dest = uniqueURL(in: folder, name: name)
        try coordinatedWrite(to: dest) { url in
            try FileManager.default.copyItem(at: source, to: url)
        }
    }

    private func coordinatedWrite(to dest: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &coordinationError) { url in
            do { try body(url) } catch { innerError = error }
        }
        if let e = coordinationError { throw e }
        if let e = innerError { throw e }
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_\(i)").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }

    // MARK: - Photo Library

    private func addToLibrary(photoData: Data?, pairedVideo: URL?, video: URL?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw StorageError.libraryDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            if let d = photoData { request.addResource(with: .photo, data: d, options: nil) }
            if let v = pairedVideo { request.addResource(with: .pairedVideo, fileURL: v, options: nil) }
            if let v = video { request.addResource(with: .video, fileURL: v, options: nil) }
        }
    }

    private static func timestampName(prefix: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(f.string(from: Date()))"
    }
}
