import Foundation
import CryptoKit
import Sentry

/// Simple file-based cache for API responses.
/// Stores JSON data in the app's caches directory with TTL-based expiry.
actor CacheService {
    static let shared = CacheService()

    private let cacheDir: URL
    private let defaultTTL: TimeInterval = 24 * 60 * 60 // 24 hours

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        // Cache v2 — bumped to invalidate bad shared-key entries from pre-rail split
        cacheDir = caches.appendingPathComponent("TMCache-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Clean up old cache dir if it exists
        let oldDir = caches.appendingPathComponent("TMCache", isDirectory: true)
        try? FileManager.default.removeItem(at: oldDir)
    }

    /// Convert a cache key to a filesystem-safe filename.
    /// Keys can exceed the 255-byte APFS filename limit (large POST param sets), which
    /// makes raw-key filenames silently fail to write for exactly the biggest requests —
    /// and naive character stripping can collapse distinct keys into the same name.
    /// A SHA256 digest is stable across launches, unique, and always short; a sanitized
    /// prefix of the key is kept for debuggability when browsing the cache directory.
    private func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        let hint = String(key.prefix(24).map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return "\(hint)-\(hash)"
    }

    /// Get cached data if not expired.
    func get(key: String) -> Data? {
        let fileURL = cacheDir.appendingPathComponent(fileName(for: key))
        let metaURL = cacheDir.appendingPathComponent(fileName(for: key) + ".meta")

        guard FileManager.default.fileExists(atPath: fileURL.path),
              FileManager.default.fileExists(atPath: metaURL.path),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData) else {
            return nil
        }

        // Check expiry
        if Date() > meta.expiresAt {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: metaURL)
            return nil
        }

        return try? Data(contentsOf: fileURL)
    }

    /// Store data with optional custom TTL.
    func set(key: String, data: Data, ttl: TimeInterval? = nil) {
        let fileURL = cacheDir.appendingPathComponent(fileName(for: key))
        let metaURL = cacheDir.appendingPathComponent(fileName(for: key) + ".meta")

        let meta = CacheMeta(
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl ?? defaultTTL)
        )

        // A failed cache write is survivable (we just refetch), but it shouldn't be
        // silent — disk-full or sandbox issues here would otherwise be invisible.
        do {
            try data.write(to: fileURL)
            try JSONEncoder().encode(meta).write(to: metaURL)
        } catch {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "cache_write", key: "cache_operation")
                scope.setExtra(value: key, key: "cache_key")
                scope.setExtra(value: data.count, key: "data_bytes")
            }
        }
    }

    /// Get the age of cached data (when it was stored)
    func getAge(key: String) -> Date? {
        let metaURL = cacheDir.appendingPathComponent(fileName(for: key) + ".meta")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData) else {
            return nil
        }
        return meta.createdAt
    }

    /// Whether an unexpired entry exists for this key, without reading the payload.
    /// Cheap freshness probe for multi-MB entries (e.g. stats CSVs) — only the tiny
    /// .meta sidecar is read.
    func hasFresh(key: String) -> Bool {
        let metaURL = cacheDir.appendingPathComponent(fileName(for: key) + ".meta")
        guard FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(fileName(for: key)).path),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData) else {
            return false
        }
        return Date() <= meta.expiresAt
    }

    /// Clear all cached data.
    func clearAll() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Sweep expired entries off disk. `get()` only removes the file it was asked for,
    /// so abandoned keys (data the user stopped browsing) sit around forever and bloat
    /// both the cache directory and the "Oldest Cache" display in Settings. Call on
    /// app launch to keep things tidy.
    func purgeExpired() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        let now = Date()
        for metaURL in files where metaURL.pathExtension == "meta" {
            guard let metaData = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData)
            else { continue }
            if now > meta.expiresAt {
                let dataURL = metaURL.deletingPathExtension()
                try? FileManager.default.removeItem(at: dataURL)
                try? FileManager.default.removeItem(at: metaURL)
            }
        }
    }

    private struct CacheMeta: Codable {
        let createdAt: Date
        let expiresAt: Date
    }
}
