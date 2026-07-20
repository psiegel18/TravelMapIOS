import Foundation
import SwiftUI
import Combine
import Sentry

/// Settings that sync across iCloud devices using NSUbiquitousKeyValueStore.
/// Falls back to UserDefaults when iCloud isn't available.
@MainActor
class SyncedSettingsService: ObservableObject {
    static let shared = SyncedSettingsService()

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard

    // MARK: - Published properties

    @Published var primaryUser: String {
        didSet {
            save("primaryUser", primaryUser)
            // Keep widget/watch in sync
            UserDefaults(suiteName: "group.com.psiegel18.TravelMapping")?
                .set(primaryUser, forKey: "widgetUsername")
            UserDefaults.standard.set(primaryUser, forKey: "watchUsername")
            WatchSyncService.shared.syncUsername(primaryUser)
        }
    }
    @Published var useMiles: Bool {
        didSet { save("useMiles", useMiles) }
    }
    @Published var accentColorName: String {
        didSet { save("accentColorName", accentColorName) }
    }
    @Published var roadLineStyle: String {
        didSet { save("roadLineStyle", roadLineStyle) }
    }
    @Published var railLineStyle: String {
        didSet { save("railLineStyle", railLineStyle) }
    }
    @Published var roadLineWidth: Double {
        didSet { save("roadLineWidth", roadLineWidth) }
    }
    @Published var railLineWidth: Double {
        didSet { save("railLineWidth", railLineWidth) }
    }
    /// Opacity of untraveled routes on the map (0.25–1.0). Untraveled lines used to be
    /// faint gray and hard to see; this lets the user dial their prominence.
    @Published var untraveledVisibility: Double {
        didSet { save("untraveledVisibility", untraveledVisibility) }
    }
    @Published var recentUsers: [String] {
        didSet { save("recentUsers", recentUsers) }
    }
    @Published var favoriteRegions: [String] {
        didSet { save("favoriteRegions", favoriteRegions) }
    }

    private init() {
        // Load from iCloud, fall back to local, then defaults
        primaryUser = Self.load("primaryUser") ?? ""
        useMiles = Self.load("useMiles") ?? true
        accentColorName = Self.load("accentColorName") ?? "Blue"
        roadLineStyle = Self.load("roadLineStyle") ?? "Solid"
        railLineStyle = Self.load("railLineStyle") ?? "Dashed"
        roadLineWidth = Self.load("roadLineWidth") ?? 3.0
        railLineWidth = Self.load("railLineWidth") ?? 4.0
        untraveledVisibility = Self.load("untraveledVisibility") ?? 0.8
        recentUsers = Self.load("recentUsers") ?? []
        favoriteRegions = Self.load("favoriteRegions") ?? []

        // Sync cloud → local on external changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud
        )
        cloud.synchronize()
    }

    // MARK: - Recent Users

    func recordRecentUser(_ username: String) {
        var recents = recentUsers
        recents.removeAll { $0 == username }
        recents.insert(username, at: 0)
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        recentUsers = recents
    }

    func clearRecentUsers() {
        recentUsers = []
    }

    // MARK: - Favorite Regions

    func toggleFavoriteRegion(_ region: String) {
        if favoriteRegions.contains(region) {
            favoriteRegions.removeAll { $0 == region }
        } else {
            favoriteRegions.append(region)
        }
    }

    func isFavoriteRegion(_ region: String) -> Bool {
        favoriteRegions.contains(region)
    }

    // MARK: - Private

    private static func load<T>(_ key: String) -> T? {
        let cloud = NSUbiquitousKeyValueStore.default
        let local = UserDefaults.standard
        // Prefer cloud if it has a value, fall back to local
        if let value = cloud.object(forKey: key) as? T {
            return value
        }
        return local.object(forKey: key) as? T
    }

    /// True while applying values that arrived FROM iCloud. The @Published didSets all
    /// call save(), which would echo every inbound change straight back to the cloud
    /// (ping-pong between devices, stale-value clobbering) — so save() skips the cloud
    /// write while this is set, but still mirrors to local UserDefaults.
    private var isApplyingCloudChange = false

    private func save(_ key: String, _ value: Any) {
        local.set(value, forKey: key)
        guard !isApplyingCloudChange else { return }
        cloud.set(value, forKey: key)
        cloud.synchronize()
    }

    // The KVS notification arrives on an arbitrary thread — extract only Sendable
    // values here, then immediately hop to the main actor for all real work.
    @objc nonisolated private func cloudDidChange(_ notification: Notification) {
        let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int ?? -1
        let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        Task { @MainActor in
            self.applyCloudChange(reason: reason, changedKeys: changedKeys)
        }
    }

    private func applyCloudChange(reason: Int, changedKeys: [String]) {
        let reasonName: String = switch reason {
        case NSUbiquitousKeyValueStoreServerChange: "serverChange"
        case NSUbiquitousKeyValueStoreInitialSyncChange: "initialSync"
        case NSUbiquitousKeyValueStoreQuotaViolationChange: "quotaViolation"
        case NSUbiquitousKeyValueStoreAccountChange: "accountChange"
        default: "unknown(\(reason))"
        }
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            SentrySDK.logger.warn("iCloud KVS quota exceeded", attributes: ["changedKeys": changedKeys.joined(separator: ",")])
        } else {
            SentrySDK.logger.info("iCloud sync received", attributes: [
                "reason": reasonName,
                "keyCount": changedKeys.count,
            ])
        }

        // Pull latest values from cloud. Only assign properties whose values actually
        // changed (each assignment fires a didSet), and suppress cloud echo throughout.
        isApplyingCloudChange = true
        defer { isApplyingCloudChange = false }
        if let v: String = Self.load("primaryUser"), v != primaryUser { primaryUser = v }
        if let v: Bool = Self.load("useMiles"), v != useMiles { useMiles = v }
        if let v: String = Self.load("accentColorName"), v != accentColorName { accentColorName = v }
        if let v: String = Self.load("roadLineStyle"), v != roadLineStyle { roadLineStyle = v }
        if let v: String = Self.load("railLineStyle"), v != railLineStyle { railLineStyle = v }
        if let v: Double = Self.load("roadLineWidth"), v != roadLineWidth { roadLineWidth = v }
        if let v: Double = Self.load("railLineWidth"), v != railLineWidth { railLineWidth = v }
        if let v: Double = Self.load("untraveledVisibility"), v != untraveledVisibility { untraveledVisibility = v }
        if let v: [String] = Self.load("recentUsers"), v != recentUsers { recentUsers = v }
        if let v: [String] = Self.load("favoriteRegions"), v != favoriteRegions { favoriteRegions = v }
        syncPreferencesContext()
    }

    func syncPreferencesContext() {
        SentrySDK.configureScope { [primaryUser, useMiles, accentColorName, roadLineStyle, railLineStyle, recentUsers] scope in
            scope.setContext(value: [
                "useMiles": useMiles,
                "sendToWatch": UserDefaults.standard.bool(forKey: "sendToWatch"),
                "accentColor": accentColorName,
                "roadLineStyle": roadLineStyle,
                "railLineStyle": railLineStyle,
            ], key: "preferences")
            scope.setContext(value: [
                "hasPrimaryUser": !primaryUser.isEmpty,
                "favoritesCount": FavoritesService.shared.favorites.count,
                "recentUsersCount": recentUsers.count,
            ], key: "profile")
        }
    }
}
