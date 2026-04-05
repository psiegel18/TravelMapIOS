import Foundation
import Combine

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
            var deleted = loadDeletedSet()
            deleted.remove(username)
            saveToCloud(favorites: favorites, deleted: deleted)
        } else {
            saveToLocal()
        }
    }

    func removeFavorite(_ username: String) {
        favorites.remove(username)

        if iCloudSyncEnabled {
            // Add to deleted set so other devices know to remove it
            var deleted = loadDeletedSet()
            deleted.insert(username)
            saveToCloud(favorites: favorites, deleted: deleted)
        } else {
            saveToLocal()
        }
    }

    // MARK: - Private

    private func loadFromCloud() {
        let cloudFavs = Set(cloud.array(forKey: favoritesKey) as? [String] ?? [])
        let cloudDeleted = Set(cloud.array(forKey: deletedKey) as? [String] ?? [])

        // Favorites = cloud favorites minus anything in the deleted set
        favorites = cloudFavs.subtracting(cloudDeleted)
    }

    private func loadFromLocal() {
        favorites = Set(local.array(forKey: localOnlyKey) as? [String] ?? [])
    }

    private func saveToLocal() {
        local.set(Array(favorites), forKey: localOnlyKey)
    }

    private func loadDeletedSet() -> Set<String> {
        Set(cloud.array(forKey: deletedKey) as? [String] ?? [])
    }

    private func saveToCloud(favorites: Set<String>, deleted: Set<String>) {
        cloud.set(Array(favorites), forKey: favoritesKey)
        cloud.set(Array(deleted), forKey: deletedKey)
        cloud.synchronize()
    }

    @objc private func cloudDidChange(_ notification: Notification) {
        Task { @MainActor in
            let cloudFavs = Set(cloud.array(forKey: favoritesKey) as? [String] ?? [])
            let cloudDeleted = Set(cloud.array(forKey: deletedKey) as? [String] ?? [])

            // Merge: union of favorites from all devices, minus union of deletions
            let mergedFavs = favorites.union(cloudFavs)
            let mergedDeleted = loadDeletedSet().union(cloudDeleted)

            favorites = mergedFavs.subtracting(mergedDeleted)
            saveToCloud(favorites: favorites, deleted: mergedDeleted)
        }
    }

    /// Migrate from old AppStorage-based favorites (one-time)
    private func migrateFromAppStorage() {
        guard let data = local.data(forKey: localFavoritesKey),
              let oldFavs = try? JSONDecoder().decode(Set<String>.self, from: data),
              !oldFavs.isEmpty else { return }

        // Merge old favorites into cloud (don't override deletions)
        let deleted = loadDeletedSet()
        let newFavs = oldFavs.subtracting(deleted)
        favorites = favorites.union(newFavs)
        saveToCloud(favorites: favorites, deleted: deleted)

        // Clear old storage
        local.removeObject(forKey: localFavoritesKey)
    }
}
