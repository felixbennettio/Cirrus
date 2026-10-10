import Foundation

/// A small JSON file cache that makes start-up instant (accounts, zones):
/// screens render the last known list, then refresh.
public struct DiskCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/cache` of the app.
    public static var standard: DiskCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DiskCache(directory: base.appendingPathComponent("cache", isDirectory: true))
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(SHA256.hex(key) + ".json")
    }

    public func read(_ key: String) -> JSON? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSON.parse(data)
    }

    public func write(_ key: String, _ value: JSON) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? value.encoded().write(to: file(key), options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
