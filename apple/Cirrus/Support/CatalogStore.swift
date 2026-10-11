import CirrusKit
import Compression
import Foundation

/// The API catalog: a copy rebuilt from Cloudflare's OpenAPI schema (if the
/// user updated it), else the one bundled with the app. Loaded on first use.
@MainActor @Observable
final class CatalogStore {
    private(set) var catalog: APICatalog?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var refreshing = false

    private static var refreshedFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("catalog.json")
    }

    var usesRefreshed: Bool { FileManager.default.fileExists(atPath: Self.refreshedFile.path) }

    /// The catalog, loading it if needed.
    func load() async -> APICatalog? {
        if let catalog { return catalog }
        if loading {
            while loading { try? await Task.sleep(for: .milliseconds(50)) }
            return catalog
        }
        loading = true
        defer { loading = false }
        let refreshed = Self.refreshedFile
        do {
            catalog = try await Task.detached(priority: .userInitiated) { () throws -> APICatalog in
                if let data = try? Data(contentsOf: refreshed) { return try APICatalog(data: data) }
                guard let url = Bundle.main.url(forResource: "catalog.json", withExtension: "gz"),
                    let gz = try? Data(contentsOf: url), let data = gunzip(gz)
                else { throw SimpleError(L("The API catalog is missing.", "缺少 API 目录。")) }
                return try APICatalog(data: data)
            }.value
            error = nil
        } catch {
            self.error = describe(error)
        }
        return catalog
    }

    /// Downloads the OpenAPI schema and rebuilds the catalog from it.
    func refresh() async throws {
        refreshing = true
        defer { refreshing = false }
        let (data, response) = try await URLSession.shared.data(from: CatalogBuilder.openAPIURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SimpleError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let file = Self.refreshedFile
        let built = try await Task.detached(priority: .userInitiated) { () throws -> APICatalog in
            let doc = try JSON.parse(data)
            let compact = CatalogBuilder.build(doc).encoded()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try compact.write(to: file, options: .atomic)
            return try APICatalog(data: compact)
        }.value
        catalog = built
    }

    func resetToBundled() async {
        try? FileManager.default.removeItem(at: Self.refreshedFile)
        catalog = nil
        _ = await load()
    }
}

/// Decompresses gzip data (RFC 1952) with the Compression framework.
func gunzip(_ data: Data) -> Data? {
    let b = [UInt8](data)
    guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
    let flags = b[3]
    var i = 10
    if flags & 0x04 != 0 { i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
    if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
    if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
    if flags & 0x02 != 0 { i += 2 }
    guard i < b.count - 8 else { return nil }
    let n = b.count
    let size = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
    var out = [UInt8](repeating: 0, count: max(size, 1))
    let written = b.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            compression_decode_buffer(
                dst.baseAddress!, dst.count, src.baseAddress! + i, n - 8 - i, nil, COMPRESSION_ZLIB)
        }
    }
    guard written == size else { return nil }
    return Data(out)
}
