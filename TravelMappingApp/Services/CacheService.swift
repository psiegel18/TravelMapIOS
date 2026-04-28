import Foundation

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

    /// Get cached data if not expired.
    func get(key: String) -> Data? {
        let fileURL = cacheDir.appendingPathComponent(key.safeFilename)
        let metaURL = cacheDir.appendingPathComponent(key.safeFilename + ".meta")

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
        let fileURL = cacheDir.appendingPathComponent(key.safeFilename)
        let metaURL = cacheDir.appendingPathComponent(key.safeFilename + ".meta")

        let meta = CacheMeta(
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl ?? defaultTTL)
        )

        try? data.write(to: fileURL)
        try? JSONEncoder().encode(meta).write(to: metaURL)
    }

    /// Get the age of cached data (when it was stored)
    func getAge(key: String) -> Date? {
        let metaURL = cacheDir.appendingPathComponent(key.safeFilename + ".meta")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData) else {
            return nil
        }
        return meta.createdAt
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

private extension String {
    /// Convert a cache key to a safe filename.
    var safeFilename: String {
        self.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "'", with: "")
    }
}
