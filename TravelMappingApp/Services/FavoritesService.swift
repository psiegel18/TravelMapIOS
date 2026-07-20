import Foundation
import Combine
import Sentry

/// Manages favorite users with iCloud sync.
/// Uses deletion-wins conflict resolution: if a user is unfavorited on any device,
/// it stays unfavorited across all devices until explicitly re-favorited.
@MainActor
class FavoritesService: ObservableObject {
    static let shared = FavoritesService()

    @Published private(set) var favorites: Set<String> = []
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled")
            if iCloudSyncEnabled {
                loadFromCloud()
            } else {
                loadFromLocal()
            }
        }
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard

    private let favoritesKey = "syncedFavorites"
    private let deletedKey = "deletedFavorites"
    private let localOnlyKey = "localFavorites"
    private let localFavoritesKey = "favoriteUsers" // legacy AppStorage key

    private init() {
        // Default iCloud sync to enabled if never set
        if local.object(forKey: "iCloudSyncEnabled") == nil {
            local.set(true, forKey: "iCloudSyncEnabled")
        }
        self.iCloudSyncEnabled = local.bool(forKey: "iCloudSyncEnabled")

        if iCloudSyncEnabled {
            loadFromCloud()
        } else {
            loadFromLocal()
        }
        migrateFromAppStorage()

        // Listen for iCloud changes from other devices
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud
        )
        cloud.synchronize()
    }

    func isFavorite(_ username: String) -> Bool {
        favorites.contains(username)
    }

    func toggleFavorite(_ username: String) {
        if favorites.contains(username) {
            removeFavorite(username)
        } else {
            addFavorite(username)
        }
    }

    func addFavorite(_ username: String) {
        favorites.insert(username)

        if iCloudSyncEnabled {
            // Remove from deleted set (user explicitly re-favorited)
            var deleted = loadDeletedMap()
            deleted.removeValue(forKey: username)
            saveToCloud(favorites: favorites, deleted: deleted)
        } else {
            saveToLocal()
        }
        SentrySDK.logger.info("Favorite added", attributes: [
            "totalFavorites": favorites.count,
            "iCloudSync": iCloudSyncEnabled,
        ])
        updateProfileContext()
    }

    func removeFavorite(_ username: String) {
        favorites.remove(username)

        if iCloudSyncEnabled {
            // Add to deleted set so other devices know to remove it
            var deleted = loadDeletedMap()
            deleted[username] = Date()
            saveToCloud(favorites: favorites, deleted: deleted)
        } else {
            saveToLocal()
        }
        SentrySDK.logger.info("Favorite removed", attributes: [
            "totalFavorites": favorites.count,
            "iCloudSync": iCloudSyncEnabled,
        ])
        updateProfileContext()
    }

    private func updateProfileContext() {
        let primaryUser = UserDefaults.standard.string(forKey: "primaryUser") ?? ""
        let recents = (UserDefaults.standard.array(forKey: "recentUsers") as? [String]) ?? []
        SentrySDK.configureScope { [favorites] scope in
            scope.setContext(value: [
                "hasPrimaryUser": !primaryUser.isEmpty,
                "favoritesCount": favorites.count,
                "recentUsersCount": recents.count,
            ], key: "profile")
        }
    }

    // MARK: - Private

    /// Tombstones older than this are pruned — they exist only to propagate a deletion
    /// to other devices, which happens well within 30 days. Without pruning they grow
    /// forever against the 1MB NSUbiquitousKeyValueStore quota.
    private static let tombstoneMaxAge: TimeInterval = 30 * 24 * 3600

    private func loadFromCloud() {
        let cloudFavs = Set(cloud.array(forKey: favoritesKey) as? [String] ?? [])
        let cloudDeleted = Set(loadDeletedMap().keys)

        // Favorites = cloud favorites minus anything in the deleted set
        favorites = cloudFavs.subtracting(cloudDeleted)
    }

    private func loadFromLocal() {
        favorites = Set(local.array(forKey: localOnlyKey) as? [String] ?? [])
    }

    private func saveToLocal() {
        local.set(Array(favorites), forKey: localOnlyKey)
    }

    /// Load deletion tombstones as username → deletion date, pruning expired entries.
    /// Gracefully migrates the legacy format (plain [String] with no timestamps) by
    /// stamping those entries with the current date.
    private func loadDeletedMap() -> [String: Date] {
        let raw: [String: Date]
        if let dict = cloud.dictionary(forKey: deletedKey) as? [String: Date] {
            raw = dict
        } else if let legacy = cloud.array(forKey: deletedKey) as? [String] {
            let now = Date()
            raw = Dictionary(legacy.map { ($0, now) }, uniquingKeysWith: { first, _ in first })
        } else {
            raw = [:]
        }
        let cutoff = Date().addingTimeInterval(-Self.tombstoneMaxAge)
        return raw.filter { $0.value > cutoff }
    }

    private func saveToCloud(favorites: Set<String>, deleted: [String: Date]) {
        cloud.set(Array(favorites), forKey: favoritesKey)
        cloud.set(deleted, forKey: deletedKey)
        cloud.synchronize()
    }

    // The KVS notification arrives on an arbitrary thread — the handler must be
    // nonisolated and immediately hop to the main actor before touching state.
    @objc nonisolated private func cloudDidChange(_ notification: Notification) {
        Task { @MainActor in
            // With sync off, remote changes must not merge in (or echo back out)
            guard self.iCloudSyncEnabled else { return }

            let cloudFavs = Set(self.cloud.array(forKey: self.favoritesKey) as? [String] ?? [])
            let deleted = self.loadDeletedMap()

            // Merge: union of favorites from all devices, minus deletions
            let mergedFavs = self.favorites.union(cloudFavs)
            self.favorites = mergedFavs.subtracting(deleted.keys)

            // Only write back when our merge actually adds something — echoing
            // every inbound change back to iCloud causes ping-pong between devices
            if self.favorites != cloudFavs {
                self.saveToCloud(favorites: self.favorites, deleted: deleted)
            }
        }
    }

    /// Migrate from old AppStorage-based favorites (one-time)
    private func migrateFromAppStorage() {
        guard let data = local.data(forKey: localFavoritesKey),
              let oldFavs = try? JSONDecoder().decode(Set<String>.self, from: data),
              !oldFavs.isEmpty else { return }

        // Merge old favorites into cloud (don't override deletions)
        let deleted = loadDeletedMap()
        let newFavs = oldFavs.subtracting(deleted.keys)
        favorites = favorites.union(newFavs)

        // Persist locally FIRST — if iCloud is off or unavailable, the cloud write
        // silently goes nowhere and removing the legacy key below would otherwise
        // permanently lose the user's favorites.
        saveToLocal()
        if iCloudSyncEnabled {
            saveToCloud(favorites: favorites, deleted: deleted)
        }

        // Clear old storage
        local.removeObject(forKey: localFavoritesKey)
    }
}
